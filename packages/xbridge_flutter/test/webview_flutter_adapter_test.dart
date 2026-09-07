import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:xbridge_flutter/xbridge_flutter.dart';

class _RecordingPlatformWebViewController extends PlatformWebViewController {
  _RecordingPlatformWebViewController()
      : super.implementation(PlatformWebViewControllerCreationParams());

  final List<String> addedChannels = [];
  final List<JavaScriptChannelParams> addedChannelParams = [];
  final List<String> removedChannels = [];
  final List<String> evaluatedScripts = [];
  final List<PlatformNavigationDelegate> navigationDelegates = [];

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    addedChannels.add(params.name);
    addedChannelParams.add(params);
  }

  @override
  Future<void> removeJavaScriptChannel(String channelName) async {
    removedChannels.add(channelName);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    evaluatedScripts.add(javaScript);
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {
    navigationDelegates.add(delegate);
  }

  @override
  Future<String?> currentUrl() async => 'https://app.example.com/archive/fill';
}

class _NoopPlatformNavigationDelegate extends PlatformNavigationDelegate {
  _NoopPlatformNavigationDelegate()
      : super.implementation(PlatformNavigationDelegateCreationParams());

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(void Function(String url) onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(
    void Function(String url) onPageFinished,
  ) async {}

  @override
  Future<void> setOnProgress(void Function(int progress) onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    void Function(WebResourceError error) onWebResourceError,
  ) async {}
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      _NoopPlatformNavigationDelegate();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
  });

  test('attach registers channel + bootstrap script', () async {
    final adapter = WebViewFlutterBridgeAdapter();
    final bridge = BridgeController();
    final platform = _RecordingPlatformWebViewController();

    adapter.attach(WebViewController.fromPlatform(platform), bridge);

    expect(platform.addedChannels, equals(['XBridge']));
    expect(
      platform.evaluatedScripts.join('\n'),
      contains('__xbridge_initialized__'),
    );

    bridge.dispose();
  });

  test('detach never removes the JS channel and injects invalidation script',
      () async {
    final adapter = WebViewFlutterBridgeAdapter();
    final bridge = BridgeController();
    final platform = _RecordingPlatformWebViewController();
    adapter.attach(WebViewController.fromPlatform(platform), bridge);

    platform.evaluatedScripts.clear();
    adapter.detach();

    // 根治点：不调用 removeJavaScriptChannel —— 避免 webview_flutter_wkwebview
    // _resetUserScripts 的"全量移除再异步重加"窗口，旧 document 的迟到调用
    // 不再撞上已注销的原生 handler（InvalidAccessError 的根因）。
    expect(platform.removedChannels, isEmpty);

    // 纵深防御：注入失效脚本，旧 document 迟到的 postMessage 同步抛出
    // XBridgeSendError，可被 JS 侧 circuit breaker 识别。
    final detachedScripts = platform.evaluatedScripts.join('\n');
    expect(detachedScripts, contains('XBridgeSendError'));
    expect(detachedScripts, contains('window.XBridge = {'));

    // 导航委托照常重置（attach 1 个 composite + detach 1 个空 delegate）。
    expect(platform.navigationDelegates, hasLength(2));

    bridge.dispose();
  });

  test('detach allows re-attach to a fresh controller', () async {
    final adapter = WebViewFlutterBridgeAdapter();
    final bridge = BridgeController();
    final first = _RecordingPlatformWebViewController();
    adapter.attach(WebViewController.fromPlatform(first), bridge);
    adapter.detach();

    final second = _RecordingPlatformWebViewController();
    final bridge2 = BridgeController();
    final firstScriptCount = first.evaluatedScripts.length;
    adapter.attach(WebViewController.fromPlatform(second), bridge2);

    expect(second.addedChannels, equals(['XBridge']));
    // 第一个 WebView 不应再收到任何新注入。
    expect(first.evaluatedScripts.length, firstScriptCount);

    bridge.dispose();
    bridge2.dispose();
  });

  test('detach drops inbound channel messages at the Dart layer', () async {
    final adapter = WebViewFlutterBridgeAdapter();
    final bridge = BridgeController();
    // allowAll so the control-group message reaches the handler instead of
    // being rejected by the deny-by-default origin policy.
    bridge.setSecurityPolicy(
      XBridgeSecurityPolicy(allowedOrigins: const {}, allowAll: true),
    );

    var handlerCalls = 0;
    bridge.addHandler('ping', (context, params, request) async {
      handlerCalls++;
      return 'pong';
    });

    final platform = _RecordingPlatformWebViewController();
    adapter.attach(WebViewController.fromPlatform(platform), bridge);

    // Control group: before detach the same message flows through the channel
    // and produces an outbound resolve script.
    platform.evaluatedScripts.clear();
    final inbound =
        platform.addedChannelParams.single.onMessageReceived;
    inbound(const JavaScriptMessage(
      message: '{"jsonrpc":"2.0","id":"ctl","method":"ping","params":{}}',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(platform.evaluatedScripts.join('\n'), contains('"ctl"'));
    expect(handlerCalls, 1);

    // Detach, then replay the identical message: the Dart-side gate must
    // swallow it — no handler execution, no outbound script, no zone errors.
    adapter.detach();
    platform.evaluatedScripts.clear();
    inbound(const JavaScriptMessage(
      message: '{"jsonrpc":"2.0","id":"post","method":"ping","params":{}}',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(handlerCalls, 1);
    expect(platform.evaluatedScripts, isEmpty);

    // Fire-and-forget post-detach message: equally dropped, silently.
    inbound(const JavaScriptMessage(
      message: '{"jsonrpc":"2.0","method":"ping","params":{}}',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(handlerCalls, 1);
    expect(platform.evaluatedScripts, isEmpty);

    bridge.dispose();
  });

  test('re-attach clears the Dart-side detached gate', () async {
    final adapter = WebViewFlutterBridgeAdapter();
    final bridge = BridgeController();
    bridge.setSecurityPolicy(
      XBridgeSecurityPolicy(allowedOrigins: const {}, allowAll: true),
    );

    final platform = _RecordingPlatformWebViewController();
    adapter.attach(WebViewController.fromPlatform(platform), bridge);
    adapter.detach();

    // Re-attach (fresh controller + bridge pairing) must clear the gate so
    // the new WebView's messages flow again.
    final platform2 = _RecordingPlatformWebViewController();
    final bridge2 = BridgeController();
    bridge2.setSecurityPolicy(
      XBridgeSecurityPolicy(allowedOrigins: const {}, allowAll: true),
    );
    adapter.attach(WebViewController.fromPlatform(platform2), bridge2);

    var handler2Calls = 0;
    bridge2.addHandler('ping', (context, params, request) async {
      handler2Calls++;
      return 'pong';
    });

    platform2.evaluatedScripts.clear();
    platform2.addedChannelParams.single.onMessageReceived(
      const JavaScriptMessage(
        message: '{"jsonrpc":"2.0","id":"re","method":"ping","params":{}}',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(handler2Calls, 1);
    expect(platform2.evaluatedScripts.join('\n'), contains('"re"'));

    bridge.dispose();
    bridge2.dispose();
  });
}
