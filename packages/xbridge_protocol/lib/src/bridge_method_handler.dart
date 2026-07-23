import 'dart:async';

import 'bridge_method_context.dart';
import 'bridge_request.dart';

/// Signature every method handler must satisfy.
///
/// Returning a [Future] makes the call asynchronous; returning a plain value
/// resolves synchronously.
typedef BridgeMethodHandler = FutureOr<dynamic> Function(
  BridgeMethodContext context,
  dynamic params,
  BridgeRequest request,
);
