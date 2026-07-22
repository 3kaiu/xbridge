import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import 'bridge_protocol.dart';

/// Low-level bridge between Flutter and the H5 bridge globals.
///
/// Every method builds a single JS string (via [jsonEncode] for safe escaping)
/// and issues exactly one `runJavaScript` call — no per-call closures or
/// repeated serialization passes (PRD §3.4 sub-ms target).
///
/// The injected scripts target the existing H5 contract:
/// * `window.__XBridge__.resolve(id, result)` /
///   `window.__XBridge__.reject(id, error)` — Promise settle callbacks
///   installed by `xbridge-js` (and the legacy `FlutterChannelAdapter`).
/// * `window.dispatchEvent(new CustomEvent('XBridgeEvent', {detail}))` — the
///   host-push event channel consumed by `xbridge-js` `onEvent`.
class BridgeJavaScriptTransport {
  const BridgeJavaScriptTransport._();

  /// Escapes characters that could break out of a `<script>` context when the
  /// JSON is injected into a WebView via `runJavaScript`/`evaluateJavascript`.
  ///
  /// `jsonEncode` already escapes quotes and backslashes, but it leaves `<`,
  /// `>`, `&`, and `</` untouched — an attacker-controlled string containing
  /// `</script>` would terminate the surrounding `<script>` tag and enable
  /// HTML injection. This method post-processes the encoded JSON to neutralize
  /// those sequences.
  static String safeJsonEncode(dynamic value) {
    final encoded = jsonEncode(value);
    // Order matters: replace `</` first so it becomes `<\/` (which is valid
    // JSON since `\/` is a valid escape), then escape `<`, `>`, `&`.
    return encoded
        .replaceAll('</', '<\\/')
        .replaceAll('<', '\\u003c')
        .replaceAll('>', '\\u003e')
        .replaceAll('&', '\\u0026');
  }

  /// Resolves the pending H5 promise for [id] with [result].
  ///
  /// Guards the global so a missing bootstrap (H5 not yet ready) is a silent
  /// no-op rather than a JS error.
  static Future<void> resolve(
    WebViewController controller,
    String id,
    dynamic result,
  ) {
    final script = 'window.__XBridge__'
        '&&window.__XBridge__.resolve'
        '&&window.__XBridge__.resolve(${safeJsonEncode(id)},${safeJsonEncode(result)});';
    return controller.runJavaScript(script);
  }

  /// Rejects the pending H5 promise for [id] with [error].
  static Future<void> reject(
    WebViewController controller,
    String id,
    dynamic error,
  ) {
    final script = 'window.__XBridge__'
        '&&window.__XBridge__.reject'
        '&&window.__XBridge__.reject(${safeJsonEncode(id)},${safeJsonEncode(error)});';
    return controller.runJavaScript(script);
  }

  /// Broadcasts [event] to H5 via a DOM `CustomEvent('XBridgeEvent')`.
  ///
  /// The `detail` payload matches the legacy shape (`{actionType, params,
  /// timestamp}`) that the H5 `FlutterChannelAdapter` expects — it listens for the
  /// literal `"XBridgeEvent"` event type and routes by `detail.actionType`.
  static Future<void> dispatchEvent(
    WebViewController controller,
    BridgeEvent event,
  ) {
    final detail = <String, dynamic>{
      'actionType': event.method,
      'params': event.params,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    final script = 'window.dispatchEvent(new CustomEvent(${safeJsonEncode('XBridgeEvent')},'
        '{detail:${safeJsonEncode(detail)}}));';
    return controller.runJavaScript(script);
  }

  /// Sends a JSON-RPC request to H5, invoking a handler registered via
  /// `XBridge.registerHandler` on the H5 side.
  ///
  /// The H5 SDK installs `window.__XBridgeInbound__` which feeds the raw JSON
  /// string into `XBridgeCore.handleRaw()`. The H5 side looks up the handler
  /// by `method`, invokes it, and sends back a response (carrying the same
  /// `id`) via the adapter's `send` channel. The response is then routed to
  /// the pending [Completer] in [BridgeController.handleRawMessage].
  static Future<void> callH5Handler(
    WebViewController controller,
    String id,
    String method,
    dynamic params,
  ) {
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    final script = 'window.__XBridgeInbound__'
        '&&window.__XBridgeInbound__(${safeJsonEncode(jsonEncode(request))});';
    return controller.runJavaScript(script);
  }
}
