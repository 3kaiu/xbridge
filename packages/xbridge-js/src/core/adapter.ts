/**
 * Adapter contracts — the seam between the XBridge core and a concrete transport.
 *
 * Implementations live under {@link ../adapters/}. An adapter owns a single
 * platform channel (e.g. `window.XBridge`, `window.webkit.messageHandlers`,
 * `window.flutter_inappwebview`) and is responsible for:
 *
 * 1. Sending a serialized XBridge wire message to the host (`send`).
 * 2. Installing a single inbound handler that receives raw wire strings and
 *    forwards them to the core (`onMessage`).
 *
 * The core installs its message handler exactly once per adapter; adapters must
 * not install additional per-call closures.
 */

/**
 * Async adapter — request/response and event transport. All methods on a given
 * instance are idempotent and safe to call repeatedly.
 */
export interface IXBridgeAdapter {
  /** Human-readable adapter name, surfaced in diagnostics. */
  readonly name: string;

  /**
   * Send a serialized wire message to the host. The string is a complete
   * JSON-RPC message; the adapter must not re-serialize it.
   */
  send(message: string): void;

  /**
   * Install the inbound handler. Called once by the core. Implementations
   * must route every subsequently-received raw wire string into `handler`.
   * Re-installing replaces the previous handler.
   */
  onMessage(handler: (raw: string) => void): void;

  /**
   * Whether the underlying transport is present in the current environment.
   * Used by {@link XBridge} for auto-sniffing. Cached externally; this method
   * must be side-effect-free.
   */
  isAvailable(): boolean;

  /**
   * Tear down adapter-side resources (event listeners, global handlers).
   * Optional — adapters that install no leakable resources may omit it.
   * Called by the host when the adapter is no longer needed. Must be
   * idempotent.
   */
  destroy?(): void;
}

/**
 * Sync adapter — a synchronous bypass channel (e.g. a native sync bridge that
 * detects `window.dsbridge`, or a native `@JavascriptInterface` object). Calls
 * return immediately; there is no correlation id and no Promise. Used by
 * {@link XBridgeCore.callSync}.
 *
 * Per PRD §P1 / audit Risk 1: Flutter channels are strictly async, so a sync
 * adapter is optional. When absent, `callSync` degrades to a warning + null.
 */
export interface ISyncAdapter {
  readonly name: string;

  /**
   * Synchronously invoke `method` on the host and return its value. Returning
   * `undefined` is indistinguishable from "no value"; callers must tolerate it.
   */
  callSync(method: string, params?: unknown): unknown;

  isAvailable(): boolean;
}
