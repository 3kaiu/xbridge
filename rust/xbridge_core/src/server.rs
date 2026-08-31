//! The local WebSocket server: accept loop, origin check, pub/sub wiring.
//!
//! ## Security invariants
//!
//! 1. **Loopback only**: the listener binds to `127.0.0.1` — never `0.0.0.0`.
//!    No off-device traffic can reach the server.
//! 2. **Origin allowlist**: the WebSocket handshake `Origin` header is checked
//!    against a set of trusted origins. Allowed defaults: `http://127.0.0.1`,
//!    `http://localhost`. `file://` is NOT included by default — add it
//!    explicitly via `with_allowed_origins` if needed. Anything else is
//!    rejected with HTTP 403 before the WS upgrade completes.
//! 3. **Connection cap**: [`MAX_CONCURRENT_CONNECTIONS`] bounds concurrency;
//!    excess connections are dropped immediately.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use log::{debug, info, warn};
use rand::RngCore;
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinSet;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::{HeaderValue, StatusCode};

use crate::error::WsError;
use crate::handler::{handle_connection, ConnectionHandler};
use crate::sink::{DataSink, SinkRegistry};
use crate::MAX_CONCURRENT_CONNECTIONS;

/// In-memory dynamic ticket storage for zero-trust session authentication.
#[derive(Debug, Default)]
pub struct TicketStore {
    tickets: Mutex<HashMap<String, Instant>>,
}

impl TicketStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Issue an ephemeral ticket valid for `ttl`.
    pub fn issue(&self, ttl: Duration) -> String {
        let mut bytes = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut bytes);
        let ticket = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
        let expires_at = Instant::now() + ttl;
        if let Ok(mut map) = self.tickets.lock() {
            let now = Instant::now();
            map.retain(|_, exp| *exp > now);
            map.insert(ticket.clone(), expires_at);
        }
        ticket
    }

    /// Validate and atomically consume a ticket (single use).
    /// Returns `true` if the ticket was valid and not expired.
    pub fn consume(&self, ticket: &str) -> bool {
        if let Ok(mut map) = self.tickets.lock() {
            if let Some(expires_at) = map.remove(ticket) {
                return Instant::now() <= expires_at;
            }
        }
        false
    }

    /// Returns the count of active tickets currently in the store.
    pub fn len(&self) -> usize {
        if let Ok(map) = self.tickets.lock() {
            map.len()
        } else {
            0
        }
    }

    /// Returns whether the ticket store is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

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
    /// Whether to require a valid one-time ticket during the handshake.
    require_ticket: bool,
    /// Custom ticket store if shared or pre-configured.
    ticket_store: Option<Arc<TicketStore>>,
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

    /// Enforce one-time dynamic ticket verification during the WebSocket handshake.
    pub fn with_ticket_auth(mut self, require: bool) -> Self {
        self.require_ticket = require;
        self
    }

    /// Use a specific shared [`TicketStore`].
    pub fn with_ticket_store(mut self, store: Arc<TicketStore>) -> Self {
        self.ticket_store = Some(store);
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
        let require_ticket = self.require_ticket;
        let ticket_store = self
            .ticket_store
            .clone()
            .unwrap_or_else(|| Arc::new(TicketStore::new()));
        let handler = Arc::new(self.build_handler(Arc::clone(&registry)));
        let allowed_origins = Arc::new(
            self.allowed_origins
                .unwrap_or_else(default_allowed_origins),
        );

        let shutdown_notify = Arc::new(tokio::sync::Notify::new());
        let shutdown_for_task = Arc::clone(&shutdown_notify);

        let conn_counter = Arc::new(AtomicUsize::new(0usize));
        let ticket_store_for_task = Arc::clone(&ticket_store);

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
                        let store = Arc::clone(&ticket_store_for_task);
                        let need_ticket = require_ticket;

                        tasks.spawn(async move {
                            // Decrement counter on exit via RAII guard.
                            let _guard = ConnGuard(cnt);
                            match upgrade_handshake(stream, origins, allow_missing, store, need_ticket).await {
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
            join_handle: Some(join),
            shutdown_notify,
            registry,
            sink_capacity,
            ticket_store,
        })
    }

    fn build_handler(&self, registry: Arc<SinkRegistry>) -> ConnectionHandler {
        let r = Arc::clone(&registry);
        crate::handler::ConnectionHandlerBuilder::new()
            .on_binary(move |bytes: Vec<u8>| {
                r.publish(bytes);
            })
            .on_text(move |text: String| {
                debug!("ws text frame received: {text}");
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
        // Saturating decrement: if the counter is already 0 (shouldn't happen
        // in normal operation), do nothing instead of wrapping to usize::MAX.
        loop {
            let current = self.0.load(Ordering::SeqCst);
            if current == 0 {
                break;
            }
            match self.0.compare_exchange(
                current,
                current - 1,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break,
                Err(_) => continue,
            }
        }
    }
}

/// A running local WS server. Hold this value to keep the server alive; drop
/// or call [`shutdown`](Self::shutdown) to stop.
///
/// # Drop behavior
///
/// Dropping `RunningServer` without calling `shutdown()` will trigger the
/// `Drop` implementation which notifies the accept loop to shut down.
/// However, the `Drop` impl cannot `.await` the join handle (dropping is
/// synchronous), so it only signals shutdown — the accept loop finishes
/// asynchronously. For a guaranteed clean shutdown, call `shutdown().await`.
pub struct RunningServer {
    /// The actual port the OS bound (useful when `port=0` was requested).
    pub actual_port: u16,
    pub(crate) join_handle: Option<tokio::task::JoinHandle<()>>,
    pub(crate) shutdown_notify: Arc<tokio::sync::Notify>,
    pub(crate) registry: Arc<SinkRegistry>,
    pub(crate) sink_capacity: Option<usize>,
    pub(crate) ticket_store: Arc<TicketStore>,
}

impl Drop for RunningServer {
    fn drop(&mut self) {
        self.shutdown_notify.notify_one();
        if let Some(handle) = self.join_handle.take() {
            handle.abort();
        }
    }
}

impl RunningServer {
    /// The bound port. When `0` was requested at [`LocalWsServer::start`],
    /// this reflects the OS-assigned port.
    pub fn actual_port(&self) -> u16 {
        self.actual_port
    }

    /// Issue an ephemeral one-time authentication ticket valid for `ttl`.
    pub fn issue_ticket(&self, ttl: Duration) -> String {
        self.ticket_store.issue(ttl)
    }

    /// Access the underlying [`TicketStore`].
    pub fn ticket_store(&self) -> Arc<TicketStore> {
        Arc::clone(&self.ticket_store)
    }

    /// Subscribe and obtain both the [`DataSink`] (sender) and the matching
    /// `Receiver`. The receiver should be drained in a dedicated task;
    /// otherwise backpressure drops frames.
    ///
    /// The `DataSink` holds the **only** sender clone outside the registry.
    /// When it is dropped, the sender is closed and the registry prunes the
    /// slot on the next `publish()` call.
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
    pub async fn shutdown(mut self) -> Result<(), WsError> {
        self.shutdown_notify.notify_one();
        if let Some(handle) = self.join_handle.take() {
            handle.await.map_err(|_| WsError::Shutdown)?;
        }
        Ok(())
    }
}

/// Default origin allowlist: loopback http(s) and `file://` schemes.
/// Default allowed origins for the loopback WS server.
///
/// `file://` is **not** included by default for security — a malicious local
/// file loaded in a WebView would pass the origin check. Apps that need
/// `file://` support should add it explicitly via `with_allowed_origins`.
fn default_allowed_origins() -> Vec<String> {
    vec![
        "http://127.0.0.1".into(),
        "http://localhost".into(),
        "https://127.0.0.1".into(),
        "https://localhost".into(),
    ]
}

/// Maximum WebSocket message size (16 MiB). Prevents memory exhaustion from
/// oversized frames on the loopback connection.
const MAX_WS_MESSAGE_SIZE: usize = 16 << 20;

/// Perform the WebSocket handshake, rejecting forbidden origins or unauthenticated
/// tickets BEFORE the upgrade completes.
async fn upgrade_handshake(
    stream: TcpStream,
    allowed: Arc<Vec<String>>,
    allow_missing_origin: bool,
    ticket_store: Arc<TicketStore>,
    require_ticket: bool,
) -> Result<tokio_tungstenite::WebSocketStream<TcpStream>, WsError> {
    let cb = HandshakeCallback {
        allowed,
        allow_missing_origin,
        ticket_store,
        require_ticket,
    };
    let config = Some(tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
        max_message_size: Some(MAX_WS_MESSAGE_SIZE),
        ..Default::default()
    });
    let ws = tokio_tungstenite::accept_hdr_async_with_config(stream, cb, config).await?;
    Ok(ws)
}

/// Handshake callback struct implementing `tungstenite::handshake::server::Callback`.
struct HandshakeCallback {
    allowed: Arc<Vec<String>>,
    allow_missing_origin: bool,
    ticket_store: Arc<TicketStore>,
    require_ticket: bool,
}

impl tokio_tungstenite::tungstenite::handshake::server::Callback for HandshakeCallback {
    fn on_request(
        self,
        req: &Request,
        resp: Response,
    ) -> Result<
        Response,
        tokio_tungstenite::tungstenite::handshake::server::ErrorResponse,
    > {
        check_handshake(
            req,
            resp,
            &self.allowed,
            self.allow_missing_origin,
            &self.ticket_store,
            self.require_ticket,
        )
    }
}

/// Extract authentication ticket from URI query param, Sec-WebSocket-Protocol,
/// or X-XBridge-Ticket header.
fn extract_ticket(req: &Request) -> Option<String> {
    // 1. Query param: `ticket` or `token`
    if let Some(query) = req.uri().query() {
        for pair in query.split('&') {
            if let Some((k, v)) = pair.split_once('=') {
                if k == "ticket" || k == "token" {
                    return Some(v.to_string());
                }
            }
        }
    }
    // 2. Sec-WebSocket-Protocol (e.g. "xbridge-ticket.<value>" or "ticket.<value>")
    if let Some(proto) = req.headers().get("Sec-WebSocket-Protocol").and_then(|v| v.to_str().ok()) {
        for sub in proto.split(',') {
            let sub = sub.trim();
            if let Some(t) = sub.strip_prefix("xbridge-ticket.") {
                return Some(t.to_string());
            } else if let Some(t) = sub.strip_prefix("ticket.") {
                return Some(t.to_string());
            }
        }
    }
    // 3. X-XBridge-Ticket header
    if let Some(t) = req.headers().get("X-XBridge-Ticket").and_then(|v| v.to_str().ok()) {
        return Some(t.trim().to_string());
    }
    None
}

/// Callback invoked by tungstenite during the handshake. Returns `Err(response)`
/// when the origin or ticket is not allowed; tungstenite then aborts the handshake.
#[allow(clippy::result_large_err)]
fn check_handshake(
    req: &Request,
    resp: Response,
    allowed: &[String],
    allow_missing_origin: bool,
    ticket_store: &TicketStore,
    require_ticket: bool,
) -> Result<Response, tokio_tungstenite::tungstenite::handshake::server::ErrorResponse> {
    let origin = req
        .headers()
        .get("Origin")
        .map(HeaderValue::to_str)
        .and_then(|r| r.ok())
        .map(|s| s.to_string());

    let origin_ok = match origin {
        Some(ref o) => {
            if o == "null" || o == "*" {
                warn!("ws handshake rejected: unsafe origin value '{o}'");
                return Err(reject_response(StatusCode::FORBIDDEN, o));
            }
            allowed.iter().any(|a| origin_matches(a, o))
        }
        None => allow_missing_origin,
    };

    if !origin_ok {
        let origin_dbg = origin.unwrap_or_else(|| "<missing>".into());
        warn!("ws handshake rejected: forbidden origin {origin_dbg}");
        return Err(reject_response(
            StatusCode::FORBIDDEN,
            &format!("forbidden origin: {origin_dbg}"),
        ));
    }

    // 2. Check Ticket if required or provided
    let ticket = extract_ticket(req);
    if require_ticket {
        match ticket {
            Some(ref t) => {
                if !ticket_store.consume(t) {
                    warn!("ws handshake rejected: invalid or expired ticket");
                    return Err(reject_response(
                        StatusCode::UNAUTHORIZED,
                        "invalid or expired ticket",
                    ));
                }
            }
            None => {
                warn!("ws handshake rejected: missing required authentication ticket");
                return Err(reject_response(
                    StatusCode::UNAUTHORIZED,
                    "missing required authentication ticket",
                ));
            }
        }
    } else if let Some(ref t) = ticket {
        // Optional consumption
        let _ = ticket_store.consume(t);
    }

    Ok(resp)
}

/// Build an `ErrorResponse` carrying a rejection reason.
fn reject_response(
    status: StatusCode,
    reason: &str,
) -> tokio_tungstenite::tungstenite::handshake::server::ErrorResponse {
    tokio_tungstenite::tungstenite::http::Response::builder()
        .status(status)
        .body(Some(format!("rejected: {reason}")))
        .unwrap_or_else(|_| {
            tokio_tungstenite::tungstenite::http::Response::new(Some(
                "403 Forbidden".to_string(),
            ))
        })
}

/// Check whether an allowed origin spec matches the actual origin.
///
/// An origin is `scheme://host[:port]` (no path, no query, no fragment).
///
/// Matching rules:
/// - If `allowed` ends with `/` (e.g. `"file://"`), it is treated as a scheme
///   prefix: the actual origin must start with `allowed`.
/// - Otherwise, `allowed` is treated as a full origin string. The actual
///   origin must match exactly, or differ only by a default port (e.g.
///   `https://example.com` matches `https://example.com:443`).
fn origin_matches(allowed: &str, actual: &str) -> bool {
    // Scheme-prefix match for entries like "file://"
    if allowed.ends_with('/') {
        return actual.starts_with(allowed);
    }
    // Exact match fast path
    if allowed == actual {
        return true;
    }
    let norm_allowed = normalize_origin(allowed);
    let norm_actual = normalize_origin(actual);
    if norm_allowed == norm_actual {
        return true;
    }
    matches_wildcard_pattern(&norm_allowed, &norm_actual)
}

/// Safely match wildcard patterns (e.g. `https://*.example.com`) against actual origins,
/// strictly enforcing DNS dot boundaries.
fn matches_wildcard_pattern(pattern: &str, actual: &str) -> bool {
    let (p_scheme, p_host) = match pattern.split_once("://") {
        Some(pair) => pair,
        None => return false,
    };
    let (a_scheme, a_host) = match actual.split_once("://") {
        Some(pair) => pair,
        None => return false,
    };
    if p_scheme != a_scheme {
        return false;
    }
    if let Some(root_domain) = p_host.strip_prefix("*.") {
        if a_host == root_domain {
            return true;
        }
        if a_host.ends_with(root_domain) && a_host.len() > root_domain.len() {
            let prefix = &a_host[..a_host.len() - root_domain.len()];
            return prefix.ends_with('.');
        }
    }
    false
}

/// Strip default ports (443 for https, 80 for http) from an origin string.
/// Uses proper URL-like parsing: finds the host:port portion after `scheme://`
/// and only strips the port if it is a numeric default for the scheme.
fn normalize_origin(origin: &str) -> String {
    let (scheme, rest) = if let Some(h) = origin.strip_prefix("https://") {
        ("https://", h)
    } else if let Some(h) = origin.strip_prefix("http://") {
        ("http://", h)
    } else {
        return origin.to_string();
    };

    // `rest` is `host[:port]` (origin has no path/query/fragment by spec).
    // Split on the LAST colon — hostnames don't contain colons (IPv6 is
    // bracketed as `[::1]` so the last colon after `]` is the port separator).
    if let Some(idx) = rest.rfind(':') {
        let host = &rest[..idx];
        let port_str = &rest[idx + 1..];
        // Only strip if the suffix is a valid numeric port.
        if port_str.chars().all(|c| c.is_ascii_digit()) {
            let port: u16 = port_str.parse().unwrap_or(0);
            let is_default = match scheme {
                "https://" => port == 443,
                "http://" => port == 80,
                _ => false,
            };
            if is_default {
                return format!("{scheme}{host}");
            }
        }
    }
    origin.to_string()
}

impl std::fmt::Debug for RunningServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RunningServer")
            .field("actual_port", &self.actual_port)
            .field("subscriber_count", &self.subscriber_count())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_origin_matches_exact_and_default_ports() {
        assert!(origin_matches("https://example.com", "https://example.com"));
        assert!(origin_matches("https://example.com", "https://example.com:443"));
        assert!(origin_matches("https://example.com:443", "https://example.com"));
        assert!(origin_matches("http://localhost", "http://localhost:80"));
        assert!(!origin_matches("https://example.com", "https://example.com:8443"));
        assert!(!origin_matches("https://example.com", "http://example.com"));
    }

    #[test]
    fn test_origin_matches_wildcards_and_dns_boundaries() {
        assert!(origin_matches("https://*.example.com", "https://example.com"));
        assert!(origin_matches("https://*.example.com", "https://app.example.com"));
        assert!(origin_matches("https://*.example.com", "https://sub.app.example.com"));
        // Suffix spoofing prevention
        assert!(!origin_matches("https://*.example.com", "https://attacker-example.com"));
        assert!(!origin_matches("https://*.example.com", "https://example.com.evil.com"));
        // Scheme mismatch
        assert!(!origin_matches("https://*.example.com", "http://app.example.com"));
    }
}

