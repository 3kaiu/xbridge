Pod::Spec.new do |s|
  s.name             = 'XBridgeiOS'
  s.version          = '0.1.0'
  s.summary          = 'Generic, business-free cross-platform bridge SDK for iOS (Flutter fallback + sync bypass + local WS).'
  s.description      = <<-DESC
XBridgeiOS is the native iOS component of the XBridge SDK. It provides:
1. A Flutter MethodChannel receiver (`xbridge/native_fallback`) that forwards
   unregistered H5 methods to an app-supplied delegate (typically the existing
   DsBridge handler), keeping the SDK free of business logic.
2. A `XBridgeSync` WKScriptMessageHandler for bridge calls that bypass the
   async Flutter channel. (Subject to WKWebView async-delivery limitations —
   see README for the `prompt()` interception alternative.)
3. A bridge to the Rust `xbridge_core` C-ABI for starting/stopping a local
   WebSocket server on 127.0.0.1 for high-performance binary streaming.
4. A security policy struct for origin allowlists (defense-in-depth).
                       DESC
  s.homepage         = 'https://github.com/nickcao/xbridge'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'XBridge Contributors' => 'dev@xbridge.io' }

  s.ios.deployment_target = '12.0'
  s.swift_version         = '5.9'

  s.source_files = 'Sources/XBridgeiOS/**/*.swift',
                   'Sources/XBridgeiOS/**/*.h',
                   'Sources/XBridgeiOS/**/*.modulemap'

  s.weak_frameworks = 'WebKit'

  # The Rust core (xbridge_core.xcframework) is NOT bundled with this pod.
  # Consumers must build it from the `rust/xbridge_core` crate and add the
  # resulting .xcframework to their Xcode project. See README.md for details.
end
