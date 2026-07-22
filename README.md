# XBridge

通用、开源、零业务耦合的跨端桥接 SDK。统一 H5 / Flutter / Native (iOS + Android + HarmonyOS) 三端通信协议。

## 架构

- **`packages/xbridge-js`** — H5 端 TypeScript SDK，NPM 分发。基于 JSON-RPC 2.0 变体协议，自动嗅探容器环境（Flutter AppBridge / WKWebView / flutter_inappwebview / dsbridge）。
- **`packages/xbridge_flutter`** — Flutter 端 Dart SDK，Pub 分发。`BridgeController` 统一接收 H5 请求，支持 `webview_flutter` 与 `flutter_inappwebview` 双引擎，未注册方法透传至 Native。
- **`packages/xbridge_platform_interface`** — Flutter 平台接口层，定义 Native 侧 Local WS Server 控制流与安全策略。
- **`rust/xbridge_core`** — Rust Local WebSocket Server，高性能多媒体流旁路通道。H5 直连 `ws://127.0.0.1:port`，ArrayBuffer 二进制全双工，零序列化开销。提供 C-ABI 供 Native 桥接。
- **`packages/xbridge-android`** — Android 原生 SDK，Maven/Gradle 分发。接收 Flutter 透传、`@JavascriptInterface` 同步旁路注入、JNI 桥接 Rust WS Server。
- **`packages/xbridge-ios`** — iOS 原生 SDK，CocoaPods 分发。`FlutterPlugin` 透传接收、`WKScriptMessageHandler` 同步旁路、Swift 桥接 Rust C-ABI。

## 性能设计

- 协议层序列化 + 路由分发开销 < 1ms（单次 `JSON.parse` / `Map` O(1) 查表 / 单次注入回传）。
- 长音频流绕过 JS Bridge：H5 直连本地 WS Server，二进制全双工，无 Base64 拷贝。
- Rust 侧 `Vec<u8>` 所有权传递，无拷贝；背压满时丢弃 + 告警。

## 三态架构

| 通道 | 用途 | 特性 |
| --- | --- | --- |
| Async Bridge | 常规 JSON-RPC 请求-响应 | 跨 Flutter Channel，绝对异步 |
| Sync Bypass | 纯同步调用（`callSync`） | 走 Native `@JavascriptInterface` / `dsbridge` 直连，绕过 Flutter 线程 |
| Local WS Server | 大体积多媒体流 | H5 ↔ 本地 WS，ArrayBuffer 全双工，零序列化 |

## 快速开始

### H5

```typescript
import { XBridge } from 'xbridge-js';
const bridge = new XBridge();
const token = await bridge.call('getToken');
const info = bridge.callSync('getAppInfo'); // 同步降级
```

### Flutter

```dart
final bridge = BridgeController()..attachWebViewController(controller);
bridge.addHandler('getToken', (ctx, params) => sessionService.token);
WebViewFlutterBridgeAdapter().attach(controller, bridge);
// 未注册方法自动经 FallbackChannel -> MethodChannel('xbridge/native_fallback') 透传到 Native
```

### Android Native

```kotlin
// 在 MainActivity.configureFlutterEngine 中：
XBridgePluginRegistry.register(
    flutterEngine,
    nativeBridge = XBridgeNativeBridge { method, params -> existingDsBridge.handle(method, params) },
    webView = webView,  // 注入 @JavascriptInterface 同步通道
)
```

### iOS Native

```swift
// 在 AppDelegate 中：
XBridgePlugin.register(with: registrar)
plugin.nativeBridge = AppNativeBridge { method, params in
    existingDsBridge.handle(method, params)  // app 自行实现，XBridge 不含业务
}
```

## 开发

```bash
# JS
cd packages/xbridge-js && npm install && npm run build

# Flutter
cd packages/xbridge_flutter && flutter pub get && dart analyze

# Rust
cd rust/xbridge_core && cargo test

# Android (需在宿主 app 的 Gradle 构建中编译)
# iOS (需 pod install + xcodebuild)
```

## 许可

MIT
