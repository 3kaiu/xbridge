# XBridge Android SDK

Native Android (Kotlin) bridge SDK. Two modules:

- **`xbridge-core`** — pure Kotlin, zero Flutter dependency. Sync bypass, security policy, JNI bridge.
- **`xbridge-flutter`** — Flutter plugin glue (`FlutterPlugin`, `MethodChannel`).

## Installation

### Flutter app (automatic)

Add `xbridge_flutter` to your `pubspec.yaml` — the Android native code is bundled automatically.

### Pure native app (JitPack)

```groovy
// build.gradle
dependencies {
    implementation 'com.github.3kaiu.xbridge:xbridge-core:v0.1.0'
}
```

> After pushing a `v*` tag, [JitPack](https://jitpack.io/com/github/3kaiu/xbridge) builds the AAR automatically.

## Usage (pure native, no Flutter)

```kotlin
// 1. Implement the bridge delegate
class YourBridgeAdapter : XBridgeNativeBridge {
    override fun invoke(method: String, params: Any?): Any? {
        return existingBridge.callHandler(method, params)
    }
}

// 2. Attach sync bypass to WebView
val syncInterface = XBridgeSyncInterface(
    nativeBridgeProvider = { YourBridgeAdapter() },
    securityPolicyProvider = { XBridgeSecurityPolicy.allowlist(setOf("https://app.example.com")) },
    originProvider = { webView.url },
)
syncInterface.attach(webView)

// 3. H5 calls sync bypass
// window.XBridgeSync.callSync('getAppInfo', '{}')
```

## Usage (with Flutter)

```kotlin
// In MainActivity.configureFlutterEngine:
XBridgePluginRegistry.register(
    flutterEngine = flutterEngine,
    nativeBridge = YourBridgeAdapter(),
    webView = webView,
)
```

## Native Library (libxbridge_core.so)

The local WebSocket server feature requires the Rust-built native library:

```bash
cd rust/xbridge_core
cargo build --release --target aarch64-linux-android
# Copy .so into xbridge-core/src/main/jniLibs/arm64-v8a/
```

If the `.so` is not present, all other features work — only the WS server is unavailable.

## Requirements

- Android `minSdk 21`, `compileSdk 34`
- Kotlin 1.9+, JVM 17
- `libxbridge_core.so` (optional — only for WS server)

## License

MIT
