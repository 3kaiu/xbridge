import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import 'fallback_channel.dart';
import 'native_reverse_channel.dart';

/// Central request router for the XBridge Flutter SDK.
///
/// Pure protocol router — zero WebView dependencies.
///
/// Responsibilities:
/// * Parse each incoming raw JSON message **once** and route to a registered
///   [BridgeMethodHandler] via an O(1) [Map] lookup (PRD §3.4).
/// * Catch every handler exception and convert it into a [BridgeError] reject
///   response — exceptions never escape the channel.
/// * Enforce an optional [XBridgeSecurityPolicy] origin allowlist before dispatching.
/// * Fall back to the native [FallbackChannel] (or an explicit fallback handler)
///   when no handler matches.
/// * Support Native → Flutter / H5 reverse calls via [NativeReverseChannel].
class BridgeController {
  BridgeController() {
    NativeReverseChannel.instance.bind(this);
  }

  final Map<String, BridgeMethodHandler> _handlers =
      <String, BridgeMethodHandler>{};
  BridgeMethodHandler? _fallbackHandler;
  XBridgeSecurityPolicy? _policy;
  BridgeTransport? _transport;

  /// Pending Native→H5 calls awaiting a response. Keyed by request id.
  final Map<String, Completer<dynamic>> _pendingH5Calls =
      <String, Completer<dynamic>>{};

  /// Monotonic counter for generating unique call ids.
  int _h5CallCounter = 0;

  /// Whether a handler is registered for [method].
  bool hasHandler(String method) => _handlers.containsKey(method);

  /// Directly invokes a registered local handler for [method].
  ///
  /// This bypasses the origin security policy because it is called from
  /// the Native → Flutter reverse channel (native is trusted). If called
  /// from an untrusted context, the caller must enforce its own security.
  Future<dynamic> invokeLocalHandler(String method, dynamic params) async {
    final handler = _handlers[method];
    if (handler == null) {
      throw StateError('[XBridge] No handler registered for method "$method"');
    }
    final req = BridgeRequest(method: method, params: params);
    return await handler(_buildContext(), params, req);
  }

  /// Registers [handler] for [method]. Replaces any prior registration.
  void addHandler(String method, BridgeMethodHandler handler) {
    _handlers[method] = handler;
  }

  /// Removes the handler for [method], if any.
  void removeHandler(String method) {
    _handlers.remove(method);
  }

  /// Installs [handler] as the catch-all for methods with no explicit registration.
  void setFallbackHandler(BridgeMethodHandler? handler) {
    _fallbackHandler = handler;
  }

  /// Installs [policy].
  void setSecurityPolicy(XBridgeSecurityPolicy? policy) {
    _policy = policy;
  }

  /// Installs a concrete [BridgeTransport] (e.g. from an adapter).
  void setTransport(BridgeTransport transport) {
    _transport = transport;
  }

  /// Dispatches a host-pushed [BridgeEvent] to H5.
  Future<void> dispatchEvent(BridgeEvent event) {
    final transport = _transport;
    if (transport == null) {
      return Future<void>.value();
    }
    return transport.dispatchEvent(event);
  }

  /// Calls a handler registered on the H5 side and awaits its response.
  Future<dynamic> callH5(
    String method, [
    dynamic params,
    Duration timeout = const Duration(seconds: 30),
  ]) {
    final transport = _transport;
    if (transport == null) {
      return Future<dynamic>.error(
        StateError('[XBridge] callH5 failed: no transport attached'),
      );
    }

    final id = '${DateTime.now().millisecondsSinceEpoch}_${_h5CallCounter++}';
    final completer = Completer<dynamic>();
    _pendingH5Calls[id] = completer;

    final timer = Timer(timeout, () {
      if (_pendingH5Calls.remove(id) != null && !completer.isCompleted) {
        completer.completeError(
          TimeoutException(
            '[XBridge] callH5("$method") timed out after ${timeout.inSeconds}s',
            timeout,
          ),
        );
      }
    });

    transport.callH5Handler(id, method, params).then((_) {
      // Request sent successfully
    }).catchError((dynamic error) {
      if (_pendingH5Calls.remove(id) != null) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      }
    });

    return completer.future.whenComplete(() {
      timer.cancel();
      _pendingH5Calls.remove(id);
    });
  }

  /// Routes an inbound H5 response to pending Completer.
  void _completeH5ResponseFromMap(Map<String, dynamic> decoded) {
    final BridgeResponse response;
    try {
      response = BridgeResponse.fromMap(decoded);
    } catch (error, stackTrace) {
      debugPrint('[XBridge] Failed to parse H5 response: $error\n$stackTrace');
      return;
    }
    final completer = _pendingH5Calls.remove(response.id);
    if (completer == null) {
      debugPrint('[XBridge] No pending H5 call for id=${response.id}');
      return;
    }
    if (completer.isCompleted) {
      // Already completed by timeout or transport error — ignore late response.
      return;
    }
    if (response.error != null) {
      completer.completeError(response.error!);
    } else {
      completer.complete(response.result);
    }
  }

  /// Handles a raw JSON message string from the WebView.
  Future<void> handleRawMessage(String jsonString) async {
    final transport = _transport;
    if (transport == null) {
      debugPrint('[XBridge] Dropping bridge message: no transport attached');
      return;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (error, stackTrace) {
      debugPrint('[XBridge] Failed to parse bridge message: $error\n$stackTrace');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      debugPrint('[XBridge] Dropping non-object bridge message');
      return;
    }

    final hasId = decoded['id'] != null && '${decoded['id']}'.trim().isNotEmpty;
    final hasMethod = decoded['method'] != null && '${decoded['method']}'.trim().isNotEmpty;
    final hasResultOrError = decoded.containsKey('result') || decoded.containsKey('error');

    // Response from H5: must have an id, no method, and a result or error key.
    // Requiring result/error prevents misclassifying malformed requests with
    // an empty method as responses (which would clobber pending calls).
    if (hasId && !hasMethod && hasResultOrError) {
      _completeH5ResponseFromMap(decoded);
      return;
    }

    // Request from H5
    BridgeRequest request;
    try {
      request = BridgeRequest.fromMap(decoded);
    } catch (error, stackTrace) {
      debugPrint('[XBridge] Failed to parse bridge request: $error\n$stackTrace');
      return;
    }

    final isFireAndForget = request.id == null || request.id!.isEmpty;

    try {
      if (!_isAllowed(request)) {
        if (!isFireAndForget) {
          try {
            await transport.reject(
              request.id!,
              BridgeError(
                code: 'BRIDGE_METHOD_FORBIDDEN',
                message: 'Current page is not allowed to call this bridge method',
              ),
            );
          } catch (e) {
            debugPrint('[XBridge] Failed to send forbidden reject: $e');
          }
        }
        return;
      }

      final handler = _handlers[request.method];
      final dynamic result;
      if (handler != null) {
        result = await handler(_buildContext(), request.params, request);
      } else if (_fallbackHandler != null) {
        result = await _fallbackHandler!(_buildContext(), request.params, request);
      } else {
        result = await FallbackChannel.instance.invoke(request.method, request.params);
      }
      // Check if dispose was called while awaiting the handler.
      if (_disposed) {
        return;
      }
      if (!isFireAndForget) {
        await transport.resolve(request.id!, result);
      }
    } catch (error, stackTrace) {
      debugPrint('[XBridge] Handler ${request.method} failed: $error\n$stackTrace');
      if (!isFireAndForget) {
        try {
          await transport.reject(request.id!, BridgeError.from(error, stackTrace));
        } catch (e) {
          debugPrint('[XBridge] Failed to send error reject: $e');
        }
      }
    }
  }

  BridgeMethodContext _buildContext() {
    return BridgeMethodContext(origin: _currentOrigin);
  }

  bool _isAllowed(BridgeRequest request) {
    final policy = _policy;
    // No policy set: deny by default for production safety.
    // In debug mode, warn that an explicit policy should be configured.
    if (policy == null) {
      assert(() {
        debugPrint('[XBridge] WARNING: no security policy set — all bridge '
            'calls are denied. Call setSecurityPolicy() with an allowlist '
            'or XBridgeSecurityPolicy.allowAll() for development.');
        return true;
      }());
      return false;
    }
    if (policy.allowAll) {
      return true;
    }
    final origin = _currentOrigin;
    if (origin == null) {
      return false;
    }
    return policy.allows(origin);
  }

  /// Explicitly sets the current page origin, used by the security policy.
  void setCurrentOrigin(String? origin) {
    _explicitOrigin = origin;
  }

  String? _explicitOrigin;
  String? get _currentOrigin => _explicitOrigin;

  /// Whether [dispose] has been called.
  bool _disposed = false;

  /// Tear down controller.
  void dispose() {
    _disposed = true;
    NativeReverseChannel.instance.unbind(this);
    for (final completer in _pendingH5Calls.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('[XBridge] BridgeController disposed'),
        );
      }
    }
    _pendingH5Calls.clear();
    _handlers.clear();
    _fallbackHandler = null;
    _policy = null;
    _transport = null;
    _explicitOrigin = null;
  }
}
