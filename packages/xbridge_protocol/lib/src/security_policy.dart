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
  ///
  /// **fail-closed**：只有显式白名单命中才放行；其余默认拒绝。
  /// 删除了旧版「[originMethodRules] 为空即放行全部方法」的宽松兜底，
  /// 否则只配置 [allowedOrigins] + [publicMethods] 时能力级鉴权形同虚设。
  ///
  /// [isMainFrame] 是 frame 归属硬门槛（方案 A1）：
  /// - `null`（默认，存量调用方未确证 frame）按主 frame 处理，向后兼容；
  /// - `false` 表示来自明确的非主 frame（iframe / 子 frame），**一律拒绝**，
  ///   早于 origin/method 判定——即使 [allowedOrigins] 命中也不例外。
  bool isMethodAllowed(String? origin, String method, {bool? isMainFrame = true}) {
    if (allowAll) {
      return true;
    }
    // frame 归属硬门槛：确证非主 frame 的调用直接拒绝。
    if (isMainFrame != null && !isMainFrame) {
      return false;
    }
    if (!allows(origin)) {
      return false;
    }
    // 显式公共白名单命中即放行。
    if (publicMethods.contains(method)) {
      return true;
    }
    // 按来源细分的方法规则；规则非空时才参与判决。
    if (originMethodRules.isNotEmpty) {
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
    }
    // 未命中任何白名单：默认拒绝。
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
