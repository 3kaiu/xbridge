import 'dart:convert';

/// Flutter → H5 host-pushed event (no `id`, fire-and-forget broadcast).
///
/// Emits `{"jsonrpc":"2.0","method":"<event>","params":<value>}`.
class BridgeEvent {
  BridgeEvent({required this.method, this.params});

  final String method;
  final dynamic params;

  /// Serializes to a JSON string ready to push through the WebView.
  String toJsonString() {
    final map = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      // Always include params, even if null, for JSON-RPC 2.0 conformance
      // and so the H5 side can rely on the field's presence.
      'params': params,
    };
    return jsonEncode(map);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BridgeEvent &&
          method == other.method &&
          params == other.params;

  @override
  int get hashCode => Object.hash(method, params);
}
