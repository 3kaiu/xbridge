import 'package:test/test.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

void main() {
  group('BridgeSecurityTelemetry', () {
    test('coalesces rapid repeated events and accumulates violationCount', () async {
      final telemetry = BridgeSecurityTelemetry(
        coalesceWindow: const Duration(milliseconds: 50),
      );

      BridgeSecurityEvent? capturedEvent;
      telemetry.onEvent = (event) {
        capturedEvent = event;
      };

      // Rapidly fire 5 events
      for (var i = 0; i < 5; i++) {
        telemetry.record(
          type: BridgeSecurityEventType.rateLimitExceeded,
          origin: 'https://attacker.com',
          method: 'payment',
          message: 'Rate limit exceeded',
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(capturedEvent, isNotNull);
      expect(capturedEvent!.type, equals(BridgeSecurityEventType.rateLimitExceeded));
      expect(capturedEvent!.origin, equals('https://attacker.com'));
      expect(capturedEvent!.method, equals('payment'));
      expect(capturedEvent!.violationCount, equals(5));

      telemetry.dispose();
    });
  });

  group('BridgeLogMasker', () {
    test('recursively masks sensitive keys while preserving other fields', () {
      final input = {
        'username': 'alice',
        'password': 'secret_password_123',
        'auth_token': 'Bearer xyz789',
        'nested': {
          'apiKey': 'AIzaSyD-12345',
          'cardNo': '6222021234567890',
          'normalField': 42,
          'innerList': [
            {'credential': 'super_secret', 'item': 'book'},
          ],
        },
      };

      final masked = BridgeLogMasker.mask(input);

      expect(masked['username'], equals('alice'));
      expect(masked['password'], equals('***'));
      expect(masked['auth_token'], equals('***'));
      expect(masked['nested']['apiKey'], equals('***'));
      expect(masked['nested']['cardNo'], equals('***'));
      expect(masked['nested']['normalField'], equals(42));
      expect(masked['nested']['innerList'][0]['credential'], equals('***'));
      expect(masked['nested']['innerList'][0]['item'], equals('book'));
    });
  });
}
