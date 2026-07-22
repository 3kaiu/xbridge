/**
 * Adapter barrel — re-export every concrete adapter so consumers can pin a
 * specific transport explicitly:
 *
 * ```ts
 * import { XBridge, FlutterChannelAdapter } from "xbridge-js";
 * const bridge = new XBridge({ adapter: new FlutterChannelAdapter() });
 * ```
 */

export { FlutterChannelAdapter } from "./flutter_channel.js";
export { WKWebViewAdapter } from "./wkwebview.js";
export {
  InAppWebViewAdapter,
  XBRIDGE_INAPP_HANDLER_NAME,
  XBRIDGE_DISPATCH_GLOBAL,
} from "./inappwebview.js";
export { NativeSyncAdapter } from "./native_sync.js";
