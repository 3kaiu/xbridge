//! Pub/sub fan-out for binary frames received by the local WS server.
//!
//! Design: the server owns a `Vec<mpsc::Sender<Vec<u8>>>`; each connected
//! subscriber holds the matching `mpsc::Receiver`. When a binary frame
//! arrives, the server `try_send`s a clone of the bytes into every live
//! sender. Backpressure policy: if a subscriber's channel is full, the frame
//! is dropped for that subscriber and a warning is logged — never block the
//! accept loop.
//!
//! Zero-copy fast path: in the common single-subscriber case the `Vec<u8>`
//! is moved (not cloned) into the channel. Multi-subscriber requires cloning
//! per subscriber; this is intentional and documented in the PRD (§1.2.4) as
//! acceptable because the multi-subscriber case is rare for streaming audio.

use log::warn;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

use crate::error::WsError;

/// Handle representing a single subscription. Held by the subscriber; when
/// dropped the sender half is closed and the server prunes the slot lazily
/// on the next publish.
///
/// `DataSink` is cheap to clone (an `Arc` around the sender). Internally
/// thread-safe via `tokio::sync::mpsc::Sender` which is itself `Sync`.
#[derive(Clone)]
pub struct DataSink {
    pub(crate) tx: mpsc::Sender<Vec<u8>>,
}

impl std::fmt::Debug for DataSink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DataSink").field("tx", &"<mpsc::Sender>").finish()
    }
}

impl DataSink {
    /// Push a binary frame into this sink. Non-blocking; on full channel
    /// returns [`WsError::ChannelFull`] so the caller can log / drop.
    ///
    /// The `Vec<u8>` is moved into the channel, not copied.
    #[allow(clippy::result_large_err)]
    pub fn try_push(&self, bytes: Vec<u8>) -> Result<(), WsError> {
        match self.tx.try_send(bytes) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => Err(WsError::ChannelFull),
            Err(mpsc::error::TrySendError::Closed(_)) => {
                // Subscriber gone — treat as full/drop so caller prunes.
                Err(WsError::ChannelFull)
            }
        }
    }

    /// Async push. Awaits if the channel is full (use only when backpressure
    /// is preferred over frame dropping). Most callers should use
    /// [`try_push`](Self::try_push) instead.
    pub async fn push(&self, bytes: Vec<u8>) -> Result<(), WsError> {
        self.tx
            .send(bytes)
            .await
            .map_err(|_| WsError::ChannelFull)
    }

    /// Borrow the inner sender for advanced patterns (e.g. wrapping in a
    /// custom transport). The sender remains owned by this `DataSink`.
    pub fn sender(&self) -> &mpsc::Sender<Vec<u8>> {
        &self.tx
    }
}

/// Shared registry of subscriber sinks. The server holds one of these and
/// appends a new slot for each `subscribe()` call.
#[derive(Debug, Default)]
pub(crate) struct SinkRegistry {
    pub(crate) sinks: Arc<Mutex<Vec<mpsc::Sender<Vec<u8>>>>>,
}

impl SinkRegistry {
    pub(crate) fn new() -> Self {
        Self {
            sinks: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Publish a binary frame to every live subscriber. Dead senders
    /// (receiver dropped) are pruned in-place.
    ///
    /// Backpressure: per subscriber, if `try_send` fails with `Full` the
    /// frame is dropped for that subscriber and a warning is logged. The
    /// accept loop is never blocked.
    ///
    /// The `Vec<Sender>` is cloned out from the Mutex and the lock is
    /// released before iterating, so `try_send` calls are never blocked by
    /// the registry lock.
    /// For a single live subscriber the bytes are moved (not cloned).
    /// For multiple subscribers, all but the last get clones; the last gets
    /// the original `Vec`.
    pub(crate) fn publish(&self, bytes: Vec<u8>) {
        let sinks = match self.sinks.lock() {
            Ok(guard) => guard.clone(),
            Err(p) => {
                // Mutex poisoned — should never happen in normal operation.
                warn!("sink registry mutex poisoned: {p}");
                p.into_inner().clone()
            }
        };

        // Identify indices of live (not closed) senders so we know which one
        // gets the moved bytes (the last live sender).
        let live_indices: Vec<usize> = sinks
            .iter()
            .enumerate()
            .filter(|(_, tx)| !tx.is_closed())
            .map(|(i, _)| i)
            .collect();
        let mut dead = Vec::new();

        // Track which is the last live sender index.
        let last_live = live_indices.last().copied();

        let mut bytes = Some(bytes);
        for (i, tx) in sinks.iter().enumerate() {
            // Determine if this is the last live sender — if so, move bytes.
            let is_last_live = Some(i) == last_live;
            let payload: Vec<u8> = if is_last_live {
                // Move original bytes out — no clone for the final live subscriber.
                // Use Option::take so we don't leave an empty Vec that could
                // accidentally be cloned by a later iteration.
                match bytes.take() {
                    Some(b) => b,
                    None => continue, // already consumed — skip dead/extra senders
                }
            } else {
                // Clone for non-last subscribers.
                bytes.as_ref().cloned().unwrap_or_default()
            };
            match tx.try_send(payload) {
                Ok(()) => {}
                Err(mpsc::error::TrySendError::Full(_)) => {
                    warn!("subscriber {i} channel full, dropping frame");
                }
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    dead.push(i);
                }
            }
        }

        if !dead.is_empty() && self.sinks.lock().map(|mut v| {
            // prune dead senders (iterate descending so indices stay valid)
            for &i in dead.iter().rev() {
                if i < v.len() {
                    v.remove(i);
                }
            }
        }).is_err() {
            warn!("failed to prune dead sinks (mutex)");
        }
    }

    /// Number of currently registered subscribers (live + dead-until-pruned).
    pub(crate) fn len(&self) -> usize {
        self.sinks.lock().map(|v| v.len()).unwrap_or(0)
    }

    /// Whether there are any subscribers.
    #[allow(dead_code)]
    pub(crate) fn is_empty(&self) -> bool {
        self.len() == 0
    }
}
