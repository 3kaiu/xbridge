import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbridge_flutter/xbridge_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(FallbackChannel.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mockHandler(Future<dynamic> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  test('forwards a method and returns the native result', () async {
    mockHandler((call) async {
      expect(call.method, 'getAppInfo');
      expect(call.arguments, {'v': 1});
      return 'native-ok';
    });

    final result = await FallbackChannel.instance.invoke('getAppInfo', {'v': 1});
    expect(result, 'native-ok');
  });

  test('maps a native PlatformException to a BridgeError', () async {
    mockHandler((call) async {
      throw PlatformException(code: 'NATIVE_ERROR', message: 'boom');
    });

    await expectLater(
      FallbackChannel.instance.invoke('fail', null),
      throwsA(
        isA<BridgeError>()
            .having((e) => e.code, 'code', 'NATIVE_ERROR')
            .having((e) => e.message, 'message', 'boom'),
      ),
    );
  });

  test('times out when the native handler never responds', () async {
    // Native handler never calls `result` — the invoke must not hang forever.
    mockHandler((call) => Completer<dynamic>().future);

    await expectLater(
      FallbackChannel.instance.invoke(
        'hang',
        null,
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(
        isA<BridgeError>().having((e) => e.code, 'code', 'BRIDGE_TIMEOUT'),
      ),
    );
  });
}
