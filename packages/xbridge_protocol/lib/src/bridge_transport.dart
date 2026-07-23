import 'bridge_event.dart';
import 'bridge_response.dart';

/// Pluggable JS transport contract.
///
/// Adapters (e.g. `WebViewFlutterBridgeAdapter`, `InAppWebViewBridgeAdapter`)
/// implement this interface to route outgoing calls into a concrete WebView instance.
///
/// Pure protocol contract — zero WebView dependencies.
abstract class BridgeTransport {
  Future<void> resolve(String id, dynamic result);
  Future<void> reject(String id, BridgeError error);
  Future<void> dispatchEvent(BridgeEvent event);
  Future<void> callH5Handler(String id, String method, dynamic params);
}
