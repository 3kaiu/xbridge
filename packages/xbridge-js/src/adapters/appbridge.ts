/**
 * AppBridgeAdapter — bridges the legacy `window.AppBridge` protocol into the
 * XBridge JSON-RPC wire format.
 *
 * Existing contract (yashi-h5 / flutter_yashi_ai `CommonJsBridge`):
 *
 *   H5 → Host:
 *     window.AppBridge.postMessage(JSON.stringify({ id, method, params }))
 *
 *   Host → H5 (resolve / reject an outstanding request):
 *     window.__YASHI_APP_BRIDGE__.resolve(id, result)
 *     window.__YASHI_APP_BRIDGE__.reject(id, error)
 *
 *   Host → H5 (push event):
 *     window.dispatchEvent(new CustomEvent('YashiAppEvent', { detail }))
 *
 * This adapter installs (or augments) the global `__YASHI_APP_BRIDGE__` object
 * and synthesizes JSON-RPC response strings for the core to consume. Host
 * events are also routed through by translating `CustomEvent.detail` into a
 * JSON-RPC event envelope.
 */

import type { IXBridgeAdapter } from "../core/adapter.js";
import { XBRIDGE_PROTOCOL_VERSION } from "../types.js";

/** Shape of the legacy resolve/reject surface installed on `window`. */
interface AppBridgeGlobal {
  resolve?: (id: string, result?: unknown) => void;
  reject?: (id: string, error?: unknown) => void;
  [key: string]: unknown;
}

interface WindowWithAppBridge {
  AppBridge?: { postMessage: (message: string) => void };
  __YASHI_APP_BRIDGE__?: AppBridgeGlobal;
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

function getWindow(): WindowWithAppBridge | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithAppBridge)
    : undefined;
}

/**
 * Adapter for `window.AppBridge`. Single `postMessage` channel; inbound route
 * via the `__YASHI_APP_BRIDGE__` global + `YashiAppEvent` CustomEvent.
 */
export class AppBridgeAdapter implements IXBridgeAdapter {
  readonly name = "AppBridge";
  private inbound: ((raw: string) => void) | undefined;
  private installed = false;
  private eventListener: ((event: unknown) => void) | undefined;
  private patchedResolve: ((id: string, result?: unknown) => void) | undefined;
  private patchedReject: ((id: string, error?: unknown) => void) | undefined;
  private priorResolve: ((id: string, result?: unknown) => void) | undefined;
  private priorReject: ((id: string, error?: unknown) => void) | undefined;

  isAvailable(): boolean {
    const w = getWindow();
    return w !== undefined && typeof w.AppBridge?.postMessage === "function";
  }

  send(message: string): void {
    const w = getWindow();
    if (w === undefined || w.AppBridge === undefined) {
      throw new Error("[AppBridgeAdapter] window.AppBridge is not available");
    }
    w.AppBridge.postMessage(message);
  }

  onMessage(handler: (raw: string) => void): void {
    this.inbound = handler;
    this.ensureInstalled();
  }

  /**
   * Install (or wrap) the global `__YASHI_APP_BRIDGE__` and the event listener.
   * Idempotent — safe to call multiple times; only installs once per adapter.
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
    const existing = w.__YASHI_APP_BRIDGE__;
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
      const obj: AppBridgeGlobal = {
        resolve: resolveFn,
        reject: rejectFn,
      };
      w.__YASHI_APP_BRIDGE__ = obj;
      this.patchedResolve = resolveFn;
      this.patchedReject = rejectFn;
    }

    // Host-pushed events arrive as CustomEvent('YashiAppEvent', { detail }).
    // The legacy detail shape is { actionType, requestId?, params?, timestamp }.
    // We re-wrap it into a JSON-RPC event envelope so the core's single parser
    // handles both responses and events uniformly. `method` is taken from
    // `actionType` when present, falling back to the literal event name so
    // listeners keyed on 'YashiAppEvent' still receive the payload.
    if (typeof w.addEventListener === "function") {
      this.eventListener = (event: unknown): void => {
        const detail = (event as { detail?: unknown } | null)?.detail;
        const detailRecord =
          detail !== null && typeof detail === "object" ? (detail as Record<string, unknown>) : null;
        const method =
          detailRecord !== null && typeof detailRecord["actionType"] === "string"
            ? String(detailRecord["actionType"])
            : "YashiAppEvent";
        self.dispatchEvent(method, detail);
      };
      w.addEventListener("YashiAppEvent", this.eventListener);
    }

    // Install the inbound global for Native→H5 requests. The Native host
    // injects `window.__XBridgeInbound__(rawJson)` to send a JSON-RPC request
    // (with both `id` and `method`) to the H5 side; the core's `handleRaw`
    // looks up a registered handler and sends back a response via
    // `adapter.send()` (which calls `AppBridge.postMessage`).
    w.__XBridgeInbound__ = (raw: string): void => {
      self.inbound?.(raw);
    };
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
        w.removeEventListener("YashiAppEvent", this.eventListener);
      }
      // Restore prior handlers if we patched an existing object.
      const existing = w.__YASHI_APP_BRIDGE__;
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
      // Remove the inbound global we installed.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      delete (w as any).__XBridgeInbound__;
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
      response["error"] = error;
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
