import 'dart:collection';

/// Sliding window rate limiter for bridge method invocations.
///
/// Uses a monotonic [Stopwatch] to prevent clock skew/manipulation from
/// disrupting rate calculations, and maintains a bounded LRU bucket cache
/// ([maxTrackedBuckets]) to prevent memory exhaustion from malicious origins.
class BridgeRateLimiter {
  BridgeRateLimiter({
    this.globalLimitPerSecond = 100,
    this.methodLimits = const <String, int>{},
    this.originLimits = const <String, int>{},
    this.maxTrackedBuckets = 256,
    this.windowDuration = const Duration(seconds: 1),
  })  : _stopwatch = Stopwatch()..start(),
        _windowMs = windowDuration.inMilliseconds;

  /// Maximum invocations allowed across all methods and origins per second.
  final int globalLimitPerSecond;

  /// Granular method-level QPS limits (e.g. `{'payment': 2}`).
  final Map<String, int> methodLimits;

  /// Granular origin-level QPS limits.
  final Map<String, int> originLimits;

  /// Maximum distinct keys tracked in memory to prevent OOM.
  final int maxTrackedBuckets;

  /// Window size for the sliding window calculation.
  final Duration windowDuration;
  final int _windowMs;

  final Stopwatch _stopwatch;

  /// Global request timestamps (monotonic ms).
  final Queue<int> _globalTimestamps = Queue<int>();

  /// Key-specific request timestamps (key -> Queue of monotonic ms).
  /// LinkedHashMap acts as an LRU cache when keys are accessed.
  final LinkedHashMap<String, Queue<int>> _buckets =
      LinkedHashMap<String, Queue<int>>();

  /// Checks if an invocation for [method] from [origin] is allowed under rate limits.
  ///
  /// Returns `true` if allowed, or `false` if the rate limit is exceeded.
  bool check(String? origin, String method) {
    final nowMs = _stopwatch.elapsedMilliseconds;
    _pruneTimestamps(_globalTimestamps, nowMs);

    // 1. Check Global Limit
    if (globalLimitPerSecond > 0 && _globalTimestamps.length >= globalLimitPerSecond) {
      return false;
    }

    // 2. Check Method Limit
    final methodLimit = methodLimits[method];
    if (methodLimit != null && methodLimit > 0) {
      final methodKey = 'method:$method';
      final queue = _getOrCreateBucket(methodKey);
      _pruneTimestamps(queue, nowMs);
      if (queue.length >= methodLimit) {
        return false;
      }
    }

    // 3. Check Origin Limit
    if (origin != null && origin.isNotEmpty) {
      final originLimit = originLimits[origin];
      if (originLimit != null && originLimit > 0) {
        final originKey = 'origin:$origin';
        final queue = _getOrCreateBucket(originKey);
        _pruneTimestamps(queue, nowMs);
        if (queue.length >= originLimit) {
          return false;
        }
      }
    }

    // Record usage
    _globalTimestamps.add(nowMs);
    if (methodLimit != null && methodLimit > 0) {
      _getOrCreateBucket('method:$method').add(nowMs);
    }
    if (origin != null && origin.isNotEmpty && originLimits[origin] != null) {
      _getOrCreateBucket('origin:$origin').add(nowMs);
    }

    return true;
  }

  Queue<int> _getOrCreateBucket(String key) {
    var queue = _buckets.remove(key);
    if (queue == null) {
      if (_buckets.length >= maxTrackedBuckets) {
        // Evict least recently accessed bucket
        _buckets.remove(_buckets.keys.first);
      }
      queue = Queue<int>();
    }
    _buckets[key] = queue; // Re-insert at end (most recently used)
    return queue;
  }

  void _pruneTimestamps(Queue<int> queue, int nowMs) {
    final cutoff = nowMs - _windowMs;
    while (queue.isNotEmpty && queue.first < cutoff) {
      queue.removeFirst();
    }
  }

  /// Reset all tracked metrics and counters.
  void reset() {
    _globalTimestamps.clear();
    _buckets.clear();
  }
}
