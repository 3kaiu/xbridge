import 'dart:convert';

/// Standard error codes used across the bridge.
class BridgeErrorCode {
  BridgeErrorCode._();

  /// Method not registered on the Flutter side.
  static const String methodNotFound = 'METHOD_NOT_FOUND';

  /// Handler threw an exception.
  static const String handlerError = 'HANDLER_ERROR';

  /// Security policy denied the call.
  static const String methodForbidden = 'BRIDGE_METHOD_FORBIDDEN';

  /// Generic bridge error.
  static const String bridgeError = 'BRIDGE_ERROR';

  /// Timeout waiting for response.
  static const String timeout = 'BRIDGE_TIMEOUT';

  /// Invalid request format.
  static const String invalidRequest = 'BRIDGE_INVALID_REQUEST';
}

/// Error envelope returned to H5 on handler failure.
class BridgeError {
  BridgeError({
    this.code = BridgeErrorCode.bridgeError,
    required this.message,
    this.detail,
    this.stackTrace,
  });

  /// Stable, human-readable error code (e.g. `'BRIDGE_METHOD_FORBIDDEN'`).
  final String code;

  /// Human-readable error description.
  final String message;

  /// Optional structured detail payload.
  final Object? detail;

  /// Preserved stack trace from the original thrown error, if any.
  final StackTrace? stackTrace;

  /// Serializes to the JSON-RPC 2.0 error object shape.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code,
      'message': message,
      if (detail != null) 'data': detail,
    };
  }

  /// Coerces an arbitrary thrown object into a [BridgeError], preserving
  /// the stack trace for debugging.
  factory BridgeError.from(Object error, [StackTrace? stackTrace]) {
    if (error is BridgeError) {
      return error;
    }
    return BridgeError(
      message: '$error',
      stackTrace: stackTrace,
    );
  }

  @override
  String toString() => 'BridgeError($code: $message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BridgeError &&
          code == other.code &&
          message == other.message &&
          detail == other.detail;

  @override
  int get hashCode => Object.hash(code, message, detail);
}

/// Flutter → H5 success/error response.
///
/// Emits `{"jsonrpc":"2.0","id":"<id>","result":<value>}` on success or
/// `{"jsonrpc":"2.0","id":"<id>","error":{...}}` on failure.
class BridgeResponse {
  BridgeResponse({this.id, this.result, this.error}) {
    if (result != null && error != null) {
      throw ArgumentError(
        'result and error are mutually exclusive per JSON-RPC 2.0',
      );
    }
  }

  /// Whether this is an error response.
  bool get isError => error != null;

  /// Whether this is a success response.
  bool get isSuccess => error == null;

  /// Builds a success response carrying [result].
  factory BridgeResponse.success({String? id, dynamic result}) {
    return BridgeResponse(id: id, result: result);
  }

  /// Builds an error response carrying [error].
  factory BridgeResponse.error({String? id, required BridgeError error}) {
    return BridgeResponse(id: id, error: error);
  }

  /// Parses [message] (a JSON string) into a [BridgeResponse].
  factory BridgeResponse.parse(String message) {
    final dynamic payload;
    try {
      payload = jsonDecode(message);
    } catch (error) {
      throw FormatException('Bridge response is not valid JSON: $error');
    }
    return BridgeResponse.fromMap(payload);
  }

  /// Builds a [BridgeResponse] from an already JSON-decoded [Map].
  factory BridgeResponse.fromMap(dynamic payload) {
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Bridge response must be a JSON object');
    }
    final rawId = payload['id'];
    final id = (rawId == null) ? null : '$rawId'.trim();
    // A response with null/empty id is a protocol violation — the caller
    // cannot correlate it to a pending request. Instead of throwing (which
    // could leave the caller in a hang state), log a warning and return a
    // response with a null id so the caller can detect and ignore it.
    if (id == null || id.isEmpty) {
      // Print to avoid pulling in package:logging for a protocol-only package.
      // ignore: avoid_print
      print('[XBridge] Warning: received response with null/empty id, ignoring');
      return BridgeResponse(id: null, result: payload['result']);
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
