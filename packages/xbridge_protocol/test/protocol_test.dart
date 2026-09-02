import 'package:test/test.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

void main() {
  group('BridgeRequest', () {
    test('parses valid JSON-RPC request', () {
      const json = '{"jsonrpc":"2.0","id":"req_1","method":"getAppInfo","params":{"key":"val"}}';
      final req = BridgeRequest.parse(json);
      expect(req.id, equals('req_1'));
      expect(req.method, equals('getAppInfo'));
      expect(req.params, equals({'key': 'val'}));
    });

    test('tolerates missing jsonrpc field', () {
      const json = '{"id":"req_2","method":"test"}';
      final req = BridgeRequest.parse(json);
      expect(req.id, equals('req_2'));
      expect(req.method, equals('test'));
    });

    test('throws FormatException on empty method', () {
      const json = '{"id":"req_3","method":""}';
      expect(() => BridgeRequest.parse(json), throwsFormatException);
    });
  });

  group('BridgeResponse', () {
    test('serializes success response correctly', () {
      final res = BridgeResponse.success(id: '123', result: {'status': 'ok'});
      final json = res.toJsonString();
      expect(json, contains('"jsonrpc":"2.0"'));
      expect(json, contains('"id":"123"'));
      expect(json, contains('"result":{"status":"ok"}'));
    });

    test('serializes error response correctly', () {
      final res = BridgeResponse.error(
        id: '124',
        error: BridgeError(code: 'FORBIDDEN', message: 'Not allowed'),
      );
      final json = res.toJsonString();
      expect(json, contains('"id":"124"'));
      expect(json, contains('"error":{"code":"FORBIDDEN","message":"Not allowed"}'));
    });
  });

  group('BridgeScriptBuilder', () {
    test('safeJsonEncode escapes HTML & script tags', () {
      final input = '<script>alert("xss")</script> & line\u2028sep';
      final encoded = BridgeScriptBuilder.safeJsonEncode(input);
      expect(encoded, isNot(contains('<script>')));
      expect(encoded, isNot(contains('</script>')));
      expect(encoded, contains(r'\u003c'));
      expect(encoded, contains(r'\u0026'));
      expect(encoded, contains(r'\u2028'));
    });

    test('buildResolveScript generates correct JS', () {
      final js = BridgeScriptBuilder.buildResolveScript('cb_1', {'data': 42});
      expect(js, contains('window.__XBridge__.resolve("cb_1",{"data":42})'));
    });
  });

  group('XBridgeSecurityPolicy', () {
    test('allowAll permits any origin', () {
      final policy = XBridgeSecurityPolicy.allowAll();
      expect(policy.allows('https://example.com'), isTrue);
      expect(policy.allows('file://'), isTrue);
      expect(policy.allows(null), isTrue);
    });

    test('allowlist restricts strictly', () {
      final policy = XBridgeSecurityPolicy.allowlist({'https://example.com'});
      expect(policy.allows('https://example.com'), isTrue);
      expect(policy.allows('https://example.com/'), isTrue);
      expect(policy.allows('https://example.com:443'), isTrue);
      expect(policy.allows('https://malicious.com'), isFalse);
      expect(policy.allows(null), isFalse);
      expect(policy.allows('null'), isFalse);
      expect(policy.allows('*'), isFalse);
    });

    test('wildcard domain matching adheres to strict DNS boundaries', () {
      final policy = XBridgeSecurityPolicy.allowlist({'https://*.example.com'});
      expect(policy.allows('https://example.com'), isTrue);
      expect(policy.allows('https://app.example.com'), isTrue);
      expect(policy.allows('https://sub.app.example.com'), isTrue);
      // DNS boundary check: attacker-example.com must NOT be allowed
      expect(policy.allows('https://attacker-example.com'), isFalse);
      expect(policy.allows('https://example.com.evil.com'), isFalse);
      expect(policy.allows('http://app.example.com'), isFalse); // scheme mismatch
    });

    test('capabilities policy enforces granular method-level permissions', () {
      final policy = XBridgeSecurityPolicy.capabilities(
        allowedOrigins: {'https://app.example.com', 'https://partner.com'},
        publicMethods: {'getAppInfo', 'ping'},
        originMethodRules: {
          'https://app.example.com': {'payment', 'storage.write'},
          'https://partner.com': {'share'},
        },
      );

      // Public methods accessible to all allowed origins
      expect(policy.isMethodAllowed('https://app.example.com', 'getAppInfo'), isTrue);
      expect(policy.isMethodAllowed('https://partner.com', 'getAppInfo'), isTrue);

      // Specific methods
      expect(policy.isMethodAllowed('https://app.example.com', 'payment'), isTrue);
      expect(policy.isMethodAllowed('https://partner.com', 'payment'), isFalse);
      expect(policy.isMethodAllowed('https://partner.com', 'share'), isTrue);
      expect(policy.isMethodAllowed('https://app.example.com', 'share'), isFalse);

      // Untrusted origins rejected for all methods
      expect(policy.isMethodAllowed('https://evil.com', 'getAppInfo'), isFalse);
      expect(policy.isMethodAllowed('https://evil.com', 'payment'), isFalse);

      // (方案 A1) 非主 frame 硬门槛：即使 origin 已允许、方法已白名单，
      // isMainFrame=false 仍一律拒绝；isMainFrame=true 不受影响。
      expect(
        policy.isMethodAllowed(
          'https://app.example.com',
          'getAppInfo',
          isMainFrame: false,
        ),
        isFalse,
      );
      expect(
        policy.isMethodAllowed(
          'https://app.example.com',
          'payment',
          isMainFrame: false,
        ),
        isFalse,
      );
      expect(
        policy.isMethodAllowed(
          'https://app.example.com',
          'getAppInfo',
          isMainFrame: true,
        ),
        isTrue,
      );
      // allowAll 策略不受 frame 门槛影响（开发模式）。
      expect(
        XBridgeSecurityPolicy.allowAll().isMethodAllowed(
          'https://anything.example.com',
          'getAppInfo',
          isMainFrame: false,
        ),
        isTrue,
      );
    });
  });
}
