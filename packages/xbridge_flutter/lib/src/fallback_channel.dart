import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bridge_method_context.dart';
import 'bridge_protocol.dart';

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
  /// Returns the native result (or `null` when the native side has nothing
  /// registered for [method]); never throws — a native error is returned as
  /// a [PlatformException]-free `null` plus a logged warning on the native
  /// side.
  Future<dynamic> invoke(String method, dynamic params) async {
    try {
      return await _channel.invokeMethod(method, params);
    } on MissingPluginException catch (_) {
      // No native handler registered for [method] — silently return null.
      return null;
    } on PlatformException catch (e) {
      debugPrint('[XBridge] FallbackChannel invoke "$method" failed: $e');
      return null;
    }
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
