//! The local WebSocket server: accept loop, origin check, pub/sub wiring.
//!
//! ## Security invariants
//!
//! 1. **Loopback only**: the listener binds to `127.0.0.1` — never `0.0.0.0`.
//!    No off-device traffic can reach the server.
//! 2. **Origin allowlist**: the WebSocket handshake `Origin` header is checked
//!    against a set of trusted origins. Allowed defaults: `http://127.0.0.1`,
//!    `http://localhost`, and `file://` (local file:// WebViews are common in
//!    hybrid apps). Anything else is rejected with HTTP 403 before the WS
//!    upgrade completes.
//! 3. **Connection cap**: [`MAX_CONCURRENT_CONNECTIONS`] bounds concurrency;
//!    excess connections are dropped immediately.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use log::{debug, info, warn};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinSet;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::{HeaderValue, StatusCode};

use crate::error::WsError;
use crate::handler::{handle_connection, ConnectionHandler};
use crate::sink::{DataSink, SinkRegistry};
use crate::MAX_CONCURRENT_CONNECTIONS;

/// A configured-but-not-yet-running local WS server. Call [`start`](Self::start)
/// to bind and obtain a [`RunningServer`].
#[derive(Debug, Default)]
pub struct LocalWsServer {
    /// Optional custom origin allowlist. When `None` the loopback defaults
    /// apply (see module docs).
    allowed_origins: Option<Vec<String>>,
    /// Per-subscriber channel capacity override.
    sink_capacity: Option<usize>,
    /// Whether to accept connections with no `Origin` header (e.g. non-browser
    /// clients). Defaults to `false` for security.
    allow_missing_origin: bool,
}

impl LocalWsServer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Restrict the `Origin` header to this exact set. Pass an empty set to
    /// deny all origins (the server will reject every connection).
    pub fn with_allowed_origins(mut self, origins: Vec<String>) -> Self {
        self.allowed_origins = Some(origins);
        self
    }

    /// Override the per-subscriber channel capacity (default
    /// [`DEFAULT_SINK_CAPACITY`](crate::DEFAULT_SINK_CAPACITY)).
    pub fn with_sink_capacity(mut self, cap: usize) -> Self {
        self.sink_capacity = Some(cap);
        self
    }

    /// Allow connections that omit the `Origin` header (e.g. raw WebSocket
    /// clients). Defaults to `false` — missing origins are rejected.
    pub fn with_allow_missing_origin(mut self, allow: bool) -> Self {
        self.allow_missing_origin = allow;
        self
    }

    /// Bind to `127.0.0.1:port` and start accepting. If `port == 0` the OS
    /// assigns a free port; the actual port is returned via [`RunningServer::actual_port`].
    pub async fn start(self, port: u16) -> Result<RunningServer, WsError> {
        let addr = SocketAddr::from(([127, 0, 0, 1], port));
        let listener = TcpListener::bind(addr).await?;

        let actual_port = listener.local_addr().map_err(WsError::Bind)?.port();
        info!("xbridge local ws server listening on 127.0.0.1:{actual_port}");

        let registry = Arc::new(SinkRegistry::new());
        let sink_capacity = self.sink_capacity;
        let allow_missing_origin = self.allow_missing_origin;
        let handler = Arc::new(self.build_handler(Arc::clone(&registry)));
        let allowed_origins = Arc::new(
            self.allowed_origins
                .unwrap_or_else(default_allowed_origins),
        );

        let shutdown_notify = Arc::new(tokio::sync::Notify::new());
        let shutdown_for_task = Arc::clone(&shutdown_notify);

        let conn_counter = Arc::new(AtomicUsize::new(0usize));

        let join = tokio::spawn(async move {
            let mut tasks: JoinSet<()> = JoinSet::new();
            loop {
                tokio::select! {
                    accept = listener.accept() => {
                        let (stream, _peer) = match accept {
                            Ok(s) => s,
                            Err(e) => {
                                warn!("accept error: {e}");
                                // Transient accept failure — keep looping so a
                                // single bad socket doesn't kill the server.
                                continue;
                            }
                        };

                        // Enforce connection cap using a CAS loop.
                        let mut stream = Some(stream);
                        let mut rejected = false;
                        loop {
                            let current = conn_counter.load(Ordering::SeqCst);
                            if current >= MAX_CONCURRENT_CONNECTIONS {
                                warn!("connection limit reached, rejecting");
                                // Drop the stream to close the socket.
                                stream.take();
                                rejected = true;
                                break;
                            }
                            match conn_counter.compare_exchange(
                                current,
                                current + 1,
                                Ordering::SeqCst,
                                Ordering::SeqCst,
                            ) {
                                Ok(_) => break,
                                Err(_) => continue, // retry CAS
                            }
                        }
                        if rejected {
                            continue;
                        }
                        // stream is guaranteed Some here (not rejected, not taken).
                        let stream = stream.take().expect("stream must be Some when not rejected");

                        let cnt = Arc::clone(&conn_counter);
                        let h = Arc::clone(&handler);
                        let origins = Arc::clone(&allowed_origins);
                        let allow_missing = allow_missing_origin;

                        tasks.spawn(async move {
                            // Decrement counter on exit via RAII guard.
                            let _guard = ConnGuard(cnt);
                            match upgrade_handshake(stream, origins, allow_missing).await {
                                Ok(ws_stream) => {
                                    handle_connection(ws_stream, h).await;
                                }
                                Err(e) => {
                                    warn!("ws handshake rejected: {e}");
                                }
                            }
                        });
                    }
                    _ = shutdown_for_task.notified() => {
                        info!("xbridge local ws server shutting down");
                        // Abort all per-connection tasks.
                        tasks.abort_all();
                        // Wait for them to finish.
                        while tasks.join_next().await.is_some() {}
                        break;
                    }
                }
            }
        });

        Ok(RunningServer {
            actual_port,
            join_handle: join,
            shutdown_notify,
            registry,
            sink_capacity,
        })
    }

    fn build_handler(&self, registry: Arc<SinkRegistry>) -> ConnectionHandler {
        let r = Arc::clone(&registry);
        crate::handler::ConnectionHandlerBuilder::new()
            .on_binary(move |bytes: Vec<u8>| {
                r.publish(bytes);
            })
            .on_text(move |text: String| {
                debug!("ws text frame (control): {text}");
                // Control frames are JSON; a full decode/route lives in the
                // higher layer. Here we just log. The data plane is binary.
            })
            .on_connect(|| {
                debug!("ws connection accepted");
            })
            .on_disconnect(|| {
                debug!("ws connection closed");
            })
            .build()
    }
}

/// RAII guard that decrements the connection counter on drop.
struct ConnGuard(Arc<AtomicUsize>);

impl Drop for ConnGuard {
    fn drop(&mut self) {
        // Use atomic fetch_sub — no async, no spawn, no lock needed.
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// A running local WS server. Hold this value to keep the server alive; drop
/// or call [`shutdown`](Self::shutdown) to stop.
pub struct RunningServer {
    /// The actual port the OS bound (useful when `port=0` was requested).
    pub actual_port: u16,
    pub(crate) join_handle: tokio::task::JoinHandle<()>,
    pub(crate) shutdown_notify: Arc<tokio::sync::Notify>,
    pub(crate) registry: Arc<SinkRegistry>,
    pub(crate) sink_capacity: Option<usize>,
}

impl RunningServer {
    /// The bound port. When `0` was requested at [`LocalWsServer::start`],
    /// this reflects the OS-assigned port.
    pub fn actual_port(&self) -> u16 {
        self.actual_port
    }

    /// Subscribe and obtain both the [`DataSink`] (sender) and the matching
    /// `Receiver`. The receiver should be drained in a dedicated task;
    /// otherwise backpressure drops frames.
    pub fn subscribe_receiver(
        &self,
    ) -> (
        DataSink,
        tokio::sync::mpsc::Receiver<Vec<u8>>,
    ) {
        let cap = self
            .sink_capacity
            .unwrap_or(crate::DEFAULT_SINK_CAPACITY);
        let (tx, rx) = tokio::sync::mpsc::channel::<Vec<u8>>(cap);
        if let Ok(mut v) = self.registry.sinks.lock() {
            v.push(tx.clone());
        }
        (DataSink { tx }, rx)
    }

    /// Current number of subscribers (approximate; may include dead senders
    /// not yet pruned).
    pub fn subscriber_count(&self) -> usize {
        self.registry.len()
    }

    /// Graceful shutdown. Notifies the accept loop, aborts all per-connection
    /// tasks, and waits for the accept loop to finish.
    pub async fn shutdown(self) -> Result<(), WsError> {
        // `notify_one()` stores a permit so even if the accept loop is
        // currently parked on `listener.accept()`, the next iteration's
        // `notified()` will fire immediately.
        self.shutdown_notify.notify_one();
        // Wait for the accept loop to finish (it aborts and joins all
        // per-connection tasks internally).
        self.join_handle.await.map_err(|_| WsError::Shutdown)?;
        Ok(())
    }
}

/// Default origin allowlist: loopback http(s) and `file://` schemes.
fn default_allowed_origins() -> Vec<String> {
    vec![
        "http://127.0.0.1".into(),
        "http://localhost".into(),
        "https://127.0.0.1".into(),
        "https://localhost".into(),
        "file://".into(),
    ]
}

/// Perform the WebSocket handshake, rejecting forbidden origins BEFORE the
/// upgrade completes.
async fn upgrade_handshake(
    stream: TcpStream,
    allowed: Arc<Vec<String>>,
    allow_missing_origin: bool,
) -> Result<tokio_tungstenite::WebSocketStream<TcpStream>, WsError> {
    let cb = OriginCallback {
        allowed,
        allow_missing_origin,
    };
    let ws = tokio_tungstenite::accept_hdr_async(stream, cb).await?;
    Ok(ws)
}

/// Handshake callback struct implementing `tungstenite::handshake::server::Callback`.
/// Using a named struct (instead of a closure) lets the compiler infer the
/// higher-ranked lifetime bound on `&Request` — closures that capture by move
/// pin a specific lifetime and fail HRTB inference.
struct OriginCallback {
    allowed: Arc<Vec<String>>,
    allow_missing_origin: bool,
}

impl tokio_tungstenite::tungstenite::handshake::server::Callback for OriginCallback {
    fn on_request(
        self,
        req: &Request,
        resp: Response,
    ) -> Result<
        Response,
        tokio_tungstenite::tungstenite::handshake::server::ErrorResponse,
    > {
        check_origin(req, resp, &self.allowed, self.allow_missing_origin)
    }
}

/// Callback invoked by tungstenite during the handshake. Returns `Err(response)`
/// (a `Response<Option<String>>` with a 403 status) when the origin is not
/// allowed; tungstenite then aborts the handshake and the TCP socket is
/// dropped. On success returns `Ok(response)` with the (possibly amended)
/// upgrade response.
#[allow(clippy::result_large_err)]
fn check_origin(
    req: &Request,
    resp: Response,
    allowed: &[String],
    allow_missing_origin: bool,
) -> Result<Response, tokio_tungstenite::tungstenite::handshake::server::ErrorResponse> {
    let origin = req
        .headers()
        .get("Origin")
        .map(HeaderValue::to_str)
        .and_then(|r| r.ok())
        .map(|s| s.to_string());

    let ok = match origin {
        Some(ref o) => {
            if allowed.iter().any(|a| a == "*" || a == "null") {
                true
            } else {
                allowed.iter().any(|a| {
                    if a.ends_with('/') {
                        o.starts_with(a.as_str())
                    } else {
                        o == a
                            || o.starts_with(&format!("{a}/"))
                            || o.starts_with(&format!("{a}:"))
                    }
                })
            }
        }
        // No Origin header: reject by default for security. Callers who
        // need to accept non-browser clients (e.g. raw WebSocket clients)
        // must explicitly set `allow_missing_origin = true`.
        None => allow_missing_origin,
    };

    if !ok {
        let origin_dbg = origin.unwrap_or_else(|| "<missing>".into());
        warn!("ws handshake rejected: forbidden origin {origin_dbg}");
        return Err(reject_response(&origin_dbg));
    }
    Ok(resp)
}

/// Build a 403 `ErrorResponse` carrying a short rejection reason as the body.
fn reject_response(reason: &str) -> tokio_tungstenite::tungstenite::handshake::server::ErrorResponse {
    tokio_tungstenite::tungstenite::http::Response::builder()
        .status(StatusCode::FORBIDDEN)
        .body(Some(format!("origin forbidden: {reason}")))
        .unwrap_or_else(|_| {
            tokio_tungstenite::tungstenite::http::Response::new(Some(
                "403 Forbidden".to_string(),
            ))
        })
}

impl std::fmt::Debug for RunningServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RunningServer")
            .field("actual_port", &self.actual_port)
            .field("subscriber_count", &self.subscriber_count())
            .finish()
    }
}
