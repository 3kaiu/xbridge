import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import '../bridge_controller.dart';

/// Adapter that wires a `flutter_inappwebview` [InAppWebViewController] into a
/// [BridgeController].
class InAppWebViewBridgeAdapter {
  BridgeTransport? _attachedTransport;

  /// Attach this adapter to the [controller] and [bridge].
  ///
  /// **Important**: You MUST also call [onLoadStop] from your
  /// `InAppWebView` widget's `onLoadStop` and `onUpdateVisitedHistory`
  /// callbacks. Without this, the origin is captured only at attach time
  /// and never updates on navigation — a page that navigates to an
  /// untrusted origin would still pass the security policy check using
  /// the stale trusted origin.
  ///
  /// [enableBatching] wraps the transport in a [BatchingTransport] that
  /// coalesces outbound JS evaluations (resolves/rejects/events) per
  /// synchronous tick into a single WebView evaluation — a large win for
  /// bursty H5 traffic with zero added latency. Pass `false` to evaluate each
  /// snippet separately. [flushInterval] switches batching to time-window
  /// mode for steady high-frequency event streams; `null` keeps microtask
  /// batching.
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
    bool enableBatching = true,
    Duration? flushInterval,
  }) {
    final inner = _InAppWebViewTransport(controller);
    final BridgeTransport transport = enableBatching
        ? BatchingTransport(inner, flushInterval: flushInterval)
        : inner;
    bridge.setTransport(transport);
    _attachedTransport = transport;
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (List<dynamic> args) {
        final raw = args.isEmpty ? '' : '${args.first}';
        bridge.handleRawMessage(raw);
      },
    );

    controller.evaluateJavascript(source: BridgeScriptBuilder.unifiedBootstrap).catchError((_) => '');

    // Set initial origin. Navigation updates can be wired via onLoadStart / onLoadStop.
    controller.getUrl().then((url) {
      bridge.setCurrentOrigin(_extractOrigin(url?.toString()));
    }).catchError((_) {});
  }

  /// Update the origin and re-inject protocol bootstrap at the start of navigation.
  void onLoadStart(InAppWebViewController controller, BridgeController bridge, {WebUri? url}) {
    if (url != null) {
      bridge.setCurrentOrigin(_extractOrigin(url.toString()));
    } else {
      controller.getUrl().then((u) {
        bridge.setCurrentOrigin(_extractOrigin(u?.toString()));
      }).catchError((_) {});
    }
    controller.evaluateJavascript(source: BridgeScriptBuilder.unifiedBootstrap).catchError((_) => '');
  }

  /// Update the current origin and ensure bootstrap is active after navigation.
  void onLoadStop(InAppWebViewController controller, BridgeController bridge, {WebUri? url}) {
    if (url != null) {
      bridge.setCurrentOrigin(_extractOrigin(url.toString()));
    } else {
      controller.getUrl().then((u) {
        bridge.setCurrentOrigin(_extractOrigin(u?.toString()));
      }).catchError((_) {});
    }
    controller.evaluateJavascript(source: BridgeScriptBuilder.unifiedBootstrap).catchError((_) => '');
  }

  void detach(
    InAppWebViewController controller,
    BridgeController bridge, {
    String handlerName = 'XBridge',
  }) {
    controller.removeJavaScriptHandler(handlerName: handlerName);
    // Flush any buffered outbound snippets before the transport is replaced:
    // a batch still queued at detach time would otherwise be lost.
    final transport = _attachedTransport;
    if (transport is BatchingTransport) {
      transport.dispose();
    }
    bridge
      ..setTransport(BrokenBridgeTransport('InAppWebView'))
      ..setCurrentOrigin(null);
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
    return '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
  } catch (_) {
    return null;
  }
}

class _InAppWebViewTransport extends ScriptTransport {
  _InAppWebViewTransport(this._controller);

  final InAppWebViewController _controller;

  @override
  Future<void> evaluateScript(String source) =>
      _controller.evaluateJavascript(source: source);
}
