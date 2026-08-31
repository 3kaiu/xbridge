import 'dart:async';

/// Enumeration of security events captured across the bridge lifecycle.
enum BridgeSecurityEventType {
  /// Invocation attempted from an unauthorized Origin.
  originForbidden,

  /// Invocation attempted for a method not permitted by the origin's capability rules.
  methodForbidden,

  /// Invocation throttled due to global, method, or origin rate limits.
  rateLimitExceeded,

  /// Malformed or structurally invalid bridge payload.
  malformedMessage,

  /// WebSocket ticket validation failure or expired token.
  wsAuthFailed,
}

/// A structured security audit event.
class BridgeSecurityEvent {
  BridgeSecurityEvent({
    required this.type,
    this.origin,
    this.method,
    required this.timestamp,
    required this.message,
    this.violationCount = 1,
    this.details,
  });

  final BridgeSecurityEventType type;
  final String? origin;
  final String? method;
  final DateTime timestamp;
  final String message;
  final int violationCount;
  final Map<String, dynamic>? details;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': type.name,
      'origin': origin,
      'method': method,
      'timestamp': timestamp.toIso8601String(),
      'message': message,
      'violationCount': violationCount,
      if (details != null) 'details': details,
    };
  }

  @override
  String toString() =>
      'BridgeSecurityEvent(type: ${type.name}, origin: $origin, method: $method, count: $violationCount, message: $message)';
}

/// Security telemetry dispatcher with anti-storm coalescing.
///
/// Throttles high-frequency attack bursts by coalescing repeated violations
/// from the same origin and event type within [coalesceWindow].
class BridgeSecurityTelemetry {
  BridgeSecurityTelemetry({
    this.coalesceWindow = const Duration(milliseconds: 500),
  });

  final Duration coalesceWindow;
  final StreamController<BridgeSecurityEvent> _controller =
      StreamController<BridgeSecurityEvent>.broadcast();

  final Map<String, _PendingEvent> _pending = <String, _PendingEvent>{};

  /// Stream of security events for APM or SIEM ingestion.
  Stream<BridgeSecurityEvent> get eventStream => _controller.stream;

  /// Callback hook for direct listener subscription.
  void Function(BridgeSecurityEvent event)? onEvent;

  /// Record a security violation event.
  void record({
    required BridgeSecurityEventType type,
    String? origin,
    String? method,
    required String message,
    Map<String, dynamic>? details,
  }) {
    final key = '${type.name}:$origin:$method';
    final existing = _pending[key];

    if (existing != null) {
      existing.count += 1;
      return;
    }

    final pending = _PendingEvent(
      event: BridgeSecurityEvent(
        type: type,
        origin: origin,
        method: method,
        timestamp: DateTime.now(),
        message: message,
        violationCount: 1,
        details: details,
      ),
    );
    _pending[key] = pending;

    Timer(coalesceWindow, () {
      _pending.remove(key);
      final finalEvent = BridgeSecurityEvent(
        type: pending.event.type,
        origin: pending.event.origin,
        method: pending.event.method,
        timestamp: pending.event.timestamp,
        message: pending.event.message,
        violationCount: pending.count,
        details: pending.event.details,
      );

      if (!_controller.isClosed) {
        _controller.add(finalEvent);
      }
      onEvent?.call(finalEvent);
    });
  }

  /// Close the telemetry stream.
  void dispose() {
    _pending.clear();
    _controller.close();
    onEvent = null;
  }
}

class _PendingEvent {
  _PendingEvent({required this.event}) : count = 1;
  final BridgeSecurityEvent event;
  int count;
}
