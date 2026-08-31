/// Security policy constraining which H5 origins are permitted to invoke
/// privileged bridge methods, with support for method-level capability ACLs
/// and safe wildcard domain matching.
class XBridgeSecurityPolicy {
  XBridgeSecurityPolicy({
    required Set<String> allowedOrigins,
    required this.allowAll,
    this.publicMethods = const <String>{},
    this.originMethodRules = const <String, Set<String>>{},
  })  : allowedOrigins = allowedOrigins,
        _normalizedAllowed = allowAll
            ? <String>{}
            : allowedOrigins.map(_normalizeOrigin).toSet(),
        _normalizedOriginMethodRules = originMethodRules.map(
          (origin, methods) => MapEntry(_normalizeOrigin(origin), methods),
        );

  /// Allow every origin and method — convenient for development, never use in production.
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

  /// Capability-based access control with granular method permissions.
  factory XBridgeSecurityPolicy.capabilities({
    required Set<String> allowedOrigins,
    Set<String> publicMethods = const <String>{},
    Map<String, Set<String>> originMethodRules = const <String, Set<String>>{},
  }) {
    return XBridgeSecurityPolicy(
      allowedOrigins: allowedOrigins,
      allowAll: false,
      publicMethods: publicMethods,
      originMethodRules: originMethodRules,
    );
  }

  /// The raw allowlist as passed to the constructor.
  final Set<String> allowedOrigins;

  /// Globally accessible public methods (e.g. `getAppInfo`) that any allowed origin can invoke.
  final Set<String> publicMethods;

  /// Granular method rules mapped by origin pattern (e.g. `{'https://pay.example.com': {'payment'}}`).
  final Map<String, Set<String>> originMethodRules;

  /// Pre-normalized allowlist for fast [allows] checks.
  final Set<String> _normalizedAllowed;

  /// Pre-normalized origin-to-methods map.
  final Map<String, Set<String>> _normalizedOriginMethodRules;

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
    final normalized = _normalizeOrigin(origin);
    if (_normalizedAllowed.contains(normalized)) {
      return true;
    }
    return _normalizedAllowed.any((pattern) => _matchesPattern(pattern, normalized));
  }

  /// Returns `true` if [origin] is allowed to invoke the specific [method].
  bool isMethodAllowed(String? origin, String method) {
    if (allowAll) {
      return true;
    }
    if (!allows(origin)) {
      return false;
    }
    if (publicMethods.contains(method)) {
      return true;
    }
    if (originMethodRules.isEmpty) {
      // Default: if no granular method rules are configured, all methods are permitted
      // for allowed origins (maintains full backward compatibility).
      return true;
    }
    final normalized = _normalizeOrigin(origin!);
    for (final entry in _normalizedOriginMethodRules.entries) {
      final pattern = entry.key;
      final allowedMethods = entry.value;
      if (pattern == normalized || _matchesPattern(pattern, normalized)) {
        if (allowedMethods.contains(method) || allowedMethods.contains('*')) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _matchesPattern(String pattern, String actual) {
    if (pattern == actual) return true;
    final patternSchemeIdx = pattern.indexOf('://');
    final actualSchemeIdx = actual.indexOf('://');
    if (patternSchemeIdx == -1 || actualSchemeIdx == -1) return false;

    final patternScheme = pattern.substring(0, patternSchemeIdx);
    final actualScheme = actual.substring(0, actualSchemeIdx);
    if (patternScheme != actualScheme) return false;

    final patternHost = pattern.substring(patternSchemeIdx + 3);
    final actualHost = actual.substring(actualSchemeIdx + 3);

    if (patternHost.startsWith('*.')) {
      final rootDomain = patternHost.substring(2);
      if (actualHost == rootDomain) return true;
      if (actualHost.endsWith('.$rootDomain')) return true;
    }
    return false;
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
