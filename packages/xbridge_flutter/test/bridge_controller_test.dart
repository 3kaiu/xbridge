import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xbridge_flutter/xbridge_flutter.dart';

class MockTransport implements BridgeTransport {
  final List<String> resolvedIds = [];
  final Map<String, dynamic> results = {};
  final List<String> rejectedIds = [];
  final Map<String, BridgeError> errors = {};

  @override
  Future<void> resolve(String id, dynamic result) async {
    resolvedIds.add(id);
    results[id] = result;
  }

  @override
  Future<void> reject(String id, BridgeError error) async {
    rejectedIds.add(id);
    errors[id] = error;
  }

  @override
  Future<void> dispatchEvent(BridgeEvent event) async {}

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BridgeController controller;
  late MockTransport transport;

  setUp(() {
    controller = BridgeController();
    transport = MockTransport();
    controller.setTransport(transport);
    controller.addHandler('getAppInfo', (ctx, params, req) async {
      return {'version': '1.0.0'};
    });
    controller.addHandler('payment', (ctx, params, req) async {
      return {'status': 'paid'};
    });
  });

  tearDown(() {
    controller.dispose();
  });

  test('denies all bridge calls by default when no policy is set (Fail-Closed)', () async {
    controller.setCurrentOrigin('https://app.example.com');
    final rawMsg = jsonEncode({
      'id': 'req_1',
      'method': 'getAppInfo',
      'params': {},
    });

    await controller.handleRawMessage(rawMsg);

    expect(transport.rejectedIds, contains('req_1'));
    expect(transport.errors['req_1']?.code, equals('BRIDGE_METHOD_FORBIDDEN'));
    expect(transport.resolvedIds, isEmpty);
  });

  test('allows calls matching security policy', () async {
    controller.setSecurityPolicy(
      XBridgeSecurityPolicy.allowlist({'https://app.example.com'}),
    );
    controller.setCurrentOrigin('https://app.example.com');

    final rawMsg = jsonEncode({
      'id': 'req_2',
      'method': 'getAppInfo',
      'params': {},
    });

    await controller.handleRawMessage(rawMsg);

    expect(transport.resolvedIds, contains('req_2'));
    expect(transport.results['req_2'], equals({'version': '1.0.0'}));
  });

  test('enforces method-level capability permissions strictly', () async {
    controller.setSecurityPolicy(
      XBridgeSecurityPolicy.capabilities(
        allowedOrigins: {'https://app.example.com', 'https://partner.com'},
        publicMethods: {'getAppInfo'},
        originMethodRules: {
          'https://app.example.com': {'payment'},
        },
      ),
    );

    // 1. Partner origin can call public method
    controller.setCurrentOrigin('https://partner.com');
    await controller.handleRawMessage(jsonEncode({
      'id': 'req_partner_pub',
      'method': 'getAppInfo',
      'params': {},
    }));
    expect(transport.resolvedIds, contains('req_partner_pub'));

    // 2. Partner origin cannot call sensitive 'payment' method
    await controller.handleRawMessage(jsonEncode({
      'id': 'req_partner_pay',
      'method': 'payment',
      'params': {},
    }));
    expect(transport.rejectedIds, contains('req_partner_pay'));
    expect(transport.errors['req_partner_pay']?.code, equals('BRIDGE_METHOD_FORBIDDEN'));

    // 3. Official app origin CAN call 'payment' method
    controller.setCurrentOrigin('https://app.example.com');
    await controller.handleRawMessage(jsonEncode({
      'id': 'req_app_pay',
      'method': 'payment',
      'params': {},
    }));
    expect(transport.resolvedIds, contains('req_app_pay'));
    expect(transport.results['req_app_pay'], equals({'status': 'paid'}));
  });

  test('enforces rate limiting and emits security telemetry events', () async {
    controller.setSecurityPolicy(
      XBridgeSecurityPolicy.allowlist({'https://app.example.com'}),
    );
    controller.setCurrentOrigin('https://app.example.com');
    controller.setRateLimiter(
      BridgeRateLimiter(globalLimitPerSecond: 2),
    );

    BridgeSecurityEvent? capturedEvent;
    controller.onSecurityEvent = (event) {
      capturedEvent = event;
    };

    // First 2 calls succeed
    await controller.handleRawMessage(jsonEncode({
      'id': 'rate_1',
      'method': 'getAppInfo',
      'params': {},
    }));
    await controller.handleRawMessage(jsonEncode({
      'id': 'rate_2',
      'method': 'getAppInfo',
      'params': {},
    }));
    expect(transport.resolvedIds, contains('rate_1'));
    expect(transport.resolvedIds, contains('rate_2'));

    // 3rd call is throttled
    await controller.handleRawMessage(jsonEncode({
      'id': 'rate_3',
      'method': 'getAppInfo',
      'params': {},
    }));
    expect(transport.rejectedIds, contains('rate_3'));
    expect(transport.errors['rate_3']?.code, equals('BRIDGE_RATE_LIMITED'));

    // Wait for telemetry debounce window
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(capturedEvent, isNotNull);
    expect(capturedEvent!.type, equals(BridgeSecurityEventType.rateLimitExceeded));
    expect(capturedEvent!.origin, equals('https://app.example.com'));
  });

  test('origin captured on page start immediately enables security policy validation', () async {
    controller.setSecurityPolicy(
      XBridgeSecurityPolicy.allowlist({'https://secure.example.com'}),
    );

    // Simulate onPageStarted updating origin before onPageFinished
    controller.setCurrentOrigin('https://secure.example.com');

    // H5 sends call during initial page load
    await controller.handleRawMessage(jsonEncode({
      'id': 'early_call',
      'method': 'getAppInfo',
      'params': {},
    }));

    expect(transport.resolvedIds, contains('early_call'));
    expect(transport.results['early_call'], equals({'version': '1.0.0'}));
  });
}
