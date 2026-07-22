# xbridge_core

**High-performance Local WebSocket Server** for the [XBridge](../..) cross-platform bridge SDK.

Part of the XBridge Monorepo. This crate provides the **streaming bypass** data
plane described in PRD §1.2.4 and the red-team audit (Risk 2): a loopback-only
WebSocket server that lets the H5 layer stream large binary payloads (e.g.
`STREAMING_AUDIO_DATA`, digital-human video frames) directly to a native
subscriber — **bypassing the JS bridge channel entirely**.

## Why a local WebSocket?

The standard JS↔Flutter/Native bridge channel serializes every payload as a
JSON or Base64 **string**. For streaming audio or video frames this is
catastrophic:

- Each frame is Base64-encoded (33% size inflation) on the JS side.
- The string is copied across the JS↔Native channel boundary.
- The native side Base64-decodes back into bytes.
- GC pressure from the transient strings causes jank.

`xbridge_core` solves this by standing up a tiny WebSocket server on
`127.0.0.1`. The H5 layer opens a direct `WebSocket` and sends `ArrayBuffer`;
the native side receives raw `Vec<u8>` via a `tokio::sync::mpsc` channel —
**zero Base64, zero JSON encoding of the payload, ownership transfer not
copying**.

## Security

- **Loopback only**: the listener binds to `127.0.0.1`, never `0.0.0.0`. No
  off-device traffic can reach the server.
- **Origin allowlist**: the WS handshake `Origin` header is checked against a
  set of trusted origins before the upgrade completes. Defaults:
  `http://127.0.0.1`, `http://localhost`, `https://127.0.0.1`,
  `https://localhost`, `file://` (local-file WebViews are common in hybrid
  apps). Override via [`LocalWsServer::with_allowed_origins`].
- **Connection cap**: at most `MAX_CONCURRENT_CONNECTIONS` (8) concurrent
  connections; excess are dropped immediately.
- **Backpressure**: if a subscriber's channel is full (default cap 256), the
  incoming frame is **dropped** for that subscriber and a warning is logged —
  the accept loop is never blocked.

## Usage

### Rust API

```rust
use xbridge_core::{LocalWsServer, DataSink};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // port=0 lets the OS assign a free port
    let server = LocalWsServer::new()
        // .with_allowed_origins(vec!["http://127.0.0.1".into()])
        .start(0)
        .await?;

    println!("listening on ws://127.0.0.1:{}", server.actual_port());

    // Subscribe to the binary data plane.
    let (_sink, mut rx) = server.subscribe_receiver();
    tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            // frame: Vec<u8> — raw bytes, zero encoding overhead
            println!("received {} bytes", frame.len());
        }
    });

    // Run the app... when done:
    server.shutdown().await?;
    Ok(())
}
```

### H5 client

```js
const ws = new WebSocket(`ws://127.0.0.1:${port}/`);
ws.binaryType = 'arraybuffer';
ws.onopen = () => {
  const pcm = audioBuffer.getChannelData(0); // Float32Array
  ws.send(pcm.buffer); // ArrayBuffer — no Base64, no JSON
};
```

### C-ABI (Android JNI / Swift)

For hosts that prefer a C ABI, three functions are exported:

```c
int32_t xbridge_ws_start(uint16_t port);
int32_t xbridge_ws_stop(void);
int32_t xbridge_ws_set_binary_callback(void (*cb)(const uint8_t*, size_t));
```

- `xbridge_ws_start(0)` binds to a free loopback port and returns it (or `-1`).
- `xbridge_ws_set_binary_callback` registers a function invoked for every
  binary frame. The pointer is valid **only for the duration of the call** —
  the native side must copy before returning.
- `xbridge_ws_stop()` shuts the server down cleanly.

## Design notes

- **Data plane = binary; control plane = text JSON.** Only control frames
  (subscribe / ping / config) are JSON-encoded; the data plane is raw bytes.
  See `control.rs`.
- **Pub/sub fan-out.** Multiple subscribers may register; each gets its own
  `mpsc::Receiver<Vec<u8>>`. The single-subscriber fast path is a move; the
  multi-subscriber path clones once per extra subscriber.
- **Backpressure = drop + warn.** Never blocks the accept loop. Tunable via
  `LocalWsServer::with_sink_capacity`.
- **No business logic.** This crate knows nothing about tokens, audio
  decoders, or payment services — it only routes bytes. Business meaning is
  layered on by the host.

## License

MIT.
