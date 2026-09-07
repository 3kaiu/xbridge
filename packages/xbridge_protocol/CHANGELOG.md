# Changelog

## 0.1.7

* Version housekeeping: all package manifests unified to 0.1.7. No code
  changes.

## 0.1.6

* **Fix**: add `BridgeScriptBuilder.buildInvalidationScript` — replaces
  `window.<channelName>` after detach with a pure-JS thrower carrying the
  `XBridgeSendError` sentinel consumed by the JS adapter's circuit breaker.
  Full replacement (not property patching) because stale `window.XBridge`
  may be a WKMessageHandler host object whose properties are not reliably
  writable; the invalidation is document-scoped and never leaks into a
  reused WebView's next page.
* Protocol tests extended to 27, covering the invalidation script.

## 0.1.5

* **Performance**: add `ScriptTransport` (single `evaluateScript` funnel for
  the four protocol operations) and `BatchingTransport` — coalesces per-tick
  outbound JS snippets into a single WebView evaluation (microtask mode, zero
  added latency) or at most one evaluation per configurable window (time-window
  mode). Adapters now default to batching enabled.

## 0.1.0

* Initial release: JSON-RPC 2.0 protocol layer with `BridgeRequest`,
  `BridgeResponse`, `BridgeEvent`, `BridgeError`, `BridgeScriptBuilder`,
  and `XBridgeSecurityPolicy`.
