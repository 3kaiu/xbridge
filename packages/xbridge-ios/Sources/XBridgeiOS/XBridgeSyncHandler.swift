// SPDX-License-Identifier: MIT
//
// XBridgeSyncHandler.swift
// XBridgeiOS
//
// Created by XBridge SDK on 2024-01-01.
//

import Foundation
import WebKit

/// A `WKScriptMessageHandler` that provides a bridge call path for H5 code,
/// bypassing the async Flutter MethodChannel.
///
/// ## ⚠️ CRITICAL iOS LIMITATION
///
/// On iOS, `WKUserContentController.add(_:name:)` delivers script messages
/// **asynchronously** to the delegate's `userContentController(_:didReceive:)`
/// method. This means true synchronous call-and-return from JavaScript to
/// native is **not possible** through the standard `add` API.
///
/// ### What this class does
///
/// `XBridgeSyncHandler` registers itself as a `WKScriptMessageHandler` named
/// `XBridgeSync` in the WKWebView's content controller. It also injects a JS
/// helper at `documentStart` that wraps the async message handler with a
/// Promise-based API. When JS calls `window.XBridgeSync.callSync(method, params)`,
/// it returns a Promise. The native side processes the call and pushes the
/// result back via `evaluateJavaScript`, resolving the Promise.
///
/// This is **not truly synchronous** — it is async with minimal overhead.
/// The H5 SDK (`xbridge-js`) probes `XBridgeSync.isAvailable()` and falls back
/// to the standard async Flutter channel if unavailable.
///
/// ### Alternative: `prompt()` interception (true sync)
///
/// For genuine synchronous returns, the host app can intercept the
/// `WKUIDelegate` method:
/// ```swift
/// func webView(_ webView: WKWebView,
///              runJavaScriptTextInputPanelWithPrompt prompt: String,
///              defaultText: String?,
///              initiatedByFrame frame: WKFrameInfo,
///              completionHandler: @escaping (String?) -> Void) {
///     // Parse `prompt` as a bridge method call, return result synchronously
///     // via `completionHandler(JSONString)`
/// }
/// ```
/// This `prompt()` hack is the only way to achieve true sync on WKWebView.
/// It is documented here as an optional upgrade path for apps that need it.
public class XBridgeSyncHandler: NSObject, WKScriptMessageHandler {

    // MARK: - State

    /// The app-supplied delegate for forwarding bridge calls.
    public weak var nativeBridge: XBridgeNativeBridge?

    /// The WKWebView to push results back via `evaluateJavaScript`.
    private weak var webView: WKWebView?

    /// Whether the JS helper script has already been injected,
    /// to avoid duplicate `WKUserScript` on re-attach.
    private var scriptInjected = false

    // MARK: - Attachment

    /// Attach this handler to a WKWebView's content controller.
    ///
    /// After calling this, the JS side can probe:
    /// ```javascript
    /// if (window.webkit.messageHandlers.XBridgeSync) {
    ///     // Send a sync call (async delivery; result via callback)
    ///     window.webkit.messageHandlers.XBridgeSync.postMessage({
    ///         method: 'getAppInfo',
    ///         params: '{}',
    ///         callbackId: 'cb_1'
    ///     });
    /// }
    /// ```
    ///
    /// Safe to call multiple times: if already registered, it removes the
    /// old handler before re-adding, and skips duplicate `WKUserScript`
    /// injection.
    public func attach(to webView: WKWebView) {
        self.webView = webView
        let contentController = webView.configuration.userContentController

        // Remove any previously registered message handler for this name
        // to avoid a crash on re-attach ("handler already registered").
        contentController.removeScriptMessageHandler(forName: "XBridgeSync")
        contentController.add(self, name: "XBridgeSync")

        // Inject the JS helper only once per instance to avoid
        // duplicate user scripts on re-attach.
        guard !scriptInjected else { return }
        scriptInjected = true

        // Inject a JS helper that wraps the async message handler with a
        // Promise-based API, simulating a sync-like call pattern.
        let jsHelper = """
        (function() {
            if (window.XBridgeSync) return;
            window.XBridgeSync = {
                _callbacks: {},
                _counter: 0,
                callSync: function(method, paramsJson) {
                    var self = this;
                    var cbId = 'xbsync_' + (++this._counter);
                    return new Promise(function(resolve, reject) {
                        self._callbacks[cbId] = { resolve: resolve, reject: reject };
                        window.webkit.messageHandlers.XBridgeSync.postMessage({
                            method: method,
                            params: paramsJson,
                            callbackId: cbId
                        });
                    });
                },
                isAvailable: function() {
                    return true;
                },
                _resolveCallback: function(cbId, result) {
                    if (this._callbacks[cbId]) {
                        this._callbacks[cbId].resolve(result);
                        delete this._callbacks[cbId];
                    }
                },
                _rejectCallback: function(cbId, error) {
                    if (this._callbacks[cbId]) {
                        this._callbacks[cbId].reject(error);
                        delete this._callbacks[cbId];
                    }
                }
            };
        })();
        """

        contentController.addUserScript(
            WKUserScript(
                source: jsHelper,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
    }

    /// Detach from the content controller to break the
    /// `WKUserContentController` retain cycle.
    ///
    /// - Important: The app **MUST** call this from an external lifecycle
    ///   hook (e.g. `viewDidDisappear`, `deinit` of the view controller,
    ///   or `AppDelegate` teardown) — **not** from this class's own
    ///   `deinit`. Because `WKUserContentController.add(self, name:)`
    ///   retains `self` (this handler), this object's `deinit` will
    ///   never fire until the message handler is removed. Calling
    ///   `detach()` from external lifecycle is the only way to break
    ///   the cycle.
    public func detach() {
        if let webView = webView {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: "XBridgeSync"
            )
        }
        webView = nil
    }

    // MARK: - WKScriptMessageHandler (async delivery) ───────────────────

    /// Called when JS posts a message to `XBridgeSync`.
    ///
    /// **This is async** — the JS side has already moved on. We process the
    /// call and push the result back via `evaluateJavaScript`.
    public func userContentController(
        _ contentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let callbackId = body["callbackId"] as? String else {
            return
        }

        // Parse params (may be a JSON string or a raw object)
        var params: Any? = nil
        if let paramsString = body["params"] as? String,
           !paramsString.isEmpty {
            if let data = paramsString.data(using: .utf8) {
                params = try? JSONSerialization.jsonObject(with: data)
            }
        } else if let p = body["params"] {
            params = p
        }

        // Invoke the delegate. If off main, dispatch to main async.
        // JS side is Promise-based, result push-back is already async.
        let invokeBlock: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard let nativeBridge = self.nativeBridge else {
                self.pushError(
                    callbackId: callbackId,
                    code: "NO_NATIVE_BRIDGE",
                    message: "XBridgeNativeBridge not set"
                )
                return
            }

            let result = nativeBridge.invoke(method: method, params: params)
            self.pushResult(callbackId: callbackId, result: result)
        }

        if Thread.isMainThread {
            invokeBlock()
        } else {
            DispatchQueue.main.async(execute: invokeBlock)
        }
    }

    // MARK: - Result push-back ───────────────────────────────────────────

    /// Push a successful result back to JS via `evaluateJavaScript`.
    ///
    /// Uses `JSONSerialization` to encode `[callbackId, result]` as a JSON
    /// array, avoiding manual string-escaping bugs (e.g. `'`, `/`, `</`).
    private func pushResult(callbackId: String, result: Any?) {
        guard let webView = webView else { return }

        // Build a JSON array [callbackId, result] and pass to the JS callback.
        // JSONSerialization handles all escaping correctly.
        var jsonResult: Any = result ?? NSNull()
        if let result = result {
            if !JSONSerialization.isValidJSONObject(result) {
                // Convert non-JSON-serializable values to strings.
                if let str = result as? String {
                    jsonResult = [str] // array with single string → extract
                    if let data = try? JSONSerialization.data(withJSONObject: jsonResult),
                       let arr = String(data: data, encoding: .utf8) {
                        jsonResult = String(arr.dropFirst().dropLast())
                    } else {
                        jsonResult = result
                    }
                } else if let b = result as? Bool {
                    jsonResult = b ? "true" : "false"
                } else if let num = result as? NSNumber {
                    jsonResult = num.stringValue
                } else {
                    jsonResult = "\(result)"
                }
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: [callbackId, jsonResult]),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }

        let js = "window.XBridgeSync._resolveCallback.apply(null, \(jsonStr));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Push an error back to JS via `evaluateJavaScript`.
    ///
    /// Uses `JSONSerialization` to encode `[callbackId, {code, message}]`
    /// as a JSON array, avoiding manual string-escaping bugs.
    private func pushError(callbackId: String, code: String, message: String) {
        guard let webView = webView else { return }

        let errorObj: [String: String] = ["code": code, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: [callbackId, errorObj]),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }

        let js = "window.XBridgeSync._rejectCallback.apply(null, \(jsonStr));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
