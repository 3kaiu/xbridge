# xbridge_protocol

XBridge JSON-RPC 2.0 protocol layer — zero-dependency pure Dart package.

## Features

- `BridgeRequest` / `BridgeResponse` / `BridgeEvent` — JSON-RPC 2.0 message models
- `BridgeError` with standard error codes (`BridgeErrorCode`)
- `BridgeScriptBuilder` — generates safe JS injection scripts for WebView
- `XBridgeSecurityPolicy` — origin allowlist / deny-all / allow-all

## Installation

```yaml
dependencies:
  xbridge_protocol:
    git:
      url: https://github.com/3kaiu/xbridge.git
      path: packages/xbridge_protocol
```

## Usage

```dart
import 'package:xbridge_protocol/xbridge_protocol.dart';

final request = BridgeRequest.parse(message);
final response = BridgeResponse.success(id: request.id, result: {'ok': true});
webView.evaluateJavaScript(response.toJsonString());
```

## License

MIT
