// SPDX-License-Identifier: MIT
//
// XBridgePlugin.swift
// XBridgeiOS
//
// Created by XBridge SDK on 2024-01-01.
//

import Foundation
import Flutter

/// The Flutter `MethodChannel` receiver for XBridge.
///
/// This plugin listens on the `xbridge/native_fallback` channel and forwards
/// incoming method calls to an app-supplied `XBridgeNativeBridge` delegate.
/// It also provides control methods for the local WebSocket server (backed by
/// the Rust `xbridge_core` C-ABI) and security policy management.
///
/// The plugin is intentionally business-free. It does not know about
/// `getToken`, `PaymentService`, or any other domain method. The app sets a
/// delegate that forwards to its existing bridge handler.
public class XBridgePlugin: NSObject, FlutterPlugin {

    // MARK: - Constants

    /// The MethodChannel name that Flutter's `BridgeController` sends
    /// fallback (unregistered) methods to.
    public static let channelName = "xbridge/native_fallback"

    // MARK: - State

    /// The app-supplied delegate that forwards to the existing bridge handler.
    /// Must be set before any `invoke` call arrives.
    public var nativeBridge: XBridgeNativeBridge?

    /// The active security policy (defense-in-depth; the primary gate is on
    /// the Flutter side via `WebViewBridgePolicy`).
    public var securityPolicy: XBridgeSecurityPolicy = .allowAll()

    /// The FlutterMethodChannel bound to this plugin instance.
    private var channel: FlutterMethodChannel?

    // MARK: - FlutterPlugin

    /// Register this plugin with the Flutter registrar.
    ///
    /// Call this from your `AppDelegate` or `FlutterViewController`:
    /// ```swift
    /// XBridgePlugin.register(with: registrar)
    /// ```
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = XBridgePlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    /// Register with a pre-configured channel (for testing or custom
    /// messenger setups).
    public static func register(
        with registrar: FlutterPluginRegistrar,
        nativeBridge: XBridgeNativeBridge
    ) -> XBridgePlugin {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = XBridgePlugin()
        instance.channel = channel
        instance.nativeBridge = nativeBridge
        registrar.addMethodCallDelegate(instance, channel: channel)
        return instance
    }

    // MARK: - MethodCallHandler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method

        // Intercept XBridge control calls (prefixed with "xbridge.").
        if method.hasPrefix("xbridge.") {
            handleControlCall(call, result: result)
            return
        }

        // All other methods are business calls forwarded from Flutter
        // FallbackChannel — route to the native bridge delegate.
        // (Android convention: call.method IS the business method name,
        // call.arguments IS the params.)
        guard let nativeBridge = nativeBridge else {
            result(FlutterError(
                code: "NO_NATIVE_BRIDGE",
                message: "XBridgeNativeBridge not set",
                details: "Call XBridgePlugin.nativeBridge = ... before receiving invoke calls."
            ))
            return
        }

        let params = call.arguments

        // Dispatch to main thread if the delegate requires it.
        // We call directly if already on main; otherwise dispatch async.
        // The delegate implementation decides its own threading needs.
        if Thread.isMainThread {
            let value = nativeBridge.invoke(method: method, params: params)
            result(value)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let value = self.nativeBridge?.invoke(method: method, params: params)
                result(value)
            }
        }
    }

    // MARK: - Control call dispatch

    private func handleControlCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        // ── Local WebSocket Server control ──
        case "xbridge.setupLocalWebSocket":
            // Arguments: {port: Int} or nil (port 0 = OS-assigned)
            var port: Int = 0
            if let args = call.arguments as? [String: Any],
               let p = args["port"] as? Int {
                port = p
            } else if let p = call.arguments as? Int {
                port = p
            }

            LocalWsServerBridge.shared.start(port: port) { res in
                switch res {
                case .success(let actualPort):
                    result(actualPort)
                case .failure(let error):
                    result(FlutterError(
                        code: "WS_START_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }

        case "xbridge.teardownLocalWebSocket":
            LocalWsServerBridge.shared.stop { res in
                switch res {
                case .success:
                    result(nil)
                case .failure(let error):
                    result(FlutterError(
                        code: "WS_STOP_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }

        // ── Security policy push (defense-in-depth) ──
        case "xbridge.setSecurityPolicy":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(
                    code: "INVALID_ARGUMENTS",
                    message: "Expected {allowedOrigins: [String], allowAll: Bool}",
                    details: nil
                ))
                return
            }

            let allowAll = args["allowAll"] as? Bool ?? false
            var origins: Set<String> = []
            if let originArray = args["allowedOrigins"] as? [String] {
                origins = Set(originArray)
            }

            if allowAll {
                self.securityPolicy = .allowAll()
            } else {
                self.securityPolicy = .allowlist(origins)
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
