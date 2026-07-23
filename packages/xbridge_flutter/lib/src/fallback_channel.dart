import 'dart:async';

import 'package:flutter/services.dart';

import 'package:xbridge_protocol/xbridge_protocol.dart';

/// Singleton [MethodChannel] used for native fallback routing.
///
/// When a [BridgeController] has no registered handler for an incoming method
/// (and no explicit fallback handler is set), the call is forwarded verbatim
/// to the native legacy plugin over this channel. The channel name is stable
/// and intentionally business-free.
///
/// Using a single cached [MethodChannel] (not per-call construction) avoids
/// codec initialization overhead on every fallback invoke (PRD §3.4).
class FallbackChannel {
  FallbackChannel._();

  static final FallbackChannel _instance = FallbackChannel._();

  /// The single shared instance.
  static FallbackChannel get instance => _instance;

  /// The stable channel name. Native implementations register a handler on
  /// this channel and forward `method`/`params` to their legacy bridge plugin.
  static const String channelName = 'xbridge/native_fallback';

  final MethodChannel _channel = const MethodChannel(channelName);

  /// Invokes [method] with [params] on the native fallback handler.
  ///
  /// Returns the native result. Throws [BridgeError] on failure so the caller
  /// can send a proper JSON-RPC error response to H5 — never masks errors as
  /// `null` success. Retries once after a short delay to handle transient
  /// failures during native plugin initialization.
  Future<dynamic> invoke(String method, dynamic params) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _channel.invokeMethod(method, params);
      } on MissingPluginException catch (_) {
        if (attempt == 0) {
          // Native plugin might not be ready yet — wait briefly and retry.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        throw BridgeError(
          code: BridgeErrorCode.methodNotFound,
          message: 'No native handler for "$method"',
        );
      } on PlatformException catch (e) {
        if (attempt == 0 && e.code.contains('NOT_READY')) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        throw BridgeError(
          code: e.code,
          message: e.message ?? 'Native error',
          detail: e.details,
        );
      }
    }
    // Unreachable — loop either returns or throws.
    throw BridgeError(
      code: BridgeErrorCode.methodNotFound,
      message: 'No native handler for "$method"',
    );
  }

  /// A default [BridgeMethodHandler] that forwards a [BridgeRequest] to the
  /// native fallback channel. Used as the default fallback on
  /// [BridgeController] when no explicit fallback handler is configured.
  static FutureOr<dynamic> defaultHandler(
    BridgeMethodContext context,
    dynamic params,
    BridgeRequest request,
  ) {
    return _instance.invoke(request.method, params);
  }
}
