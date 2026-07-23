/// XBridge Flutter SDK — a generic, business-free bridge for H5 ↔ Flutter.
library xbridge_flutter;

export 'package:xbridge_protocol/xbridge_protocol.dart';

export 'src/adapters/inappwebview_adapter.dart';
export 'src/adapters/webview_flutter_adapter.dart';
export 'src/bridge_controller.dart';
export 'src/bridge_method_context.dart';
export 'src/bridge_protocol.dart';
export 'src/fallback_channel.dart';
export 'src/local_web_socket_bridge.dart';
export 'src/method_channel_xbridge_platform.dart';
export 'src/native_reverse_channel.dart';
export 'src/rust_core_ffi.dart';

// Re-export the security policy & platform interface for single-import usage
export 'package:xbridge_platform_interface/xbridge_platform_interface.dart'
    show XBridgePlatform;
