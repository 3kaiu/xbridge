/**
 * Pending-request dispatcher.
 *
 * Maintains an O(1) {@link Map} keyed by correlation id. A single dispatcher
 * instance is bound once per {@link XBridgeCore}; inbound wire messages are
 * routed here after a single JSON parse in {@link XBridgeCore}.
 *
 * Allocation discipline: the per-call timer is installed lazily; `resolve` /
 * `reject` / `cancel` clear it in O(1) before mutating the map. Timeout
 * callbacks are created via `setTimeout` (browser/Node compatible) and cleared
 * with `clearTimeout`.
 */

/** A pending request awaiting its response. */
export interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: unknown) => void;
  timer: ReturnType<typeof setTimeout> | undefined;
  method: string;
  startedAt: number;
}

/** Default timeout (ms) for a call without an explicit `timeout`. */
export const DEFAULT_TIMEOUT_MS = 30000;

/**
 * Error thrown (and passed to {@link PendingRequest.reject}) when a call
 * exceeds its configured timeout. `code` mirrors JSON-RPC error codes loosely.
 */
export interface TimeoutError {
  code: number;
  message: string;
  data?: unknown;
}

function makeTimeoutError(method: string, timeoutMs: number): TimeoutError {
  return {
    code: -32000,
    message: `XBridge call '${method}' timed out after ${timeoutMs}ms`,
    data: { method, timeoutMs },
  };
}

/**
 * Map of pending requests. Exposed as a concrete class so the bridge can hold
 * one instance and bind handlers once.
 */
export class Dispatcher {
  private readonly pending: Map<string, PendingRequest> = new Map();

  /** Current number of in-flight requests. Useful for diagnostics. */
  get size(): number {
    return this.pending.size;
  }

  /**
   * Register a pending request.
   *
   * @param id correlation id
   * @param entry resolve/reject pair plus method name
   * @param timeoutMs timeout in ms; `0` disables the timer
   * @param onTimeout invoked when the timer fires (typically a no-op; the
   *   dispatcher itself rejects the entry). Kept on the signature so the bridge
   *   can hook metrics without wrapping `setTimeout` per call.
   */
  register(
    id: string,
    entry: Omit<PendingRequest, "timer" | "startedAt">,
    timeoutMs: number = DEFAULT_TIMEOUT_MS,
    onTimeout?: (id: string, method: string, timeoutMs: number) => void,
  ): void {
    let timer: ReturnType<typeof setTimeout> | undefined;
    if (timeoutMs > 0) {
      // Bind the timeout handler once per registration. The closure captures
      // only `id` + `method` + `timeoutMs` — no per-message allocation.
      const method = entry.method;
      timer = setTimeout((): void => {
        const existing = this.pending.get(id);
        if (existing === undefined) {
          return;
        }
        this.pending.delete(id);
        existing.reject(makeTimeoutError(method, timeoutMs));
        if (onTimeout !== undefined) {
          onTimeout(id, method, timeoutMs);
        }
      }, timeoutMs);
    }
    this.pending.set(id, {
      resolve: entry.resolve,
      reject: entry.reject,
      timer,
      method: entry.method,
      startedAt: Date.now(),
    });
  }

  /** Resolve a pending request by id. No-op if unknown (e.g. timed out). */
  resolve(id: string, result: unknown): void {
    const entry = this.pending.get(id);
    if (entry === undefined) {
      return;
    }
    if (entry.timer !== undefined) {
      clearTimeout(entry.timer);
    }
    this.pending.delete(id);
    entry.resolve(result);
  }

  /** Reject a pending request by id. No-op if unknown. */
  reject(id: string, error: unknown): void {
    const entry = this.pending.get(id);
    if (entry === undefined) {
      return;
    }
    if (entry.timer !== undefined) {
      clearTimeout(entry.timer);
    }
    this.pending.delete(id);
    entry.reject(error);
  }

  /** Whether a pending request with this id exists. */
  has(id: string): boolean {
    return this.pending.has(id);
  }

  /**
   * Cancel a pending request without resolving/rejecting it (e.g. the caller
   * gave up). Clears the timer and removes the entry. No-op if unknown.
   */
  cancel(id: string): void {
    const entry = this.pending.get(id);
    if (entry === undefined) {
      return;
    }
    if (entry.timer !== undefined) {
      clearTimeout(entry.timer);
    }
    this.pending.delete(id);
  }

  /** Cancel every pending request. Used on teardown. */
  clear(): void {
    for (const entry of this.pending.values()) {
      if (entry.timer !== undefined) {
        clearTimeout(entry.timer);
      }
      entry.reject({ code: -32000, message: "XBridge disposed" });
    }
    this.pending.clear();
  }
}
