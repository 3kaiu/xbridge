import 'package:webview_flutter/webview_flutter.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import '../bridge_controller.dart';

/// Adapter that wires a `webview_flutter` [WebViewController] into a
/// [BridgeController].
class WebViewFlutterBridgeAdapter {
  WebViewController? _attachedController;
  BridgeController? _attachedBridge;
  BridgeTransport? _attachedTransport;

  /// Attach this adapter to [controller] and [bridge].
  ///
  /// Optionally pass [hostNavigationDelegate] so that existing app-level
  /// navigation callbacks (such as page progress, resource errors, or URL routing)
  /// are preserved and invoked alongside bridge lifecycle events.
  ///
  /// [enableBatching] wraps the transport in a [BatchingTransport] that
  /// coalesces outbound JS evaluations (resolves/rejects/events) per synchronous
  /// tick into a single WebView evaluation — a large win for bursty H5 traffic
  /// with zero added latency. Pass `false` to evaluate each snippet separately.
  /// [flushInterval] switches batching to time-window mode (at most one
  /// evaluation per interval) for steady high-frequency event streams; `null`
  /// keeps microtask batching.
  void attach(
    WebViewController controller,
    BridgeController bridge, {
    String channelName = 'XBridge',
    NavigationDelegate? hostNavigationDelegate,
    bool enableBatching = true,
    Duration? flushInterval,
  }) {
    final inner = _WebViewFlutterTransport(controller);
    final BridgeTransport transport = enableBatching
        ? BatchingTransport(inner, flushInterval: flushInterval)
        : inner;
    bridge.setTransport(transport);
    _attachedTransport = transport;
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
    // Flush any buffered outbound snippets before the transport is replaced:
    // a batch still queued at detach time would otherwise be lost.
    final transport = _attachedTransport;
    if (transport is BatchingTransport) {
      transport.dispose();
    }
    // Clear the transport on the bridge so post-detach calls fail loudly
    // instead of silently operating on a detached WebView.
    _attachedBridge?.setTransport(BrokenBridgeTransport('WebView'));
    _attachedController = null;
    _attachedBridge = null;
    _attachedTransport = null;
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

class _WebViewFlutterTransport extends ScriptTransport {
  _WebViewFlutterTransport(this._controller);

  final WebViewController _controller;

  @override
  Future<void> evaluateScript(String source) =>
      _controller.runJavaScript(source);
}
