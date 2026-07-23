import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import '../bridge_controller.dart';

/// Adapter that wires a `flutter_inappwebview` [InAppWebViewController] into a
/// [BridgeController].
class InAppWebViewBridgeAdapter {
  /// Attach this adapter to the [controller] and [bridge].
  ///
  /// **Important**: You MUST also call [onLoadStop] from your
  /// `InAppWebView` widget's `onLoadStop` and `onUpdateVisitedHistory`
  /// callbacks. Without this, the origin is captured only at attach time
  /// and never updates on navigation — a page that navigates to an
  /// untrusted origin would still pass the security policy check using
  /// the stale trusted origin.
  ///
  /// ```dart
  /// InAppWebView(
  ///   onLoadStop: (controller, url) {
  ///     adapter.onLoadStop(controller, bridge);
  ///   },
  ///   ...
  /// )
  /// ```
  void attach(
    InAppWebViewController controller,
    BridgeController bridge, {
    String handlerName = 'XBridge',
  }) {
    bridge.setTransport(_InAppWebViewTransport(controller));
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (List<dynamic> args) {
        final raw = args.isEmpty ? '' : '${args.first}';
        bridge.handleRawMessage(raw);
      },
    );

    controller.evaluateJavascript(source: BridgeScriptBuilder.unifiedBootstrap).catchError((_) => '');

    // Set initial origin. Navigation updates MUST be wired by the caller
    // via onLoadStop() — see the attach() doc above.
    controller.getUrl().then((url) {
      bridge.setCurrentOrigin(_extractOrigin(url?.toString()));
    }).catchError((_) {});
  }

  /// Update the current origin after navigation. Call this from your
  /// `InAppWebView` widget's `onLoadStop` and `onUpdateVisitedHistory`
  /// callbacks to keep the security policy origin in sync.
  void onLoadStop(InAppWebViewController controller, BridgeController bridge) {
    controller.getUrl().then((url) {
      bridge.setCurrentOrigin(_extractOrigin(url?.toString()));
    }).catchError((_) {});
  }

  void detach(
    InAppWebViewController controller,
    BridgeController bridge, {
    String handlerName = 'XBridge',
  }) {
    controller.removeJavaScriptHandler(handlerName: handlerName);
    bridge
      ..setTransport(_NullTransport())
      ..setCurrentOrigin(null);
  }
}

/// Extracts the origin (scheme://host[:port]) from a full URL.
/// Returns `null` if the URL is null or cannot be parsed.
String? _extractOrigin(String? url) {
  if (url == null || url.isEmpty) return null;
  try {
    final uri = Uri.parse(url);
    if (!uri.hasScheme || uri.host.isEmpty) return null;
    return '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
  } catch (_) {
    return null;
  }
}

class _InAppWebViewTransport implements BridgeTransport {
  _InAppWebViewTransport(this._controller);

  final InAppWebViewController _controller;

  @override
  Future<void> resolve(String id, dynamic result) {
    return _controller.evaluateJavascript(source: BridgeScriptBuilder.buildResolveScript(id, result));
  }

  @override
  Future<void> reject(String id, BridgeError error) {
    return _controller.evaluateJavascript(source: BridgeScriptBuilder.buildRejectScript(id, error.toJson()));
  }

  @override
  Future<void> dispatchEvent(BridgeEvent event) {
    return _controller.evaluateJavascript(source: BridgeScriptBuilder.buildEventScript(event));
  }

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) {
    return _controller.evaluateJavascript(source: BridgeScriptBuilder.buildCallH5Script(id, method, params));
  }
}

class _NullTransport implements BridgeTransport {
  @override
  Future<void> resolve(String id, dynamic result) async {
    throw StateError('[XBridge] InAppWebView adapter has been detached');
  }
  @override
  Future<void> reject(String id, BridgeError error) async {
    throw StateError('[XBridge] InAppWebView adapter has been detached');
  }
  @override
  Future<void> dispatchEvent(BridgeEvent event) async {
    throw StateError('[XBridge] InAppWebView adapter has been detached');
  }
  @override
  Future<void> callH5Handler(String id, String method, dynamic params) async {
    throw StateError('[XBridge] InAppWebView adapter has been detached');
  }
}
