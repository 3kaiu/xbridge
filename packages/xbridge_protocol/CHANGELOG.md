# Changelog

## 0.1.5 (unreleased)

* **Performance**: add `ScriptTransport` (single `evaluateScript` funnel for
  the four protocol operations) and `BatchingTransport` — coalesces per-tick
  outbound JS snippets into a single WebView evaluation (microtask mode, zero
  added latency) or at most one evaluation per configurable window (time-window
  mode). Adapters now default to batching enabled.

## 0.1.0

* Initial release: JSON-RPC 2.0 protocol layer with `BridgeRequest`,
  `BridgeResponse`, `BridgeEvent`, `BridgeError`, `BridgeScriptBuilder`,
  and `XBridgeSecurityPolicy`.
