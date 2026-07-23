/// Security policy constraining which H5 origins are permitted to invoke
/// privileged bridge methods.
class XBridgeSecurityPolicy {
  XBridgeSecurityPolicy({
    required Set<String> allowedOrigins,
    required this.allowAll,
  })  : allowedOrigins = allowedOrigins,
        _normalizedAllowed = allowAll
            ? <String>{}
            : allowedOrigins.map(_normalizeOrigin).toSet();

  /// Allow every origin — convenient for development, never use in production.
  factory XBridgeSecurityPolicy.allowAll() {
    return XBridgeSecurityPolicy(
      allowedOrigins: <String>{},
      allowAll: true,
    );
  }

  /// Deny all origins — secure default. Use [allowAll] for development or
  /// [allowlist] for production.
  factory XBridgeSecurityPolicy.denyAll() {
    return XBridgeSecurityPolicy(
      allowedOrigins: <String>{},
      allowAll: false,
    );
  }

  /// Only allow the listed origins (scheme + host [+ port]).
  factory XBridgeSecurityPolicy.allowlist(Set<String> origins) {
    return XBridgeSecurityPolicy(
      allowedOrigins: origins,
      allowAll: false,
    );
  }

  /// The raw allowlist as passed to the constructor.
  final Set<String> allowedOrigins;

  /// Pre-normalized allowlist for O(1) [allows] checks.
  final Set<String> _normalizedAllowed;

  /// When `true`, every origin is accepted and [allowedOrigins] is ignored.
  final bool allowAll;

  /// Returns `true` when [origin] passes this policy.
  ///
  /// Rejects `null`, empty, `"null"`, and `"*"` origins unconditionally
  /// (matching the Rust WS server's security behavior).
  bool allows(String? origin) {
    if (allowAll) {
      return true;
    }
    if (origin == null || origin.isEmpty) {
      return false;
    }
    // Reject "null" origin (sandboxed iframes, data: URIs) and wildcard "*"
    // to match the Rust WS server's security checks.
    if (origin == 'null' || origin == '*') {
      return false;
    }
    return _normalizedAllowed.contains(_normalizeOrigin(origin));
  }

  static String _normalizeOrigin(String origin) {
    var value = origin.trim().toLowerCase();
    // Strip trailing slashes.
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    // Strip default ports for http/https.
    if (value.startsWith('https://')) {
      final host = value.substring(8);
      value = host.endsWith(':443')
          ? 'https://${host.substring(0, host.length - 4)}'
          : 'https://$host';
    } else if (value.startsWith('http://')) {
      final host = value.substring(7);
      value = host.endsWith(':80')
          ? 'http://${host.substring(0, host.length - 3)}'
          : 'http://$host';
    }
    return value;
  }
}
