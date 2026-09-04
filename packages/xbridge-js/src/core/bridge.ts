/**
 * XBridge core — protocol engine, transport-agnostic.
 *
 * Owns a {@link Dispatcher} for pending requests and a single event listener
 * map for host-pushed events. Wires exactly one `onMessage` handler into the
 * provided adapter; inbound bytes are parsed once and routed on a fast path
 * keyed on the presence of `id`.
 *
 * Performance contract (PRD §3.4): the serialize+route overhead per call is
 * a single `JSON.stringify` + one `Map.set` + one `adapter.send`. Inbound is
 * a single `JSON.parse` + one `Map.get`/emit. No per-call closures beyond the
 * Promise resolver.
 */

import type { IXBridgeAdapter } from "./adapter.js";
import { DEFAULT_TIMEOUT_MS, Dispatcher } from "./dispatcher.js";
import { generateId } from "./id.js";
import type {
  XBridgeCallOptions,
  XBridgeError,
  XBridgeEvent,
  XBridgeMessage,
  XBridgeRequest,
  XBridgeResponse,
} from "../types.js";
import { XBRIDGE_PROTOCOL_VERSION, XBridgeSendError } from "../types.js";

/** Event listener signature for {@link XBridgeCore.onEvent}. */
export type XBridgeEventListener = (params: unknown) => void;

/** Handler signature for Native→H5 RPC calls. */
export type XBridgeHandler = (params: unknown) => unknown | Promise<unknown>;

function isSendError(err: unknown): err is XBridgeSendError {
  return (
    err instanceof XBridgeSendError ||
    (err instanceof Error && err.name === "XBridgeSendError")
  );
}

function isResponse(msg: XBridgeMessage): msg is XBridgeResponse {
  const id = (msg as XBridgeResponse).id;
  return (typeof id === "string" || typeof id === "number")
    && typeof (msg as XBridgeEvent).method !== "string"
    && ("result" in msg || "error" in msg);
}

function isInboundRequest(msg: XBridgeMessage): msg is XBridgeRequest {
  const id = (msg as XBridgeRequest).id;
  return (typeof id === "string" || typeof id === "number") && typeof (msg as XBridgeRequest).method === "string";
}

/**
 * Core engine. Construct once per adapter (or reuse via {@link XBridge} which
 * auto-picks one). Thread-safe in the JS single-threaded sense; no shared
 * mutable state leaks beyond the dispatcher + listener map.
 */
export class XBridgeCore {
  private readonly dispatcher = new Dispatcher();
  private readonly events: Map<string, Set<XBridgeEventListener>> = new Map();
  private readonly handlers: Map<string, XBridgeHandler> = new Map();
  private readonly adapter: IXBridgeAdapter;
  private readonly fallbackAdapter?: IXBridgeAdapter;
  private messageHandlerBound = false;
  private readonly pendingReadyCleanups: Set<() => void> = new Set();
  private readonly pendingReadyRejects: Set<(err: Error) => void> = new Set();
  private disposed = false;

  constructor(
    adapter: IXBridgeAdapter,
    fallbackAdapter?: IXBridgeAdapter,
  ) {
    this.adapter = adapter;
    this.fallbackAdapter = fallbackAdapter;
    this.installInboundHandler();
  }

  /** Adapter name (diagnostics). */
  get adapterName(): string {
    return this.adapter.name;
  }

  /** The primary async adapter currently in use. */
  getAdapter(): IXBridgeAdapter {
    return this.adapter;
  }

  /** The fallback async adapter, if any. */
  getFallbackAdapter(): IXBridgeAdapter | undefined {
    return this.fallbackAdapter;
  }

  /**
   * Whether any underlying async adapter is connected and available.
   */
  isConnected(): boolean {
    return this.adapter.isAvailable() || (this.fallbackAdapter?.isAvailable() ?? false);
  }

  /**
   * Wait for the bridge to become available and ready.
   *
   * Resolves immediately if the bridge is already available.
   * Otherwise listens to the host's `XBridgeReady` CustomEvent, checks `window.__xbridge_ready__`,
   * or polls at short intervals until `timeoutMs` (default 3000ms).
   */
  ready(timeoutMs: number = 3000): Promise<void> {
    if (this.disposed) {
      return Promise.reject(new XBridgeSendError("[XBridge] bridge has been disposed"));
    }
    if (this.isConnected()) {
      return Promise.resolve();
    }
    if (
      typeof globalThis !== "undefined" &&
      (globalThis as unknown as { __xbridge_ready__?: boolean }).__xbridge_ready__ === true
    ) {
      return Promise.resolve();
    }
    if (timeoutMs <= 0) {
      return Promise.reject(new XBridgeSendError("[XBridge] bridge is not ready"));
    }

    return new Promise<void>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      let interval: ReturnType<typeof setInterval> | undefined;
      let cleanedUp = false;

      const cleanup = (): void => {
        if (cleanedUp) return;
        cleanedUp = true;
        if (timer !== undefined) clearTimeout(timer);
        if (interval !== undefined) clearInterval(interval);
        if (typeof globalThis !== "undefined" && typeof globalThis.removeEventListener === "function") {
          globalThis.removeEventListener("XBridgeReady", onReadyEvent);
        }
        this.pendingReadyCleanups.delete(cleanup);
        this.pendingReadyRejects.delete(reject);
      };

      // Track for dispose() cleanup to avoid leaks when bridge is torn down
      // while ready() is still polling.
      this.pendingReadyCleanups.add(cleanup);
      this.pendingReadyRejects.add(reject);

      const onReadyEvent = (): void => {
        cleanup();
        resolve();
      };

      if (typeof globalThis !== "undefined" && typeof globalThis.addEventListener === "function") {
        globalThis.addEventListener("XBridgeReady", onReadyEvent, { once: true });
      }

      // Short-interval polling in case event was fired before listener attached
      interval = setInterval((): void => {
        if (
          this.isConnected() ||
          (typeof globalThis !== "undefined" &&
            (globalThis as unknown as { __xbridge_ready__?: boolean }).__xbridge_ready__ === true)
        ) {
          cleanup();
          resolve();
        }
      }, 15);

      timer = setTimeout((): void => {
        cleanup();
        if (this.isConnected()) {
          resolve();
        } else {
          reject(
            new XBridgeSendError(
              `[XBridge] bridge ready handshake timed out after ${timeoutMs}ms. Host container may not have injected the bridge global.`,
            ),
          );
        }
      }, timeoutMs);
    });
  }

  /**
   * Invoke `method` on the host and await its response.
   *
   * @param method host method name
   * @param params optional payload
   * @param options `{ timeout?, noCallback?, fallback?, readyTimeout? }`. `noCallback` resolves
   *   immediately after `send` (fire-and-forget) — matches the WK no-callback
   *   semantics where `requestId` is `null`.
   */
  call(method: string, params?: unknown, options?: XBridgeCallOptions): Promise<unknown> {
    const hasFallback = options !== undefined && "fallback" in options;
    const readyTimeout = options?.readyTimeout ?? 1500;
    const retryAttempt = options?._retryAttempt ?? 0;
    // 关键：`call` 不能是 async，否则 `return pendingPromise` 会让 async 机制
    // 生成一个「采纳后的新 promise」返回给调用方，而本方法内的 no-op catch 若只
    // 挂在内部 `pendingPromise` 上，就保护不了调用方实际持有的那个采纳 promise，
    // 造成 dispose/超时 reject 时仍触发全局 `unhandledrejection`（P2 F2）。
    // 这里统一包一层 async IIFE 得到唯一的 `outer` promise，并把 no-op catch
    // 挂在 `outer` 上（调用方拿到的正是它），使 WebKit 缓解真正生效；调用方后续
    // 的 `await`/`catch` 仍是同一 promise 的第二个 handler，依然能看到拒绝。
    const outer = (async (): Promise<unknown> => {
      if (!this.isConnected() && readyTimeout > 0) {
        try {
          await this.ready(readyTimeout);
        } catch {
          if (hasFallback) {
            return (options as XBridgeCallOptions).fallback;
          }
        }
      }

      try {
        return await this.callDispatch(method, params, options, hasFallback);
      } catch (err) {
        // Auto-retry on InvalidAccessError (network recovery race condition)
        if (this.isInvalidAccessError(err) && retryAttempt === 0) {
          if (typeof console !== "undefined") {
            console.warn(
              `[XBridge] call('${method}') encountered InvalidAccessError (likely network recovery race), waiting for XBridgeReady...`,
            );
          }
          // Wait for bridge to become ready (max 500ms)
          try {
            await this.ready(500);
            if (typeof console !== "undefined") {
              console.warn(`[XBridge] call('${method}') XBridge ready, retrying...`);
            }
            // Retry once with _retryAttempt flag to prevent infinite loop
            return await this.call(method, params, {
              ...options,
              _retryAttempt: 1,
            });
          } catch (readyErr) {
            // ready() timed out, treat as permanently unavailable
            if (typeof console !== "undefined") {
              console.warn(
                `[XBridge] call('${method}') ready timeout, treating as permanently unavailable`,
              );
            }
          }
        }
        // Re-throw original error after retry failure or non-retryable error
        throw err;
      }
    })();
    // Attach a no-op catch to suppress WebKit's transient unhandledrejection
    // (the caller's `await`/`catch` will still observe the rejection).
    outer.catch(() => {});
    return outer;
  }

  /**
   * Check if an error is an InvalidAccessError from postMessage.
   * This typically occurs during network recovery when the WebView bridge
   * channel is not yet ready.
   */
  private isInvalidAccessError(err: unknown): boolean {
    if (!err) return false;
    const error = err as { name?: string; message?: string };
    return (
      error.name === "InvalidAccessError" ||
      (typeof error.message === "string" &&
        /The object does not support the operation/.test(error.message))
    );
  }

  /**
   * Core dispatch for {@link call} after the ready handshake completes.
   * Returns the promise that settles with the response (or rejection).
   */
  private callDispatch(
    method: string,
    params?: unknown,
    options?: XBridgeCallOptions,
    hasFallback: boolean = false,
  ): Promise<unknown> {
    const timeout = options?.timeout ?? DEFAULT_TIMEOUT_MS;
    const noCallback = options?.noCallback === true;

    const id = noCallback ? null : generateId();
    const request: XBridgeRequest = {
      jsonrpc: XBRIDGE_PROTOCOL_VERSION,
      id,
      method,
      params,
    };

    if (noCallback) {
      // Fire-and-forget: hand the message to the adapter and resolve at once.
      // We deliberately do not register a pending entry — there is no id to
      // correlate on the host side (host treats id === null as "no reply").
      try {
        this.adapter.send(JSON.stringify(request));
      } catch (err) {
        // Transparent failover to fallbackAdapter if available
        if (isSendError(err) && this.fallbackAdapter && this.fallbackAdapter.isAvailable()) {
          try {
            if (typeof console !== "undefined") {
              console.warn(
                `[XBridge] call('${method}') primary adapter (${this.adapter.name}) failed, failing over to ${this.fallbackAdapter.name}`,
              );
            }
            this.fallbackAdapter.send(JSON.stringify(request));
            return Promise.resolve(undefined);
          } catch (fallbackErr) {
            err = fallbackErr;
          }
        }

        if (typeof console !== "undefined") {
          console.warn(
            `[XBridge] call('${method}') failed to send:`,
            err instanceof Error ? err.message : err,
          );
        }
        if (hasFallback) {
          return Promise.resolve((options as XBridgeCallOptions).fallback);
        }
        return Promise.reject(err);
      }
      return Promise.resolve(undefined);
    }

    const pendingPromise = new Promise<unknown>((resolve, reject): void => {
      this.dispatcher.register(
        id as string,
        { method, resolve, reject },
        timeout,
      );
      try {
        this.adapter.send(JSON.stringify(request));
      } catch (err) {
        // Transparent failover to fallbackAdapter if available
        if (isSendError(err) && this.fallbackAdapter && this.fallbackAdapter.isAvailable()) {
          try {
            if (typeof console !== "undefined") {
              console.warn(
                `[XBridge] call('${method}') primary adapter (${this.adapter.name}) failed, failing over to ${this.fallbackAdapter.name}`,
              );
            }
            this.fallbackAdapter.send(JSON.stringify(request));
            // Successfully handed off to fallbackAdapter — keep the pending entry alive!
            return;
          } catch (fallbackErr) {
            err = fallbackErr;
          }
        }

        // Send failed on all available transports — clean up pending entry before resolving fallback or rejecting
        this.dispatcher.cancel(id as string);
        if (typeof console !== "undefined") {
          console.warn(
            `[XBridge] call('${method}') failed to send:`,
            err instanceof Error ? err.message : err,
          );
        }
        if (hasFallback) {
          resolve((options as XBridgeCallOptions).fallback);
          return;
        }
        reject(err);
      }
    });
    return pendingPromise;
  }

  /**
   * Subscribe to host-pushed events identified by `method`. Multiple listeners
   * per method are supported. Returns an unsubscribe function.
   */
  onEvent(method: string, handler: XBridgeEventListener): () => void {
    let listeners = this.events.get(method);
    if (listeners === undefined) {
      listeners = new Set();
      this.events.set(method, listeners);
    }
    listeners.add(handler);

    return (): void => {
      const set = this.events.get(method);
      if (set === undefined) {
        return;
      }
      set.delete(handler);
      if (set.size === 0) {
        this.events.delete(method);
      }
    };
  }

  /**
   * Register a handler for Native→H5 RPC calls. When the host sends a request
   * with both `id` and `method`, the handler is invoked and its return value
   * (or thrown error) is sent back as a JSON-RPC response.
   *
   * Returns an unregister function (same pattern as {@link onEvent}).
   */
  registerHandler(method: string, handler: XBridgeHandler): () => void {
    this.handlers.set(method, handler);
    return (): void => {
      // Only delete if still the same handler — avoids removing a replacement.
      if (this.handlers.get(method) === handler) {
        this.handlers.delete(method);
      }
    };
  }

  /** Tear down: cancel all pending requests, drop listeners and handlers,
   * and destroy the adapter to clean up installed globals and event listeners. */
  dispose(): void {
    this.disposed = true;
    // Abort any pending ready() polls to avoid timer leaks. Reject them
    // explicitly so callers awaiting `call()` (which awaits `ready()`) do not
    // hang forever after disposal.
    const pendingRejects = Array.from(this.pendingReadyRejects);
    for (const cleanup of this.pendingReadyCleanups) {
      try {
        cleanup();
      } catch {
        // ignore
      }
    }
    this.pendingReadyCleanups.clear();
    for (const rej of pendingRejects) {
      try {
        rej(new XBridgeSendError("[XBridge] bridge has been disposed"));
      } catch {
        // ignore if already settled
      }
    }
    this.pendingReadyRejects.clear();
    this.dispatcher.clear();
    this.events.clear();
    this.handlers.clear();
    this.adapter.destroy?.();
    this.fallbackAdapter?.destroy?.();
  }

  // ---------------------------------------------------------------------
  // Inbound wiring
  // ---------------------------------------------------------------------

  private installInboundHandler(): void {
    if (this.messageHandlerBound) {
      return;
    }
    this.messageHandlerBound = true;
    // Single installed handler — bound once, no per-message allocation.
    this.adapter.onMessage((raw: string | object): void => {
      this.handleRaw(raw);
    });
    if (this.fallbackAdapter) {
      this.fallbackAdapter.onMessage((raw: string | object): void => {
        this.handleRaw(raw);
      });
    }
  }

  private handleRaw(raw: string | object): void {
    // 兼容两种入站形态：Dart 注入 `window.__XBridgeInbound__({...})` 传入对象
    // 字面量，而本地 JS/原生 adapter 传入 JSON 字符串。若对对象直接
    // JSON.parse，对象会被 ToString 化成 "[object Object]" 而静默丢弃，
    // 导致 Flutter→H5 回调失效。这里统一先规整为字符串再解析。
    if (typeof raw !== "string") {
      try {
        raw = JSON.stringify(raw);
      } catch {
        // 无法序列化（如循环引用）则按非法入站丢弃
        if (typeof console !== "undefined") {
          console.warn("[XBridge] dropped non-serializable inbound message");
        }
        return;
      }
    }
    let msg: XBridgeMessage;
    try {
      msg = JSON.parse(raw) as XBridgeMessage;
    } catch {
      if (typeof console !== "undefined") {
        console.warn("[XBridge] dropped non-JSON inbound message");
      }
      return;
    }

    // jsonrpc version check: if the field exists and != "2.0", drop the message.
    // If absent, accept for backward compatibility.
    const version = (msg as { jsonrpc?: unknown }).jsonrpc;
    if (version !== undefined && version !== XBRIDGE_PROTOCOL_VERSION) {
      if (typeof console !== "undefined") {
        console.warn(`[XBridge] dropped message with unsupported jsonrpc version:`, version);
      }
      return;
    }

    // Fast path: `id` is a string AND `method` is NOT a string ⇒ response.
    if (isResponse(msg)) {
      const response = msg as XBridgeResponse;
      if (response.error !== undefined) {
        // Validate error shape: must be an object with a string `message`.
        // Otherwise wrap as a structured error so downstream reject always
        // receives a well-formed XBridgeError.
        const rawError = response.error;
        if (
          rawError !== null &&
          typeof rawError === "object" &&
          typeof (rawError as { message?: unknown }).message === "string"
        ) {
          // Normalize code: JSON-RPC 2.0 specifies numeric codes, but the
          // Flutter/Dart side may send String codes (e.g. 'BRIDGE_METHOD_FORBIDDEN').
          // Preserve the original value so consumers can distinguish error types.
          const rawCode = (rawError as { code?: unknown }).code;
          const code: number | string = typeof rawCode === "number" || typeof rawCode === "string"
            ? rawCode
            : -32000;
          this.dispatcher.reject(response.id, {
            code,
            message: (rawError as { message: string }).message,
            data: (rawError as { data?: unknown }).data,
          });
        } else {
          this.dispatcher.reject(response.id, {
            code: -32000,
            message: "Malformed error from host",
            data: rawError,
          });
        }
      } else {
        this.dispatcher.resolve(response.id, response.result);
      }
      return;
    }

    // Inbound request from Native: `id` is a string AND `method` is a string.
    // Look up a registered handler, invoke it, and send back a JSON-RPC
    // response with the same `id`.
    if (isInboundRequest(msg)) {
      const request = msg as XBridgeRequest;
      this.handleInboundRequest(request);
      return;
    }

    // No `id` but has `method` ⇒ host-pushed event.
    const evt = msg as XBridgeEvent;
    if (typeof evt.method === "string") {
      this.emitEvent(evt.method, evt.params);
    }
  }

  private emitEvent(method: string, params: unknown): void {
    const listeners = this.events.get(method);
    if (listeners === undefined || listeners.size === 0) {
      return;
    }
    // Iterate the Set directly — the ECMAScript spec guarantees that
    // entries deleted during iteration (e.g. a listener unsubscribes itself)
    // are skipped safely, and new entries added during iteration are not
    // visited. This avoids the per-dispatch allocation of Array.from.
    for (const listener of listeners) {
      try {
        listener(params);
      } catch (err) {
        if (typeof console !== "undefined") {
          console.warn(`[XBridge] event listener for '${method}' threw:`, err);
        }
      }
    }
  }

  /**
   * Handle an inbound JSON-RPC request from the Native host. Invokes the
   * registered handler (if any) and sends back a success or error response
   * with the same correlation `id`. When no handler is registered, a
   * `-32601 Method not found` error is returned.
   */
  private handleInboundRequest(request: XBridgeRequest): void {
    const id = (request.id ?? "") as string | number;
    const handler = this.handlers.get(request.method);
    if (handler === undefined) {
      this.sendInboundResponse(id, undefined, {
        code: -32601,
        message: "Method not found",
      });
      return;
    }
    // Invoke handler and send response. The handler may be sync or async.
    Promise.resolve()
      .then((): unknown => handler(request.params))
      .then(
        (result: unknown): void => {
          this.sendInboundResponse(id, result, undefined);
        },
        (err: unknown): void => {
          // Make the error JSON-serializable: Error objects have
          // non-enumerable properties, so JSON.stringify(Error) → "{}".
          let serializableData: unknown;
          if (err instanceof Error) {
            serializableData = { name: err.name, message: err.message };
          } else {
            serializableData = err;
          }
          this.sendInboundResponse(id, undefined, {
            code: -32000,
            message: typeof err === "string" ? err : (err as { message?: string })?.message ?? "Handler error",
            data: serializableData,
          });
        },
      );
  }

  /** Serialize and send a JSON-RPC response back to the Native host. */
  private sendInboundResponse(
    id: string | number,
    result: unknown,
    error: XBridgeError | undefined,
  ): void {
    // JSON-RPC 2.0 §5: result and error are mutually exclusive.
    const response: XBridgeResponse = error !== undefined
      ? { jsonrpc: XBRIDGE_PROTOCOL_VERSION, id, error }
      : { jsonrpc: XBRIDGE_PROTOCOL_VERSION, id, result };
    try {
      this.adapter.send(JSON.stringify(response));
    } catch (err) {
      if (isSendError(err) && this.fallbackAdapter && this.fallbackAdapter.isAvailable()) {
        try {
          this.fallbackAdapter.send(JSON.stringify(response));
          return;
        } catch {
          // ignore
        }
      }
      if (typeof console !== "undefined") {
        console.warn("[XBridge] failed to send inbound response:", err);
      }
    }
  }
}
