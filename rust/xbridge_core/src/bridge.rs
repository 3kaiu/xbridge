//! Thin C-ABI surface for Android JNI / Swift bindings.
//!
//! These functions are the minimal stable contract between the native host
//! (Android JNI / Swift) and the Rust core. They are intentionally tiny —
//! all heavy lifting lives in the typed Rust API ([`crate::server`]). The
//! ABI functions start a background tokio runtime and stash the running
//! server in a process-global slot.
//!
//! ## Safety
//!
//! - [`xbridge_ws_start`] spawns a background runtime. Callers MUST call
//!   [`xbridge_ws_stop`] exactly once per start to join the runtime.
//! - [`xbridge_ws_set_binary_callback`] stores a raw function pointer; the
//!   pointer MUST remain valid for the lifetime of the server. Passing a
//!   dangling pointer or a function compiled in a different ABI is UB.
//! - The `bytes` pointer passed to the callback points to a buffer owned by
//!   Rust for the duration of the call only — the native side MUST copy
//!   before returning.

use std::sync::OnceLock;

use log::{info, warn};
use tokio::sync::Mutex;

use crate::error::WsError;
use crate::server::{LocalWsServer, RunningServer};

/// Process-global slot holding the running server + its dedicated runtime.
struct GlobalState {
    runtime: tokio::runtime::Runtime,
    server: Option<RunningServer>,
    /// Raw binary callback (JNI/Swift). Stored as an `Option<extern "C" fn>`.
    binary_cb: Option<extern "C" fn(*const u8, usize)>,
}

static GLOBAL: OnceLock<Mutex<GlobalState>> = OnceLock::new();

fn global() -> &'static Mutex<GlobalState> {
    GLOBAL.get_or_init(|| {
        Mutex::new(GlobalState {
            runtime: tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("failed to build xbridge tokio runtime"),
            server: None,
            binary_cb: None,
        })
    })
}

/// Block on a future using the dedicated runtime, avoiding the
/// "Cannot start a runtime from within a runtime" panic when the caller
/// is already inside a tokio runtime.
///
/// - If the caller is NOT inside a tokio runtime, `runtime.block_on(fut)`
///   is safe.
/// - If the caller IS inside a tokio runtime, use `block_in_place` to
///   convert the current worker thread into a blocking thread, then
///   `Handle::block_on` on the dedicated runtime. This avoids the panic
///   that `Runtime::block_on` would cause when called from within a
///   runtime context.
fn block_on_dedicated<F, T>(runtime: &tokio::runtime::Runtime, fut: F) -> T
where
    F: std::future::Future<Output = T>,
{
    match tokio::runtime::Handle::try_current() {
        // We are inside a tokio runtime — block_in_place lets us
        // synchronously block, then we drive the future on the
        // dedicated runtime's handle.
        Ok(_) => {
            tokio::task::block_in_place(|| runtime.handle().block_on(fut))
        }
        // Not inside a tokio runtime — direct block_on is safe.
        Err(_) => runtime.block_on(fut),
    }
}

/// Start the local WS server on `127.0.0.1:port`. If `port == 0` the OS
/// assigns a free port, which is returned (as a positive `i32`). On error
/// returns `-1`.
///
/// Calling start twice without an intervening stop is a no-op: the second
/// call returns the already-bound port without restarting anything.
///
/// # Safety
///
/// This function is safe to call from any thread. It internally manages a
/// process-global tokio runtime. The returned port is valid until
/// [`xbridge_ws_stop`] is called.
#[no_mangle]
pub extern "C" fn xbridge_ws_start(port: u16) -> i32 {
    let g = global();
    // `tokio::sync::Mutex::blocking_lock` returns the guard directly (not a
    // Result — that's `std::sync::Mutex::lock`). Safe because we are calling
    // from a non-async context and the runtime is dedicated.
    let mut state = g.blocking_lock();

    if state.server.is_some() {
        warn!("xbridge_ws_start: server already running, returning existing port");
        return state
            .server
            .as_ref()
            .map(|s| s.actual_port() as i32)
            .unwrap_or(-1);
    }

    // Build the server with default origin allowlist + sink capacity.
    let server_result = block_on_dedicated(&state.runtime, async move {
        LocalWsServer::new().start(port).await
    });

    let server = match server_result {
        Ok(s) => s,
        Err(e) => {
            warn!("xbridge_ws_start: failed to start server: {e}");
            return -1;
        }
    };

    // If a binary callback was registered before start, wire it into the
    // server's sink by spawning a drain task.
    if let Some(cb) = state.binary_cb {
        spawn_callback_drain(&state.runtime, &server, cb);
    }

    let port = server.actual_port() as i32;
    info!("xbridge_ws_start: server bound to 127.0.0.1:{port}");
    state.server = Some(server);
    port
}

/// Stop the local WS server. Returns `0` on success, `-1` if no server is
/// running.
///
/// # Safety
///
/// Safe to call from any thread. Joins the background accept loop.
#[no_mangle]
pub extern "C" fn xbridge_ws_stop() -> i32 {
    let g = global();
    let mut state = g.blocking_lock();

    let server = match state.server.take() {
        Some(s) => s,
        None => {
            warn!("xbridge_ws_stop: no running server");
            return -1;
        }
    };

    let shutdown_result = block_on_dedicated(&state.runtime, async move { server.shutdown().await });
    match shutdown_result {
        Ok(()) => {
            info!("xbridge_ws_stop: server shut down cleanly");
            0
        }
        Err(e) => {
            warn!("xbridge_ws_stop: shutdown error: {e}");
            -1
        }
    }
}

/// Register a callback invoked for every binary frame the server receives.
/// The callback receives a raw pointer + length; the buffer is valid only
/// for the duration of the call.
///
/// # Safety
///
/// `cb` MUST be a valid function pointer that remains callable for the
/// lifetime of the server. Passing `None` (represented as a null pointer at
/// the ABI level by callers passing zero) unregisters the callback.
#[no_mangle]
pub unsafe extern "C" fn xbridge_ws_set_binary_callback(
    cb: Option<extern "C" fn(*const u8, usize)>,
) -> i32 {
    let g = global();
    let mut state = g.blocking_lock();

    state.binary_cb = cb;

    // If the server is already running, wire the callback by spawning a
    // drain task on the existing server.
    if let (Some(cb), Some(server)) = (cb, state.server.as_ref()) {
        spawn_callback_drain(&state.runtime, server, cb);
    }

    0
}

/// Spawn a task on the given runtime that drains the server's sink and
/// forwards each `Vec<u8>` to the C callback. The buffer's memory is owned
/// by the `Vec`; we pass a pointer to its contents and let the `Vec` drop
/// after the callback returns — so the native side must not retain the
/// pointer past return.
fn spawn_callback_drain(
    runtime: &tokio::runtime::Runtime,
    server: &RunningServer,
    cb: extern "C" fn(*const u8, usize),
) {
    let (_sink, mut rx) = server.subscribe_receiver();
    runtime.spawn(async move {
        while let Some(bytes) = rx.recv().await {
            let len = bytes.len();
            let ptr = bytes.as_ptr();
            // Invoke the C callback. The pointer is valid until this fn
            // returns because `bytes` still owns the allocation.
            cb(ptr, len);
            // `bytes` drops here, freeing the allocation.
        }
    });
}

/// Convenience Rust-native helper exposed for tests / embedded use that
/// prefer to avoid the global C-ABI slot. Starts a fresh server on the
/// caller's runtime. Equivalent to [`LocalWsServer::start`].
pub async fn start_server(port: u16) -> Result<RunningServer, WsError> {
    LocalWsServer::new().start(port).await
}
