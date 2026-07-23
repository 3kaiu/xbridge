import 'dart:convert';

import 'bridge_event.dart';

/// Centralized JavaScript code generator and safe JSON encoding utilities.
///
/// Pure Dart class — zero dependencies on Flutter framework or WebViews.
class BridgeScriptBuilder {
  const BridgeScriptBuilder._();

  /// Unified bootstrap script injected into WebView on initialization.
  /// Standardizes `window.XBridge` and `window.__XBridge__` across all WebViews.
  static const String unifiedBootstrap = '''
(function() {
  'use strict';
  if (window.__xbridge_initialized__) return;
  Object.defineProperty(window, '__xbridge_initialized__', {
    value: true, writable: false, configurable: false, enumerable: false
  });
  var bridge = window.__XBridge__ || {};
  bridge.resolve = bridge.resolve || function(){};
  bridge.reject = bridge.reject || function(){};
  Object.defineProperty(window, '__XBridge__', {
    value: bridge, writable: false, configurable: false, enumerable: false
  });
  Object.defineProperty(window, '__XBridgeInbound__', {
    value: function(){}, writable: true, configurable: false, enumerable: false
  });
})();
''';

  /// Escapes characters that could break out of a `<script>` context.
  ///
  /// `jsonEncode` escapes quotes and backslashes, but leaves `<`, `>`, `&`,
  /// `</`, and Unicode line separators intact. This method neutralizes them.
  static String safeJsonEncode(dynamic value) {
    final encoded = jsonEncode(value);
    return encoded
        .replaceAll('</', '<\\/')
        .replaceAll('<', '\\u003c')
        .replaceAll('>', '\\u003e')
        .replaceAll('&', '\\u0026')
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
  }

  /// Builds JS snippet to resolve a pending H5 promise.
  static String buildResolveScript(String id, dynamic result) {
    final encodedResult = _tryEncode(result);
    return 'window.__XBridge__'
        '&&window.__XBridge__.resolve'
        '&&window.__XBridge__.resolve(${safeJsonEncode(id)},$encodedResult);';
  }

  /// Builds JS snippet to reject a pending H5 promise.
  static String buildRejectScript(String id, dynamic error) {
    final encodedError = _tryEncode(error);
    return 'window.__XBridge__'
        '&&window.__XBridge__.reject'
        '&&window.__XBridge__.reject(${safeJsonEncode(id)},$encodedError);';
  }

  /// Tries to JSON-encode [value]; falls back to `null` if the value is not
  /// serializable (e.g. a custom Dart object). This prevents an unhandled
  /// exception from leaving the H5 promise permanently unresolved.
  static String _tryEncode(dynamic value) {
    try {
      return safeJsonEncode(value);
    } catch (_) {
      return 'null';
    }
  }

  /// Builds JS snippet to dispatch a host event via CustomEvent.
  static String buildEventScript(BridgeEvent event, {int? timestampMs}) {
    final detail = <String, dynamic>{
      'actionType': event.method,
      'params': event.params,
      'timestamp': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
    };
    return 'window.dispatchEvent(new CustomEvent(${safeJsonEncode('XBridgeEvent')},'
        '{detail:${safeJsonEncode(detail)}}));';
  }

  /// Builds JS snippet to call an H5 registered handler via `__XBridgeInbound__`.
  static String buildCallH5Script(String id, String method, dynamic params) {
    final request = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    return 'window.__XBridgeInbound__'
        '&&window.__XBridgeInbound__(${safeJsonEncode(request)});';
  }
}
