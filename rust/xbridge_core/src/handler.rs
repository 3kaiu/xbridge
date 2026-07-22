//! Per-connection callbacks and the connection accept/handle loop.
//!
//! The handler bundles four stateless callbacks (`on_connect`, `on_disconnect`,
//! `on_binary`, `on_text`) so a single `Arc<ConnectionHandler>` can be shared
//! across every accepted connection — no per-connection allocation beyond the
//! connection task itself.

use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use log::{debug, warn};
use tokio_tungstenite::tungstenite::protocol::Message;
use tokio_tungstenite::WebSocketStream;

/// Bundle of callbacks invoked by [`handle_connection`] for each connection
/// lifecycle event.
///
/// All callbacks are `Send + Sync + 'static` so they can be shared via `Arc`
/// across the per-connection tokio tasks spawned by the accept loop. Business
/// logic stays out: this struct only routes raw frames; meaning-making belongs
/// to the subscriber (see [`crate::sink::DataSink`]).
pub struct ConnectionHandler {
    /// Invoked for every binary frame. Receives owned `Vec<u8>` — no copy.
    pub on_binary: Box<dyn Fn(Vec<u8>) + Send + Sync>,
    /// Invoked for every text frame (control messages, JSON-encoded).
    pub on_text: Box<dyn Fn(String) + Send + Sync>,
    /// Invoked once when the WS handshake completes.
    pub on_connect: Box<dyn Fn() + Send + Sync>,
    /// Invoked once when the connection closes (clean or error).
    pub on_disconnect: Box<dyn Fn() + Send + Sync>,
}

impl std::fmt::Debug for ConnectionHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionHandler")
            .field("on_binary", &"<fn>")
            .field("on_text", &"<fn>")
            .field("on_connect", &"<fn>")
            .field("on_disconnect", &"<fn>")
            .finish()
    }
}

/// Ergonomic builder for [`ConnectionHandler`]. Avoids enormous positional
/// `Box::new(...)` call sites.
#[derive(Default)]
pub struct ConnectionHandlerBuilder {
    on_binary: Option<Box<dyn Fn(Vec<u8>) + Send + Sync>>,
    on_text: Option<Box<dyn Fn(String) + Send + Sync>>,
    on_connect: Option<Box<dyn Fn() + Send + Sync>>,
    on_disconnect: Option<Box<dyn Fn() + Send + Sync>>,
}

impl ConnectionHandlerBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn on_binary<F>(mut self, f: F) -> Self
    where
        F: Fn(Vec<u8>) + Send + Sync + 'static,
    {
        self.on_binary = Some(Box::new(f));
        self
    }

    pub fn on_text<F>(mut self, f: F) -> Self
    where
        F: Fn(String) + Send + Sync + 'static,
    {
        self.on_text = Some(Box::new(f));
        self
    }

    pub fn on_connect<F>(mut self, f: F) -> Self
    where
        F: Fn() + Send + Sync + 'static,
    {
        self.on_connect = Some(Box::new(f));
        self
    }

    pub fn on_disconnect<F>(mut self, f: F) -> Self
    where
        F: Fn() + Send + Sync + 'static,
    {
        self.on_disconnect = Some(Box::new(f));
        self
    }

    pub fn build(self) -> ConnectionHandler {
        ConnectionHandler {
            on_binary: self.on_binary.unwrap_or_else(|| Box::new(|_| {})),
            on_text: self.on_text.unwrap_or_else(|| Box::new(|_| {})),
            on_connect: self.on_connect.unwrap_or_else(|| Box::new(|| {})),
            on_disconnect: self.on_disconnect.unwrap_or_else(|| Box::new(|| {})),
        }
    }
}

/// Drive a single WebSocket connection to completion.
///
/// Loops over `stream.next()` forwarding each frame to the matching callback.
/// Binary frames arrive as owned `Vec<u8>` — the value is moved into the
/// callback, no copy. Text frames are interpreted as JSON control messages
/// (see [`crate::control`]) but the raw string is still forwarded verbatim so
/// downstream subscribers may decode once and reuse.
///
/// The function returns when the peer closes the socket or any error occurs.
/// It never panics: handler exceptions are not possible in safe Rust (the
/// callbacks are plain `Fn` closures; if they panic, the connection task
/// aborts but the server keeps running because each connection is isolated in
/// its own `tokio::spawn` task).
pub async fn handle_connection<S>(stream: WebSocketStream<S>, handler: Arc<ConnectionHandler>)
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut ws_stream = stream;

    (handler.on_connect)();

    while let Some(msg) = ws_stream.next().await {
        match msg {
            Ok(Message::Binary(bytes)) => {
                // ownership transfer, zero copy
                (handler.on_binary)(bytes);
            }
            Ok(Message::Text(text)) => {
                (handler.on_text)(text);
            }
            Ok(Message::Ping(payload)) => {
                // Respond with pong — tungstenite auto-responds in
                // most configs, but be explicit so keepalives work
                // even when auto-respond is disabled.
                let _ = ws_stream.send(Message::Pong(payload)).await;
            }
            Ok(Message::Pong(_)) => {
                // ignore; keepalive acknowledgement
            }
            Ok(Message::Close(_)) => {
                debug!("ws connection closed by peer");
                break;
            }
            Ok(Message::Frame(_)) => {
                // Raw frame — tungstenite handles internally; ignore.
            }
            Err(e) => {
                warn!("ws connection error: {e}");
                break;
            }
        }
    }

    (handler.on_disconnect)();
}
