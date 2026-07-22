# xbridge_flutter

A generic, business-free cross-platform bridge SDK for Flutter ↔ H5 WebView integration.

Part of the [XBridge](https://github.com/nicklama/xbridge) monorepo. Pair with [`xbridge-js`](../xbridge-js) on the H5 side and [`xbridge_platform_interface`](../xbridge_platform_interface) for native platform contracts.

## Features

- **Unified protocol** — JSON-RPC 2.0 variant (`{jsonrpc:"2.0",id,method,params}` / `{jsonrpc:"2.0",id,result|error}` / `{jsonrpc:"2.0",method,params}` events).
- **Engine-agnostic** — adapters for both [`webview_flutter`](https://pub.dev/packages/webview_flutter) and [`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview).
- **Dynamic routing** — O(1) `Map` lookup for registered handlers; no Pigeon code-gen (audit Risk 4).
- **Native fallback** — unregistered methods are forwarded verbatim to the native legacy plugin via a singleton `MethodChannel`.
- **Security** — optional `XBridgeSecurityPolicy` origin allowlist.
- **High-perf bypass** — `LocalWebSocketBridge` controls a loopback-only WebSocket server for zero-serialization binary streaming (audio/video).

## Quick start

### 1. Register handlers

```dart
import 'package:xbridge_flutter/xbridge_flutter.dart';

final bridge = BridgeController();

bridge.addHandler('getAppInfo', (ctx, params) async {
  return {'version': '1.0.0', 'platform': 'flutter'};
});

bridge.addHandler('showToast', (ctx, params) {
  // ... show toast ...
  return true;
});
```

### 2. Attach a WebView engine

#### `webview_flutter`

```dart
final controller = WebViewController()
  ..setJavaScriptMode(JavaScriptMode.unrestricted);

WebViewFlutterBridgeAdapter().attach(controller, bridge);

// use controller in WebViewWidget(controller)
```

#### `flutter_inappwebview`

```dart
InAppWebView(
  onWebViewCreated: (controller) {
    InAppWebViewBridgeAdapter().attach(controller, bridge);
  },
);
```

### 3. Push events to H5

```dart
bridge.dispatchEvent(BridgeEvent(
  method: 'onAudioFinished',
  params: {'requestId': 'abc-123'},
));
```

### 4. Security policy

```dart
bridge.setSecurityPolicy(XBridgeSecurityPolicy.allowlist({
  'https://app.example.com',
}));
```

### 5. Native fallback

Methods not registered on the Flutter side are automatically forwarded to the native legacy plugin over `MethodChannel('xbridge/native_fallback')`. Implement a native handler on Android/iOS that dispatches by method name — no XBridge changes needed when adding new H5 methods.

### 6. Local WebSocket bypass (high-perf streaming)

```dart
final ws = LocalWebSocketBridge();
await ws.start(port: 0); // OS picks a free loopback port
final endpoint = await ws.getEndpoint(); // ws://127.0.0.1:<port>
// Pass `endpoint` to H5; H5 opens `new WebSocket(endpoint)` directly.
```

The data plane (binary frames) flows H5 ↔ native WS directly — no Base64, no JSON, no JS Bridge overhead.

## API reference

| Symbol | Purpose |
| :--- | :--- |
| `BridgeController` | Central router; `addHandler`, `setFallbackHandler`, `setSecurityPolicy`, `handleRawMessage`, `dispatchEvent`. |
| `BridgeTransport` | Pluggable JS injection contract (implement for custom WebView engines). |
| `BridgeRequest` / `BridgeResponse` / `BridgeEvent` / `BridgeError` | Protocol models. |
| `BridgeMethodContext` / `BridgeMethodHandler` | Handler contract. |
| `BridgeJavaScriptTransport` | Default transport for `webview_flutter`. |
| `WebViewFlutterBridgeAdapter` / `InAppWebViewBridgeAdapter` | Engine adapters. |
| `FallbackChannel` | Singleton native fallback `MethodChannel`. |
| `LocalWebSocketBridge` | Control-plane client for the local WS bypass. |
| `XBridgeSecurityPolicy` | Origin allowlist / allow-all policy. |

## Zero business coupling

This package contains no business logic (no `getToken`, `YashiApi`, `PaymentService`, etc.). Platform channel names (`AppBridge`, `humanBridge`, `dsbridge`, `flutter_inappwebview`) are transport-level and do not constitute business coupling.

## License

MIT
