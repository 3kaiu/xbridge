Pod::Spec.new do |s|
  s.name             = 'XBridgeiOS'
  s.version          = '0.1.4'
  s.summary          = 'Generic, business-free cross-platform bridge SDK for iOS (sync bypass + local WS + Flutter fallback).'
  s.description      = <<-DESC
XBridgeiOS is the native iOS component of the XBridge SDK. It provides:
1. A `XBridgeSync` WKScriptMessageHandler for bridge calls that bypass the
   async Flutter channel. (Subject to WKWebView async-delivery limitations —
   see README for the `prompt()` interception alternative.)
2. A bridge to the Rust `xbridge_core` C-ABI for starting/stopping a local
   WebSocket server on 127.0.0.1 for high-performance binary streaming.
3. A security policy struct for origin allowlists (defense-in-depth).
4. An optional Flutter MethodChannel receiver (`xbridge/native_fallback`).

## Subspecs

- `Core` — pure Swift, no Flutter dependency. Use in native iOS apps:
  `pod 'XBridgeiOS/Core'`
- `Flutter` — Flutter plugin glue (FlutterPlugin, MethodChannel). Use in
  Flutter apps: `pod 'XBridgeiOS/Flutter'`
                       DESC
  s.homepage         = 'https://github.com/3kaiu/xbridge'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'XBridge Contributors' => 'dev@xbridge.io' }

  # 注意：git tag 统一使用 `v` 前缀（如 v0.1.4）。这里必须带 v，否则
  # CocoaPods 会去找不带前缀的 tag（0.1.4），而仓库里并不存在该 tag，
  # 造成发布阻断。以 `v#{s.version}` 与仓库 tag 约定保持一致。
  s.source           = { :git => 'https://github.com/3kaiu/xbridge.git', :tag => "v#{s.version}" }
  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  # WebKit is needed by both subspecs (XBridgeSyncHandler uses WKScriptMessageHandler).
  s.frameworks = 'WebKit'

  # The Rust core (xbridge_core.xcframework) is NOT bundled with this pod.
  # Consumers must build it from the `rust/xbridge_core` crate and add the
  # resulting .xcframework to their Xcode project. See README.md for details.
  # This is the same pattern used by Cargokit-based Flutter+Rust plugins.

  # Preserve the C header and modulemap for consumers that link
  # xbridge_core.xcframework — they need these files available but NOT
  # compiled as Swift sources.
  s.preserve_paths = 'Sources/XBridgeiOS/WebSocket/*.h',
                     'Sources/XBridgeiOS/WebSocket/*.modulemap'
  s.xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(PODS_ROOT)/XBridgeiOS/Sources/XBridgeiOS/WebSocket'
  }

  # ── Core subspec: pure Swift, no Flutter ───────────────────────────────
  # Pure native iOS apps use this subspec:
  #   pod 'XBridgeiOS/Core'
  s.subspec 'Core' do |core|
    # All Swift files EXCEPT XBridgePlugin.swift (the Flutter glue).
    core.source_files =
      'Sources/XBridgeiOS/XBridgeSyncHandler.swift',
      'Sources/XBridgeiOS/XBridgeNativeBridge.swift',
      'Sources/XBridgeiOS/Security/**/*.swift',
      'Sources/XBridgeiOS/WebSocket/*.swift'
  end

  # ── Flutter subspec: Flutter plugin glue ───────────────────────────────
  # Flutter apps use this subspec (or Flutter toolchain auto-resolves it):
  #   pod 'XBridgeiOS/Flutter'
  s.subspec 'Flutter' do |fl|
    fl.dependency 'XBridgeiOS/Core'
    fl.dependency 'Flutter'
    fl.source_files = 'Sources/XBridgeiOS/XBridgePlugin.swift'
  end

  # Default subspec — when someone writes `pod 'XBridgeiOS'` without a
  # subspec, they get everything (including Flutter). This is correct for
  # Flutter projects where the Flutter toolchain resolves the pod.
  s.default_subspecs = 'Flutter'
end
