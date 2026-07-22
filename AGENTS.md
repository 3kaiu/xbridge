# AGENTS.md

XBridge 是一个 Monorepo，包含 JS / Flutter / Rust / Android / iOS 五个语言域的独立包。请遵守以下约定。

## 仓库布局

```
xbridge/
├── packages/
│   ├── xbridge-js/                  # H5 TypeScript SDK (NPM)
│   ├── xbridge_flutter/             # Flutter Dart SDK (Pub)
│   ├── xbridge_platform_interface/  # Flutter 平台接口层
│   ├── xbridge-android/             # Android 原生 SDK (Maven/Gradle)
│   └── xbridge-ios/                 # iOS 原生 SDK (CocoaPods)
├── rust/
│   └── xbridge_core/                # Rust Local WS Server (高性能流旁路, C-ABI)
├── README.md
└── .gitignore
```

## 核心原则

1. **零业务耦合**：核心源码中禁止出现 `getToken`、`YashiApi`、`PaymentService`、`AudioPlayer` 等业务领域词汇。平台通道名（`AppBridge`、`humanBridge`、`dsbridge`、`flutter_inappwebview`）属于宿主协议契约，允许保留。
2. **协议优先**：所有端遵循 JSON-RPC 2.0 变体（`{jsonrpc:"2.0", id, method, params, result, error}`）。协议字段是不可变契约。
3. **三态架构**：Async Bridge（常规 JSON-RPC）、Sync Bypass（`callSync` 走 Native 直连）、Local WS Server（大体积二进制流旁路）。
4. **性能**：协议层序列化 + 路由开销须 < 1ms。单次 parse、单次 Map 查表、单次注入回传。流数据零 Base64、零拷贝。

## 各包构建与测试

### xbridge-js
```bash
cd packages/xbridge-js
npm install
npm run build        # tsc -> dist/
npm run typecheck   # tsc --noEmit
```
- 无运行时依赖，ID 生成用原生 `crypto.randomUUID`。
- 严格模式，`unknown` 而非 `any`。

### xbridge_flutter + xbridge_platform_interface
```bash
cd packages/xbridge_flutter
flutter pub get
dart analyze         # 必须 0 issues
```
- 依赖 `webview_flutter` 与 `flutter_inappwebview`（双引擎，可选）。
- `BridgeController.handleRawMessage` 是性能关键路径：单次 `jsonDecode` + 单次 Map 查表 + 单次 `jsonEncode`。
- 透传 Native 用 `MethodChannel('xbridge/native_fallback')`（动态路由，**禁用 Pigeon** 处理业务报文 —— 见审计 Risk 4）。

### rust/xbridge_core
```bash
cd rust/xbridge_core
cargo check
cargo test
```
- 仅绑定 `127.0.0.1`（loopback），禁止 `0.0.0.0`。
- 二进制帧 `Vec<u8>` 所有权传递，无拷贝；背压满时丢弃 + 告警。
- C-ABI（`xbridge_ws_start` / `xbridge_ws_stop` / `xbridge_ws_set_binary_callback`）供 Android JNI / Swift 桥接。

### xbridge-android
- `io.xbridge` 包，`minSdk 21`，Maven 分发（`io.xbridge:xbridge-android:0.1.0`）。
- `XBridgePlugin` 接收 `MethodChannel('xbridge/native_fallback')`，转发给 app 注入的 `XBridgeNativeBridge` delegate（业务无关，app 自行转发到现有 DsBridge）。
- `XBridgeSyncInterface` 注入 `window.XBridgeSync`，`@JavascriptInterface callSync` 用 `CountDownLatch` 跨线程同步分发到主线程。
- `LocalWsServerJni` 桥接 Rust `libxbridge_core.so`（放在 `src/main/jniLibs/<abi>/`），`System.loadLibrary` 失败时优雅降级。
- **限制**：二进制帧回调 JNI 桥需 native shim，已文档化（文本控制帧可用，二进制建议 H5 直连 WS）。

### xbridge-ios
- `XBridgeiOS` module，Swift 5.9，iOS 12+，CocoaPods 分发。
- `XBridgePlugin: FlutterPlugin` 接收透传，转发给 `XBridgeNativeBridge` protocol（app 实现）。
- `XBridgeSyncHandler` 注入 `window.XBridgeSync`，**诚实声明 iOS WKWebView 的 `add(_:name:)` 是异步交付**，`callSync` 返回 Promise 占位，真实同步需 `prompt()` 拦截替代方案（文档化）。
- `LocalWsServerBridge` 通过 `import XBridgeCoreC`（module.modulemap + xbridge_core.h）调用 Rust C-ABI，`#if canImport` 守卫，未链接时优雅失败。
- `xbridge_core.xcframework` 由 Rust `cargo build` + `lipo`/`xcodebuild -create-xcframework` 产出，app 需加入 Xcode 项目。

## 契约兼容性（迁移约束）

- H5 端 `nativeBridge.ts` 对外函数签名（`callHandler`、`callWKBridge`、`waitForBridgeEvent` 等）必须 100% 保持兼容。
- Flutter 端 `CommonJsBridge` 的 `BridgeError.code` 是 **String**（如 `'BRIDGE_ERROR'`），而 JS 协议层 `error.code` 是 number。调度时按松匹配处理，迁移层负责适配。
- Flutter 未注册的方法必须透传回 Native 旧插件，不得丢失。

## Git 约定

- 不主动执行 `git commit` / `push` / `rebase`，除非用户明确授权。
- 分支命名：`feat/*`、`fix/*`、`perf/*`。
