// SPDX-License-Identifier: MIT
//
// XBridgeSecurityPolicy.swift
// XBridgeiOS
//
// Created by XBridge SDK on 2024-01-01.
//

import Foundation

/// A security policy that controls which origins are allowed to use the
/// native bridge.
///
/// This is a **defense-in-depth** layer. The primary security gate lives on
/// the Flutter side (`WebViewBridgePolicy` in `xbridge_flutter`). This native
/// policy can be applied as an additional check when the app intercepts
/// URL loading or evaluates bridge calls.
///
/// Example:
/// ```swift
/// let policy = XBridgeSecurityPolicy.allowlist(["https://app.example.com"])
/// // Later:
/// if policy.allows(origin: "https://app.example.com") {
///     // permit bridge call
/// }
/// ```
public struct XBridgeSecurityPolicy {

    /// The set of allowed origins (e.g. `"https://app.example.com"`).
    public let allowedOrigins: Set<String>

    /// If `true`, all origins are permitted (useful for development).
    public let allowAll: Bool

    /// Private initializer — use the static factory methods.
    private init(allowedOrigins: Set<String>, allowAll: Bool) {
        self.allowedOrigins = allowedOrigins
        self.allowAll = allowAll
    }

    // MARK: - Factory methods

    /// Create a policy that permits all origins.
    /// - Warning: Use only in development environments.
    public static func allowAll() -> XBridgeSecurityPolicy {
        return XBridgeSecurityPolicy(allowedOrigins: [], allowAll: true)
    }

    /// Create a policy that permits only the specified origins.
    public static func allowlist(_ origins: Set<String>) -> XBridgeSecurityPolicy {
        return XBridgeSecurityPolicy(allowedOrigins: origins, allowAll: false)
    }

    // MARK: - Evaluation

    /// Check if the given origin is allowed by this policy.
    ///
    /// - Parameter origin: The origin string (e.g. `"https://app.example.com"`).
    /// - Returns: `true` if the origin is permitted.
    public func allows(origin: String) -> Bool {
        if allowAll {
            return true
        }
        return allowedOrigins.contains(origin)
    }
}
