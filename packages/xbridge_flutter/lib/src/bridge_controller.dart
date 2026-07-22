import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:xbridge_platform_interface/xbridge_platform_interface.dart';

import 'bridge_java_script_transport.dart';
import 'bridge_method_context.dart';
import 'bridge_protocol.dart';
import 'fallback_channel.dart';

/// Pluggable JS transport contract. The default implementation routes through
/// [BridgeJavaScriptTransport] against a `webview_flutter` [WebViewController];
/// the `flutter_inappwebview` adapter supplies an alternative that calls
/// `InAppWebViewController.evaluateJavascript`.
abstract class BridgeTransport {
  Future<void> resolve(String id, dynamic result);
  Future<void> reject(String id, BridgeError error);
  Future<void> dispatchEvent(BridgeEvent event);
  Future<void> callH5Handler(String id, String method, dynamic params);
}

/// Central request router for the XBridge Flutter SDK.
///
/// Responsibilities:
/// * Parse each incoming raw JSON message **once** and route to a registered
///   [BridgeMethodHandler] via an O(1) [Map] lookup (PRD §3.4).
/// * Catch every handler exception and convert it into a [BridgeError] reject
///   response — exceptions never escape the channel.
/// * Enforce an optional [XBridgeSecurityPolicy] origin allowlist before
///   dispatching.
/// * Fall back to the native [FallbackChannel] (or an explicit fallback
///   handler) when no handler matches, so legacy DSBridge methods keep working.
/// * Push host events back to H5 via the installed [BridgeTransport].
///
/// The controller is engine-agnostic: adapters ([WebViewFlutterBridgeAdapter],
/// [InAppWebViewBridgeAdapter]) feed it raw message strings and supply a
/// [BridgeTransport] that knows how to inject JS into the concrete WebView.
class BridgeController {
  BridgeController();

  final Map<String, BridgeMethodHandler> _handlers =
      <String, BridgeMethodHandler>{};
  BridgeMethodHandler? _fallbackHandler;
  XBridgeSecurityPolicy? _policy;
  BridgeTransport? _transport;
  WebViewController? _webViewController;

  /// Pending Native→H5 calls awaiting a response. Keyed by request id.
  final Map<String, Completer<dynamic>> _pendingH5Calls =
      <String, Completer<dynamic>>{};

  /// Monotonic counter for generating unique call ids (combined with timestamp).
  int _h5CallCounter = 0;

  /// Registers [handler] for [method]. Replaces any prior registration.
  void addHandler(String method, BridgeMethodHandler handler) {
    _handlers[method] = handler;
  }

  /// Removes the handler for [method], if any.
  void removeHandler(String method) {
    _handlers.remove(method);
  }

  /// Installs [handler] as the catch-all for methods with no explicit
  /// registration. Pass `null` to clear. When no fallback is set, the default
  /// [FallbackChannel] route is used.
  void setFallbackHandler(BridgeMethodHandler? handler) {
    _fallbackHandler = handler;
  }

  /// Installs [policy]. When set and `allowAll` is `false`, every request is
  /// checked against the current page origin; disallowed calls are rejected
  /// with `BRIDGE_METHOD_FORBIDDEN`.
  void setSecurityPolicy(XBridgeSecurityPolicy? policy) {
    _policy = policy;
  }

  /// Attaches the [WebViewController] used by the default
  /// `_WebViewControllerTransport`. Adapters that supply a custom
  /// [BridgeTransport] via [setTransport] do not need to call this.
  void attachWebViewController(WebViewController controller) {
    _webViewController = controller;
    _transport ??= _WebViewControllerTransport(controller);
  }

  /// Installs a custom [BridgeTransport]. Used by the `flutter_inappwebview`
  /// adapter whose `InAppWebViewController` is not a `WebViewController`.
  void setTransport(BridgeTransport transport) {
    _transport = transport;
  }

  /// Dispatches a host-pushed [BridgeEvent] to H5.
  ///
  /// Returns immediately (no-op) when no transport is attached.
  Future<void> dispatchEvent(BridgeEvent event) {
    final transport = _transport;
    if (transport == null) {
      return Future<void>.value();
    }
    return transport.dispatchEvent(event);
  }

  /// Calls a handler registered on the H5 side and awaits its response.
  ///
  /// Generates a unique request id, sends a JSON-RPC request to H5 via the
  /// transport's [callH5Handler], and completes the returned future when the
  /// H5 response arrives (routed back through [handleRawMessage]).
  ///
  /// If [timeout] elapses without a response, the future completes with a
  /// [TimeoutException]. The pending entry is cleaned up on either outcome.
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
      if (_pendingH5Calls.remove(id) != null) {
        completer.completeError(
          TimeoutException(
            '[XBridge] callH5("$method") timed out after ${timeout.inSeconds}s',
            timeout,
          ),
        );
      }
    });

    transport.callH5Handler(id, method, params).then((_) {
      // Request sent successfully — response will arrive via handleRawMessage.
    }).catchError((dynamic error) {
      if (_pendingH5Calls.remove(id) != null) {
        timer.cancel();
        completer.completeError(error);
      }
    });

    // When the response arrives, cancel the timeout timer.
    return completer.future.whenComplete(() {
      timer.cancel();
      _pendingH5Calls.remove(id);
    });
  }

  /// Routes an inbound H5 response (id present, method absent) to the
  /// pending [Completer] registered by [callH5].
  void _completeH5Response(String jsonString) {
    final BridgeResponse response;
    try {
      response = BridgeResponse.parse(jsonString);
    } catch (error, stackTrace) {
      debugPrint('[XBridge] Failed to parse H5 response: $error\n$stackTrace');
      return;
    }
    final completer = _pendingH5Calls.remove(response.id);
    if (completer == null) {
      // No pending call for this id — likely a duplicate or late response.
      debugPrint('[XBridge] No pending H5 call for id=${response.id}');
      return;
    }
    if (response.error != null) {
      completer.completeError(response.error!);
    } else {
      completer.complete(response.result);
    }
  }

  /// Handles a raw JSON message string from the WebView.
  ///
  /// Performance path: single [jsonDecode] (inside [BridgeRequest.parse] or
  /// [BridgeResponse.parse]), single [Map] lookup for the handler or pending
  /// completer, single [jsonEncode] for the response. Handler invocation is
  /// awaited but exceptions are swallowed and reported back to H5.
  ///
  /// Routing:
  /// * `id` present, `method` absent → H5 response to a prior `callH5` →
  ///   complete the pending [Completer].
  /// * `method` present (with or without `id`) → H5 request → dispatch to
  ///   handler. When `id` is null/empty the call is fire-and-forget: the
  ///   handler still runs but no resolve/reject is sent back.
  Future<void> handleRawMessage(String jsonString) async {
    final transport = _transport;
    if (transport == null) {
      debugPrint('[XBridge] Dropping bridge message: no transport attached');
      return;
    }

    // Peek at the raw JSON to distinguish a response from a request without
    // forcing a full parse twice. A response has `id` but no `method`.
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

    final hasId = decoded['id'] != null &&
        '${decoded['id']}'.trim().isNotEmpty;
    final hasMethod = decoded['method'] != null &&
        '${decoded['method']}'.trim().isNotEmpty;

    // Response from H5 (id present, method absent) → route to pending completer.
    if (hasId && !hasMethod) {
      _completeH5Response(jsonString);
      return;
    }

    // Request from H5 → parse and dispatch.
    BridgeRequest request;
    try {
      request = BridgeRequest.parse(jsonString);
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
              const BridgeError(
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
        result = await handler(_buildContext(), request.params);
      } else if (_fallbackHandler != null) {
        result = await _fallbackHandler!(_buildContext(), request.params);
      } else {
        result = await FallbackChannel.instance.invoke(request.method, request.params);
      }
      if (!isFireAndForget) {
        await transport.resolve(request.id!, result);
      }
    } catch (error, stackTrace) {
      debugPrint('[XBridge] Handler ${request.method} failed: $error\n$stackTrace');
      if (!isFireAndForget) {
        try {
          await transport.reject(request.id!, BridgeError.from(error));
        } catch (e) {
          debugPrint('[XBridge] Failed to send error reject: $e');
        }
      }
    }
  }

  BridgeMethodContext _buildContext() {
    // The context's controller may be null when a non-webview_flutter engine
    // is attached. Handlers that need the concrete controller should obtain
    // it through the adapter-specific path; [BridgeMethodContext.controller]
    // is a non-nullable type by contract, so we fall back to a sentinel via
    // the transport when the default engine is not in use. In practice the
    // webview_flutter adapter always calls [attachWebViewController].
    final controller = _webViewController;
    if (controller != null) {
      return BridgeMethodContext(controller: controller, origin: _currentOrigin);
    }
    // No webview_flutter controller — the inappwebview path supplies its own
    // context injection. We create a throwaway context backed by a detached
    // controller to satisfy the non-nullable contract; handlers running under
    // inappwebview should access the InAppWebViewController through the
    // adapter rather than the context.
    return BridgeMethodContext(controller: _detachedControllerOrInit, origin: _currentOrigin);
  }

  bool _isAllowed(BridgeRequest request) {
    final policy = _policy;
    if (policy == null || policy.allowAll) {
      return true;
    }
    final origin = _currentOrigin;
    if (origin == null) {
      return false;
    }
    return policy.allows(origin);
  }

  String? get _currentOrigin => _explicitOrigin;

  /// Explicitly sets the current page origin, used by the security policy.
  ///
  /// Adapters that can observe navigation (e.g. `flutter_inappwebview`) call
  /// this on `onLoadStop` / URL change so the [BridgeController] can make
  /// origin-based decisions without awaiting `getUrl()`.
  void setCurrentOrigin(String? origin) {
    _explicitOrigin = origin;
  }

  String? _explicitOrigin;

  // A lazily-created detached WebViewController used only as a non-null
  // placeholder for BridgeMethodContext when the inappwebview adapter is in
  // charge. Handlers that need the real controller must obtain it via the
  // adapter-specific path; under webview_flutter the real controller is set
  // via [attachWebViewController].
  // Instance field (not static) so each BridgeController gets its own
  // placeholder — a static singleton would share mutable WebView state across
  // independent controllers.
  WebViewController? _detachedController;

  WebViewController get _detachedControllerOrInit =>
      _detachedController ??= WebViewController();
}

/// Default [BridgeTransport] backed by a `webview_flutter` [WebViewController].
class _WebViewControllerTransport implements BridgeTransport {
  _WebViewControllerTransport(this._controller);

  final WebViewController _controller;

  @override
  Future<void> resolve(String id, dynamic result) =>
      BridgeJavaScriptTransport.resolve(_controller, id, result);

  @override
  Future<void> reject(String id, BridgeError error) =>
      BridgeJavaScriptTransport.reject(_controller, id, error.toJson());

  @override
  Future<void> dispatchEvent(BridgeEvent event) =>
      BridgeJavaScriptTransport.dispatchEvent(_controller, event);

  @override
  Future<void> callH5Handler(String id, String method, dynamic params) =>
      BridgeJavaScriptTransport.callH5Handler(_controller, id, method, params);
}
