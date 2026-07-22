# XBridgeiOS

Native iOS component of the [XBridge](https://github.com/nickcao/xbridge) SDK — a generic, business-free cross-platform bridge for H5 ↔ Flutter ↔ Native communication.

## Features

1. **Flutter Fallback Receiver** — Listens on `MethodChannel('xbridge/native_fallback')` and forwards unregistered H5 methods to an app-supplied delegate.
2. **Sync Bypass** — Injects a `XBridgeSync` message handler into `WKWebView` for (pseudo-)synchronous bridge calls that bypass the async Flutter channel.
3. **Local WebSocket Server Control** — Bridges to the Rust `xbridge_core` C-ABI to start/stop a local WS server on `127.0.0.1` for high-performance binary streaming.
4. **Security Policy** — Origin allowlist struct for defense-in-depth (primary gate is on the Flutter side).

## Installation

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'XBridgeiOS', :path => 'path/to/xbridge/packages/xbridge-ios'
```

Or publish to a private spec repo and use:

```ruby
pod 'XBridgeiOS'
```

Then run `pod install`.

### Rust Core (for WebSocket features)

If you need the local WebSocket server, you must build the Rust `xbridge_core` crate as an `.xcframework`:

```bash
cd rust/xbridge_core
cargo build --release --target aarch64-apple-ios
cargo build --release --target x86_64-apple-ios
# Use cargo-lipo or xcodebuild to create the .xcframework
```

Add the resulting `xbridge_core.xcframework` to your Xcode project's "Frameworks, Libraries, and Embedded Content".

If the Rust core is not linked, WebSocket features gracefully degrade — `start()` returns an error with a clear message. All other features (fallback receiver, sync bypass) work without it.

## Usage

### 1. Implement the delegate

Create a class that conforms to `XBridgeNativeBridge`. This is the **only** place where business logic enters — it forwards to your existing DsBridge handler:

```swift
import XBridgeiOS

class MyAppBridgeAdapter: XBridgeNativeBridge {
    func invoke(method: String, params: Any?) -> Any? {
        // Forward to your existing DsBridge / YashiBridgePlugin handler
        // Example:
        // return existingDsBridge.call(method, args: params)
        return nil
    }
}
```

### 2. Register the plugin (AppDelegate)

```swift
import XBridgeiOS
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        let controller = window?.rootViewController as? FlutterViewController
        if let controller = controller {
            let registrar = controller.registrar(forPlugin: "XBridgePlugin")!
            let plugin = XBridgePlugin.register(with: registrar)
            plugin.nativeBridge = MyAppBridgeAdapter()
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
```

### 3. Attach the sync handler (optional, for sync bypass)

In your `WKWebView` setup:

```swift
let syncHandler = XBridgeSyncHandler()
syncHandler.nativeBridge = MyAppBridgeAdapter()
syncHandler.attach(to: webView)
```

The JS side can then call:

```javascript
// Probe availability
if (window.XBridgeSync) {
    // Pseudo-sync call (async under the hood on iOS — see limitation below)
    const result = await window.XBridgeSync.callSync('getAppInfo', '{}')
}
```

### 4. Local WebSocket Server (for high-perf streaming)

From the Flutter side:

```dart
final port = await bridgeController.setupLocalWebSocket(port: 0);
// H5 can now connect: new WebSocket('ws://127.0.0.1:$port')
```

Or from native:

```swift
LocalWsServerBridge.shared.start(port: 0) { result in
    switch result {
    case .success(let port):
        print("WS server on 127.0.0.1:\(port)")
    case .failure(let error):
        print("Failed: \(error.localizedDescription)")
    }
}
```

### 5. Security Policy

```swift
// Push from Flutter side (defense-in-depth):
plugin.securityPolicy = .allowlist(["https://app.example.com"])

// Check:
if plugin.securityPolicy.allows(origin: "https://app.example.com") {
    // permit
}
```

## ⚠️ iOS Sync Bypass Limitation

**True synchronous JavaScript-to-native calls are not possible on WKWebView** through the standard `WKUserContentController.add(_:name:)` API. Script messages are delivered asynchronously.

### What XBridgeiOS does instead

`XBridgeSyncHandler` injects a JS helper that wraps the async message handler with a Promise-based API. When H5 calls `XBridgeSync.callSync(method, params)`, it returns a Promise that resolves when the native handler completes. This is **not truly synchronous** — it's async with minimal overhead.

### Alternative: `prompt()` interception (true sync)

For apps that need genuine synchronous returns, intercept `WKUIDelegate`:

```swift
func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
) {
    // Parse `prompt` as a JSON-RPC bridge call
    // e.g. prompt = '{"method":"getAppInfo","params":{}}'
    if let data = prompt.data(using: .utf8),
       let call = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let method = call["method"] as? String {
        let result = nativeBridge.invoke(method: method, params: call["params"])
        // Serialize and return synchronously
        let json = serializeResult(result)
        completionHandler(json)
        return
    }
    completionHandler(defaultText)
}
```

This `prompt()` hack is the only way to achieve true sync on WKWebView. It is an optional upgrade path — the H5 SDK (`xbridge-js`) probes `XBridgeSync.isAvailable()` and falls back to the async path if unavailable.

## Architecture

```
Sources/XBridgeiOS/
├── XBridgePlugin.swift          # FlutterPlugin: MethodChannel receiver + WS control
├── XBridgeSyncHandler.swift     # WKScriptMessageHandler for sync bypass
├── XBridgeNativeBridge.swift    # Delegate protocol (app implements this)
├── WebSocket/
│   ├── LocalWsServerBridge.swift  # Singleton bridging to Rust C-ABI
│   ├── xbridge_core.h             # C header for Rust functions
│   └── module.modulemap           # Swift module map for the C header
└── Security/
    └── XBridgeSecurityPolicy.swift  # Origin allowlist
```

## Zero Business Coupling

XBridgeiOS contains **no** business methods. It is a generic infrastructure layer. The app supplies a `XBridgeNativeBridge` delegate that forwards `method` strings to its existing bridge handler. No `getToken`, `YashiApi`, `PaymentService`, or similar references appear anywhere in the SDK source.

## License

MIT
