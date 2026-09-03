import 'package:xbridge_protocol/xbridge_protocol.dart';
import 'package:test/test.dart';

/// Bare-bones [ScriptTransport] that records every evaluation for assertions.
class RecordingTransport extends ScriptTransport {
  final List<String> evaluations = <String>[];

  /// When set, every evaluation throws instead of recording (simulating a
  /// detached/broken WebView).
  String? failMessage;

  @override
  Future<void> evaluateScript(String source) async {
    final fail = failMessage;
    if (fail != null) {
      throw StateError(fail);
    }
    evaluations.add(source);
  }
}

void main() {
  group('BatchingTransport (microtask mode, flushInterval: null)', () {
    test('coalesces a synchronous burst of resolves into ONE evaluation', () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(inner);

      batching.resolve('a', 1);
      batching.resolve('b', 2);
      batching.resolve('c', 3);

      // Allow the scheduled microtask to drain the burst.
      await Future<void>.delayed(Duration.zero);

      expect(inner.evaluations, hasLength(1));
      // The single evaluation must carry all three correlation ids in order.
      // `safeJsonEncode` produces JSON (double-quoted) string literals.
      final script = inner.evaluations.single;
      final idA = script.indexOf('"a"');
      final idB = script.indexOf('"b"');
      final idC = script.indexOf('"c"');
      expect(idA, isNot(-1));
      expect(idB, isNot(-1));
      expect(idC, isNot(-1));
      expect(idA < idB && idB < idC, isTrue,
          reason: 'batch order must match enqueue order');

      batching.dispose();
    });

    test('flush() drains synchronously regardless of the scheduling mode', () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(inner);

      batching.reject(
        'r1',
        BridgeError(code: 'BRIDGE_ERROR', message: 'boom'),
      );
      // flush() must push the buffered snippet to the inner transport now,
      // without waiting for the microtask.
      await batching.flush();

      expect(batching.pendingCount, 0);
      expect(inner.evaluations, hasLength(1));
      expect(inner.evaluations.single, contains('r1'));

      batching.dispose();
    });

    test('dispatchEvent and callH5Handler share the same coalescing', () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(inner);

      final event = BridgeEvent(method: 'onNetworkChange', params: {'up': true});
      batching.dispatchEvent(event);
      batching.callH5Handler('h5_1', 'getUserConfirmation', {'q': 'ok?'});

      await batching.flush();

      expect(inner.evaluations, hasLength(1));
      final script = inner.evaluations.single;
      expect(script, contains('onNetworkChange'));
      expect(script, contains('h5_1'));
      expect(script, contains('getUserConfirmation'));

      batching.dispose();
    });

    test('a failed batch evaluation is swallowed and does not break later calls',
        () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(inner);

      // Poison the next (and only) batch.
      inner.failMessage = 'WebView detached';
      batching.resolve('dead', 1);
      await batching.flush();
      // Failure must be swallowed: flush() completes normally.
      expect(inner.evaluations, isEmpty);

      // Recovery: unpoison and confirm the transport still works.
      inner.failMessage = null;
      batching.resolve('alive', 2);
      await batching.flush();
      expect(inner.evaluations, hasLength(1));
      expect(inner.evaluations.single, contains('alive'));

      batching.dispose();
    });

    test('dispose() flushes pending snippets and blocks further enqueue', () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(inner);

      batching.resolve('pre_dispose', 1);
      await batching.dispose();

      expect(inner.evaluations, hasLength(1));
      expect(inner.evaluations.single, contains('pre_dispose'));

      // Enqueue after dispose must fail loudly, not silently drop.
      await expectLater(
        batching.resolve('post_dispose', 2),
        throwsStateError,
      );
    });
  });

  group('BatchingTransport (time-window mode)', () {
    test('coalesces a steady stream into one evaluation per interval', () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(
        inner,
        flushInterval: const Duration(milliseconds: 10),
      );

      // Emit snippets across several event-loop turns (each `await` lets the
      // timer-based flush window accumulate them instead of a microtask drain).
      batching.resolve('e1', 1);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      batching.resolve('e2', 2);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      batching.resolve('e3', 3);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // All three emitted within the window coalesce into a single evaluation.
      expect(inner.evaluations, hasLength(1));
      final script = inner.evaluations.single;
      expect(script, contains('e1'));
      expect(script, contains('e2'));
      expect(script, contains('e3'));

      batching.dispose();
    });

    test('a stream longer than the window flushes in multiple batches', () async {
      final inner = RecordingTransport();
      final batching = BatchingTransport(
        inner,
        flushInterval: const Duration(milliseconds: 10),
      );

      batching.resolve('w1', 1);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      batching.resolve('w2', 2);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      // Two separate windows → two evaluations, each carrying one snippet.
      expect(inner.evaluations, hasLength(2));
      expect(inner.evaluations[0], contains('w1'));
      expect(inner.evaluations[1], contains('w2'));

      batching.dispose();
    });
  });
}
