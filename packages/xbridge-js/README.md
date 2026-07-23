# xbridge-js

Open-source, zero-business-coupling H5 bridge SDK. Implements a JSON-RPC 2.0
variant protocol with a universal `StandardAdapter` for any container that
injects `window.XBridge.postMessage`, plus a sync bypass adapter for
`window.dsbridge.call`.

## Install

```sh
npm install xbridge-js
# or
pnpm add xbridge-js
```

## Quick start

```ts
import { XBridge } from "xbridge-js";

const bridge = new XBridge();

// Async RPC (Promise, JSON-RPC over the detected transport)
const info = await bridge.call("getDeviceInfo");

// Fire-and-forget (no id, no response expected)
await bridge.call("logEvent", { foo: 1 }, { noCallback: true });

// Sync bypass — only when a sync adapter (e.g. your existing native bridge) is present
const version = bridge.callSync("getAppVersion");

// Subscribe to host-pushed events
const off = bridge.onEvent("onNetworkChange", (params) => {
  console.log("network changed", params);
});
// later
off();

// Register a handler for Native → H5 calls
const unreg = bridge.registerHandler("getUserConfirmation", (params) => {
  return confirm(params?.message);
});
// later
unreg();

// Re-sniff if the container injects window.XBridge after SDK init
import { resetSniffCache } from "xbridge-js";
resetSniffCache();
const bridge2 = new XBridge(); // picks up StandardAdapter now
```

## Auto-sniff order

The constructor probes `window` once (cached) and picks the first available
adapter:

1. `window.XBridge.postMessage` → `StandardAdapter` (async, bidirectional)
2. `window.dsbridge.call` → `NativeSyncAdapter` (sync only; `call()` warns)
3. none → `NoopAdapter` (warns "no bridge environment")

Override explicitly when you need to force a transport, e.g. for tests:

```ts
import { XBridge, StandardAdapter } from "xbridge-js";

const bridge = new XBridge({ adapter: new StandardAdapter() });
```

## Adapters

| Adapter | Transport | Direction |
| --- | --- | --- |
| `StandardAdapter` | `window.XBridge.postMessage(str)` | async bidirectional via `window.__XBridge__.resolve/reject` + `window.__XBridgeInbound__` + `XBridgeEvent` |
| `NativeSyncAdapter` | `window.dsbridge.call(method, args)` | sync only (returns value directly) |

`StandardAdapter` installs global overrides that route host → H5 messages
into the core. The overrides are re-installed lazily on each `send()` call,
so they survive host bootstrap re-injection.

## Protocol

```jsonc
// H5 → Host
{ "jsonrpc": "2.0", "id": "<uuid>", "method": "getDeviceInfo", "params": {} }

// Host → H5 (response)
{ "jsonrpc": "2.0", "id": "<uuid>", "result": "..." }
{ "jsonrpc": "2.0", "id": "<uuid>", "error": { "code": -32000, "message": "..." } }

// Host → H5 (event, no id)
{ "jsonrpc": "2.0", "method": "onNetworkChange", "params": {} }
```

`XBRIDGE_PROTOCOL_VERSION` is exported as `"2.0"`.

## Performance

- Single installed message handler per adapter; inbound parsed once.
- O(1) `Map` for pending-request correlation and event listeners.
- `JSON.stringify` / `JSON.parse` only — no intermediate allocations.
- `generateId()` uses native `crypto.randomUUID` when available (cached).
- No runtime dependencies.

## License

MIT
