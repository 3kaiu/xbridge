# xbridge-js

Open-source, zero-business-coupling H5 bridge SDK. Implements a JSON-RPC 2.0
variant protocol with adapters for the common WebView transports
(`flutter_inappwebview`, `window.AppBridge`, WK `humanBridge`, `dsbridge` sync).

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
const token = await bridge.call("getToken");

// Fire-and-forget (mirrors WK noCallback semantics)
await bridge.call("notifyEnumAction", { foo: 1 }, { noCallback: true });

// Sync bypass — only when a sync adapter (e.g. dsbridge) is present
const info = bridge.callSync("getAppInfo");

// Subscribe to host-pushed events
const off = bridge.onEvent("onAudioFinished", (params) => {
  console.log("audio finished", params);
});
// later
off();
```

## Auto-sniff order

The constructor probes `window` once (cached) and picks the first available
adapter:

1. `window.flutter_inappwebview.callHandler` → `InAppWebViewAdapter`
2. `window.AppBridge.postMessage` → `AppBridgeAdapter`
3. `window.webkit.messageHandlers.humanBridge.postMessage` → `WKBridgeAdapter`
4. `window.dsbridge.call` → `DSBridgeSyncAdapter` (sync only; `call()` warns)
5. none → `NoopAdapter` (warns "no bridge environment")

Override explicitly when you need to force a transport, e.g. for tests:

```ts
import { XBridge, AppBridgeAdapter } from "xbridge-js";

const bridge = new XBridge({ adapter: new AppBridgeAdapter() });
```

## Adapters

| Adapter | Transport | Direction |
| --- | --- | --- |
| `InAppWebViewAdapter` | `window.flutter_inappwebview.callHandler('XBridge', str)` | async bidirectional via `window.__XBridgeDispatch__` |
| `AppBridgeAdapter` | `window.AppBridge.postMessage(str)` | async bidirectional via `window.__YASHI_APP_BRIDGE__` + `YashiAppEvent` |
| `WKBridgeAdapter` | `window.webkit.messageHandlers.humanBridge.postMessage([m,d,id,ts])` | async bidirectional via `window.__wkBridgeCallback` |
| `DSBridgeSyncAdapter` | `window.dsbridge.call(method, args)` | sync only |

Each adapter installs its inbound handler exactly once and synthesizes JSON-RPC
response/event envelopes so the core parses a single inbound format.

## Protocol

```jsonc
// H5 → Host
{ "jsonrpc": "2.0", "id": "<uuid>", "method": "getToken", "params": {} }

// Host → H5 (response)
{ "jsonrpc": "2.0", "id": "<uuid>", "result": "..." }
{ "jsonrpc": "2.0", "id": "<uuid>", "error": { "code": -32000, "message": "..." } }

// Host → H5 (event, no id)
{ "jsonrpc": "2.0", "method": "onAudioFinished", "params": {} }
```

`XBRIDGE_PROTOCOL_VERSION` is exported as `"2.0"`.

## Performance

- Single installed message handler per adapter; inbound parsed once.
- O(1) `Map` for pending-request correlation and event listeners.
- `JSON.stringify` / `JSON.parse` only — no intermediate allocations.
- `generateId()` uses native `crypto.randomUUID` when available (cached).
- No runtime dependencies (no `uuid`).

## License

MIT
