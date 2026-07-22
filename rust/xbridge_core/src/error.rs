//! Error type for the XBridge local WebSocket server.
//!
//! All variants map to a stable stringified [`Display`](thiserror::Error) form so
//! that C-ABI consumers (Android JNI / Swift) can read the reason via
//! `to_string()` without depending on Rust's error trait graph.

use std::io;

/// Errors emitted by [`crate::server::LocalWsServer`].
///
/// `code` is intentionally numeric-friendly so the C-ABI layer can translate
/// losslessly (see [`crate::bridge`]).
#[derive(thiserror::Error, Debug)]
#[allow(clippy::result_large_err)]
pub enum WsError {
    /// Binding the listener to `127.0.0.1:port` failed (port in use, etc.).
    #[error("bind failed: {0}")]
    Bind(#[from] io::Error),

    /// Accepting a new TCP connection failed.
    #[error("accept failed: {0}")]
    Accept(io::Error),

    /// The WebSocket handshake (HTTP upgrade) failed — either the peer sent
    /// a malformed request or the origin was forbidden (in which case we
    /// returned a 403 and the client aborted).
    #[error("ws handshake failed: {0}")]
    Handshake(#[from] tokio_tungstenite::tungstenite::Error),

    /// Graceful shutdown encountered an internal error.
    #[error("shutdown failed")]
    Shutdown,

    /// Connection limit (`MAX_CONCURRENT_CONNECTIONS`) reached; new conn rejected.
    #[error("connection limit reached")]
    ConnectionLimit,

    /// Origin header missing or not in the allowlist / loopback set.
    #[error("origin forbidden: {origin}")]
    OriginForbidden { origin: String },

    /// An attempt was made to operate on a server that is not running.
    #[error("server not running")]
    NotRunning,

    /// Subscriber channel capacity exceeded; frame dropped (backpressure).
    /// Surfaced only when a caller explicitly awaits a send result.
    #[error("subscriber channel full, frame dropped")]
    ChannelFull,

    /// Generic internal error not covered by the variants above.
    #[error("internal error: {0}")]
    Internal(String),
}

impl WsError {
    /// Stable numeric code for the C-ABI layer (see [`crate::bridge`]).
    ///
    /// Order MUST NOT change once published — ABI stability contract.
    pub fn code(&self) -> i32 {
        match self {
            WsError::Bind(_) => 1,
            WsError::Accept(_) => 2,
            WsError::Shutdown => 3,
            WsError::ConnectionLimit => 4,
            WsError::OriginForbidden { .. } => 5,
            WsError::NotRunning => 6,
            WsError::ChannelFull => 7,
            WsError::Handshake(_) => 8,
            WsError::Internal(_) => 99,
        }
    }
}
