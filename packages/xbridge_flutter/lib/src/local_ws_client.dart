import 'package:xbridge_platform_interface/xbridge_platform_interface.dart';

/// Control-plane client for the high-performance Local WebSocket bypass
/// (PRD §1.2.4 / audit Risk 2).
///
/// The local WS server is hosted on the native side (Rust `xbridge_core` or a
/// platform implementation of [XBridgePlatform]). The **data plane** — large
/// binary frames such as streaming audio — flows directly between the H5
/// `WebSocket` and the native server, bypassing the JS Bridge channel entirely
/// (no Base64, no JSON, zero serialization overhead).
///
/// This class manages only the **control plane**: starting/stopping the native
/// server and discovering its endpoint. Once [getEndpoint] returns a non-null
/// `ws://127.0.0.1:<port>` URL, the H5 side opens its own WebSocket directly.
class LocalWebSocketBridge {
  LocalWebSocketBridge();

  /// Starts the local WebSocket server on the native side.
  ///
  /// Pass `port: 0` to let the OS pick a free loopback port; the actual port
  /// is then observable via [getEndpoint]. Safe to call multiple times —
  /// repeated calls are forwarded to the platform implementation which is
  /// expected to be idempotent.
  Future<void> start({int port = 0}) {
    return _platform.setupLocalWebSocketServer(port: port);
  }

  /// Returns the server endpoint (`ws://127.0.0.1:<port>`) when running, or
  /// `null` when stopped.
  Future<String?> getEndpoint() {
    return _platform.getLocalWebSocketEndpoint();
  }

  /// Returns `true` when the local WebSocket server is accepting connections.
  Future<bool> isRunning() {
    return _platform.isLocalWebSocketServerRunning();
  }

  /// Stops the local WebSocket server. Safe to call when already stopped.
  Future<void> stop() {
    return _platform.teardownLocalWebSocketServer();
  }

  /// Installs [policy] on the native server (origin allowlist for the WS
  /// handshake).
  Future<void> setSecurityPolicy(XBridgeSecurityPolicy policy) {
    return _platform.setSecurityPolicy(policy);
  }

  static XBridgePlatform get _platform => XBridgePlatform.instance;
}
