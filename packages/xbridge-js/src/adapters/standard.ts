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
import { XBRIDGE_PROTOCOL_VERSION, XBridgeSendError } from "../types.js";

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

/**
 * Extract the JSON-RPC `method` from a serialized message. Used only in error
 * paths so it adds zero overhead on the happy path.
 * @internal
 */
function extractMethod(message: string): string {
  try {
    return (JSON.parse(message) as { method?: string }).method ?? "<unknown>";
  } catch {
    return "<parse-error>";
  }
}

/** Sanitize href to pathname + minimal query marker to avoid PII leakage. */
function sanitizeHref(href: string): string {
  try {
    const url = new URL(href);
    // Keep pathname, drop query values, keep only presence marker
    const hasQuery = url.search.length > 0;
    return url.pathname + (hasQuery ? "?<query>" : "") + (url.hash ? "#<hash>" : "");
  } catch {
    // Fallback for non-URL hrefs (e.g. about:blank, data:)
    return href.length > 80 ? href.slice(0, 80) + "…" : href;
  }
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
  private _inboundOverride: ((request: string | object) => void) | null = null;

  /** Snapshot of pre-override globals, for restoration in `destroy()`. */
  private saved: SavedOriginals | null = null;

  /** Bound event listener reference so we can remove it in `destroy()`. */
  private boundEventListener: ((ev: Event) => void) | null = null;

  /** Circuit-breaker state: CLOSED (healthy), PROBING (probing after cooldown), OPEN (tripped). */
  private circuitState: "CLOSED" | "PROBING" | "OPEN" = "CLOSED";
  private failureCount = 0;
  private lastFailureTime = 0;
  /** Cooldown before probing again when in OPEN state (1 second). */
  private static readonly COOLDOWN_MS = 1000;
  /** Consecutive failures required to trip the circuit breaker. */
  private static readonly MAX_FAILURES = 2;
  /** Deduplicate full diagnostic snapshots per method to avoid console flooding. */
  private loggedMethods: Set<string> = new Set();

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

  /** Check if the circuit breaker can probe after cooldown. */
  private canProbe(): boolean {
    return Date.now() - this.lastFailureTime >= StandardAdapter.COOLDOWN_MS;
  }

  /** Whether the circuit breaker is currently broken (tripped and cooling down). */
  get isBroken(): boolean {
    return this.circuitState === "OPEN" && !this.canProbe();
  }

  /** Current circuit state for diagnostics and tests. */
  get state(): "CLOSED" | "PROBING" | "OPEN" {
    return this.circuitState;
  }

  /** Reset internal circuit-breaker state back to healthy. */
  reset(): void {
    this.circuitState = "CLOSED";
    this.failureCount = 0;
    this.lastFailureTime = 0;
    this.loggedMethods.clear();
  }

  isAvailable(): boolean {
    if (this.circuitState === "OPEN" && !this.canProbe()) {
      return false;
    }
    const w = getWindow();
    if (w === undefined) {
      return false;
    }
    const inapp = (w as unknown as { flutter_inappwebview?: { callHandler?: unknown } }).flutter_inappwebview;
    return (
      typeof w.XBridge?.postMessage === "function" ||
      typeof inapp?.callHandler === "function" ||
      (w as unknown as { __xbridge_ready__?: boolean }).__xbridge_ready__ === true
    );
  }

  send(message: string): void {
    if (this.circuitState === "OPEN") {
      if (this.canProbe()) {
        this.circuitState = "PROBING";
      } else {
        const method = extractMethod(message);
        throw new XBridgeSendError(
          `[XBridge] StandardAdapter: postMessage is disabled (circuit-breaker tripped). ` +
          `Attempted call('${method}'). Bridge postMessage is cooling down after a previous runtime error.`,
        );
      }
    }

    const w = getWindow();
    if (w === undefined) {
      throw new XBridgeSendError("[XBridge] StandardAdapter: globalThis is not available");
    }
    // Lazy re-install: if the host bootstrap reset our overrides to stubs
    // (or never let us install them), re-install now.
    if (this.handler !== null) {
      this.ensureOverridesInstalled(w);
    }

    // 1. Primary path: standard window.XBridge.postMessage
    if (typeof w.XBridge?.postMessage === "function") {
      const postFn = w.XBridge.postMessage;
      try {
        // Defensive invocation: ensure w.XBridge is preserved as `this` context
        postFn.call(w.XBridge, message);
        // Successful transmission restores health
        this.circuitState = "CLOSED";
        this.failureCount = 0;
        return;
      } catch (err) {
        this.failureCount++;
        this.lastFailureTime = Date.now();
        if (this.circuitState === "PROBING" || this.failureCount >= StandardAdapter.MAX_FAILURES) {
          this.circuitState = "OPEN";
        }

        // ── Diagnostic snapshot (triage for InvalidAccessError) ──────────
        const method = extractMethod(message);
        const detail = err instanceof Error ? err.message : String(err);
        const errorName = err instanceof Error ? err.name : undefined;
        if (typeof console !== "undefined") {
          const isRepeat = this.loggedMethods.has(method);
          const rawHref = typeof location !== "undefined" ? location.href : undefined;
          const sanitizedHref = rawHref ? sanitizeHref(rawHref) : undefined;
          if (isRepeat) {
            // Sampled repeat: avoid flooding console on every InvalidAccessError
            // in high-frequency call sites (e.g. XiaoeEmbed network batch).
            console.warn(
              `[XBridge] postMessage threw (repeat) method=${method} error=${errorName ?? "Error"}:${detail} circuit=${this.circuitState}`,
            );
          } else {
            console.error("[XBridge] postMessage threw — diagnostic snapshot:", {
              method,
              errorName,
              errorMessage: detail,
              circuitState: this.circuitState,
              failureCount: this.failureCount,
              messageLength: message.length,
              timestamp: Date.now(),
              visibilityState: typeof document !== "undefined" ? document.visibilityState : undefined,
              readyState: typeof document !== "undefined" ? document.readyState : undefined,
              href: sanitizedHref,
              userAgent: typeof navigator !== "undefined" ? navigator.userAgent : undefined,
              xbridgeExists: w.XBridge !== undefined,
              postMessageType: typeof w.XBridge?.postMessage,
            });
            this.loggedMethods.add(method);
          }
        }
        // ── End diagnostic snapshot ──────────────────────────────────────

        throw new XBridgeSendError(
          `[XBridge] StandardAdapter: postMessage threw on call('${method}') ` +
          `(${errorName ?? "Error"}: ${detail}). ` +
          "This may indicate that the native bridge is unavailable, detached, or running outside a supported native container.",
          err,
        );
      }
    }

    // 2. Transparent fallback path: flutter_inappwebview.callHandler
    const inapp = (w as unknown as { flutter_inappwebview?: { callHandler?: (handler: string, ...args: unknown[]) => void } }).flutter_inappwebview;
    if (typeof inapp?.callHandler === "function") {
      const handlerFn = inapp.callHandler;
      try {
        // Preserve `this` (some WebView impls rely on it)
        handlerFn.call(inapp, "XBridge", message);
        this.circuitState = "CLOSED";
        this.failureCount = 0;
        return;
      } catch (err) {
        this.failureCount++;
        this.lastFailureTime = Date.now();
        if (this.circuitState === "PROBING" || this.failureCount >= StandardAdapter.MAX_FAILURES) {
          this.circuitState = "OPEN";
        }
        const method = extractMethod(message);
        throw new XBridgeSendError(
          `[XBridge] StandardAdapter: flutter_inappwebview.callHandler threw on call('${method}'): ${err}`,
          err,
        );
      }
    }

    // Neither exists yet — this is a transient "not ready" condition during page startup,
    // NOT a runtime fatal crash. We throw XBridgeSendError but DO NOT trip the circuit breaker,
    // allowing subsequent calls to proceed as soon as the bridge is injected.
    throw new XBridgeSendError(
      "[XBridge] StandardAdapter: window.XBridge.postMessage is not available",
    );
  }

  onMessage(handler: (raw: string | object) => void): void {
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
        // 显式保留 `result` 键：当宿主对 void 方法不传结果时（`result` 为
        // `undefined`），`JSON.stringify` 会省略该键，导致内核的 `isResponse`
        // 判不中（要求存在 `result in msg`）而把整条响应作事件静默丢弃，
        // pending 调用会一直挂到超时。这里统一补齐为 `result: null` 以保住键。
        handler(
          JSON.stringify({
            jsonrpc: XBRIDGE_PROTOCOL_VERSION,
            id,
            result: result ?? null,
          }),
        );
      };
      try {
        w.__XBridge__.resolve = this._resolveOverride;
      } catch {
        try {
          Object.defineProperty(w.__XBridge__, "resolve", {
            value: this._resolveOverride,
            writable: true,
            configurable: true,
          });
        } catch {
          // ignore
        }
      }
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
      try {
        w.__XBridge__.reject = this._rejectOverride;
      } catch {
        try {
          Object.defineProperty(w.__XBridge__, "reject", {
            value: this._rejectOverride,
            writable: true,
            configurable: true,
          });
        } catch {
          // ignore
        }
      }
    }

    // Override the inbound request dispatcher — same guard.
    if (w.__XBridgeInbound__ !== this._inboundOverride) {
      this._inboundOverride = (request: string | object): void => {
        // 统一把对象字面量规整为 JSON 字符串交给内核，避免对象被
        // JSON.stringify 之外的路径以原始对象形态产出分歧。
        handler(typeof request === "string" ? request : JSON.stringify(request));
      };
      try {
        w.__XBridgeInbound__ = this._inboundOverride;
      } catch {
        try {
          Object.defineProperty(w, "__XBridgeInbound__", {
            value: this._inboundOverride,
            writable: true,
            configurable: true,
          });
        } catch {
          // ignore
        }
      }
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
        try {
          if (this.saved.resolve !== null) {
            w.__XBridge__.resolve = this.saved.resolve;
          } else {
            delete w.__XBridge__.resolve;
          }
        } catch {
          // Ignore strict mode delete failure on non-configurable property
        }
        try {
          if (this.saved.reject !== null) {
            w.__XBridge__.reject = this.saved.reject;
          } else {
            delete w.__XBridge__.reject;
          }
        } catch {
          // Ignore strict mode delete failure on non-configurable property
        }
        // If we created __XBridge__ from scratch and it's now empty, clean up.
        if (
          this.saved.resolve === null &&
          this.saved.reject === null &&
          w.__XBridge__.resolve === undefined &&
          w.__XBridge__.reject === undefined
        ) {
          try {
            delete w.__XBridge__;
          } catch {
            // Ignore strict mode delete failure
          }
        }
      }

      // Restore __XBridgeInbound__
      try {
        if (this.saved.inbound !== null) {
          w.__XBridgeInbound__ = this.saved.inbound;
        } else {
          delete w.__XBridgeInbound__;
        }
      } catch {
        // Ignore strict mode delete failure
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
    this.reset();
  }
}
