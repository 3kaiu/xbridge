/// Security policy constraining which H5 origins are permitted to invoke
/// privileged bridge methods.
///
/// Platform implementations read this via
/// `XBridgePlatform.instance.setSecurityPolicy(...)` and enforce it inside the
/// local WebSocket server (origin check) as well as the native fallback route.
class XBridgeSecurityPolicy {
  XBridgeSecurityPolicy({
    required this.allowedOrigins,
    required this.allowAll,
  });

  /// Allow every origin — convenient for development, never use in production.
  factory XBridgeSecurityPolicy.allowAll() {
    return XBridgeSecurityPolicy(
      allowedOrigins: <String>{},
      allowAll: true,
    );
  }

  /// Only allow the listed origins (scheme + host [+ port]).
  factory XBridgeSecurityPolicy.allowlist(Set<String> origins) {
    return XBridgeSecurityPolicy(
      allowedOrigins: origins.toSet(),
      allowAll: false,
    );
  }

  /// Explicit allowlist. Ignored when [allowAll] is `true`.
  final Set<String> allowedOrigins;

  /// When `true`, every origin is accepted and [allowedOrigins] is ignored.
  final bool allowAll;

  /// Returns `true` when [origin] passes this policy.
  ///
  /// Matching is case-insensitive on the host segment and tolerant of a
  /// trailing slash, so callers can pass raw `window.location.origin`-style
  /// strings without extra normalization.
  bool allows(String origin) {
    if (allowAll) {
      return true;
    }
    if (origin.isEmpty) {
      return false;
    }
    final normalized = _normalizeOrigin(origin);
    for (final allowed in allowedOrigins) {
      if (_normalizeOrigin(allowed) == normalized) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeOrigin(String origin) {
    var value = origin.trim().toLowerCase();
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
