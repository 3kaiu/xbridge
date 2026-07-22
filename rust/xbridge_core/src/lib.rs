//! # xbridge_core
//!
//! High-performance Local WebSocket Server for the XBridge cross-platform bridge SDK.
//!
//! ## Purpose
//!
//! Provides a loopback-only (`127.0.0.1`) WebSocket server that lets the H5 layer
//! stream large binary payloads (e.g. `STREAMING_AUDIO_DATA`, digital-human video
//! frames) directly to a native subscriber — **bypassing the JS bridge channel
//! entirely**. Binary frames travel as `Vec<u8>` ownership transfers with zero
//! Base64 / JSON encoding of the payload (PRD §1.2.4, audit Risk 2).
//!
//! Only **control** frames (subscribe / unsubscribe / ping) are JSON text; the
//! data plane is raw binary.
//!
//! ## Modules
//!
//! - [`error`] — `WsError` error enum.
//! - [`handler`] — per-connection callbacks (`ConnectionHandler`).
//! - [`sink`] — pub/sub fan-out via `mpsc::Sender<Vec<u8>>` (`DataSink`).
//! - [`server`] — `LocalWsServer` + `RunningServer` (accept loop, origin check).
//! - [`control`] — generic `ControlMessage` / `ControlResponse`.
//! - [`bridge`] — thin C-ABI for Android JNI / Swift bindings.

pub mod bridge;
pub mod control;
pub mod error;
pub mod handler;
pub mod server;
pub mod sink;

pub use bridge::{
    xbridge_ws_set_binary_callback, xbridge_ws_start, xbridge_ws_stop,
};
pub use control::{ControlMessage, ControlResponse};
pub use error::WsError;
pub use handler::{ConnectionHandler, ConnectionHandlerBuilder};
pub use server::{LocalWsServer, RunningServer};
pub use sink::DataSink;

/// Maximum number of concurrent WS connections the local server will accept.
/// Loopback-only server is not designed for high fan-out; cap protects against
/// accidental resource exhaustion.
pub const MAX_CONCURRENT_CONNECTIONS: usize = 8;

/// Default per-subscriber channel capacity. When full the server drops the frame
/// and logs a warning (backpressure policy, PRD §1.2.4).
pub const DEFAULT_SINK_CAPACITY: usize = 256;
