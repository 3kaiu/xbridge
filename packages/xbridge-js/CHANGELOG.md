# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
