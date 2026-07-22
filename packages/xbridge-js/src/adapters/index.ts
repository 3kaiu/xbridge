/**
 * Adapter barrel — re-export every concrete adapter so consumers can pin a
 * specific transport explicitly:
 *
 * ```ts
 * import { XBridge, AppBridgeAdapter } from "xbridge-js";
 * const bridge = new XBridge({ adapter: new AppBridgeAdapter() });
 * ```
 */

export { AppBridgeAdapter } from "./appbridge.js";
export { WKBridgeAdapter } from "./wkbridge.js";
export {
  InAppWebViewAdapter,
  XBRIDGE_INAPP_HANDLER_NAME,
  XBRIDGE_DISPATCH_GLOBAL,
} from "./inappwebview.js";
export { DSBridgeSyncAdapter } from "./dsbridge_sync.js";
