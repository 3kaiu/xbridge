import 'dart:convert';

/// A single H5 → Flutter RPC request parsed from the wire.
///
/// The wire format is a JSON-RPC 2.0 variant:
/// `{"jsonrpc":"2.0","id":"<string>","method":"<string>","params":<any>}`.
/// For backward compatibility with the legacy `{id,method,params}` shape,
/// [BridgeRequest.parse] tolerates the absence of the `jsonrpc` marker — only
/// `id` and `method` are required.
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
    return BridgeRequest.fromMap(payload);
  }

  /// Builds a [BridgeRequest] from an already JSON-decoded [Map].
  ///
  /// Use this when the message was already decoded by the router to avoid
  /// a redundant second `jsonDecode` pass (PRD §3.4 single-decode path).
  factory BridgeRequest.fromMap(dynamic payload) {
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Bridge payload must be a JSON object');
    }
    // Validate jsonrpc version when present. Absence is tolerated for
    // backward compatibility, but an explicit wrong version is rejected.
    final rawVersion = payload['jsonrpc'];
    if (rawVersion != null && rawVersion != '2.0') {
      throw FormatException(
        'Unsupported jsonrpc version: $rawVersion (expected "2.0")',
      );
    }
    final rawId = payload['id'];
    final id = (rawId == null) ? null : '$rawId'.trim();
    // Per JSON-RPC 2.0, method MUST be a string. Reject non-string types
    // instead of silently coercing them.
    final rawMethod = payload['method'];
    if (rawMethod is! String) {
      throw const FormatException(
        'Bridge payload requires a string method field',
      );
    }
    final method = rawMethod.trim();
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
  String toString() => 'BridgeRequest(id=$id, method=$method, params=$params)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BridgeRequest &&
          id == other.id &&
          method == other.method &&
          params == other.params;

  @override
  int get hashCode => Object.hash(id, method, params);
}
