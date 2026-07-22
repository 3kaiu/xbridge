/// XBridge Flutter SDK — a generic, business-free bridge for H5 ↔ Flutter.
///
/// The public API surface consists of:
/// * [BridgeController] — the central router that dispatches H5 requests to
///   registered handlers, falls back to a [FallbackChannel] when no handler
///   matches, and enforces an [XBridgeSecurityPolicy] origin allowlist.
/// * [BridgeTransport] — pluggable JS injection contract.
/// * [BridgeRequest] / [BridgeResponse] / [BridgeEvent] / [BridgeError] —
///   the JSON-RPC 2.0 variant protocol models.
/// * [BridgeMethodContext] / [BridgeMethodHandler] — the handler contract.
/// * [BridgeJavaScriptTransport] — default transport for `webview_flutter`.
/// * [WebViewFlutterBridgeAdapter] / [InAppWebViewBridgeAdapter] — adapters
///   that wire a WebView engine into a [BridgeController].
/// * [FallbackChannel] — singleton [MethodChannel] for native passthrough.
/// * [LocalWebSocketBridge] — control-plane client for the high-perf local
///   WebSocket bypass (PRD P1).
library xbridge_flutter;

export 'src/bridge_controller.dart';
export 'src/bridge_java_script_transport.dart';
export 'src/bridge_method_context.dart';
export 'src/bridge_protocol.dart';
export 'src/fallback_channel.dart';
export 'src/local_ws_client.dart';
export 'src/adapters/inappwebview_adapter.dart';
export 'src/adapters/webview_flutter_adapter.dart';

// Re-export the security policy so consumers configure a single import.
export 'package:xbridge_platform_interface/xbridge_platform_interface.dart'
    show XBridgeSecurityPolicy, XBridgePlatform;
