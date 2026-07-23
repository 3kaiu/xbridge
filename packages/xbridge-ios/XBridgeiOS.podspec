Pod::Spec.new do |s|
  s.name             = 'XBridgeiOS'
  s.version          = '0.1.0'
  s.summary          = 'Generic, business-free cross-platform bridge SDK for iOS (Flutter fallback + sync bypass + local WS).'
  s.description      = <<-DESC
XBridgeiOS is the native iOS component of the XBridge SDK. It provides:
1. A Flutter MethodChannel receiver (`xbridge/native_fallback`) that forwards
   unregistered H5 methods to an app-supplied delegate (typically the existing
   your existing native bridge handler), keeping the SDK free of business logic.
2. A `XBridgeSync` WKScriptMessageHandler for bridge calls that bypass the
   async Flutter channel. (Subject to WKWebView async-delivery limitations —
   see README for the `prompt()` interception alternative.)
3. A bridge to the Rust `xbridge_core` C-ABI for starting/stopping a local
   WebSocket server on 127.0.0.1 for high-performance binary streaming.
4. A security policy struct for origin allowlists (defense-in-depth).
                       DESC
  s.homepage         = 'https://github.com/3kaiu/xbridge'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'XBridge Contributors' => 'dev@xbridge.io' }

  s.source           = { :git => 'https://github.com/3kaiu/xbridge.git', :tag => s.version.to_s }
  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  s.source_files = 'Sources/XBridgeiOS/**/*.swift'

  # WebKit is a stable framework since iOS 8 — use strong link, not weak.
  s.frameworks = 'WebKit'

  # Flutter framework — the plugin imports the `Flutter` module and
  # implements `FlutterPlugin`. Consumers' Flutter tooling provides this.
  s.dependency 'Flutter'

  # The Rust core (xbridge_core.xcframework) is NOT bundled with this pod.
  # Consumers must build it from the `rust/xbridge_core` crate and add the
  # resulting .xcframework to their Xcode project. See README.md for details.

  # Preserve the C header and modulemap for consumers that link
  # xbridge_core.xcframework — they need these files available but NOT
  # compiled as Swift sources.
  s.preserve_paths = 'Sources/XBridgeiOS/WebSocket/*.h',
                     'Sources/XBridgeiOS/WebSocket/*.modulemap'
  s.xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(PODS_ROOT)/XBridgeiOS/Sources/XBridgeiOS/WebSocket'
  }
end
