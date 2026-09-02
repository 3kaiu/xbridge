import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xbridge_flutter/xbridge_flutter.dart';

class _ReverseTransport implements BridgeTransport {
  final List<BridgeEvent> events = [];
  final List<({String id, String method, dynamic params})> h5Calls = [];
  bool failH5Calls = false;

  @override
  Future<void> resolve(String id, dynamic result) async {}

  @override
  Future<void> reject(String id, BridgeError error) async {}

  @override
  Future<void> dispatchEvent(BridgeEvent event) async {
    events.add(event);
  }

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) async {
    h5Calls.add((id: id, method: method, params: params));
    if (failH5Calls) {
      // Fail after recording so the test can assert the forward happened —
      // the failure is only used to complete the pending call and reply.
      throw StateError('boom');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();
  late BridgeController controller;
  late _ReverseTransport transport;

  setUp(() {
    controller = BridgeController();
    transport = _ReverseTransport();
    controller.setTransport(transport);
  });

  tearDown(() {
    controller.dispose();
    NativeReverseChannel.instance.unbind(controller);
  });

  // Native → Flutter/H5 reverse-call injection: delivers a platform message on
  // the reverse channel exactly as the native plugin would, routing it through
  // the handler registered by NativeReverseChannel.bind.
  Future<void> injectReverse(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      NativeReverseChannel.channelName,
      codec.encodeMethodCall(call),
      (ByteData? reply) {},
    );
  }

  test('routes a native pushEvent to H5 via dispatchEvent with the event name from args', () async {
    NativeReverseChannel.instance.bind(controller);

    await injectReverse(
      const MethodCall('pushEvent', {'method': 'onPayment', 'params': {'ok': true}}),
    );

    expect(transport.events, hasLength(1));
    final event = transport.events.single;
    expect(event.method, 'onPayment');
    expect(event.params, {'ok': true});
    expect(transport.h5Calls, isEmpty);
  });

  test('pushEvent with null params still dispatches an event', () async {
    NativeReverseChannel.instance.bind(controller);

    await injectReverse(
      const MethodCall('pushEvent', {'method': 'onRaw'}),
    );

    expect(transport.events, hasLength(1));
    expect(transport.events.single.method, 'onRaw');
    expect(transport.events.single.params, isNull);
  });

  test('legacy "__event__:" prefix from older native binaries still dispatches an event', () async {
    NativeReverseChannel.instance.bind(controller);

    await injectReverse(const MethodCall('__event__:onLegacy', {'a': 1}));

    expect(transport.events, hasLength(1));
    expect(transport.events.single.method, 'onLegacy');
    expect(transport.events.single.params, {'a': 1});
  });

  test('a plain business method goes to a locally-registered handler (no event misrouting)', () async {
    NativeReverseChannel.instance.bind(controller);
    controller.addHandler('getVersion', (ctx, params, req) async => '2.1.0');

    final reply = <ByteData?>[];
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      const MethodChannel(NativeReverseChannel.channelName).name,
      codec.encodeMethodCall(const MethodCall('getVersion', null)),
      (ByteData? data) => reply.add(data),
    );

    expect(transport.events, isEmpty);
    expect(transport.h5Calls, isEmpty);
    // Handler result '2.1.0' round-trips through the standard codec reply.
    final envelope = reply.single;
    expect(envelope, isNotNull);
    expect(codec.decodeEnvelope(envelope!), '2.1.0');
  });

  test('an unknown plain method is forwarded to H5 (callH5), never treated as an event', () async {
    NativeReverseChannel.instance.bind(controller);

    // Make H5 forwarding fail immediately so the pending call completes and
    // the platform-message reply is delivered without hanging the test.
    transport.failH5Calls = true;

    await injectReverse(const MethodCall('businessMethod', {'x': 1}));

    expect(transport.events, isEmpty);
    expect(transport.h5Calls, hasLength(1));
    expect(transport.h5Calls.single.method, 'businessMethod');
    expect(transport.h5Calls.single.params, {'x': 1});
  });
}