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
/// * `window.__YASHI_APP_BRIDGE__.resolve(id, result)` /
///   `window.__YASHI_APP_BRIDGE__.reject(id, error)` — Promise settle callbacks
///   installed by `xbridge-js` (and the legacy `AppBridgeAdapter`).
/// * `window.dispatchEvent(new CustomEvent('YashiAppEvent', {detail}))` — the
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
    final script = 'window.__YASHI_APP_BRIDGE__'
        '&&window.__YASHI_APP_BRIDGE__.resolve'
        '&&window.__YASHI_APP_BRIDGE__.resolve(${safeJsonEncode(id)},${safeJsonEncode(result)});';
    return controller.runJavaScript(script);
  }

  /// Rejects the pending H5 promise for [id] with [error].
  static Future<void> reject(
    WebViewController controller,
    String id,
    dynamic error,
  ) {
    final script = 'window.__YASHI_APP_BRIDGE__'
        '&&window.__YASHI_APP_BRIDGE__.reject'
        '&&window.__YASHI_APP_BRIDGE__.reject(${safeJsonEncode(id)},${safeJsonEncode(error)});';
    return controller.runJavaScript(script);
  }

  /// Broadcasts [event] to H5 via a DOM `CustomEvent('YashiAppEvent')`.
  ///
  /// The `detail` payload matches the legacy shape (`{actionType, requestId?,
  /// params?, timestamp}`) for backward compatibility, but wraps under the
  /// XBridge event `method` so `xbridge-js` `onEvent` listeners also receive
  /// it.
  static Future<void> dispatchEvent(
    WebViewController controller,
    BridgeEvent event,
  ) {
    // Build the script in one interpolation pass — no intermediate list/join.
    final script = 'window.dispatchEvent(new CustomEvent(${safeJsonEncode(event.method)},'
        '{detail:${safeJsonEncode(event.params)}}));';
    return controller.runJavaScript(script);
  }
}
