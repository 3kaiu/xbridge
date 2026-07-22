/**
 * NativeSyncAdapter — the synchronous bypass channel.
 *
 * Per PRD §P1 / audit Risk 1: Flutter WebView channels are strictly async,
 * but a handful of legacy H5 call sites depend on a truly synchronous return
 * value (e.g. prompt-based or `@JavascriptInterface` objects injected by the
 * native shell). A native sync bridge (detects `window.dsbridge`) historically
 * provided this via `window.dsbridge.call(method, args)` which returns the
 * value synchronously.
 *
 * This adapter implements {@link ISyncAdapter} only — it carries no
 * request/response correlation and does not participate in the async dispatcher.
 * Its sole role is to expose `callSync` so business code that genuinely cannot
 * be async-ized keeps working during a brownfield migration.
 *
 * Note: in a pure Flutter WebView environment this adapter is unavailable and
 * `XBridge.callSync` degrades to a warning + `undefined` — by design.
 *
 * Security note: `callSync` delegates to `window.dsbridge.call`, which is a
 * native-injected object accessible from any same-origin frame. Sandboxed
 * or cross-origin iframes cannot access `window.dsbridge` (it is injected
 * only into the main frame's context by the native shell). If the host
 * injects it into subframes, the host is responsible for access control.
 */

import type { ISyncAdapter } from "../core/adapter.js";

interface NativeSyncGlobal {
  call: (method: string, args?: unknown) => unknown;
}

interface WindowWithNativeSync {
  dsbridge?: NativeSyncGlobal;
}

function getWindow(): WindowWithNativeSync | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowWithNativeSync)
    : undefined;
}

/** Sync adapter backed by a native sync bridge (detects `window.dsbridge`). */
export class NativeSyncAdapter implements ISyncAdapter {
  readonly name = "NativeSync";

  isAvailable(): boolean {
    const w = getWindow();
    return w !== undefined && typeof w.dsbridge?.call === "function";
  }

  callSync(method: string, params?: unknown): unknown {
    const w = getWindow();
    const call = w?.dsbridge?.call;
    if (typeof call !== "function") {
      // Defensive: `isAvailable()` is checked by the core before calling, but
      // the environment may have torn down between checks.
      if (typeof console !== "undefined") {
        console.warn(`[NativeSyncAdapter] native sync bridge unavailable for '${method}'`);
      }
      return undefined;
    }
    // The native sync bridge expects the args as the second positional
    // argument; passing `undefined` is equivalent to no args.
    return call(method, params);
  }
}
