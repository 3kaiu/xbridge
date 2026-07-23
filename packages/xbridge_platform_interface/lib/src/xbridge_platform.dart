import 'package:flutter/services.dart';

import 'security_policy.dart';

/// Abstract contract every platform implementation must satisfy.
///
/// The app-facing package ([xbridge_flutter]) calls into [instance]; platform
/// packages ([xbridge_android], [xbridge_ios], …) install a concrete
/// implementation via [instance=] at registration time.
///
/// Dynamic routing is intentionally modeled on [MethodChannel] (audit Risk 4):
/// the H5 bridge protocol is string-keyed, so a static Pigeon surface would
/// either lose the dynamic nature or re-introduce business coupling.
abstract class XBridgePlatform {
  /// Single static instance — the last registered implementation wins.
  static XBridgePlatform? _instance;

  /// The currently registered platform implementation.
  ///
  /// Throws an [UnimplementedError] when no platform has registered itself.
  static XBridgePlatform get instance {
    final impl = _instance;
    if (impl == null) {
      throw UnimplementedError(
        'XBridgePlatform is not registered. '
        'Add a platform implementation (e.g. xbridge_android) to pubspec.yaml.',
      );
    }
    return impl;
  }

  /// Installs [platform] as the active implementation.
  static set instance(XBridgePlatform? platform) {
    _instance = platform;
  }

  /// Whether a concrete platform implementation has registered itself.
  static bool get hasInstance => _instance != null;

  /// Starts a local WebSocket server bound to the loopback interface on [port].
  ///
  /// Pass `0` to let the OS pick a free port; the actual bound port is
  /// returned as a positive `int`. Platform implementations must
  /// only ever bind to `127.0.0.1` (or `::1`) — never to `0.0.0.0`.
  Future<int> setupLocalWebSocketServer({required int port});

  /// Stops the local WebSocket server started by [setupLocalWebSocketServer].
  ///
  /// Safe to call when no server is running.
  Future<void> teardownLocalWebSocketServer();

  /// Returns `true` when the local WebSocket server is currently accepting
  /// connections.
  Future<bool> isLocalWebSocketServerRunning();

  /// Returns `ws://127.0.0.1:<port>` when the server is running, `null`
  /// otherwise.
  Future<String?> getLocalWebSocketEndpoint();

  /// Installs [policy] on the native side, enforcing it for both the local
  /// WebSocket server origin check and the native fallback route.
  Future<void> setSecurityPolicy(XBridgeSecurityPolicy policy);

  /// The [MethodChannel] used for dynamic fallback routing — Flutter forwards
  /// any unregistered H5 method here so the native legacy plugin can handle
  /// it verbatim. Implementations must not use Pigeon for this channel (audit
  /// Risk 4): the method name is the dynamic H5 request method.
  MethodChannel get methodChannel;
}
