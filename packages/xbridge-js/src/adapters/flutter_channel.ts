/**
 * FlutterChannelAdapter — bridges the `window.XBridge` (Flutter JavaScriptChannel)
 * protocol into the XBridge JSON-RPC wire format.
 *
 * Existing contract (the host app's `CommonJsBridge`):
 *
 *   H5 → Host:
 *     window.XBridge.postMessage(JSON.stringify({ id, method, params }))
 *
 *   Host → H5 (resolve / reject an outstanding request):
 *     window.__XBridge__.resolve(id, result)
 *     window.__XBridge__.reject(id, error)
 *
 *   Host → H5 (push event):
 *     window.dispatchEvent(new CustomEvent('XBridgeEvent', { detail }))
 *
 * This adapter installs (or augments) the global `__XBridge__` object
 * and synthesizes JSON-RPC response strings for the core to consume. Host
 * events are also routed through by translating `CustomEvent.detail` into a
 * JSON-RPC event envelope.
 *
 * Security: the `__XBridge__` global is defined via `Object.defineProperty`
 * as non-configurable and non-enumerable, preventing page scripts from
 * replacing or enumerating the hook.
 */

import type { IXBridgeAdapter } from "../core/adapter.js";
import { XBRIDGE_PROTOCOL_VERSION } from "../types.js";

/** Shape of the resolve/reject surface installed on `window`. */
interface XBridgeGlobal {
  resolve?: (id: string, result?: unknown) => void;
  reject?: (id: string, error?: unknown) => void;
  [key: string]: unknown;
}

interface WindowWithXBridge {
  XBridge?: { postMessage: (message: string) => void };
  __XBridge__?: XBridgeGlobal;
  __XBridgeInbound__?: (raw: string) => void;
  addEventListener?: (
    type: string,
    listener: (event: unknown) => void,
  ) => void;
  removeEventListener?: (
    type: string,
    listener: (event: unknown) => void,
  ) => void;
}

function getWindow(): WindowWithXBridge | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithXBridge)
    : undefined;
}

/** Event name for host-pushed CustomEvents. */
const XBRIDGE_EVENT_NAME = "XBridgeEvent";

/**
 * Adapter for `window.XBridge`. Single `postMessage` channel; inbound route
 * via the `__XBridge__` global + `XBridgeEvent` CustomEvent.
 */
export class FlutterChannelAdapter implements IXBridgeAdapter {
  readonly name = "XBridge";
  private inbound: ((raw: string) => void) | undefined;
  private installed = false;
  private eventListener: ((event: unknown) => void) | undefined;
  private inboundFn: ((raw: string) => void) | undefined;
  private patchedResolve: ((id: string, result?: unknown) => void) | undefined;
  private patchedReject: ((id: string, error?: unknown) => void) | undefined;
  private priorResolve: ((id: string, result?: unknown) => void) | undefined;
  private priorReject: ((id: string, error?: unknown) => void) | undefined;

  isAvailable(): boolean {
    const w = getWindow();
    return w !== undefined && typeof w.XBridge?.postMessage === "function";
  }

  send(message: string): void {
    const w = getWindow();
    if (w === undefined || w.XBridge === undefined) {
      throw new Error("[FlutterChannelAdapter] window.XBridge is not available");
    }
    w.XBridge.postMessage(message);
  }

  onMessage(handler: (raw: string) => void): void {
    this.inbound = handler;
    this.ensureInstalled();
  }

  /**
   * Install (or wrap) the global `__XBridge__` and the event listener.
   * Idempotent — safe to call multiple times; only installs once per adapter.
   *
   * Security: when creating a fresh `__XBridge__` object, it is defined via
   * `Object.defineProperty` with `configurable: false` and `enumerable: false`
   * so page scripts cannot replace or enumerate the hook. When an existing
   * object is already present (installed by the host), its methods are patched
   * in place — the property descriptor is left as-is out of caution.
   */
  private ensureInstalled(): void {
    if (this.installed) {
      return;
    }
    this.installed = true;
    const w = getWindow();
    if (w === undefined) {
      return;
    }

    const self = this;

    const resolveFn = (id: string, result?: unknown): void => {
      self.dispatchResponse(id, result, undefined, false);
    };
    const rejectFn = (id: string, error?: unknown): void => {
      self.dispatchResponse(id, undefined, error, true);
    };

    // Patch methods on the existing object instead of replacing it — preserves
    // any other properties the host may have installed.
    const existing = w.__XBridge__;
    if (existing !== undefined) {
      // Preserve any prior install: chain behind it so existing callers still
      // observe. In practice the bridge is the sole owner, but be defensive.
      this.priorResolve = existing.resolve;
      this.priorReject = existing.reject;
      existing.resolve = (id: string, result?: unknown): void => {
        resolveFn(id, result);
        if (self.priorResolve !== undefined) {
          self.priorResolve(id, result);
        }
      };
      existing.reject = (id: string, error?: unknown): void => {
        rejectFn(id, error);
        if (self.priorReject !== undefined) {
          self.priorReject(id, error);
        }
      };
      this.patchedResolve = existing.resolve;
      this.patchedReject = existing.reject;
    } else {
      const obj: XBridgeGlobal = {
        resolve: resolveFn,
        reject: rejectFn,
      };
      // Define as non-configurable and non-enumerable to prevent page scripts
      // from replacing or discovering the hook via enumeration.
      Object.defineProperty(w, "__XBridge__", {
        value: obj,
        writable: true,
        configurable: false,
        enumerable: false,
      });
      this.patchedResolve = resolveFn;
      this.patchedReject = rejectFn;
    }

    // Host-pushed events arrive as CustomEvent('XBridgeEvent', { detail }).
    // The legacy detail shape is { actionType, requestId?, params?, timestamp }.
    // We re-wrap it into a JSON-RPC event envelope so the core's single parser
    // handles both responses and events uniformly. `method` is taken from
    // `actionType` when present, falling back to the literal event name so
    // listeners keyed on 'XBridgeEvent' still receive the payload.
    if (typeof w.addEventListener === "function") {
      this.eventListener = (event: unknown): void => {
        const detail = (event as { detail?: unknown } | null)?.detail;
        const detailRecord =
          detail !== null && typeof detail === "object" ? (detail as Record<string, unknown>) : null;
        const method =
          detailRecord !== null && typeof detailRecord["actionType"] === "string"
            ? String(detailRecord["actionType"])
            : XBRIDGE_EVENT_NAME;
        self.dispatchEvent(method, detail);
      };
      w.addEventListener(XBRIDGE_EVENT_NAME, this.eventListener);
    }

    // Install the inbound global for Native→H5 requests. The Native host
    // injects `window.__XBridgeInbound__(rawJson)` to send a JSON-RPC request
    // (with both `id` and `method`) to the H5 side; the core's `handleRaw`
    // looks up a registered handler and sends back a response via
    // `adapter.send()` (which calls `XBridge.postMessage`).
    this.inboundFn = (raw: string): void => {
      self.inbound?.(raw);
    };
    Object.defineProperty(w, "__XBridgeInbound__", {
      value: this.inboundFn,
      writable: false,
      configurable: false,
      enumerable: false,
    });
  }

  /**
   * Tear down: remove the event listener and restore prior resolve/reject
   * handlers. Safe to call multiple times.
   */
  destroy(): void {
    if (!this.installed) {
      return;
    }
    this.installed = false;
    const w = getWindow();
    if (w !== undefined) {
      if (this.eventListener !== undefined && typeof w.removeEventListener === "function") {
        w.removeEventListener(XBRIDGE_EVENT_NAME, this.eventListener);
      }
      // Restore prior handlers if we patched an existing object.
      const existing = w.__XBridge__;
      if (existing !== undefined) {
        if (this.priorResolve !== undefined) {
          existing.resolve = this.priorResolve;
        } else if (this.patchedResolve !== undefined) {
          delete existing.resolve;
        }
        if (this.priorReject !== undefined) {
          existing.reject = this.priorReject;
        } else if (this.patchedReject !== undefined) {
          delete existing.reject;
        }
      }
      // Remove the inbound global only if we still own it (hasn't been
      // replaced by another adapter). Since it was installed via
      // defineProperty(configurable:false), we can't delete it — but we
      // can nullify the handler so calls become no-ops.
      if (this.inboundFn !== undefined && w.__XBridgeInbound__ === this.inboundFn) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        try { delete (w as any).__XBridgeInbound__; } catch { /* non-configurable — no-op fallback */ }
      }
      this.inboundFn = undefined;
    }
    this.eventListener = undefined;
    this.patchedResolve = undefined;
    this.patchedReject = undefined;
    this.priorResolve = undefined;
    this.priorReject = undefined;
  }

  private dispatchResponse(id: string, result: unknown, error: unknown, isError: boolean): void {
    if (this.inbound === undefined) {
      return;
    }
    // Synthesize a JSON-RPC 2.0 response. Use an explicit isError flag rather
    // than inferring from null-ness — `reject(id, null)` must still produce an
    // error response, not a resolve.
    const response: Record<string, unknown> = {
      jsonrpc: XBRIDGE_PROTOCOL_VERSION,
      id,
    };
    if (isError) {
      // Normalize error into a well-formed XBridgeError so the core's
      // reject path doesn't bury the original message in `data`.
      response["error"] =
        error !== null && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
          ? error
          : {
              code: -32000,
              message: typeof error === "string" ? error : "Host error",
              data: error,
            };
    } else {
      response["result"] = result;
    }
    this.inbound(JSON.stringify(response));
  }

  private dispatchEvent(method: string, params: unknown): void {
    if (this.inbound === undefined) {
      return;
    }
    const envelope: Record<string, unknown> = {
      jsonrpc: XBRIDGE_PROTOCOL_VERSION,
      method,
    };
    if (params !== undefined) {
      envelope["params"] = params;
    }
    this.inbound(JSON.stringify(envelope));
  }
}
