/**
 * Universal Standard Adapter.
 *
 * Connects to the container-injected `window.XBridge.postMessage` global.
 * Eliminates environmental sniffing by providing a single stable contract
 * regardless of whether Flutter uses webview_flutter or a native shell.
 *
 * Inbound path: the host bootstrap (e.g. `BridgeScriptBuilder.unifiedBootstrap`
 * on the Dart side) installs `window.__XBridge__.resolve`,
 * `window.__XBridge__.reject`, `window.__XBridgeInbound__`, and dispatches
 * `XBridgeEvent` CustomEvents as no-op stubs. The adapter overrides these
 * AFTER construction to route inbound messages into the core handler. Because
 * the H5 SDK constructor may run before or after the bootstrap injection,
 * overrides are re-checked lazily on each `send()` call — if the bootstrap
 * has reset them to stubs, the adapter re-installs its overrides.
 */

import type { IXBridgeAdapter } from "../core/adapter.js";
import { XBRIDGE_PROTOCOL_VERSION } from "../types.js";

// ---------------------------------------------------------------------------
// Typed global interfaces (W1: replace `as any` with proper typing)
// ---------------------------------------------------------------------------

/** Shape of the host-injected `window.__XBridge__` resolve/reject object. */
interface XBridgeGlobal {
  resolve?: (id: string, result?: unknown) => void;
  reject?: (id: string, error?: unknown) => void;
}

/** Shape of the host-injected inbound request dispatcher. */
type XBridgeInboundHandler = (requestJson: string) => void;

/** Detail payload for `XBridgeEvent` CustomEvents. */
interface XBridgeEventDetail {
  actionType?: string;
  params?: unknown;
}

/**
 * Typed view of the global object for this adapter. Every property is
 * optional because the host injects them at runtime.
 */
interface WindowWithXBridge {
  XBridge?: { postMessage?: (message: string) => void };
  __XBridge__?: XBridgeGlobal;
  __XBridgeInbound__?: XBridgeInboundHandler;
  addEventListener?: (
    type: string,
    listener: (ev: Event) => void,
  ) => void;
  removeEventListener?: (
    type: string,
    listener: (ev: Event) => void,
  ) => void;
}

function getWindow(): WindowWithXBridge | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithXBridge)
    : undefined;
}

// ---------------------------------------------------------------------------
// Internal invalidation hook for the sniff cache (W2)
//
// `index.ts` owns the `sniffCache` module variable. We expose a registration
// mechanism so that the exported `resetSniffCache()` can clear it without a
// circular import. `index.ts` calls `setSniffCacheInvalidator(...)` at module
// load time.
// ---------------------------------------------------------------------------

let sniffCacheInvalidator: (() => void) | null = null;

/**
 * Register a callback invoked by {@link resetSniffCache}. Called once by
 * `index.ts` to wire the module-level `sniffCache` invalidation.
 * @internal
 */
export function setSniffCacheInvalidator(fn: (() => void) | null): void {
  sniffCacheInvalidator = fn;
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

/**
 * Saved originals for `destroy()` restoration. `null` means the property
 * did not exist before we overrode it (so `destroy` deletes it).
 */
interface SavedOriginals {
  resolve: XBridgeGlobal["resolve"] | null;
  reject: XBridgeGlobal["reject"] | null;
  inbound: XBridgeInboundHandler | null;
  /** Whether we installed the XBridgeEvent listener. */
  eventListenerInstalled: boolean;
}

/**
 * Universal async adapter backed by `window.XBridge.postMessage`.
 *
 * The inbound path is installed lazily and re-validated on each `send()` to
 * survive host bootstrap re-injection.
 */
export class StandardAdapter implements IXBridgeAdapter {
  readonly name = "Standard";

  /** The inbound handler set by the core via `onMessage`. */
  private handler: ((raw: string) => void) | null = null;

  /** Stored override functions so we can detect if the host replaced them. */
  private _resolveOverride: ((id: string, result?: unknown) => void) | null = null;
  private _rejectOverride: ((id: string, error?: unknown) => void) | null = null;
  private _inboundOverride: ((requestJson: string) => void) | null = null;

  /** Snapshot of pre-override globals, for restoration in `destroy()`. */
  private saved: SavedOriginals | null = null;

  /** Bound event listener reference so we can remove it in `destroy()`. */
  private boundEventListener: ((ev: Event) => void) | null = null;

  /**
   * Invalidate the XBridge environment sniff cache so that a late-injected
   * `window.XBridge` (e.g. after the page already constructed `XBridge`) is
   * detected on the next `XBridge` construction.
   */
  static resetSniffCache(): void {
    if (sniffCacheInvalidator !== null) {
      sniffCacheInvalidator();
    }
  }

  isAvailable(): boolean {
    const w = getWindow();
    return w !== undefined && typeof w.XBridge?.postMessage === "function";
  }

  send(message: string): void {
    const w = getWindow();
    if (w === undefined) {
      throw new Error("[XBridge] StandardAdapter: globalThis is not available");
    }
    // Lazy re-install: if the host bootstrap reset our overrides to stubs
    // (or never let us install them), re-install now.
    if (this.handler !== null) {
      this.ensureOverridesInstalled(w);
    }
    if (typeof w.XBridge?.postMessage === "function") {
      w.XBridge.postMessage(message);
    } else {
      throw new Error(
        "[XBridge] StandardAdapter: window.XBridge.postMessage is not available",
      );
    }
  }

  onMessage(handler: (raw: string) => void): void {
    // Re-installing replaces the previous handler.
    this.handler = handler;
    const w = getWindow();
    if (w !== undefined) {
      this.ensureOverridesInstalled(w);
    }
  }

  /**
   * Install global overrides for the inbound path. Captures originals on
   * first invocation so `destroy()` can restore them. Only re-installs if
   * the host bootstrap has replaced our overrides with something else —
   * detected by comparing function references. This avoids races where
   * re-installing mid-flight orphaned an in-flight host-side response.
   */
  private ensureOverridesInstalled(w: WindowWithXBridge): void {
    if (this.handler === null) {
      return;
    }
    const handler = this.handler;

    // Capture originals on the first install.
    let saved = this.saved;
    if (saved === null) {
      const xb = w.__XBridge__;
      saved = {
        resolve: xb?.resolve ?? null,
        reject: xb?.reject ?? null,
        inbound: w.__XBridgeInbound__ ?? null,
        eventListenerInstalled: false,
      };
      this.saved = saved;
    }

    // Ensure the `__XBridge__` host object exists (the bootstrap may not have
    // created it yet). We create a minimal object so resolve/reject land here.
    if (w.__XBridge__ === undefined) {
      w.__XBridge__ = {};
    }

    // Override resolve — but only if our override is not already in place.
    // This prevents re-assignment on every `send()` call, which races with
    // the host bootstrap and can orphan in-flight host-side responses.
    if (w.__XBridge__.resolve !== this._resolveOverride) {
      this._resolveOverride = (id: string, result?: unknown): void => {
        handler(
          JSON.stringify({
            jsonrpc: XBRIDGE_PROTOCOL_VERSION,
            id,
            result,
          }),
        );
      };
      w.__XBridge__.resolve = this._resolveOverride;
    }

    // Override reject — same guard.
    if (w.__XBridge__.reject !== this._rejectOverride) {
      this._rejectOverride = (id: string, error?: unknown): void => {
        handler(
          JSON.stringify({
            jsonrpc: XBRIDGE_PROTOCOL_VERSION,
            id,
            error,
          }),
        );
      };
      w.__XBridge__.reject = this._rejectOverride;
    }

    // Override the inbound request dispatcher — same guard.
    if (w.__XBridgeInbound__ !== this._inboundOverride) {
      this._inboundOverride = (requestJson: string): void => {
        handler(requestJson);
      };
      w.__XBridgeInbound__ = this._inboundOverride;
    }

    // Install the XBridgeEvent CustomEvent listener. The host dispatches:
    //   window.dispatchEvent(new CustomEvent('XBridgeEvent', {
    //     detail: { actionType, params }
    //   }))
    // We translate it into a JSON-RPC event message.
    if (!saved.eventListenerInstalled && typeof w.addEventListener === "function") {
      this.boundEventListener = (ev: Event): void => {
        const detail = (ev as CustomEvent<XBridgeEventDetail>).detail;
        if (detail === undefined || detail === null) {
          return;
        }
        const actionType = detail.actionType;
        if (typeof actionType !== "string") {
          return;
        }
        handler(
          JSON.stringify({
            jsonrpc: XBRIDGE_PROTOCOL_VERSION,
            method: actionType,
            params: detail.params,
          }),
        );
      };
      w.addEventListener("XBridgeEvent", this.boundEventListener);
      saved.eventListenerInstalled = true;
    }
  }

  /**
   * Remove all installed listeners and restore the original global functions.
   * Idempotent — safe to call multiple times.
   */
  destroy(): void {
    const w = getWindow();
    if (w !== undefined && this.saved !== null) {
      // Restore __XBridge__.resolve/reject. We unconditionally restore the
      // saved originals (or delete if they never existed). This is safe
      // because ensureOverridesInstalled captures originals before the first
      // override on each property.
      if (w.__XBridge__ !== undefined) {
        if (this.saved.resolve !== null) {
          w.__XBridge__.resolve = this.saved.resolve;
        } else {
          delete w.__XBridge__.resolve;
        }
        if (this.saved.reject !== null) {
          w.__XBridge__.reject = this.saved.reject;
        } else {
          delete w.__XBridge__.reject;
        }
        // If we created __XBridge__ from scratch and it's now empty, clean up.
        if (
          this.saved.resolve === null &&
          this.saved.reject === null &&
          w.__XBridge__.resolve === undefined &&
          w.__XBridge__.reject === undefined
        ) {
          delete w.__XBridge__;
        }
      }

      // Restore __XBridgeInbound__
      if (this.saved.inbound !== null) {
        w.__XBridgeInbound__ = this.saved.inbound;
      } else {
        delete w.__XBridgeInbound__;
      }

      // Remove the XBridgeEvent listener.
      if (
        this.saved.eventListenerInstalled &&
        this.boundEventListener !== null &&
        typeof w.removeEventListener === "function"
      ) {
        w.removeEventListener("XBridgeEvent", this.boundEventListener);
      }
    }

    this.saved = null;
    this.boundEventListener = null;
    this._resolveOverride = null;
    this._rejectOverride = null;
    this._inboundOverride = null;
    this.handler = null;
  }
}
