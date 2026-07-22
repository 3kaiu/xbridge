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
    this.id,
    required this.method,
    this.params,
  });

  /// Parses [message] (a JSON string) into a [BridgeRequest].
  ///
  /// Throws [FormatException] when the payload is not a JSON object, or when
  /// `method` is missing or empty. A missing or empty `id` is accepted — it
  /// denotes a fire-and-forget call (no response expected).
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
    final rawId = payload['id'];
    final id = (rawId == null) ? null : '$rawId'.trim();
    final method = '${payload['method'] ?? ''}'.trim();
    if (method.isEmpty) {
      throw const FormatException('Bridge payload requires a non-empty method');
    }
    return BridgeRequest(
      id: (id == null || id.isEmpty) ? null : id,
      method: method,
      params: payload['params'],
    );
  }

  /// Correlates the request with its response. `null` for fire-and-forget
  /// calls where no response is expected.
  final String? id;

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
  BridgeResponse({this.id, this.result, this.error});

  /// Builds a success response carrying [result].
  factory BridgeResponse.success({String? id, dynamic result}) {
    return BridgeResponse(id: id, result: result);
  }

  /// Builds an error response carrying [error].
  factory BridgeResponse.error({String? id, required BridgeError error}) {
    return BridgeResponse(id: id, error: error);
  }

  /// Parses [message] (a JSON string) into a [BridgeResponse].
  ///
  /// Throws [FormatException] when the payload is not a JSON object or when
  /// `id` is missing (a response without an id is uncorrelatable and useless).
  factory BridgeResponse.parse(String message) {
    final dynamic payload;
    try {
      payload = jsonDecode(message);
    } catch (error) {
      throw FormatException('Bridge response is not valid JSON: $error');
    }
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Bridge response must be a JSON object');
    }
    final rawId = payload['id'];
    final id = (rawId == null) ? null : '$rawId'.trim();
    if (id == null || id.isEmpty) {
      throw const FormatException('Bridge response requires a non-empty id');
    }
    final rawError = payload['error'];
    BridgeError? error;
    if (rawError != null) {
      if (rawError is Map<String, dynamic>) {
        error = BridgeError(
          code: '${rawError['code'] ?? 'BRIDGE_ERROR'}',
          message: '${rawError['message'] ?? ''}',
          detail: rawError['data'],
        );
      } else {
        error = BridgeError(message: '$rawError');
      }
    }
    return BridgeResponse(id: id, result: payload['result'], error: error);
  }

  final String? id;
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
