import 'package:webview_flutter/webview_flutter.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import '../bridge_controller.dart';

/// Adapter that wires a `webview_flutter` [WebViewController] into a
/// [BridgeController].
class WebViewFlutterBridgeAdapter {
  WebViewController? _attachedController;
  BridgeController? _attachedBridge;

  /// Attach this adapter to [controller] and [bridge].
  ///
  /// Optionally pass [hostNavigationDelegate] so that existing app-level
  /// navigation callbacks (such as page progress, resource errors, or URL routing)
  /// are preserved and invoked alongside bridge lifecycle events.
  void attach(
    WebViewController controller,
    BridgeController bridge, {
    String channelName = 'XBridge',
    NavigationDelegate? hostNavigationDelegate,
  }) {
    bridge.setTransport(_WebViewFlutterTransport(controller));
    controller.addJavaScriptChannel(
      channelName,
      onMessageReceived: (JavaScriptMessage message) {
        bridge.handleRawMessage(message.message);
      },
    );

    // Install composite NavigationDelegate that hooks lifecycle events
    // without clobbering host app callbacks.
    controller.setNavigationDelegate(
      createNavigationDelegate(
        controller: controller,
        bridge: bridge,
        hostDelegate: hostNavigationDelegate,
      ),
    );

    // 1. Initial bootstrap injection (for already loaded or current frame)
    controller.runJavaScript(BridgeScriptBuilder.unifiedBootstrap).catchError((_) {});

    // 2. Initial origin capture
    controller.currentUrl().then((url) {
      if (url != null && url.isNotEmpty) {
        bridge.setCurrentOrigin(_extractOrigin(url));
      }
    }).catchError((_) {});

    _attachedController = controller;
    _attachedBridge = bridge;
  }

  /// Creates a [NavigationDelegate] combining bridge lifecycle management
  /// (bootstrap injection, origin tracking) with an optional [hostDelegate].
  NavigationDelegate createNavigationDelegate({
    required WebViewController controller,
    required BridgeController bridge,
    NavigationDelegate? hostDelegate,
  }) {
    return NavigationDelegate(
      onPageStarted: (String url) {
        bridge.setCurrentOrigin(_extractOrigin(url));
        controller.runJavaScript(BridgeScriptBuilder.unifiedBootstrap).catchError((_) {});
        hostDelegate?.onPageStarted?.call(url);
      },
      onPageFinished: (String url) async {
        bridge.setCurrentOrigin(_extractOrigin(url));
        controller.runJavaScript(BridgeScriptBuilder.unifiedBootstrap).catchError((_) {});
        hostDelegate?.onPageFinished?.call(url);
      },
      onProgress: hostDelegate?.onProgress,
      onWebResourceError: hostDelegate?.onWebResourceError,
      onNavigationRequest: hostDelegate?.onNavigationRequest,
    );
  }

  void detach({String channelName = 'XBridge'}) {
    final controller = _attachedController;
    if (controller != null) {
      controller.removeJavaScriptChannel(channelName);
      controller.setNavigationDelegate(NavigationDelegate());
    }
    // Clear the transport on the bridge so post-detach calls fail loudly
    // instead of silently operating on a detached WebView.
    _attachedBridge?.setTransport(_DisposedTransport());
    _attachedController = null;
    _attachedBridge = null;
  }
}

/// Extracts the origin (scheme://host[:port]) from a full URL.
/// Returns `null` if the URL is null or cannot be parsed.
String? _extractOrigin(String? url) {
  if (url == null || url.isEmpty) return null;
  try {
    final uri = Uri.parse(url);
    if (!uri.hasScheme || uri.host.isEmpty) return null;
    final origin = '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
    return origin;
  } catch (_) {
    return null;
  }
}

class _WebViewFlutterTransport implements BridgeTransport {
  _WebViewFlutterTransport(this._controller);

  final WebViewController _controller;

  @override
  Future<void> resolve(String id, dynamic result) =>
      _controller.runJavaScript(BridgeScriptBuilder.buildResolveScript(id, result));

  @override
  Future<void> reject(String id, BridgeError error) =>
      _controller.runJavaScript(BridgeScriptBuilder.buildRejectScript(id, error.toJson()));

  @override
  Future<void> dispatchEvent(BridgeEvent event) =>
      _controller.runJavaScript(BridgeScriptBuilder.buildEventScript(event));

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) =>
      _controller.runJavaScript(BridgeScriptBuilder.buildCallH5Script(id, method, params));
}

/// Transport that throws on all calls — used after `detach` to ensure
/// callers get a clear error instead of silently operating on a detached
/// WebView.
class _DisposedTransport implements BridgeTransport {
  @override
  Future<void> resolve(String id, dynamic result) async {
    throw StateError('[XBridge] WebView adapter has been detached');
  }

  @override
  Future<void> reject(String id, BridgeError error) async {
    throw StateError('[XBridge] WebView adapter has been detached');
  }

  @override
  Future<void> dispatchEvent(BridgeEvent event) async {
    throw StateError('[XBridge] WebView adapter has been detached');
  }

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) async {
    throw StateError('[XBridge] WebView adapter has been detached');
  }
}
