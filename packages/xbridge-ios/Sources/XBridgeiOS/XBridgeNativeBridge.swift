// SPDX-License-Identifier: MIT
//
// XBridgeNativeBridge.swift
// XBridgeiOS
//
// Created by XBridge SDK on 2024-01-01.
//

import Foundation

/// A generic delegate protocol that the host app implements to forward
/// XBridge fallback calls to its existing bridge handler (e.g. your existing native bridge).
///
/// XBridge itself contains zero business logic. The app supplies an
/// implementation of this protocol that knows how to route `method` strings
/// to its existing native bridge plugin instance.
///
/// Usage:
/// ```swift
/// class MyBridgeAdapter: XBridgeNativeBridge {
///     func invoke(method: String, params: Any?) -> Any? {
///         // Forward to your existing bridge plugin handler
///         return existingBridge.call(method, args: params)
///     }
/// }
/// ```
public protocol XBridgeNativeBridge: AnyObject {
    /// Invoke a bridge method synchronously.
    ///
    /// - Parameters:
    ///   - method: The method name (e.g. `"getDeviceInfo"`, `"getAppInfo"`).
    ///   - params: Arbitrary parameters from the caller. May be nil.
    /// - Returns: The result value, or nil if the method has no return value.
    ///
    /// - Note: Implementations should be thread-safe. If the underlying
    ///   bridge handler requires the main thread, the implementation is
    ///   responsible for dispatching.
    func invoke(method: String, params: Any?) -> Any?
}
