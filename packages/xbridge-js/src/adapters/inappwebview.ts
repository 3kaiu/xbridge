/**
 * InAppWebViewAdapter — bridges the `flutter_inappwebview` JS ↔ Flutter channel
 * into the XBridge JSON-RPC wire format.
 *
 * Contract (flutter_inappwebview ≥ 6.0):
 *
 *   H5 → Flutter:
 *     // `callHandler` returns a Promise that resolves with the handler's
 *     // return value. We pass the full JSON-RPC request string as the single
 *     // argument so the Flutter side can parse+route generically.
 *     await window.flutter_inappwebview.callHandler('XBridge', jsonRequestString)
 *
 *   Flutter → H5 (responses + host-pushed events):
 *     // The Flutter side invokes a global JS function injected by this
 *     // adapter. It receives a raw JSON-RPC response or event string.
 *     window.__XBridgeDispatch__(jsonResponseOrEventString)
 *
 * This adapter installs `window.__XBridgeDispatch__` once and routes every
 * inbound string to the core's single message handler. On `send`, because
 * `callHandler` is itself Promise-returning, we treat it as fire-and-forget:
 * the actual response will arrive asynchronously via `__XBridgeDispatch__`
 * carrying the matching correlation id. We deliberately do NOT await the
 * returned Promise here — that would duplicate the dispatcher's correlation
 * logic and break the uniform single-parser model.
 *
 * Flutter-side counterpart: `InAppWebViewBridgeAdapter` (xbridge_flutter)
 * registers `addJavaScriptHandler(handlerName: 'XBridge', ...)` and calls back
 * via `window.__XBridgeDispatch__`.
 */

import type { IXBridgeAdapter } from "../core/adapter.js";

interface InAppWebViewGlobal {
  callHandler: (handlerName: string, ...args: unknown[]) => Promise<unknown>;
}

interface WindowWithInAppWebView {
  flutter_inappwebview?: InAppWebViewGlobal;
  __XBridgeDispatch__?: (raw: string) => void;
  __XBridgeInbound__?: (raw: string) => void;
}

function getWindow(): WindowWithInAppWebView | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithInAppWebView)
    : undefined;
}

/** Default handler name on the Flutter side. */
export const XBRIDGE_INAPP_HANDLER_NAME = "XBridge";

/** Default dispatch function name installed on `window`. */
export const XBRIDGE_DISPATCH_GLOBAL = "__XBridgeDispatch__";

/** Adapter for `window.flutter_inappwebview`. */
export class InAppWebViewAdapter implements IXBridgeAdapter {
  readonly name = "InAppWebView";
  private installed = false;
  private readonly handlerName: string;
  private dispatchFn: ((raw: string) => void) | undefined;

  /** Ownership marker: if this symbol is on the installed global, this class
   * instance owns it and re-install should replace (not chain). */
  private static readonly OWNERSHIP = Symbol("InAppWebViewAdapter");

  constructor(handlerName: string = XBRIDGE_INAPP_HANDLER_NAME) {
    this.handlerName = handlerName;
  }

  isAvailable(): boolean {
    const w = getWindow();
    return w !== undefined && typeof w.flutter_inappwebview?.callHandler === "function";
  }

  send(message: string): void {
    const w = getWindow();
    const call = w?.flutter_inappwebview?.callHandler;
    if (typeof call !== "function") {
      throw new Error("[InAppWebViewAdapter] flutter_inappwebview is not available");
    }
    // Fire-and-forget at the transport layer; the Promise resolves later but
    // we do not await it — correlation is by id in __XBridgeDispatch__.
    void call(this.handlerName, message).catch((err: unknown): void => {
      if (typeof console !== "undefined") {
        console.warn("[InAppWebViewAdapter] callHandler rejected:", err);
      }
    });
  }

  onMessage(handler: (raw: string) => void): void {
    this.ensureInstalled(handler);
  }

  private ensureInstalled(handler: (raw: string) => void): void {
    if (this.installed) {
      return;
    }
    this.installed = true;
    const w = getWindow();
    if (w === undefined) {
      return;
    }

    // Capture the handler at install time — reading `self.inbound` live would
    // route to whatever handler is current, even if onMessage is called again.
    const captured = handler;
    const ownership = InAppWebViewAdapter.OWNERSHIP;
    const prior = w.__XBridgeDispatch__;

    // Detect same-class re-install via the ownership marker. If the prior
    // install belongs to an InAppWebViewAdapter instance, replace it directly
    // instead of chaining (avoids a growing call chain on repeated installs).
    const priorIsOurs =
      typeof prior === "function" &&
      typeof (prior as unknown as { [key: symbol]: unknown })[ownership] !== "undefined";

    const dispatch = (raw: string): void => {
      captured(raw);
    };

    if (priorIsOurs) {
      // Replace the same-class install — no chaining needed.
      (dispatch as unknown as { [key: symbol]: unknown })[ownership] = true;
      w.__XBridgeDispatch__ = dispatch;
    } else if (typeof prior === "function") {
      // Chain behind a different-class prior install for brownfield coexistence.
      const chained = (raw: string): void => {
        captured(raw);
        prior(raw);
      };
      (chained as unknown as { [key: symbol]: unknown })[ownership] = true;
      w.__XBridgeDispatch__ = chained;
    } else {
      (dispatch as unknown as { [key: symbol]: unknown })[ownership] = true;
      w.__XBridgeDispatch__ = dispatch;
    }

    this.dispatchFn = w.__XBridgeDispatch__;

    // Install the inbound global for Native→H5 requests. The Native host
    // injects `window.__XBridgeInbound__(rawJson)` to send a JSON-RPC request
    // to the H5 side; the core's `handleRaw` looks up a registered handler
    // and sends back a response via `adapter.send()`.
    w.__XBridgeInbound__ = (raw: string): void => {
      captured(raw);
    };
  }

  destroy(): void {
    if (!this.installed) {
      return;
    }
    this.installed = false;
    const w = getWindow();
    if (w !== undefined && this.dispatchFn !== undefined) {
      // Only remove if we still own the global (hasn't been replaced by another adapter).
      if (w.__XBridgeDispatch__ === this.dispatchFn) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        delete (w as any)[XBRIDGE_DISPATCH_GLOBAL];
      }
      // Remove the inbound global we installed.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      delete (w as any).__XBridgeInbound__;
    }
    this.dispatchFn = undefined;
  }
}
