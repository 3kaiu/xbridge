/// Context handed to every registered [BridgeMethodHandler].
///
/// Pure protocol value object — zero WebView dependencies.
/// [origin] is the best-known page origin at dispatch time.
/// [extras] allows adapters to attach optional metadata (e.g. underlying controller).
class BridgeMethodContext {
  const BridgeMethodContext({
    this.origin,
    this.extras,
  });

  /// Best-effort origin (`scheme://host[:port]`) of the page that issued the call.
  final String? origin;

  /// Optional metadata dictionary attached by the adapter.
  final Map<String, Object>? extras;
}
