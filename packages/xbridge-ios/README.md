# XBridgeiOS

Native iOS (Swift) bridge SDK. Two subspecs:

- **`Core`** — pure Swift, no Flutter dependency. Sync bypass, security policy, Rust C-ABI bridge.
- **`Flutter`** — Flutter plugin glue (`FlutterPlugin`, `MethodChannel`).

## Installation

### Flutter app (automatic)

Add `xbridge_flutter` to your `pubspec.yaml` — the iOS native code is bundled automatically.

### Pure native app (CocoaPods)

```ruby
# Podfile
pod 'XBridgeiOS/Core', :git => 'https://github.com/3kaiu/xbridge.git', :tag => 'v0.1.0'
```

## Usage (pure native, no Flutter)

```swift
// 1. Implement the bridge delegate
class YourBridgeAdapter: XBridgeNativeBridge {
    func invoke(method: String, params: Any?) -> Any? {
        return existingBridge.handle(method, params)
    }
}

// 2. Attach sync bypass to WKWebView
let syncHandler = XBridgeSyncHandler()
syncHandler.nativeBridge = YourBridgeAdapter()
syncHandler.securityPolicy = .allowlist(["https://app.example.com"])
syncHandler.originProvider = { webView.url?.originString }
syncHandler.attach(to: webView)

// 3. H5 calls sync bypass
// window.XBridgeSync.callSync('getAppInfo', '{}')
```

## Usage (with Flutter)

```swift
// In AppDelegate:
let plugin = XBridgePlugin.register(with: registrar)
plugin.nativeBridge = YourBridgeAdapter()
plugin.securityPolicy = .allowlist(["https://app.example.com"])
```

## Rust Core (xbridge_core.xcframework)

The local WebSocket server feature requires the Rust-built xcframework:

```bash
cd rust/xbridge_core
cargo build --release --target aarch64-apple-ios
# Use xcodebuild to create .xcframework
```

If the xcframework is not linked, all other features work — only the WS server is unavailable.

## Limitation

`WKUserContentController.add(_:name:)` delivers messages asynchronously. True synchronous JS→native calls require `prompt()` interception (see `WKUIDelegate`). The sync bypass uses a Promise-based wrapper with minimal overhead.

## License

MIT
