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

import type { IXBridgeAdapter, ISyncAdapter } from "./adapter.js";
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
import { XBRIDGE_PROTOCOL_VERSION } from "../types.js";

/** Event listener signature for {@link XBridgeCore.onEvent}. */
export type XBridgeEventListener = (params: unknown) => void;

/** Handler signature for Native→H5 RPC calls. */
export type XBridgeHandler = (params: unknown) => unknown | Promise<unknown>;

function isResponse(msg: XBridgeMessage): msg is XBridgeResponse {
  return typeof (msg as XBridgeResponse).id === "string" && typeof (msg as XBridgeEvent).method !== "string";
}

function isInboundRequest(msg: XBridgeMessage): msg is XBridgeRequest {
  return typeof (msg as XBridgeRequest).id === "string" && typeof (msg as XBridgeRequest).method === "string";
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
  private readonly syncAdapter: ISyncAdapter | undefined;
  private messageHandlerBound = false;

  constructor(adapter: IXBridgeAdapter, syncAdapter?: ISyncAdapter) {
    this.adapter = adapter;
    this.syncAdapter = syncAdapter;
    this.installInboundHandler();
  }

  /** Adapter name (diagnostics). */
  get adapterName(): string {
    return this.adapter.name;
  }

  /** The underlying async adapter. */
  getAdapter(): IXBridgeAdapter {
    return this.adapter;
  }

  /** The sync adapter, if any. */
  getSyncAdapter(): ISyncAdapter | undefined {
    return this.syncAdapter;
  }

  /**
   * Invoke `method` on the host and await its response.
   *
   * @param method host method name
   * @param params optional payload
   * @param options `{ timeout?, noCallback? }`. `noCallback` resolves
   *   immediately after `send` (fire-and-forget) — matches the WK no-callback
   *   semantics where `requestId` is `null`.
   */
  call(method: string, params?: unknown, options?: XBridgeCallOptions): Promise<unknown> {
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
        return Promise.reject(err);
      }
      return Promise.resolve(undefined);
    }

    return new Promise<unknown>((resolve, reject): void => {
      this.dispatcher.register(
        id as string,
        { method, resolve, reject },
        timeout,
      );
      try {
        this.adapter.send(JSON.stringify(request));
      } catch (err) {
        // Send failed — clean up the pending entry before rejecting so the
        // timer doesn't fire on a dead request.
        this.dispatcher.cancel(id as string);
        reject(err);
      }
    });
  }

  /**
   * Synchronously invoke `method`. Routes to the sync adapter when present;
   * otherwise warns and returns `undefined` (PRD §P1). Never throws to the
   * caller — a missing sync channel is a soft-degraded state, not an error.
   */
  callSync(method: string, params?: unknown): unknown {
    if (this.syncAdapter === undefined || !this.syncAdapter.isAvailable()) {
      if (typeof console !== "undefined") {
        console.warn(
          `[XBridge] callSync('${method}') is not supported in this environment (no sync adapter); returning undefined.`,
        );
      }
      return undefined;
    }
    try {
      return this.syncAdapter.callSync(method, params);
    } catch (err) {
      if (typeof console !== "undefined") {
        console.warn(`[XBridge] callSync('${method}') threw:`, err);
      }
      return undefined;
    }
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

  /** Tear down: cancel all pending requests, drop listeners and handlers. */
  dispose(): void {
    this.dispatcher.clear();
    this.events.clear();
    this.handlers.clear();
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
    this.adapter.onMessage((raw: string): void => {
      this.handleRaw(raw);
    });
  }

  private handleRaw(raw: string): void {
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
        const raw = response.error;
        if (
          raw !== null &&
          typeof raw === "object" &&
          typeof (raw as { message?: unknown }).message === "string"
        ) {
          this.dispatcher.reject(response.id, raw as XBridgeError);
        } else {
          this.dispatcher.reject(response.id, {
            code: -32000,
            message: "Malformed error from host",
            data: raw,
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
    // Iterate a snapshot so a listener may unsubscribe during dispatch.
    for (const listener of Array.from(listeners)) {
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
    const id = request.id as string;
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
          this.sendInboundResponse(id, undefined, {
            code: -32000,
            message: typeof err === "string" ? err : (err as { message?: string })?.message ?? "Handler error",
            data: err,
          });
        },
      );
  }

  /** Serialize and send a JSON-RPC response back to the Native host. */
  private sendInboundResponse(
    id: string,
    result: unknown,
    error: XBridgeError | undefined,
  ): void {
    const response: XBridgeResponse = {
      jsonrpc: XBRIDGE_PROTOCOL_VERSION,
      id,
      result,
      error,
    };
    try {
      this.adapter.send(JSON.stringify(response));
    } catch (err) {
      if (typeof console !== "undefined") {
        console.warn("[XBridge] failed to send inbound response:", err);
      }
    }
  }
}
