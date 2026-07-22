import 'package:webview_flutter/webview_flutter.dart';

import '../bridge_controller.dart';

/// Adapter that wires a `webview_flutter` [WebViewController] into a
/// [BridgeController].
///
/// Attach once after creating the controller:
///
/// ```dart
/// final controller = WebViewController();
/// final bridge = BridgeController();
/// WebViewFlutterBridgeAdapter().attach(controller, bridge);
/// ```
///
/// The adapter:
/// * Registers a JavaScript channel named [channelName] (default `XBridge`)
///   whose `onMessageReceived` forwards `msg.message` to
///   `bridge.handleRawMessage`.
/// * Attaches the controller on the bridge so JS callbacks can be injected.
/// * Installs a no-op `window.__XBridge__` bootstrap so the H5 SDK
///   does not crash if it calls `resolve`/`reject` before Flutter is ready —
///   the real resolve/reject are injected lazily by [BridgeJavaScriptTransport]
///   on each response.
/// * Wires a `NavigationDelegate` `onPageFinished` callback that fetches the
///   current URL and calls `bridge.setCurrentOrigin(url)` so the security
///   policy has an up-to-date origin without manual wiring.
class WebViewFlutterBridgeAdapter {
  WebViewController? _attachedController;

  /// The JavaScript bootstrap injected on attach. Keeps the H5 side from
  /// throwing when it references the global before Flutter has responded.
  static const String _bootstrapScript = ''
      'window.__XBridge__=window.__XBridge__||{'
      'resolve:function(){},'
      'reject:function(){}'
      '};';

  void attach(
    WebViewController controller,
    BridgeController bridge, {
    String channelName = 'XBridge',
  }) {
    bridge.attachWebViewController(controller);
    controller.addJavaScriptChannel(
      channelName,
      onMessageReceived: (JavaScriptMessage message) {
        // Fire-and-forget: handleRawMessage is async and self-contained.
        bridge.handleRawMessage(message.message);
      },
    );

    // Populate the current origin whenever a page finishes loading so the
    // security policy can make origin-based decisions automatically.
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) async {
          final url = await controller.currentUrl();
          bridge.setCurrentOrigin(url);
        },
      ),
    );

    // Best-effort bootstrap; ignore errors (page not ready yet).
    controller.runJavaScript(_bootstrapScript).catchError((_) {});

    _attachedController = controller;
  }

  /// Removes the JavaScript channel registered by [attach] and clears the
  /// reference to the controller. Call this when the WebView is being disposed
  /// to prevent a leaked channel (and leaked JS → Dart callbacks).
  void detach({String channelName = 'XBridge'}) {
    final controller = _attachedController;
    if (controller != null) {
      controller.removeJavaScriptChannel(channelName);
      // Reset the navigation delegate so the onPageFinished callback no
      // longer fires into a disposed bridge.
      controller.setNavigationDelegate(NavigationDelegate());
    }
    _attachedController = null;
  }
}
