/**
 * NativeSyncAdapter — the synchronous bypass channel.
 *
 * Per PRD §P1 / audit finding M1: Flutter WebView channels are strictly async,
 * but a handful of legacy H5 call sites depend on a truly synchronous return
 * value (e.g. prompt-based or `@JavascriptInterface` objects injected by the
 * native shell). This adapter exposes two native sync globals:
 *
 *   1. `window.XBridgeSync` — the official XBridge native sync channel.
 *      * Android: a `@JavascriptInterface` whose `callSync(method, paramsJson)`
 *        is **truly synchronous** and returns a JSON string envelope
 *        `{"result": <value>}` or `{"error": {"code","message"}}`.
 *      * iOS: a Promise-based JS wrapper (`XBridgeSyncHandler`). Because
 *        WKWebView delivers script messages asynchronously, iOS's sync path is
 *        **not truly synchronous** — see below.
 *   2. `window.dsbridge` — legacy dsbridge shell (`dsbridge.call(method, args)`
 *      returns the value synchronously).
 *
 * This adapter implements {@link ISyncAdapter} only — it carries no
 * request/response correlation and does not participate in the async dispatcher.
 * Its sole role is to expose `callSync` so business code that genuinely cannot
 * be async-ized keeps working during a brownfield migration.
 *
 * ## iOS sync-path reality
 *
 * On iOS the native `XBridgeSync.callSync` is intrinsically async (WK delivers
 * script messages asynchronously; result is pushed back via a Promise). No
 * synchronous adapter can consume it — true sync on WKWebView requires the
 * `prompt()` interception hack. To avoid silently returning `undefined`, this
 * adapter detects the Promise return shape and emits a clear warning advising
 * the caller to use the standard async channel instead.
 *
 * ## Security note
 *
 * `callSync` delegates to a native-injected object that is accessible from any
 * same-origin frame. Sandboxed or cross-origin iframes cannot access
 * `window.XBridgeSync` / `window.dsbridge` (they are injected only into the
 * main frame's context by the native shell). If the host injects them into
 * subframes, the host is responsible for access control. Android cannot
 * attribute sync calls to a frame (the gate is origin + method allowlist only);
 * iOS enforces real frame attribution via `frameInfo.isMainFrame`.
 */

import type { ISyncAdapter } from "../core/adapter.js";

/** Android `@JavascriptInterface` sync bridge (or a `callSync`-shaped global). */
interface XBridgeSyncGlobal {
  callSync: (method: string, paramsJson?: string) => unknown;
  isAvailable?: () => unknown;
}

interface DsBridgeGlobal {
  call: (method: string, args?: unknown) => unknown;
}

interface WindowWithNativeSync {
  XBridgeSync?: XBridgeSyncGlobal;
  dsbridge?: DsBridgeGlobal;
}

function getWindow(): WindowWithNativeSync | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithNativeSync)
    : undefined;
}

/** Detect the native sync bridge. Prefers `XBridgeSync`, falls back to `dsbridge`. */
function detectSyncGlobal():
  | { kind: "xbridge"; value: XBridgeSyncGlobal }
  | { kind: "dsbridge"; value: DsBridgeGlobal }
  | undefined {
  const w = getWindow();
  if (w?.XBridgeSync && typeof w.XBridgeSync.callSync === "function") {
    return { kind: "xbridge", value: w.XBridgeSync };
  }
  if (w?.dsbridge && typeof w.dsbridge.call === "function") {
    return { kind: "dsbridge", value: w.dsbridge };
  }
  return undefined;
}

/** Is the value a `thenable` (the iOS Promise shape)? */
function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
  return (
    value !== null &&
    typeof value === "object" &&
    typeof (value as PromiseLike<unknown>).then === "function"
  );
}

/** Parse a JSON-string envelope from Android's `XBridgeSync.callSync`. */
function unwrapEnvelope(raw: string): unknown {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // Not JSON — pass through the raw string (matches dsbridge behavior).
    return raw;
  }
  if (parsed === null || typeof parsed !== "object") {
    return parsed;
  }
  const obj = parsed as Record<string, unknown>;
  // Surface the error envelope so XBridgeCore.callSync throws it.
  if (obj.error !== undefined) {
    return obj;
  }
  // Unwrap the success envelope so callers receive the bare result value.
  return obj.result !== undefined ? obj.result : parsed;
}

/** Sync adapter backed by a native sync bridge (`XBridgeSync` or `dsbridge`). */
export class NativeSyncAdapter implements ISyncAdapter {
  readonly name = "NativeSync";

  isAvailable(): boolean {
    return detectSyncGlobal() !== undefined;
  }

  callSync(method: string, params?: unknown): unknown {
    const detected = detectSyncGlobal();
    if (detected === undefined) {
      // Defensive: `isAvailable()` is checked by the core before calling, but
      // the environment may have torn down between checks.
      if (typeof console !== "undefined") {
        console.warn(`[NativeSyncAdapter] native sync bridge unavailable for '${method}'`);
      }
      return undefined;
    }

    if (detected.kind === "dsbridge") {
      const call = detected.value.call;
      // The dsbridge shell expects args as the second positional argument;
      // passing `undefined` is equivalent to no args.
      return call(method, params);
    }

    // XBridgeSync native channel.
    const xb = detected.value;
    // Android's `@JavascriptInterface` expects a JSON-encoded params string.
    const paramsJson =
      params === undefined || params === null ? "" : JSON.stringify(params);
    const result = xb.callSync(method, paramsJson);

    if (isPromiseLike(result)) {
      // iOS's XBridgeSync is async (WK limitation) — cannot be consumed by a
      // synchronous adapter. Do NOT return the Promise (it would be ignored and
      // the caller would think the call succeeded). Emit a clear warning.
      if (typeof console !== "undefined") {
        console.warn(
          `[NativeSyncAdapter] '${method}': native XBridgeSync is asynchronous on this platform ` +
            "(iOS WKWebView delivers script messages asynchronously). " +
            "Use bridge.call() (async channel) instead of callSync().",
        );
      }
      return undefined;
    }

    if (typeof result === "string") {
      // Android returns a JSON envelope string — unwrap it so the caller gets
      // the bare value and XBridgeCore can throw on the {"error":...} shape.
      return unwrapEnvelope(result);
    }

    // Object/number/boolean result passed through as-is (dsbridge-style).
    return result;
  }
}
