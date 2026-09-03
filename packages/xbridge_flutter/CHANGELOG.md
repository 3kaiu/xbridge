# Changelog

## 0.1.5 (unreleased)

* **Performance**: outbound JS (resolves/rejects/events/reverse calls) is now
  coalesced by `BatchingTransport` — a synchronous burst of bridge responses is
  delivered to the WebView in a single evaluation instead of one per snippet.
  Both adapters (`webview_flutter`, `inappwebview`) enable this by default;
  pass `enableBatching: false` to disable, or `flushInterval:` for time-window
  batching of steady high-frequency event streams.

## 0.1.0

* Initial release: Flutter bridge SDK with WebView H5 integration,
  sync bypass, local WebSocket server, and platform interface.
