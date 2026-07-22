# XBridge Android SDK

A native Android (Kotlin) SDK that bridges the Flutter-based XBridge
protocol to the native Android WebView and legacy bridge plugins.

## What This Package Does

1. **Fallback receiver** — Receives unregistered method calls forwarded from
   the Flutter `BridgeController` via `MethodChannel('xbridge/native_fallback')`
   and routes them to your existing native bridge.
2. **Sync bypass injection** — Injects a `@JavascriptInterface` named
   `XBridgeSync` into the WebView so H5 can make truly synchronous native
   calls that bypass the async Flutter channel (audit Risk 1).
3. **Local WS server control** — Calls the Rust `xbridge_core` C-ABI to
   start/stop a local WebSocket server on `127.0.0.1` for high-performance
   binary streaming (audit Risk 2).
4. **Security policy** — Defense-in-depth origin allowlist (primary gate
   is Flutter's `WebViewBridgePolicy`).

## Installation

### Gradle

Add to your app-level `build.gradle`:

```groovy
dependencies {
    implementation 'io.xbridge:xbridge-android:0.1.0'
}
```

If publishing to a Maven repository isn't set up, use a local file dependency:

```groovy
dependencies {
    implementation files('libs/xbridge-android-0.1.0.aar')
}
```

### Native Library (libxbridge_core.so)

The local WebSocket server feature requires the Rust-built native library.
Build it from `rust/xbridge_core/`:

```bash
# From the monorepo root
cd rust/xbridge_core

# Build for each target ABI
cargo build --release --target aarch64-linux-android
cargo build --release --target armv7-linux-androideabi
cargo build --release --target x86_64-linux-android

# Copy .so files into jniLibs
cp target/aarch64-linux-android/release/libxbridge_core.so \
   ../../packages/xbridge-android/src/main/jniLibs/arm64-v8a/
# ... repeat for other ABIs
```

If the `.so` is not present, all other features work normally — only the
local WebSocket server is unavailable (calls return `-1` with a log warning).

## Usage

### 1. Implement `XBridgeNativeBridge`

Create a delegate that forwards to your existing native bridge:

```kotlin
class YourBridgeAdapter(
    private val existingBridge: Any, // your existing bridge instance
) : XBridgeNativeBridge {
    override fun invoke(method: String, params: Any?): Any? {
        // Forward to your existing native bridge handler synchronously
        return existingBridge.callHandler(method, params)
    }
}
```

### 2. Register in `MainActivity`

```kotlin
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        XBridgePluginRegistry.register(
            flutterEngine = flutterEngine,
            nativeBridge = YourBridgeAdapter(existingBridge),
            securityPolicy = XBridgeSecurityPolicy.allowlist(
                "https://app.example.com",
            ),
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        XBridgePluginRegistry.unregister(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
```

### 3. Attach Sync Bypass (when WebView is ready)

If the WebView isn't available at `configureFlutterEngine` time (e.g. it's
created as a platform view later), attach the sync interface once you have
a `WebView` reference:

```kotlin
XBridgePluginRegistry.attachSyncInterface(webView)
```

### 4. Control the Local WS Server

From the Flutter side, use the `MethodChannel`:

```dart
// Start (port 0 = auto-assign)
final port = await MethodChannel('xbridge/native_fallback')
    .invokeMethod('xbridge.setupLocalWebSocket', {'port': 0});

// Stop
await MethodChannel('xbridge/native_fallback')
    .invokeMethod('xbridge.teardownLocalWebSocket');
```

H5 then connects directly:

```javascript
const ws = new WebSocket(`ws://127.0.0.1:${port}`);
ws.binaryType = 'arraybuffer';
ws.onmessage = (e) => { /* binary data */ };
```

### 5. H5 Sync Bypass

H5 probes and calls the sync interface:

```javascript
if (window.XBridgeSync?.isAvailable()) {
    const result = JSON.parse(
        window.XBridgeSync.callSync('getAppInfo', '{}')
    );
    // result = { result: {...} } or { error: { code, message } }
}
```

## MethodChannel Contract

The `MethodChannel('xbridge/native_fallback')` receives:

| `call.method` | `call.arguments` | Return |
|---|---|---|
| Any business method (e.g. `"someMethod"`) | params from H5 | Forwarded to `XBridgeNativeBridge.invoke()` |
| `"xbridge.setupLocalWebSocket"` | `{"port": Int}` | Bound port (`Int`) or error |
| `"xbridge.teardownLocalWebSocket"` | — | `0` or `-1` |
| `"xbridge.setSecurityPolicy"` | `{"allowedOrigins": List<String>, "allowAll": Boolean}` | `null` |

## Architecture

```
H5 (JavaScript)
    │
    ├── Async: JSON-RPC → Flutter BridgeController → (unregistered) → MethodChannel → XBridgePlugin → XBridgeNativeBridge
    │                                                                    ↑
    │                                                              fallback receiver
    │
    ├── Sync: window.XBridgeSync.callSync() → @JavascriptInterface → XBridgeSyncInterface → XBridgeNativeBridge
    │                                                                    ↑
    │                                                              sync bypass (audit Risk 1)
    │
    └── Streaming: ws://127.0.0.1:port ← (binary, zero-serialization) ← Rust xbridge_core (libxbridge_core.so)
                                                                       ↑
                                                                 local WS server (audit Risk 2)
```

## Known Limitations

### Binary Callback JNI Bridge

The Rust C-ABI `xbridge_ws_set_binary_callback` expects a raw C function
pointer. JNI cannot directly pass a Kotlin/Java function as a C
`extern "C" fn` — it requires a native (.c/.cpp) JNI registration shim.
This is a substantial piece not included in this SDK. **Text-frame
communication works** (H5 connects and sends/receives text); binary frame
callback forwarding to Kotlin is the missing piece.

Consumers needing binary callbacks should either:
1. Add a small JNI `.c` shim with `registerNatives`.
2. Use `xbridge_ws_set_binary_callback` from C++ code in their own JNI layer.

### Flutter Embedding Dependency

This library uses `compileOnly` for the Flutter embedding — your app must
already include the Flutter Android embedding (it does if you're a Flutter app).

## Requirements

- Android `minSdk 21`, `targetSdk/compileSdk 34`
- Kotlin 1.9+, JVM target 17
- Flutter embedding (provided by the host app)
- `libxbridge_core.so` (optional — only for WS server feature)
