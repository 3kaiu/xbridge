/**
 * Adapter barrel — re-export concrete adapters.
 *
 * `StandardAdapter` is the universal async adapter for all containers that
 * inject `window.XBridge.postMessage` (Flutter webview_flutter and native
 * shells that follow the standard contract).
 *
 * `NativeSyncAdapter` is the sync bypass adapter for `window.dsbridge.call`.
 */

export { StandardAdapter } from "./standard.js";
export { NativeSyncAdapter } from "./native_sync.js";
