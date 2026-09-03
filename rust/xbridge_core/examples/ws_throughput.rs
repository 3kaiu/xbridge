//! End-to-end throughput benchmark for the XBridge local WebSocket data plane.
//!
//! Real path exercised: WS client (TCP) → server accept loop → on_binary
//! callback → SinkRegistry.publish → DataSink → subscriber receiver. This is
//! the exact H5 → native binary-streaming path (zero Base64/JSON, `Vec<u8>`
//! ownership move in the single-subscriber case).
//!
//! Run: `cargo run --release --example ws_throughput`

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use futures_util::SinkExt;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use xbridge_core::LocalWsServer;

/// Run one scenario and print its throughput.
async fn run_scenario(
    name: &str,
    frame_size: usize,
    frames: usize,
    subscribers: usize,
) {
    let server = LocalWsServer::new()
        .with_allow_missing_origin(true)
        .start(0)
        .await
        .expect("server start");
    let port = server.actual_port();

    // Native-side subscriber(s): drain the data plane and count received bytes.
    let received_frames = Arc::new(AtomicUsize::new(0));
    let received_bytes = Arc::new(AtomicUsize::new(0));
    let mut drains = Vec::new();
    for _ in 0..subscribers {
        let (_, mut rx) = server.subscribe_receiver();
        let rf = Arc::clone(&received_frames);
        let rb = Arc::clone(&received_bytes);
        drains.push(tokio::spawn(async move {
            while let Some(bytes) = rx.recv().await {
                rf.fetch_add(1, Ordering::Relaxed);
                rb.fetch_add(bytes.len(), Ordering::Relaxed);
            }
        }));
    }

    // H5-side client: connect over a real WebSocket (browser-like Origin).
    let mut req = format!("ws://127.0.0.1:{port}/").into_client_request().unwrap();
    req.headers_mut().insert(
        "Origin",
        HeaderValue::from_static("http://127.0.0.1"),
    );
    let (mut ws, _) = tokio_tungstenite::connect_async(req)
        .await
        .expect("ws connect");

    let payload: Vec<u8> = vec![0xA5u8; frame_size];
    let t0 = Instant::now();
    for _ in 0..frames {
        ws.send(Message::Binary(payload.clone())).await.expect("send");
    }
    let elapsed = t0.elapsed();

    // Give the data plane a moment to drain the final frames.
    let _ = ws.close(None).await;
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    for d in drains {
        d.abort();
    }
    let _ = server.shutdown().await;

    let got_frames = received_frames.load(Ordering::Relaxed);
    let got_bytes = received_bytes.load(Ordering::Relaxed);
    // received_* counts accumulate across every subscriber (each frame is
    // delivered once per subscriber), so the expected total is frames × subs.
    let expected_frames = frames * subscribers;
    let secs = elapsed.as_secs_f64();
    let mbps = (got_bytes as f64) / (1024.0 * 1024.0) / secs;
    let fps = got_frames as f64 / secs;
    println!(
        "{name:>14}  {frame_size:>6}B × {frames:>6} (×{subscribers}订阅)  →  {got_frames:>6}/{expected_frames} 帧  "
    );
    println!(
        "{name:>14}  耗时 {elapsed:?}  ≈ {fps:>10.0} 帧/s   ≈ {mbps:>8.1} MB/s  (合计丢帧 {})",
        expected_frames.saturating_sub(got_frames)
    );
}

#[tokio::main]
async fn main() {
    println!("XBridge WS 数据面端到端压测（真实 TCP + WebSocket 全链路）\n");

    // 场景 1：小帧高帧率（遥测/事件类）
    run_scenario("小帧 1KB", 1024, 100_000, 1).await;
    // 场景 2：大帧流媒体（音频/视频帧），单订阅者零拷贝路径
    run_scenario("大帧 64KB", 64 * 1024, 8_000, 1).await;
    // 场景 3：大帧流媒体，双订阅者（fan-out clone 路径）
    run_scenario("大帧 64KB×2", 64 * 1024, 8_000, 2).await;
}
