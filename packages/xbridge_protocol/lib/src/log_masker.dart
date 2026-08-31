/// Recursive sensitive data masker for secure debug logging and telemetry.
class BridgeLogMasker {
  static const Set<String> _sensitiveKeys = <String>{
    'password',
    'passwd',
    'secret',
    'token',
    'access_token',
    'refreshtoken',
    'authorization',
    'auth',
    'card',
    'cardno',
    'cvv',
    'pin',
    'credential',
    'privatekey',
    'apikey',
  };

  /// Recursively masks sensitive keys in [data] (Maps and Lists) up to [maxDepth].
  static dynamic mask(dynamic data, {int maxDepth = 5}) {
    if (maxDepth <= 0 || data == null) {
      return data;
    }
    if (data is Map) {
      final maskedMap = <String, dynamic>{};
      for (final entry in data.entries) {
        final keyStr = '${entry.key}';
        final keyLower = keyStr.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final isSensitive = _sensitiveKeys.any((k) => keyLower.contains(k));

        if (isSensitive) {
          maskedMap[keyStr] = '***';
        } else {
          maskedMap[keyStr] = mask(entry.value, maxDepth: maxDepth - 1);
        }
      }
      return maskedMap;
    } else if (data is List) {
      return data.map((item) => mask(item, maxDepth: maxDepth - 1)).toList();
    }
    return data;
  }
}
