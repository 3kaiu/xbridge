import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../bridge_controller.dart';
import '../bridge_java_script_transport.dart';
import '../bridge_protocol.dart';

/// Adapter that wires a `flutter_inappwebview` [InAppWebViewController] into a
/// [BridgeController].
///
/// Attach inside `onWebViewCreated`:
///
/// ```dart
/// InAppWebView(
///   onWebViewCreated: (controller) {
///     InAppWebViewBridgeAdapter().attach(controller, bridge);
///   },
///   onLoadStop: (controller, uri) {
///     InAppWebViewBridgeAdapter().onLoadStop(controller, bridge);
///   },
/// )
/// ```
///
/// Because `InAppWebViewController` is not a `webview_flutter`
/// `WebViewController`, this adapter installs a dedicated [BridgeTransport]
/// (via [BridgeController.setTransport]) that injects JS through
/// `evaluateJavascript` instead of `runJavaScript`.
class InAppWebViewBridgeAdapter {
  void attach(
    InAppWebViewController controller,
    BridgeController bridge, {
    String handlerName = 'XBridge',
  }) {
    // Install the transport first so handleRawMessage can respond immediately.
    bridge.setTransport(_InAppWebViewTransport(controller));
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (List<dynamic> args) {
        // The H5 SDK calls callHandler('XBridge', jsonStr); args[0] is the
        // raw JSON string. Fire-and-forget — the response is pushed back via
        // the transport's resolve/reject, not via the handler return value.
        final raw = args.isEmpty ? '' : '${args.first}';
        bridge.handleRawMessage(raw);
      },
    );
    // Bootstrap the H5-side global so resolve/reject references don't throw
    // before Flutter has answered.
    controller.evaluateJavascript(source: _bootstrapScript).catchError((_) => '');

    // Best-effort origin population on attach — covers the initial page load
    // when the WebView already has a URL. Subsequent navigations should wire
    // [onLoadStop] into the InAppWebView widget callback.
    controller.getUrl().then((url) {
      bridge.setCurrentOrigin(url?.toString());
    }).catchError((_) {});
  }

  /// Call this from the `InAppWebView` widget's `onLoadStop` callback to keep
  /// the bridge's current origin in sync with navigation.
  void onLoadStop(InAppWebViewController controller, BridgeController bridge) {
    controller.getUrl().then((url) {
      bridge.setCurrentOrigin(url?.toString());
    }).catchError((_) {});
  }

  static const String _bootstrapScript = ''
      'window.__XBridge__=window.__XBridge__||{'
      'resolve:function(){},'
      'reject:function(){}'
      '};';
}

/// [BridgeTransport] backed by an [InAppWebViewController].
///
/// Mirrors [BridgeJavaScriptTransport]'s script construction (single
/// interpolation, [BridgeJavaScriptTransport.safeJsonEncode] for escaping)
/// but injects via `evaluateJavascript` instead of `runJavaScript`.
class _InAppWebViewTransport implements BridgeTransport {
  _InAppWebViewTransport(this._controller);

  final InAppWebViewController _controller;

  @override
  Future<void> resolve(String id, dynamic result) {
    final script = 'window.__XBridge__'
        '&&window.__XBridge__.resolve'
        '&&window.__XBridge__.resolve(${BridgeJavaScriptTransport.safeJsonEncode(id)},${BridgeJavaScriptTransport.safeJsonEncode(result)});';
    return _controller.evaluateJavascript(source: script);
  }

  @override
  Future<void> reject(String id, BridgeError error) {
    final script = 'window.__XBridge__'
        '&&window.__XBridge__.reject'
        '&&window.__XBridge__.reject(${BridgeJavaScriptTransport.safeJsonEncode(id)},${BridgeJavaScriptTransport.safeJsonEncode(error.toJson())});';
    return _controller.evaluateJavascript(source: script);
  }

  @override
  Future<void> dispatchEvent(BridgeEvent event) {
    final detail = <String, dynamic>{
      'actionType': event.method,
      'params': event.params,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final script = 'window.dispatchEvent(new CustomEvent(${BridgeJavaScriptTransport.safeJsonEncode('XBridgeEvent')},'
        '{detail:${BridgeJavaScriptTransport.safeJsonEncode(detail)}}));';
    return _controller.evaluateJavascript(source: script);
  }

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) {
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final script = 'window.__XBridgeInbound__'
        '&&window.__XBridgeInbound__(${BridgeJavaScriptTransport.safeJsonEncode(jsonEncode(request))});';
    return _controller.evaluateJavascript(source: script);
  }
}
