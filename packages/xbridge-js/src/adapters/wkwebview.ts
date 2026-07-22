/**
 * WKWebViewAdapter — bridges the iOS WKWebView `XBridgeWK` message handler
 * protocol into the XBridge JSON-RPC wire format.
 *
 * Existing contract (the consumer app's WK bridge):
 *
 *   H5 → Host (array post — NOT JSON-RPC on the wire):
 *     window.webkit.messageHandlers.XBridgeWK.postMessage(
 *       [method, data, requestId, timestamp]
 *     )
 *     - requestId === null for fire-and-forget (noCallback) calls.
 *
 *   Host → H5:
 *     window.__XBridgeWKCallback__(requestId, result, error)
 *
 * Because the WK transport is array-based and not JSON-RPC, this adapter owns
 * the protocol gap: on `send` it emits the legacy array; on inbound it
 * synthesizes JSON-RPC responses so the core can treat all adapters
 * uniformly.
 */

import type { IXBridgeAdapter } from "../core/adapter.js";
import { XBRIDGE_PROTOCOL_VERSION } from "../types.js";

interface XBridgeWKCallback {
  (requestId: string | null, result?: unknown, error?: unknown): void;
}

interface WindowWithWK {
  webkit?: {
    messageHandlers?: {
      XBridgeWK?: {
        postMessage: (message: unknown[]) => void;
      };
    };
  };
  __XBridgeWKCallback__?: XBridgeWKCallback;
  __XBridgeInbound__?: (raw: string) => void;
}

function getWindow(): WindowWithWK | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithWK)
    : undefined;
}

/** Adapter for `window.webkit.messageHandlers.XBridgeWK`. */
export class WKWebViewAdapter implements IXBridgeAdapter {
  readonly name = "WKWebView";
  private inbound: ((raw: string) => void) | undefined;
  private installed = false;

  isAvailable(): boolean {
    const w = getWindow();
    return (
      w !== undefined &&
      typeof w.webkit?.messageHandlers?.XBridgeWK?.postMessage === "function"
    );
  }

  send(message: string): void {
    const w = getWindow();
    const post = w?.webkit?.messageHandlers?.XBridgeWK?.postMessage;
    if (typeof post !== "function") {
      throw new Error("[WKWebViewAdapter] XBridgeWK.postMessage is not available");
    }
    let parsed: {
      method: string;
      params?: unknown;
      id?: string;
    };
    try {
      parsed = JSON.parse(message) as { method: string; params?: unknown; id?: string };
    } catch {
      // If the core ever sends a non-JSON payload (defensive), we cannot map
      // it to the array contract — drop it loudly.
      if (typeof console !== "undefined") {
        console.warn("[WKWebViewAdapter] dropped non-JSON send payload");
      }
      return;
    }
    // Emit the legacy array: [method, data, requestId, timestamp].
    // requestId === null ⇒ fire-and-forget (matches noCallback semantics).
    const id = parsed.id ?? null;
    post([parsed.method, parsed.params, id, Date.now()]);
  }

  onMessage(handler: (raw: string) => void): void {
    this.inbound = handler;
    this.ensureInstalled();
  }

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
    const callback: XBridgeWKCallback = (
      requestId: string | null,
      result?: unknown,
      error?: unknown,
    ): void => {
      if (requestId === null || requestId === undefined) {
        // Fire-and-forget reply — nothing to correlate. Drop silently.
        return;
      }
      self.dispatchResponse(String(requestId), result, error);
    };

    // Preserve any prior install by chaining. In practice XBridge owns this
    // global; the consumer app may have registered a callback here before
    // adopting XBridge — chaining keeps a brownfield migration no-op safe.
    const prior = w.__XBridgeWKCallback__;
    if (typeof prior === "function") {
      w.__XBridgeWKCallback__ = (
        requestId: string | null,
        result?: unknown,
        error?: unknown,
      ): void => {
        callback(requestId, result, error);
        prior(requestId, result, error);
      };
    } else {
      w.__XBridgeWKCallback__ = callback;
    }

    // Install the inbound global for Native→H5 requests. The Native host
    // injects `window.__XBridgeInbound__(rawJson)` to send a JSON-RPC request
    // to the H5 side; the core's `handleRaw` looks up a registered handler
    // and sends back a response via `adapter.send()`.
    w.__XBridgeInbound__ = (raw: string): void => {
      self.inbound?.(raw);
    };
  }

  private dispatchResponse(id: string, result: unknown, error: unknown): void {
    if (this.inbound === undefined) {
      return;
    }
    const response: Record<string, unknown> = {
      jsonrpc: XBRIDGE_PROTOCOL_VERSION,
      id,
    };
    if (error !== undefined && error !== null) {
      // Legacy WK error is a free-form object/string. Wrap into a JSON-RPC
      // error envelope; keep `data` as the original for round-trip fidelity.
      response["error"] =
        error !== null && typeof error === "object" && "message" in error
          ? error
          : {
              code: -32000,
              message: typeof error === "string" ? error : "WK bridge error",
              data: error,
            };
    } else {
      response["result"] = result;
    }
    this.inbound(JSON.stringify(response));
  }
}
