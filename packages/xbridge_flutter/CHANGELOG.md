# Changelog

## 0.1.7

* Version housekeeping: all package manifests unified to 0.1.7. No code
  changes.

## 0.1.6

* **Fix**: eliminate the `InvalidAccessError` window on WebView detach.
  On `webview_flutter_wkwebview`, removing the JS channel resets all user
  scripts and message handlers asynchronously, so a still-running old
  document could `postMessage` into an unregistered handler and throw a
  native `InvalidAccessError` (seen on /archive/fill, iOS 15.4–18.7).
  `detach()` now keeps the channel and injects an invalidation script whose
  sentinel error (`XBridgeSendError`) is recognized by the JS circuit
  breaker; the Dart-side `_detached` gate deterministically drops inbound
  traffic after detach; outbound traffic goes through `BrokenBridgeTransport`
  (flush-before-swap, no buffered-batch loss). Re-attach clears the gate.
* iOS podspec now ships the LICENSE file it references.

## 0.1.5

* **Performance**: outbound JS (resolves/rejects/events/reverse calls) is now
  coalesced by `BatchingTransport` — a synchronous burst of bridge responses is
  delivered to the WebView in a single evaluation instead of one per snippet.
  Both adapters (`webview_flutter`, `inappwebview`) enable this by default;
  pass `enableBatching: false` to disable, or `flushInterval:` for time-window
  batching of steady high-frequency event streams.

## 0.1.0

* Initial release: Flutter bridge SDK with WebView H5 integration,
  sync bypass, local WebSocket server, and platform interface.
