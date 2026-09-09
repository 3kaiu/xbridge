# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.9] - 2026-09-09

### Fixed
- **Root-Cause Elimination of WebKit Unhandled Rejection**: In `callDispatch`, when `adapter.send` throws a synchronous `InvalidAccessError` (iOS WKWebView detach or network recovery race), the pending Promise is now kept in `pending` state during the 120ms backoff interval. It NEVER calls `reject(err)`. This completely prevents WebKit/Safari from capturing a transient rejected promise and emitting `window.onunhandledrejection` to monitoring agents (ARMS/Sentry).
- **In-Place Safe Retry Execution**: Retry execution on transient `InvalidAccessError` is handled in-place; if the retry also encounters `InvalidAccessError`, it resolves `fallback ?? undefined` without ever rejecting. Host business errors (RPC errors returned by native via `__XBridge__.reject`) remain completely unaffected and reject cleanly to callers.

## [0.1.8] - 2026-09-08

### Fixed
- **Eliminate 0.12ms Short-Circuit in Backoff Retry**: Race explicit `XBridgeReady` CustomEvent against 120ms backoff timer instead of `this.ready(500)` which short-circuits due to synchronous `isConnected() === true`. Legacy hosts safely wait 120ms before retrying, while modern hosts wake up in ~25ms.
- **Fallback Transparency**: Prevent `callDispatch` from immediately resolving fallback on transient `InvalidAccessError` during the first attempt (`retryAttempt === 0`). Rejects to let outer `call()` execute auto-retry before falling back.
- **Destroy Event Listener Leak**: In `StandardAdapter.destroy()`, ensure `pageshow` listener removal runs unconditionally even when inbound overrides were never installed (`this.saved === null`).

### Added
- **Dual Availability Probe Cooldown**: Probe failures now use a 200ms cooldown for transient `InvalidAccessError` vs a 5000ms cooldown for permanent host security rejections.
- **AbortSignal Support for `ready()`**: `ready(timeoutMs, signal)` allows callers to cancel pending ready handshakes and cleans up all polling intervals and listeners.
- **Enterprise Observability Hook**: Introduced `onTransportWarning` callback and `XBridgeDiagnosticSnapshot` across `XBridgeOptions` and `StandardAdapterOptions`.
- **BFCache Restoration Healing**: Added `pageshow` listener in `StandardAdapter` to automatically reset circuit-breaker and probe state when restored from iOS BFCache (`persisted === true`).
- **Boundary & Malformed Payload Immunity**: Hardened inbound parser against non-object primitives (`null`, numbers, booleans) and malformed wire data.
- **Host RPC Serialization Defense**: Handlers returning circular structures now immediately send a JSON-RPC `-32603` response to Native, preventing host timeout hangs.
- **Post-Disposal Safeguards**: Disposed bridges cleanly reject pending or subsequent `call()` operations without leaking memory or registering handlers.

## [0.1.7] - 2026-09-07

### Fixed
- **Probe-Verified Availability**: Synchronous probe determines genuine postMessage usability in third-party containers.
- **WebKit Unhandled Rejection Suppression**: Prevent asynchronous microtask rejection gap from triggering global error handlers.

## [0.1.6] - 2024-09-04

### Fixed
- **Auto-retry on `InvalidAccessError` during network recovery**: When `call()` encounters an `InvalidAccessError` (typically during network recovery when the WebView bridge channel is not yet ready), it now automatically waits for `XBridgeReady` event (max 500ms) and retries once. This eliminates the need for application-layer workarounds.
  - Prevents immediate circuit breaker trip during transient WebView injection races
  - Zero breaking changes: fully backward compatible
  - Retry is limited to one attempt via internal `_retryAttempt` flag to prevent infinite loops
  - Logs clear diagnostic messages when retry occurs

### Internal
- Added `XBridgeCallOptions._retryAttempt` internal field (not for external use)
- Added `XBridgeCore.isInvalidAccessError()` private method for error detection

## [0.1.5] - 2024-09-03

(Previous changes...)
