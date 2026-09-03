Pod::Spec.new do |s|
  s.name             = 'xbridge_flutter'
  s.version          = '0.1.5'
  s.summary          = 'XBridge Flutter plugin — bridge SDK for H5 ↔ Flutter ↔ Native.'
  s.description      = <<-DESC
XBridge Flutter plugin provides the native Android and iOS integration for
the XBridge cross-platform bridge SDK. It includes:
1. A Flutter MethodChannel receiver (`xbridge/native_fallback`).
2. A bridge to the Rust `xbridge_core` C-ABI for local WebSocket server.
3. A security policy struct for origin allowlists.

The bridge is strictly async JSON-RPC: H5 calls flow
`window.XBridge.postMessage` → JavaScriptChannel → Dart method handler →
this native bridge. No synchronous bypass channel.
                       DESC
  s.homepage         = 'https://github.com/3kaiu/xbridge'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'XBridge' => 'https://github.com/3kaiu/xbridge' }

  s.source           = { :git => 'https://github.com/3kaiu/xbridge.git', :tag => "v#{s.version}" }
  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  s.source_files = 'Classes/**/*.swift'

  # Flutter framework — provided by the host app's Flutter tooling.
  s.dependency 'Flutter'

  # The Rust core (xbridge_core.xcframework) is NOT bundled.
  # Consumers must build it from the `rust/xbridge_core` crate and add the
  # resulting .xcframework to their Xcode project. See README.md for details.

  # Preserve the C header and modulemap for consumers that link
  # xbridge_core.xcframework.
  s.preserve_paths = 'Classes/WebSocket/*.h',
                     'Classes/WebSocket/*.modulemap'
  s.xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(PODS_ROOT)/xbridge_flutter/Classes/WebSocket'
  }
end
