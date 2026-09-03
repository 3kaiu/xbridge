import 'dart:async';

import 'bridge_event.dart';
import 'bridge_response.dart';
import 'bridge_script_builder.dart';

/// Pluggable JS transport contract.
///
/// Adapters (e.g. `WebViewFlutterBridgeAdapter`, `InAppWebViewBridgeAdapter`)
/// implement this interface to route outgoing calls into a concrete WebView instance.
///
/// Pure protocol contract — zero WebView dependencies.
abstract class BridgeTransport {
  Future<void> resolve(String id, dynamic result);
  Future<void> reject(String id, BridgeError error);
  Future<void> dispatchEvent(BridgeEvent event);
  Future<void> callH5Handler(String id, String method, dynamic params);
}

/// A [BridgeTransport] whose four protocol operations funnel through a single
/// raw JS-evaluation primitive.
///
/// Concrete WebView adapters extend this and only implement [evaluateScript];
/// [resolve] / [reject] / [dispatchEvent] / [callH5Handler] are generated from
/// [BridgeScriptBuilder] by the shared default implementations below. This
/// removes per-adapter duplication and gives [BatchingTransport] a single seam
/// to hook into for coalescing evaluations.
abstract class ScriptTransport implements BridgeTransport {
  /// Evaluate [source] as JavaScript in the attached WebView context.
  Future<void> evaluateScript(String source);

  @override
  Future<void> resolve(String id, dynamic result) =>
      evaluateScript(BridgeScriptBuilder.buildResolveScript(id, result));

  @override
  Future<void> reject(String id, BridgeError error) =>
      evaluateScript(BridgeScriptBuilder.buildRejectScript(id, error.toJson()));

  @override
  Future<void> dispatchEvent(BridgeEvent event) =>
      evaluateScript(BridgeScriptBuilder.buildEventScript(event));

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) =>
      evaluateScript(BridgeScriptBuilder.buildCallH5Script(id, method, params));
}

/// Buffers outgoing JS snippets and flushes them as a single evaluation.
///
/// Every WebView JS evaluation is a real bridge round-trip (platform channel +
/// engine evaluation), so per-snippet evaluation is the dominant cost on the
/// Flutter → H5 path. When a synchronous burst produces multiple outbound
/// messages (several H5 requests resolved in one handler, a burst of pushed
/// events, a batch of reverse calls), this transport coalesces them into one
/// JavaScript string joined by `;` and performs a single evaluation instead of N.
///
/// Flush scheduling:
/// - **Microtask mode** (default, `flushInterval: null`): the first enqueue
///   schedules a microtask, so everything queued in the same synchronous tick
///   drains in one evaluation with **zero added latency** — the burst case is
///   the common one and gets the full benefit.
/// - **Time-window mode** (`flushInterval` given): a timer flushes at most once
///   per interval, coalescing a steady event stream into one evaluation per
///   window at the cost of up to one window of delivery latency.
/// - [flush] forces an immediate drain in either mode (e.g. right before
///   navigation or teardown).
///
/// ## Failure semantics
/// A failed batch evaluation drops all snippets contained in it (the H5 side
/// owns ultimate retry via its per-request timeout) — never partially applies
/// a split batch, which would make correlation impossible.
class BatchingTransport implements BridgeTransport {
  BatchingTransport(
    this._inner, {
    this.flushInterval,
  });

  final ScriptTransport _inner;

  /// When non-null, outbound snippets are coalesced into at most one
  /// evaluation per interval. `null` (default) uses microtask coalescing,
  /// which batches only the current synchronous tick with zero latency.
  final Duration? flushInterval;

  final List<String> _pending = <String>[];
  Timer? _flushTimer;
  bool _disposed = false;

  /// Number of JS snippets currently buffered (diagnostics).
  int get pendingCount => _pending.length;

  void _scheduleFlush() {
    if (_disposed || _flushTimer != null) {
      return;
    }
    final interval = flushInterval;
    if (interval != null && interval > Duration.zero) {
      // Time-window mode: coalesce everything arriving within one interval.
      _flushTimer = Timer(interval, _flush);
    } else {
      // Microtask mode: batch the current synchronous tick, zero latency.
      scheduleMicrotask(_flush);
    }
  }

  /// Flush any buffered snippets to the inner transport as one evaluation.
  /// Safe to call in both scheduling modes; no-op when nothing is buffered.
  Future<void> flush() => _flush();

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) {
      return;
    }
    final batch = _pending.join(';\n');
    _pending.clear();
    try {
      await _inner.evaluateScript(batch);
    } catch (error) {
      // Batch failure: H5 owns ultimate retry via its request timeout. Log the
      // diagnostic surface (transport type) rather than silently dropping.
      // ignore: avoid_print
      print('[XBridge] batch evaluate failed (${_inner.runtimeType}): $error');
    }
  }

  /// Prevent further enqueues and flush any remaining buffered snippets.
  /// Idempotent — safe to call from `detach`.
  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }

  Future<void> _enqueue(String script) {
    if (_disposed) {
      return Future<void>.error(
        StateError('[XBridge] BatchingTransport has been disposed'),
      );
    }
    _pending.add(script);
    _scheduleFlush();
    return Future<void>.value();
  }

  @override
  Future<void> resolve(String id, dynamic result) =>
      _enqueue(BridgeScriptBuilder.buildResolveScript(id, result));

  @override
  Future<void> reject(String id, BridgeError error) =>
      _enqueue(BridgeScriptBuilder.buildRejectScript(id, error.toJson()));

  @override
  Future<void> dispatchEvent(BridgeEvent event) =>
      _enqueue(BridgeScriptBuilder.buildEventScript(event));

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) =>
      _enqueue(BridgeScriptBuilder.buildCallH5Script(id, method, params));
}

/// A [BridgeTransport] that refuses every call because the underlying transport
/// has been detached/destroyed.
///
/// Adapters install this no-op after `detach` so that any late call surfaces a
/// clear error instead of silently operating on a broken WebView. This is the
/// single shared implementation — it replaces per-adapter duplicates.
class BrokenBridgeTransport implements BridgeTransport {
  /// Human-readable context shown in every error message (e.g. the transport
  /// name like `InAppWebView` or `WebView`).
  final String context;

  BrokenBridgeTransport([this.context = 'bridge']);

  StateError _error() =>
      StateError('[XBridge] $context transport has been detached');

  @override
  Future<void> resolve(String id, dynamic result) async => throw _error();
  @override
  Future<void> reject(String id, BridgeError error) async => throw _error();
  @override
  Future<void> dispatchEvent(BridgeEvent event) async => throw _error();
  @override
  Future<void> callH5Handler(String id, String method, dynamic params) async =>
      throw _error();
}
