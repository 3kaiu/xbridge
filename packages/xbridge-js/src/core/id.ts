/**
 * Correlation-id generator for {@link XBridgeRequest.id}.
 *
 * Uses native `crypto.randomUUID` when available (browsers, Node ≥ 14.17),
 * otherwise falls back to a counter + timestamp + random combination that is
 * still unique within a single JS realm — sufficient for correlating
 * request/response over a bridge channel.
 */

let hasNative: boolean | null = null;

function detectNative(): boolean {
  if (typeof globalThis === "undefined" || typeof globalThis.crypto === "undefined") {
    return false;
  }
  return typeof globalThis.crypto.randomUUID === "function";
}

function nativeAvailable(): boolean {
  if (hasNative === null) {
    hasNative = detectNative();
  }
  return hasNative;
}

let fallbackCounter = 0;

function fallbackId(): string {
  // Monotonic counter + high-res timestamp + random ensures uniqueness across
  // re-entries and overlapping calls within one realm.
  fallbackCounter = (fallbackCounter + 1) & 0x7fffffff;
  const stamp =
    typeof performance !== "undefined" && typeof performance.now === "function"
      ? performance.now()
      : Date.now();
  const rand = Math.floor(Math.random() * 0x1000000)
    .toString(16)
    .padStart(6, "0");
  return `xb-${stamp.toString(36)}-${fallbackCounter.toString(36)}-${rand}`;
}

/** Generate a new correlation id. Cached detection — no per-call overhead. */
export function generateId(): string {
  if (nativeAvailable()) {
    try {
      return globalThis.crypto.randomUUID();
    } catch {
      // A throw here would be exceptional (e.g. insecure context); fall through.
    }
  }
  return fallbackId();
}
