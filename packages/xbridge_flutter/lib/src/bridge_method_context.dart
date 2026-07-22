import 'dart:async';

import 'package:webview_flutter/webview_flutter.dart';

/// Context handed to every registered [BridgeMethodHandler].
///
/// Handlers receive the owning [WebViewController] so they can drive the WebView
/// (navigate, inject JS, read the URL for security decisions) without depending
/// on the concrete channel/adapter that delivered the message. [origin] is the
/// best-known page origin at dispatch time, populated when a
/// [BridgeController] has a controller attached and a URL observable.
class BridgeMethodContext {
  BridgeMethodContext({
    required this.controller,
    this.origin,
  });

  /// The WebView controller the message originated from.
  final WebViewController controller;

  /// Best-effort origin (`scheme://host[:port]`) of the page that issued the
  /// call, or `null` when unknown.
  final String? origin;
}

/// Signature every method handler must satisfy.
///
/// Returning a [Future] makes the call asynchronous; returning a plain value
/// resolves synchronously. Throwing is always caught by [BridgeController]
/// and converted into a [BridgeError] reject response — exceptions never
/// escape the channel.
typedef BridgeMethodHandler = FutureOr<dynamic> Function(
  BridgeMethodContext context,
  dynamic params,
);
