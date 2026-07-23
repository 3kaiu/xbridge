import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xbridge_protocol/xbridge_protocol.dart';

import 'bridge_controller.dart';

/// MethodChannel for Native → Flutter / H5 reverse calls.
///
/// Channel name: `xbridge/native_reverse` (independent channel per design decision).
///
/// This class manages the `MethodChannel` handler for native reverse calls.
/// Only one [BridgeController] can be bound at a time because Flutter's
/// `MethodChannel.setMethodCallHandler` is a singleton per channel name.
/// If a second controller binds, the first is silently detached — this is
/// logged as a warning in debug mode.
class NativeReverseChannel {
  NativeReverseChannel._();

  static final NativeReverseChannel _instance = NativeReverseChannel._();
  static NativeReverseChannel get instance => _instance;

  static const String channelName = 'xbridge/native_reverse';

  final MethodChannel _channel = const MethodChannel(channelName);
  BridgeController? _boundController;

  /// Binds a [BridgeController] to handle incoming reverse method calls from Native.
  ///
  /// If another controller is already bound, it is silently replaced.
  /// In debug mode, a warning is printed to help diagnose lost reverse calls.
  void bind(BridgeController controller) {
    if (_boundController != null && _boundController != controller) {
      debugPrint('[XBridge] NativeReverseChannel: replacing already-bound '
          'BridgeController. The previous controller will no longer receive '
          'reverse calls from Native. Ensure you dispose() the previous '
          'controller before creating a new one, or use separate channel names.');
    }
    _boundController = controller;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// Unbinds the current controller, but only if [controller] matches the
  /// bound controller. This prevents a disposed controller from clearing
  /// the handler for a newer controller that has since bound.
  void unbind(BridgeController controller) {
    if (_boundController != controller) {
      // This controller was already replaced — don't clear the handler.
      return;
    }
    _boundController = null;
    _channel.setMethodCallHandler(null);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final controller = _boundController;
    if (controller == null) {
      throw StateError('[XBridge] Reverse call received but no BridgeController is bound');
    }

    final method = call.method;
    final params = call.arguments;

    // Special event routing
    if (method.startsWith('__event__:')) {
      final eventName = method.substring('__event__:'.length);
      await controller.dispatchEvent(BridgeEvent(method: eventName, params: params));
      return null;
    }

    // Check if Flutter has a local handler registered
    if (controller.hasHandler(method)) {
      return controller.invokeLocalHandler(method, params);
    }

    // Otherwise forward to H5 registered handler
    return controller.callH5(method, params);
  }
}
