import 'package:flutter/services.dart';
import 'package:xbridge_platform_interface/xbridge_platform_interface.dart';

/// Concrete [XBridgePlatform] that forwards calls to the native side via
/// a [MethodChannel].
///
/// The native Android (`XBridgePlugin.kt`) and iOS (`XBridgePlugin.swift`)
/// plugins listen on [channelName] and handle the following methods:
///
/// - `xbridge.setupLocalWebSocket` (`{port: int}`) → returns the actual bound
///   port as an `int`.
/// - `xbridge.teardownLocalWebSocket` → stops the server.
/// - `xbridge.setSecurityPolicy` (`{allowedOrigins: List<String>,
///   allowAll: bool}`) → installs the policy.
/// - `xbridge.isWsRunning` → returns `bool`.
/// - `xbridge.getWsEndpoint` → returns `String?`.
class MethodChannelXBridgePlatform extends XBridgePlatform {
  /// Creates a platform implementation backed by [channel].
  ///
  /// Defaults to the standard `xbridge/native_fallback` channel name.
  MethodChannelXBridgePlatform({
    MethodChannel? methodChannel,
  }) : methodChannel = methodChannel ??
            const MethodChannel('xbridge/native_fallback');

  /// Registers this implementation as the active [XBridgePlatform.instance].
  /// Call this once during app startup (e.g. in `main()`).
  static void register() {
    XBridgePlatform.instance = MethodChannelXBridgePlatform();
  }

  @override
  MethodChannel methodChannel;

  @override
  Future<int> setupLocalWebSocketServer({required int port}) async {
    final result = await methodChannel.invokeMethod<int>(
      'xbridge.setupLocalWebSocket',
      <String, dynamic>{'port': port},
    );
    return result ?? -1;
  }

  @override
  Future<void> teardownLocalWebSocketServer() {
    return methodChannel.invokeMethod('xbridge.teardownLocalWebSocket');
  }

  @override
  Future<bool> isLocalWebSocketServerRunning() async {
    final result = await methodChannel.invokeMethod<bool>('xbridge.isWsRunning');
    return result ?? false;
  }

  @override
  Future<String?> getLocalWebSocketEndpoint() {
    return methodChannel.invokeMethod<String>('xbridge.getWsEndpoint');
  }

  @override
  Future<void> setSecurityPolicy(XBridgeSecurityPolicy policy) {
    return methodChannel.invokeMethod(
      'xbridge.setSecurityPolicy',
      <String, dynamic>{
        'allowedOrigins': policy.allowedOrigins.toList(),
        'allowAll': policy.allowAll,
      },
    );
  }
}
