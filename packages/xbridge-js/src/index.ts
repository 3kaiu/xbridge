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
  /** Force a specific sync adapter (skip env sniffing). */
  syncAdapter?: ISyncAdapter;
}

/**
 * No-op adapter used when no host bridge is detected. Every `send` throws
 * immediately so the caller gets a clear "no transport" error instead of
 * hanging for the full dispatcher timeout (30s by default).
 */
class NoopAdapter implements IXBridgeAdapter {
  readonly name = "Noop";

  isAvailable(): boolean {
    return false;
  }

  send(_message: string): void {
    throw new Error(
      "[XBridge] no bridge environment detected; call() cannot deliver messages. " +
        "Ensure the host (Flutter/native) has injected the bridge global before calling.",
    );
  }

  onMessage(_handler: (raw: string) => void): void {
    // Noop: never receives inbound messages.
  }
}

interface WindowForSniff {
  XBridge?: { postMessage?: unknown };
  dsbridge?: { call?: unknown };
}

function sniffWindow(): WindowForSniff | undefined {
  return typeof globalThis !== "undefined"
    ? (globalThis as unknown as WindowForSniff)
    : undefined;
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
  StandardAdapter.resetSniffCache();
}

function detectEnv(): SniffCache {
  if (sniffCache !== null) {
    return sniffCache;
  }
  const w = sniffWindow();
  const hasStandard =
    w !== undefined && typeof w.XBridge?.postMessage === "function";
  const hasNativeSync = w !== undefined && typeof w.dsbridge?.call === "function";

  let warned = false;
  if (hasNativeSync && !hasStandard) {
    warned = true;
    if (typeof console !== "undefined") {
      console.warn(
        "[XBridge] only native sync bridge detected; callSync is available but async call() has no transport.",
      );
    }
  } else if (!hasStandard) {
    warned = true;
    if (typeof console !== "undefined") {
      console.warn("[XBridge] no bridge environment detected.");
    }
  }

  sniffCache = { hasStandard, hasNativeSync, warned };
  return sniffCache;
}

/**
 * Construct a fresh async adapter from cached env detection. Returns a NoopAdapter
 * when no transport is detected.
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
  private readonly _syncAdapter: ISyncAdapter | undefined;

  constructor(options?: XBridgeOptions) {
    const env = detectEnv();
    if (options !== undefined && (options.adapter !== undefined || options.syncAdapter !== undefined)) {
      // Manual override: use the explicitly provided adapter(s). If only the
      // async adapter is overridden, re-detect the sync adapter fresh (don't
      // reuse a cached sync adapter instance which may be stale).
      this._adapter = options.adapter ?? pickAdapter(env);
      this._syncAdapter =
        options.syncAdapter !== undefined ? options.syncAdapter : pickSyncAdapter(env);
    } else {
      this._adapter = pickAdapter(env);
      this._syncAdapter = pickSyncAdapter(env);
    }
    this.core = new XBridgeCore(this._adapter, this._syncAdapter);
  }

  /** The async adapter currently in use. */
  getAdapter(): IXBridgeAdapter {
    return this._adapter;
  }

  /** The sync adapter, if any. */
  getSyncAdapter(): ISyncAdapter | undefined {
    return this._syncAdapter;
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
}
