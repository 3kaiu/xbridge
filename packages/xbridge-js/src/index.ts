/**
 * XBridge — H5 SDK entry point.
 *
 * Auto-sniffs the host container on construction (cached) and wires the
 * matching adapter into {@link XBridgeCore}. Consumers may instead inject an
 * explicit adapter for testing or for environments where the sniff order is
 * wrong.
 *
 * Sniff order (first match wins):
 *   1. `window.XBridge.postMessage` → StandardAdapter
 *   2. `window.dsbridge.call`        → NativeSyncAdapter (sync only, async warns)
 *   3. none                           → NoopAdapter (warns "no bridge environment")
 *
 * When `window.dsbridge` is detected but no async adapter is, it is installed
 * as the sync adapter only — `callSync` works, `call` warns. This matches the
 * brownfield reality that a pure native-sync shell has sync semantics and no
 * JSON-RPC async channel.
 */

import type { IXBridgeAdapter, ISyncAdapter } from "./core/adapter.js";
import { XBridgeCore } from "./core/bridge.js";
import type { XBridgeEventListener, XBridgeHandler } from "./core/bridge.js";
import type { XBridgeCallOptions } from "./types.js";
import { XBridgeSendError } from "./types.js";
import { StandardAdapter } from "./adapters/standard.js";
import { setSniffCacheInvalidator } from "./adapters/standard.js";
import { NativeSyncAdapter } from "./adapters/native_sync.js";

// Re-export the full public surface.
export { XBridgeCore } from "./core/bridge.js";
export type { XBridgeEventListener, XBridgeHandler } from "./core/bridge.js";
export { Dispatcher, DEFAULT_TIMEOUT_MS } from "./core/dispatcher.js";
export type { PendingRequest, TimeoutError } from "./core/dispatcher.js";
export { generateId } from "./core/id.js";
export type { IXBridgeAdapter, ISyncAdapter } from "./core/adapter.js";
export {
  StandardAdapter,
  NativeSyncAdapter,
} from "./adapters/index.js";
export {
  XBRIDGE_PROTOCOL_VERSION,
  XBridgeSendError,
} from "./types.js";
export type {
  XBridgeRequest,
  XBridgeResponse,
  XBridgeEvent,
  XBridgeError,
  XBridgeMessage,
  XBridgeCallOptions,
} from "./types.js";

/** Constructor options for {@link XBridge}. */
export interface XBridgeOptions {
  /** Force a specific async adapter (skip env sniffing). */
  adapter?: IXBridgeAdapter;
  /**
   * Secondary / fallback async adapter.
   * If the primary adapter's send() fails with a transport error (e.g. XBridgeSendError),
   * XBridgeCore will automatically and transparently failover to this adapter.
   */
  fallbackAdapter?: IXBridgeAdapter;
  /** Force a specific sync adapter (skip env sniffing). */
  syncAdapter?: ISyncAdapter;
}

/**
 * No-op adapter used when no host bridge is detected at construction time.
 * It is **live-aware**: if a bridge is injected late (after this instance
 * was created), `isAvailable()` dynamically reflects the new global and
 * `send()`/`onMessage()` transparently delegate to an internal
 * StandardAdapter. This preserves backward compatibility for singleton
 * bridges created before native injection, while still allowing strict
 * `pickAdapter` semantics (Noop vs Standard) for correct environment
 * classification and to avoid `InvalidAccessError` in non-app containers.
 */
class NoopAdapter implements IXBridgeAdapter {
  readonly name = "Noop";
  private _delegate: StandardAdapter | null = null;
  private _handler: ((raw: string) => void) | null = null;

  private get delegate(): StandardAdapter {
    if (this._delegate === null) {
      this._delegate = new StandardAdapter();
      if (this._handler !== null) {
        this._delegate.onMessage(this._handler);
      }
    }
    return this._delegate;
  }

  isAvailable(): boolean {
    // Delegate's isAvailable probes the same live globals (including circuit
    // breaker). If delegate not yet created, probe directly via shared helper
    // to avoid instantiating StandardAdapter unnecessarily.
    if (this._delegate !== null) {
      return this._delegate.isAvailable();
    }
    return hasLiveBridge(sniffWindow());
  }

  send(_message: string): void {
    // If no live bridge yet, throw the classic Noop error (not Standard's
    // "postMessage not available" which is considered transient).
    if (!this.isAvailable()) {
      throw new XBridgeSendError(
        "[XBridge] no bridge environment detected; call() cannot deliver messages. " +
          "Ensure the host (Flutter/native) has injected the bridge global before calling.",
      );
    }
    // Live bridge exists — delegate to StandardAdapter which handles
    // circuit breaker, diagnostic snapshot, and inbound wiring.
    // Ensure inbound wiring is installed before send (mirrors Standard).
    return this.delegate.send(_message);
  }

  onMessage(handler: (raw: string) => void): void {
    this._handler = handler;
    // Eagerly wire delegate so that Native→H5 inbound requests/events that
    // arrive before the first H5→Native `send()` are not lost (cold-start
    // push scenario). The delegate's `ensureOverridesInstalled` is idempotent
    // and will create the `window.__XBridge__` placeholder if needed.
    this.delegate.onMessage(handler);
  }

  // For XBridgeCore teardown compatibility
  destroy(): void {
    this._delegate?.destroy();
    this._delegate = null;
    this._handler = null;
  }
}

interface WindowForSniff {
  XBridge?: { postMessage?: unknown };
  flutter_inappwebview?: { callHandler?: unknown };
  dsbridge?: { call?: unknown };
  __xbridge_ready__?: boolean;
}

function sniffWindow(): WindowForSniff | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowForSniff)
    : undefined;
}

/** Shared live-bridge probe — single source of truth for environment sniffing. */
function hasLiveBridge(w: WindowForSniff | undefined): boolean {
  if (w === undefined) return false;
  const inapp = (w as unknown as { flutter_inappwebview?: { callHandler?: unknown } }).flutter_inappwebview;
  return (
    typeof w.XBridge?.postMessage === "function" ||
    typeof inapp?.callHandler === "function" ||
    w.__xbridge_ready__ === true
  );
}

/** Cached environment detection booleans — never store adapter instances. */
interface SniffCache {
  hasStandard: boolean;
  hasNativeSync: boolean;
  warned: boolean;
}

let sniffCache: SniffCache | null = null;

// Wire the sniff-cache invalidator so `StandardAdapter.resetSniffCache()` and
// the exported `resetSniffCache()` can clear this cache without a circular
// import.
setSniffCacheInvalidator((): void => {
  sniffCache = null;
});

/**
 * Invalidate the cached environment sniff result so that a late-injected
 * `window.XBridge` is detected on the next `XBridge` construction.
 *
 * Delegates to `StandardAdapter.resetSniffCache()`.
 */
export function resetSniffCache(): void {
  sniffCache = null;
  StandardAdapter.resetSniffCache();
}

function detectEnv(): SniffCache {
  // Only return cached detection if a bridge was actually found.
  // Never lock into a negative detection permanently because WebView injections
  // can complete asynchronously after initial bundle execution.
  if (sniffCache !== null && (sniffCache.hasStandard || sniffCache.hasNativeSync)) {
    return sniffCache;
  }
  const w = sniffWindow();
  const hasStandard = hasLiveBridge(w);
  const hasNativeSync = w !== undefined && typeof w.dsbridge?.call === "function";

  const warned = false;
  sniffCache = { hasStandard, hasNativeSync, warned };
  return sniffCache;
}

/**
 * Construct an async adapter from cached env detection. Returns a NoopAdapter
 * when no transport is detected.
 *
 * NOTE: `typeof globalThis !== "undefined"` is intentionally NOT used as a
 * fallback — it is tautologically true in every JS runtime (browser, Node,
 * WebView) and would make NoopAdapter dead code, misclassifying every
 * non-app container (Safari, Apple Mail, XiaoeEmbed) as `xbridge` and
 * triggering `InvalidAccessError` when `postMessage` is invoked without
 * native MessageHandler permission. Late-injected bridges are handled via
 * {@link XBridgeCore.ready} polling and live `isAvailable()` checks, not by
 * eagerly defaulting to StandardAdapter.
 */
function pickAdapter(env: SniffCache): IXBridgeAdapter {
  if (env.hasStandard) {
    return new StandardAdapter();
  }
  return new NoopAdapter();
}

/**
 * Construct a fresh sync adapter from cached env detection. Returns `undefined`
 * when no native sync bridge is available.
 */
function pickSyncAdapter(env: SniffCache): ISyncAdapter | undefined {
  if (env.hasNativeSync) {
    return new NativeSyncAdapter();
  }
  return undefined;
}

/**
 * H5-facing facade. Construct once and reuse; the auto-sniff runs a single
 * time across all instances (cached).
 */
export class XBridge {
  private readonly core: XBridgeCore;
  private readonly _adapter: IXBridgeAdapter;
  private readonly _fallbackAdapter: IXBridgeAdapter | undefined;
  private readonly _syncAdapter: ISyncAdapter | undefined;

  constructor(options?: XBridgeOptions) {
    const env = detectEnv();
    if (
      options !== undefined &&
      (options.adapter !== undefined ||
        options.syncAdapter !== undefined ||
        options.fallbackAdapter !== undefined)
    ) {
      // Manual override: use the explicitly provided adapter(s). If only the
      // async adapter is overridden, re-detect the sync adapter fresh (don't
      // reuse a cached sync adapter instance which may be stale).
      this._adapter = options.adapter ?? pickAdapter(env);
      this._fallbackAdapter = options.fallbackAdapter;
      this._syncAdapter =
        options.syncAdapter !== undefined ? options.syncAdapter : pickSyncAdapter(env);
    } else {
      this._adapter = pickAdapter(env);
      this._fallbackAdapter = undefined;
      this._syncAdapter = pickSyncAdapter(env);
    }
    this.core = new XBridgeCore(this._adapter, this._syncAdapter, this._fallbackAdapter);
  }

  /** The async adapter currently in use. */
  getAdapter(): IXBridgeAdapter {
    return this._adapter;
  }

  /** The fallback adapter, if any. */
  getFallbackAdapter(): IXBridgeAdapter | undefined {
    return this._fallbackAdapter;
  }

  /** The sync adapter, if any. */
  getSyncAdapter(): ISyncAdapter | undefined {
    return this._syncAdapter;
  }

  /**
   * Wait for the bridge transport to become available and ready.
   *
   * @param timeoutMs max milliseconds to wait (default 3000ms).
   * @returns Promise that resolves when the bridge is ready.
   */
  ready(timeoutMs?: number): Promise<void> {
    return this.core.ready(timeoutMs);
  }

  /** Async RPC. @see {@link XBridgeCore.call}. */
  call(method: string, params?: unknown, options?: XBridgeCallOptions): Promise<unknown> {
    return this.core.call(method, params, options);
  }

  /** Sync bypass. @see {@link XBridgeCore.callSync}. */
  callSync(method: string, params?: unknown): unknown {
    return this.core.callSync(method, params);
  }

  /** Subscribe to host-pushed events. @see {@link XBridgeCore.onEvent}. */
  onEvent(method: string, handler: XBridgeEventListener): () => void {
    return this.core.onEvent(method, handler);
  }

  /** Register a handler for Native→H5 calls. @see {@link XBridgeCore.registerHandler}. */
  registerHandler(method: string, handler: XBridgeHandler): () => void {
    return this.core.registerHandler(method, handler);
  }

  /** Release all pending requests and listeners. */
  dispose(): void {
    this.core.dispose();
  }

  /**
   * Whether the underlying async adapter is available in the current
   * environment. Returns `false` when no bridge transport is detected
   * (NoopAdapter) or when the StandardAdapter's `postMessage` is absent.
   *
   * H5 apps can use this to conditionally skip bridge calls:
   * ```ts
   * if (bridge.isConnected()) {
   *   const safeArea = await bridge.call('getSafeArea');
   * } else {
   *   // fallback for non-app environments
   * }
   * ```
   */
  isConnected(): boolean {
    return this._adapter.isAvailable() || (this._fallbackAdapter?.isAvailable() ?? false);
  }
}
