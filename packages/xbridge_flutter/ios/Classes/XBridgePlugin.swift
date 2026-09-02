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
/// any domain-specific method. The app sets a
/// delegate that forwards to its existing bridge handler.
///
/// - Note: This class is `@MainActor` to ensure thread-safe access to
///   `securityPolicy` and `origin`. Flutter's `MethodChannel` delivers
///   calls on the main thread by default, so this alignment is natural.
@MainActor
public class XBridgePlugin: NSObject, FlutterPlugin {

    // MARK: - Constants

    /// The MethodChannel name that Flutter's `BridgeController` sends
    /// fallback (unregistered) methods to.
    public static let channelName = "xbridge/native_fallback"

    /// The MethodChannel name for Native → Flutter/H5 reverse calls.
    public static let reverseChannelName = "xbridge/native_reverse"

    /// Fixed reverse-channel method that Native uses to broadcast an event to
    /// H5. The real event name lives in `arguments["method"]` (and `params` in
    /// `arguments["params"]`), NOT in the method-name prefix, so no business
    /// method name can collide with the event namespace.
    public static let reverseEventMethod = "pushEvent"

    // MARK: - State

    /// The app-supplied delegate that forwards to the existing bridge handler.
    /// Must be set before any `invoke` call arrives.
    public var nativeBridge: XBridgeNativeBridge?

    /// The active security policy (defense-in-depth; the primary gate is on
    /// the Flutter side via `WebViewBridgePolicy`).
    public var securityPolicy: XBridgeSecurityPolicy = .denyAll()

    /// The current page origin, set by the host app when it observes
    /// navigation. Used for defense-in-depth security checks on the
    /// MethodChannel path.
    public var origin: String?

    /// The FlutterMethodChannel bound to this plugin instance.
    private var channel: FlutterMethodChannel?
    private var reverseChannel: FlutterMethodChannel?

    // MARK: - Reverse calls (Native → Flutter / H5)

    /// Invoke a method registered on Flutter or H5 asynchronously from Native.
    public func callH5(method: String, params: Any?, result: FlutterResult? = nil) {
        reverseChannel?.invokeMethod(method, arguments: params, result: result)
    }

    /// Broadcast an event from Native to H5.
    ///
    /// Delivered as a fixed method name (`pushEvent`) with the real event name
    /// carried in the arguments map — not encoded into the method-name prefix —
    /// so a business method can never collide with the event-marker namespace.
    public func pushEvent(method: String, params: Any?) {
        var args: [String: Any] = ["method": method]
        if let params = params {
            args["params"] = params
        }
        reverseChannel?.invokeMethod(Self.reverseEventMethod, arguments: args)
    }

    // MARK: - FlutterPlugin

    /// Register this plugin with the Flutter registrar.
    ///
    /// - Note: This method is `@MainActor`-isolated because `XBridgePlugin`
    ///   is a `@MainActor` class. Flutter's registrar typically calls on the
    ///   main thread, so this alignment is natural.
    @MainActor
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let reverseChannel = FlutterMethodChannel(
            name: reverseChannelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = XBridgePlugin()
        instance.channel = channel
        instance.reverseChannel = reverseChannel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    /// Register with a pre-configured channel (for testing or custom
    /// messenger setups).
    @MainActor
    public static func register(
        with registrar: FlutterPluginRegistrar,
        nativeBridge: XBridgeNativeBridge
    ) -> XBridgePlugin {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let reverseChannel = FlutterMethodChannel(
            name: reverseChannelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = XBridgePlugin()
        instance.channel = channel
        instance.reverseChannel = reverseChannel
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

        // 安全收紧（fail-closed + 能力级鉴权）：
        // 1) origin 未设置（nil）直接拒绝 —— 与同步 bypass 路径一致，
        //    避免异步 MethodChannel 在未授权 origin 下被放行，架空 denyAll 兜底。
        // 2) origin 必须通过 `allows` 来源级校验。
        // 3) 再通过 `isMethodAllowed` 能力级校验（publicMethods / originMethodRules），
        //    使异步通道与同步路径具备同等 gates。
        if origin == nil
            || !securityPolicy.allows(origin: origin)
            || !securityPolicy.isMethodAllowed(origin: origin, method: method)
        {
            result(FlutterError(
                code: "ORIGIN_NOT_ALLOWED",
                message: "Origin '\(origin ?? "nil")' is not permitted by the security policy for method '\(method)'",
                details: nil
            ))
            return
        }

        // With @MainActor, this method is already isolated to the main thread.
        let value = nativeBridge.invoke(method: method, params: params)
        result(value)
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

        case "xbridge.isWsRunning":
            result(LocalWsServerBridge.shared.isRunning)

        case "xbridge.getWsEndpoint":
            result(LocalWsServerBridge.shared.endpoint)

        // ── Security policy push (defense-in-depth) ──
        case "xbridge.setSecurityPolicy":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(
                    code: "INVALID_ARGUMENTS",
                    message: "Expected {allowedOrigins: [String], allowAll: Bool, publicMethods: [String], originMethodRules: [String: [String]]}",
                    details: nil
                ))
                return
            }

            let allowAll = args["allowAll"] as? Bool ?? false
            var origins: Set<String> = []
            if let originArray = args["allowedOrigins"] as? [String] {
                origins = Set(originArray)
            }

            var publicMethods: Set<String> = []
            if let pubArray = args["publicMethods"] as? [String] {
                publicMethods = Set(pubArray)
            }

            var originMethodRules: [String: Set<String>] = [:]
            if let rulesMap = args["originMethodRules"] as? [String: [String]] {
                for (origin, methods) in rulesMap {
                    originMethodRules[origin] = Set(methods)
                }
            }

            if allowAll {
                self.securityPolicy = .allowAll()
            } else {
                self.securityPolicy = .capabilities(
                    allowedOrigins: origins,
                    publicMethods: publicMethods,
                    originMethodRules: originMethodRules
                )
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
