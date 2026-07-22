/**
 * XBridge protocol types — JSON-RPC 2.0 variant.
 *
 * Wire format contract shared by H5 (`xbridge-js`), Flutter (`xbridge_flutter`)
 * and native hosts. The protocol is the only "contract" between ends; adapters
 * are responsible for translating platform-specific transports into these
 * messages.
 *
 * @see https://www.jsonrpc.org/specification
 */

/** Protocol version marker embedded in every wire message. */
export const XBRIDGE_PROTOCOL_VERSION = "2.0" as const;

/**
 * H5 → Host request.
 *
 * `id` correlates the eventual {@link XBridgeResponse}. `params` is optional
 * for methods that take no arguments.
 */
export interface XBridgeRequest {
  jsonrpc: typeof XBRIDGE_PROTOCOL_VERSION;
  id?: string | null;
  method: string;
  params?: unknown;
}

/**
 * Host → H5 response. Exactly one of `result` / `error` is meaningful per
 * JSON-RPC 2.0; both are optional here because the host may omit `result`
 * for void methods (resolved as `undefined`).
 */
export interface XBridgeResponse {
  jsonrpc: typeof XBRIDGE_PROTOCOL_VERSION;
  id: string;
  result?: unknown;
  error?: XBridgeError;
}

/**
 * Host → H5 push event. Carries no `id` — it is a one-way notification that
 * zero or more H5 listeners may observe via {@link XBridge.onEvent}.
 */
export interface XBridgeEvent {
  jsonrpc: typeof XBRIDGE_PROTOCOL_VERSION;
  method: string;
  params?: unknown;
}

/**
 * Structured error. `code` is numeric per JSON-RPC 2.0 convention; the Flutter
 * side historically uses a String code (e.g. `'BRIDGE_ERROR'`), and the H5
 * dispatcher treats the field loosely so either form round-trips.
 */
export interface XBridgeError {
  code: number | string;
  message: string;
  data?: unknown;
}

/** Union of inbound host → H5 wire messages. */
export type XBridgeMessage = XBridgeResponse | XBridgeEvent | XBridgeRequest;

/** Options accepted by {@link XBridgeCore.call}. */
export interface XBridgeCallOptions {
  /** Per-call timeout in milliseconds. `0` disables the timeout. */
  timeout?: number;
  /**
   * Fire-and-forget: resolve immediately after the message is handed to the
   * adapter, without registering a pending entry. Mirrors the WK no-callback
   * semantics where `requestId` is `null`.
   */
  noCallback?: boolean;
}
