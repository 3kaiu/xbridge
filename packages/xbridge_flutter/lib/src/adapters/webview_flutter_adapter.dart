import 'package:webview_flutter/webview_flutter.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import '../bridge_controller.dart';

/// Adapter that wires a `webview_flutter` [WebViewController] into a
/// [BridgeController].
class WebViewFlutterBridgeAdapter {
  WebViewController? _attachedController;
  BridgeController? _attachedBridge;
  BridgeTransport? _attachedTransport;

  /// Set by [detach] and cleared by [attach].
  ///
  /// While true, inbound channel messages are dropped before they reach the
  /// bridge. The JS-side invalidation script is the primary defense, but on
  /// some platforms it may not take effect (Android's `addJavascriptInterface`
  /// host object can expose read-only properties), so the Dart side must
  /// enforce the post-detach cut-off deterministically.
  bool _detached = false;

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
  ///
  /// Attach is expected to be paired with a single [detach] when the WebView
  /// is permanently torn down. Detaching while reusing the same controller is
  /// unsupported — see [detach] for why.
  void attach(
    WebViewController controller,
    BridgeController bridge, {
    String channelName = 'XBridge',
    NavigationDelegate? hostNavigationDelegate,
    bool enableBatching = true,
    Duration? flushInterval,
  }) {
    _detached = false;
    final inner = _WebViewFlutterTransport(controller);
    final BridgeTransport transport = enableBatching
        ? BatchingTransport(inner, flushInterval: flushInterval)
        : inner;
    bridge.setTransport(transport);
    _attachedTransport = transport;
    controller.addJavaScriptChannel(
      channelName,
      onMessageReceived: (JavaScriptMessage message) {
        // Dart-side inbound gate: the JS invalidation script can fail to land
        // (e.g. read-only host object on Android), so post-detach messages
        // must be dropped here where the cut-off is always enforceable.
        if (_detached) {
          return;
        }
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

  /// Detaches this adapter from the previously attached WebView.
  ///
  /// Contract: only call this when the WebView is about to be destroyed.
  ///
  /// On webview_flutter_wkwebview, `removeJavaScriptChannel` is implemented as
  /// "remove ALL user scripts + message handlers, then re-add them
  /// asynchronously" (`_resetUserScripts`). During that window a still-running
  /// old document keeps its stale `window.XBridge`, and any
  /// `XBridge.postMessage` from it synchronously throws a native
  /// `InvalidAccessError`. Therefore detach deliberately does NOT remove the
  /// JavaScript channel. Instead it injects an invalidation script that
  /// replaces `window.<channelName>` with a thrower whose error carries
  /// `name === 'XBridgeSendError'` — the sentinel the JS adapter's circuit
  /// breaker recognizes, so late sends fail loudly but safely.
  ///
  /// The buffered transport is flushed and the bridge is switched to a
  /// [BrokenBridgeTransport] so post-detach native-side traffic fails fast.
  ///
  /// As the last line of defense, inbound messages arriving after [detach]
  /// are dropped at the Dart layer: the invalidation script may fail to land
  /// on some platforms (e.g. Android's `addJavascriptInterface` host object
  /// can expose read-only properties), so this Dart-side guard — not the JS
  /// script — is the authoritative cut-off for post-detach requests.
  void detach({String channelName = 'XBridge'}) {
    _detached = true;
    final controller = _attachedController;
    if (controller != null) {
      controller
          .runJavaScript(BridgeScriptBuilder.buildInvalidationScript(channelName))
          .catchError((_) {});
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
