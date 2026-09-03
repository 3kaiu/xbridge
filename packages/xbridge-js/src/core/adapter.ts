/**
 * Adapter contracts — the seam between the XBridge core and a concrete transport.
 *
 * Implementations live under {@link ../adapters/}. An adapter owns a single
 * platform channel (e.g. `window.XBridge`) and is responsible for:
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
   * must route every subsequently-received raw wire message into `handler`.
   * Re-installing replaces the previous handler.
   *
   * `raw` may be a JSON string or an object literal (e.g. the Flutter host
   * injecting `window.__XBridgeInbound__({...})`). The core normalizes both.
   */
  onMessage(handler: (raw: string | object) => void): void;

  /**
   * Whether the underlying transport is present in the current environment.
   * Used by {@link XBridge} for auto-sniffing. Cached externally; this method
   * must be side-effect-free.
   */
  isAvailable(): boolean;

  /**
   * Optional availability-probe verdict for transports that are present-but-
   * maybe-broken. Returns one of:
   * - `"unprobed"`: no probe has been sent yet (availability not yet verified).
   * - `"healthy"`: probe succeeded — the transport is genuinely usable.
   * - `"broken"`: probe failed (e.g. a `window.XBridge.postMessage` that throws
   *   `InvalidAccessError` because the underlying handler was never registered,
   *   as in third-party hosts that expose a fake handle).
   *
   * Callers use this instead of re-sniffing the raw global, so availability
   * decisions stay driven by the single probe verdict rather than by manual
   * `typeof window.XBridge?.postMessage` checks. Adapters without a probe step
   * may omit it.
   */
  readonly availabilityProbe?: "unprobed" | "healthy" | "broken";

  /**
   * Tear down adapter-side resources (event listeners, global handlers).
   * Optional — adapters that install no leakable resources may omit it.
   * Called by the host when the adapter is no longer needed. Must be
   * idempotent.
   */
  destroy?(): void;

  /**
   * Reset any internal circuit-breaker or error state back to healthy.
   * Optional — adapters that maintain no internal error state may omit it.
   */
  reset?(): void;
}
