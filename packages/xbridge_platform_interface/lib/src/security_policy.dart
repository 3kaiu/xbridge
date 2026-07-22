/// Security policy constraining which H5 origins are permitted to invoke
/// privileged bridge methods.
///
/// Platform implementations read this via
/// `XBridgePlatform.instance.setSecurityPolicy(...)` and enforce it inside the
/// local WebSocket server (origin check) as well as the native fallback route.
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

  /// Only allow the listed origins (scheme + host [+ port]).
  factory XBridgeSecurityPolicy.allowlist(Set<String> origins) {
    return XBridgeSecurityPolicy(
      allowedOrigins: origins,
      allowAll: false,
    );
  }

  /// The raw allowlist as passed to the constructor. Pre-normalized set
  /// is in [_normalizedAllowed] for O(1) lookup. Ignored when [allowAll].
  final Set<String> allowedOrigins;

  /// Pre-normalized allowlist for O(1) [allows] checks.
  final Set<String> _normalizedAllowed;

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
    return _normalizedAllowed.contains(_normalizeOrigin(origin));
  }

  static String _normalizeOrigin(String origin) {
    var value = origin.trim().toLowerCase();
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
