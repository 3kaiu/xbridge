# XBridge

通用、开源、零业务耦合的跨端桥接 SDK。H5 / Flutter / Native 三层各自独立可用，不强制依赖其他层。

## 架构

```
┌───────────────────────────────────────┐
│  H5 层 (xbridge-js)                    │  npm 包
├───────────────────────────────────────┤
│  Flutter 层 (xbridge_flutter)          │  git 依赖，含 Android/iOS 原生代码
├───────────────────────────────────────┤
│  Native 层                             │
│  ├ Android (xbridge-android)           │  JitPack AAR
│  ├ iOS (xbridge-ios)                   │  CocoaPods
│  └ Rust core (xbridge_core)            │  build-time 源码依赖 / C-ABI
└───────────────────────────────────────┘
```

## 安装与最小示例

### H5（npm）

```bash
pnpm add @3kaiu/xbridge-js
```

```typescript
import { XBridge } from '@3kaiu/xbridge-js'
const bridge = new XBridge()
const token = await bridge.call('getToken')
```

Flutter 适配器在 attach 及每次导航时幂等注入统一 bootstrap（含 `postMessage` 自动 polyfill + `XBridgeReady` 就绪握手）。若 H5 先于注入执行（如预渲染/首屏抢跑），用 `ready()` 等待就绪后再调用：

```typescript
try {
  await bridge.ready() // resolve = 就绪；超时/无桥 reject
  const safeArea = await bridge.call('getSafeArea')
}
catch {
  // 非 App 容器或超时，走 fallback
}
```

### Flutter（git 依赖）

```yaml
# pubspec.yaml
dependencies:
  xbridge_flutter:
    git:
      url: https://github.com/3kaiu/xbridge.git
      path: packages/xbridge_flutter
      ref: v0.1.3
```

```dart
final bridge = BridgeController()..attachWebViewController(controller);
bridge.addHandler('getToken', (ctx, params) => sessionService.token);
```

Android/iOS 原生代码随 Flutter plugin 自动包含，零配置。

### Android（JitPack）

```groovy
implementation 'com.github.3kaiu.xbridge:xbridge-core:v0.1.3'
```

```kotlin
val syncInterface = XBridgeSyncInterface(
    nativeBridgeProvider = { myBridge },
    securityPolicyProvider = { XBridgeSecurityPolicy.allowlist(setOf("https://app.example.com")) },
    originProvider = { webView.url },
)
syncInterface.attach(webView)
```

### iOS（CocoaPods）

```ruby
pod 'XBridgeiOS/Core', :git => 'https://github.com/3kaiu/xbridge.git', :tag => 'v0.1.3'
```

```swift
let syncHandler = XBridgeSyncHandler()
syncHandler.nativeBridge = MyNativeBridge()
syncHandler.securityPolicy = .allowlist(["https://app.example.com"])
syncHandler.attach(to: webView)
```

### Rust（build-time 依赖）

由原生层从源码构建（`rust/xbridge_core`），或使用 CI 提供的预编译二进制，不发布到任何 registry。

## 三态通道

| 通道 | 用途 | 特性 |
| --- | --- | --- |
| Async Bridge | 常规 JSON-RPC 请求-响应 | 跨 Flutter Channel，绝对异步 |
| Sync Bypass | 纯同步调用（`callSync`） | 走 Native `@JavascriptInterface` / WKScriptMessageHandler 直连 |
| Local WS Server | 大体积多媒体流 | H5 ↔ 本地 WS，ArrayBuffer 全双工，零序列化 |

## 包结构

| 包 | 分发方式 | 依赖 Flutter？ |
| --- | --- | --- |
| xbridge-js | npm | ❌ |
| xbridge_flutter | git 依赖 | ✅ |
| xbridge_protocol | git 依赖 (纯 Dart) | ❌ |
| xbridge_platform_interface | git 依赖 | ✅ |
| xbridge-android | JitPack | ❌ (Core) / ✅ (Flutter) |
| xbridge-ios | CocoaPods | ❌ (Core) / ✅ (Flutter) |
| xbridge_core | build-time 源码 / 预编译二进制 | ❌ |

全部包位于 `packages/`（Flutter/Android/iOS/JS）与 `rust/xbridge_core`。

### 原生代码「单一事实源」约定（务必阅读）

原生层与 Flutter 层内容相同的原生能力，当前以**两份源码**形式共存：

| 唯一事实源（在此修改） | 同步副本（勿直接改逻辑） |
| --- | --- |
| `packages/xbridge-android/`（JitPack SDK） | `packages/xbridge_flutter/android/`（Flutter plugin 原生目录） |
| `packages/xbridge-ios/`（CocoaPods SDK） | `packages/xbridge_flutter/ios/`（Flutter plugin 原生目录） |

**规则：**
- Android/iOS 原生逻辑一律在**唯一事实源**（`xbridge-android` / `xbridge-ios`）修改；
- 修改后运行 `scripts/sync_native_to_flutter.sh`，把源同步到 Flutter 副本，再把副本产生的改动一并提交；
- 脚本提供 `--check` 模式，CI 会以该模式在每次 PR / main push 校验副本与源**逐字节一致**，漂移直接拦截，并输出修复指引；
- `packages/xbridge-android/.../XBridgeOriginRuleSanitizer.kt` 是独立工具（死代码），**不在**同步白名单内，副本刻意不包含它。

**为什么：** 若直接改 Flutter 副本、或两处各自演进，会导致 Android / iOS / Flutter 三端安全逻辑漂移（历史上曾因此出现过一次 Jenkins 构建失败与接口不一致）。

## 开发

```bash
# JS
cd packages/xbridge-js && npm install && npm run build

# Flutter
cd packages/xbridge_flutter && flutter pub get && dart analyze

# Rust
cd rust/xbridge_core && cargo test

# Android
cd packages/xbridge-android && ./gradlew :xbridge-core:build

# iOS (需 pod install + xcodebuild)
```

## 发布

推送 `v*` tag 触发 GitHub Actions 自动发布：

```bash
git tag v0.1.3
git push origin v0.1.3
```

- npm 自动 publish（需配置 `NPM_TOKEN` secret）
- JitPack 自动监听 tag 构建 AAR
- GitHub Release 自动创建，带安装说明

## 许可

MIT