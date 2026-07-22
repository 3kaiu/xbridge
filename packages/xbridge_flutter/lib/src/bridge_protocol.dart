import 'dart:convert';

/// A single H5 → Flutter RPC request parsed from the wire.
///
/// The wire format is a JSON-RPC 2.0 variant:
/// `{"jsonrpc":"2.0","id":"<string>","method":"<string>","params":<any>}`.
/// For backward compatibility with the legacy `{id,method,params}` shape used
/// by the existing `CommonJsBridge`, [BridgeRequest.parse] tolerates the
/// absence of the `jsonrpc` marker — only `id` and `method` are required.
class BridgeRequest {
  BridgeRequest({
    required this.id,
    required this.method,
    this.params,
  });

  /// Parses [message] (a JSON string) into a [BridgeRequest].
  ///
  /// Throws [FormatException] when the payload is not a JSON object, or when
  /// `id`/`method` are missing or empty.
  factory BridgeRequest.parse(String message) {
    final dynamic payload;
    try {
      payload = jsonDecode(message);
    } catch (error) {
      throw FormatException('Bridge payload is not valid JSON: $error');
    }
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Bridge payload must be a JSON object');
    }
    final id = '${payload['id'] ?? ''}'.trim();
    final method = '${payload['method'] ?? ''}'.trim();
    if (id.isEmpty || method.isEmpty) {
      throw const FormatException('Bridge payload requires non-empty id and method');
    }
    return BridgeRequest(id: id, method: method, params: payload['params']);
  }

  /// Correlates the request with its response. UUID on the H5 side.
  final String id;

  /// The method name to route to a registered handler.
  final String method;

  /// Arbitrary JSON-decoded params (may be `null`, a primitive, a `List`, or
  /// a `Map<String, dynamic>`).
  final dynamic params;

  @override
  String toString() => 'BridgeRequest(id=$id, method=$method)';
}

/// Error envelope returned to H5 on handler failure.
///
/// Contract gap (documented):
/// The H5 `xbridge-js` SDK models `XBridgeError.code` as a **number**
/// (JSON-RPC 2.0 convention), while the legacy Flutter `CommonJsBridge`
/// modeled `BridgeError.code` as a **String** (e.g. `'BRIDGE_ERROR'`,
/// `'BRIDGE_METHOD_FORBIDDEN'`, `'INVALID_PARAMS'`). To keep both ecosystems
/// interoperable without a breaking rename, the Flutter side emits String
/// codes and the JS dispatcher treats the code loosely (accepts either form).
/// New code should prefer the human-readable String codes.
class BridgeError {
  const BridgeError({
    this.code = 'BRIDGE_ERROR',
    required this.message,
    this.detail,
  });

  /// Stable, human-readable error code (e.g. `'BRIDGE_METHOD_FORBIDDEN'`).
  final String code;

  /// Human-readable error description.
  final String message;

  /// Optional structured detail payload.
  final Object? detail;

  /// Serializes to the JSON-RPC 2.0 error object shape.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code,
      'message': message,
      if (detail != null) 'data': detail,
    };
  }

  /// Coerces an arbitrary thrown object into a [BridgeError].
  ///
  /// [BridgeError] instances are returned as-is; everything else is wrapped
  /// with the default `BRIDGE_ERROR` code.
  factory BridgeError.from(Object error) {
    if (error is BridgeError) {
      return error;
    }
    return BridgeError(message: '$error');
  }

  @override
  String toString() => 'BridgeError($code: $message)';
}

/// Flutter → H5 success/error response.
///
/// Emits `{"jsonrpc":"2.0","id":"<id>","result":<value>}` on success or
/// `{"jsonrpc":"2.0","id":"<id>","error":{...}}` on failure. Exactly one of
/// [result]/[error] is non-null.
class BridgeResponse {
  BridgeResponse({required this.id, this.result, this.error});

  /// Builds a success response carrying [result].
  factory BridgeResponse.success({required String id, dynamic result}) {
    return BridgeResponse(id: id, result: result);
  }

  /// Builds an error response carrying [error].
  factory BridgeResponse.error({required String id, required BridgeError error}) {
    return BridgeResponse(id: id, error: error);
  }

  final String id;
  final dynamic result;
  final BridgeError? error;

  /// Serializes to a JSON string ready to push through the WebView.
  String toJsonString() {
    final map = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
    };
    if (error != null) {
      map['error'] = error!.toJson();
    } else {
      map['result'] = result;
    }
    return jsonEncode(map);
  }
}

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
    };
    if (params != null) {
      map['params'] = params;
    }
    return jsonEncode(map);
  }
}
