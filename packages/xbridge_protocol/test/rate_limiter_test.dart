import 'package:test/test.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

void main() {
  group('BridgeRateLimiter', () {
    test('enforces global QPS limit', () {
      final limiter = BridgeRateLimiter(globalLimitPerSecond: 3);

      expect(limiter.check('https://app.example.com', 'foo'), isTrue);
      expect(limiter.check('https://app.example.com', 'foo'), isTrue);
      expect(limiter.check('https://app.example.com', 'foo'), isTrue);
      // 4th call within same second is rejected
      expect(limiter.check('https://app.example.com', 'foo'), isFalse);
    });

    test('enforces method-specific limit', () {
      final limiter = BridgeRateLimiter(
        globalLimitPerSecond: 10,
        methodLimits: {'payment': 2, 'getAppInfo': 5},
      );

      expect(limiter.check('https://app.example.com', 'payment'), isTrue);
      expect(limiter.check('https://app.example.com', 'payment'), isTrue);
      expect(limiter.check('https://app.example.com', 'payment'), isFalse);

      // Other methods still permitted
      expect(limiter.check('https://app.example.com', 'getAppInfo'), isTrue);
    });

    test('enforces origin-specific limit', () {
      final limiter = BridgeRateLimiter(
        globalLimitPerSecond: 20,
        originLimits: {'https://untrusted.com': 1},
      );

      expect(limiter.check('https://untrusted.com', 'foo'), isTrue);
      expect(limiter.check('https://untrusted.com', 'foo'), isFalse);

      expect(limiter.check('https://trusted.com', 'foo'), isTrue);
      expect(limiter.check('https://trusted.com', 'foo'), isTrue);
    });

    test('evicts least recently used buckets when exceeding maxTrackedBuckets', () {
      final limiter = BridgeRateLimiter(
        globalLimitPerSecond: 100,
        maxTrackedBuckets: 2,
        methodLimits: {'m1': 1, 'm2': 1, 'm3': 1},
      );

      expect(limiter.check(null, 'm1'), isTrue);
      expect(limiter.check(null, 'm2'), isTrue);
      // Accessing m3 evicts m1
      expect(limiter.check(null, 'm3'), isTrue);

      // m1 bucket was evicted so new check reallocates queue
      expect(limiter.check(null, 'm1'), isTrue);
    });
  });
}
