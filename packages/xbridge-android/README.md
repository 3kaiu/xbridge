# XBridge Android SDK

Native Android (Kotlin) bridge SDK. Two modules:

- **`xbridge-core`** — pure Kotlin, zero Flutter dependency. Security policy, JNI bridge.
- **`xbridge-flutter`** — Flutter plugin glue (`FlutterPlugin`, `MethodChannel`).

The bridge is strictly async JSON-RPC: H5 calls flow
`window.XBridge.postMessage` → JavaScriptChannel → Dart method handler →
this native bridge. No synchronous `@JavascriptInterface` bypass.

## Installation

### Flutter app (automatic)

Add `xbridge_flutter` to your `pubspec.yaml` — the Android native code is bundled automatically.

### Pure native app (JitPack)

```groovy
// build.gradle
dependencies {
    implementation 'com.github.3kaiu.xbridge:xbridge-core:v0.1.5'
}
```

> After pushing a `v*` tag, [JitPack](https://jitpack.io/com/github/3kaiu/xbridge) builds the AAR automatically.

## Usage (pure native, no Flutter)

```kotlin
// Implement the bridge delegate
class YourBridgeAdapter : XBridgeNativeBridge {
    override fun invoke(method: String, params: Any?): Any? {
        return existingBridge.callHandler(method, params)
    }
}
```

## Usage (with Flutter)

```kotlin
// In MainActivity.configureFlutterEngine:
XBridgePluginRegistry.register(
    flutterEngine = flutterEngine,
    nativeBridge = YourBridgeAdapter(),
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
