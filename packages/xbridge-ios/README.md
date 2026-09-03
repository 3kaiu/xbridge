# XBridgeiOS

Native iOS (Swift) bridge SDK. Two subspecs:

- **`Core`** — pure Swift, no Flutter dependency. Security policy, Rust C-ABI bridge.
- **`Flutter`** — Flutter plugin glue (`FlutterPlugin`, `MethodChannel`).

The bridge is strictly async JSON-RPC: H5 calls flow
`window.XBridge.postMessage` → JavaScriptChannel → Dart method handler →
this native bridge. No synchronous `@JavascriptInterface` bypass.

## Installation

### Flutter app (automatic)

Add `xbridge_flutter` to your `pubspec.yaml` — the iOS native code is bundled automatically.

### Pure native app (CocoaPods)

```ruby
# Podfile
pod 'XBridgeiOS/Core', :git => 'https://github.com/3kaiu/xbridge.git', :tag => 'v0.1.5'
```

## Usage (pure native, no Flutter)

```swift
// Implement the bridge delegate
class YourBridgeAdapter: XBridgeNativeBridge {
    func invoke(method: String, params: Any?) -> Any? {
        return existingBridge.handle(method, params)
    }
}
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

## License

MIT
