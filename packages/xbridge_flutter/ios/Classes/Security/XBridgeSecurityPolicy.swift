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

    /// Globally accessible public methods (e.g. `"getAppInfo"`) that any allowed origin can invoke.
    public let publicMethods: Set<String>

    /// Granular method rules mapped by origin pattern.
    public let originMethodRules: [String: Set<String>]

    /// If `true`, all origins are permitted (useful for development).
    public let allowAll: Bool

    /// Pre-normalized origin method rules for fast lookups.
    private let normalizedOriginMethodRules: [String: Set<String>]

    /// Initializer with capability support.
    public init(
        allowedOrigins: Set<String> = [],
        allowAll: Bool = false,
        publicMethods: Set<String> = [],
        originMethodRules: [String: Set<String>] = [:]
    ) {
        self.allowedOrigins = Set(allowedOrigins.map(XBridgeSecurityPolicy.normalizeOrigin))
        self.allowAll = allowAll
        self.publicMethods = publicMethods
        self.originMethodRules = originMethodRules

        var normalizedRules: [String: Set<String>] = [:]
        for (origin, methods) in originMethodRules {
            normalizedRules[XBridgeSecurityPolicy.normalizeOrigin(origin)] = methods
        }
        self.normalizedOriginMethodRules = normalizedRules
    }

    // MARK: - Factory methods

    /// Create a policy that denies all origins — secure default.
    /// Use `allowAll()` for development or `allowlist(_:)` for production.
    public static func denyAll() -> XBridgeSecurityPolicy {
        return XBridgeSecurityPolicy(allowedOrigins: [], allowAll: false)
    }

    /// Create a policy that permits all origins.
    /// - Warning: Use only in development environments.
    public static func allowAll() -> XBridgeSecurityPolicy {
        return XBridgeSecurityPolicy(allowedOrigins: [], allowAll: true)
    }

    /// Create a policy that permits only the specified origins.
    public static func allowlist(_ origins: Set<String>) -> XBridgeSecurityPolicy {
        return XBridgeSecurityPolicy(allowedOrigins: origins, allowAll: false)
    }

    /// Create a capability-based policy with granular method-level permissions.
    public static func capabilities(
        allowedOrigins: Set<String>,
        publicMethods: Set<String> = [],
        originMethodRules: [String: Set<String>] = [:]
    ) -> XBridgeSecurityPolicy {
        return XBridgeSecurityPolicy(
            allowedOrigins: allowedOrigins,
            allowAll: false,
            publicMethods: publicMethods,
            originMethodRules: originMethodRules
        )
    }

    // MARK: - Origin normalization

    /// Normalize an origin string for comparison.
    ///
    /// Trims whitespace, lowercases, strips trailing slashes, and strips
    /// default ports (443 for https, 80 for http) so that
    /// `"https://app.example.com:443/"` and `"https://app.example.com"` match.
    static func normalizeOrigin(_ origin: String) -> String {
        var value = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasPrefix("https://") {
            let host = String(value.dropFirst("https://".count))
            value = host.hasSuffix(":443")
                ? "https://\(String(host.dropLast(":443".count)))"
                : "https://\(host)"
        } else if value.hasPrefix("http://") {
            let host = String(value.dropFirst("http://".count))
            value = host.hasSuffix(":80")
                ? "http://\(String(host.dropLast(":80".count)))"
                : "http://\(host)"
        }
        return value
    }

    // MARK: - Evaluation

    /// Check if the given origin is allowed by this policy.
    ///
    /// - Parameter origin: The origin string (e.g. `"https://app.example.com"`),
    ///   or `nil` when the origin is unknown. `nil` is always rejected.
    /// - Returns: `true` if the origin is permitted.
    public func allows(origin: String?) -> Bool {
        if allowAll {
            return true
        }
        guard let origin = origin else {
            return false
        }
        // Reject "null" origin (sandboxed iframes, data: URIs) and wildcard "*"
        // to match the Rust WS server's security checks.
        if origin == "null" || origin == "*" {
            return false
        }
        let normalized = XBridgeSecurityPolicy.normalizeOrigin(origin)
        if allowedOrigins.contains(normalized) {
            return true
        }
        return allowedOrigins.contains { pattern in
            XBridgeSecurityPolicy.matchesPattern(pattern: pattern, actual: normalized)
        }
    }

    /// Check if the given origin is permitted to invoke the specific method.
    public func isMethodAllowed(origin: String?, method: String) -> Bool {
        if allowAll {
            return true
        }
        guard allows(origin: origin) else {
            return false
        }
        if publicMethods.contains(method) {
            return true
        }
        if originMethodRules.isEmpty {
            return true
        }
        guard let origin = origin else {
            return false
        }
        let normalized = XBridgeSecurityPolicy.normalizeOrigin(origin)
        for (pattern, methods) in normalizedOriginMethodRules {
            if pattern == normalized || XBridgeSecurityPolicy.matchesPattern(pattern: pattern, actual: normalized) {
                if methods.contains(method) || methods.contains("*") {
                    return true
                }
            }
        }
        return false
    }

    /// Safely match pattern with wildcard support (e.g. `"https://*.example.com"`).
    /// Adheres to strict DNS label boundaries to prevent suffix-match spoofing.
    static func matchesPattern(pattern: String, actual: String) -> Bool {
        if pattern == actual {
            return true
        }
        guard let patternSchemeRange = pattern.range(of: "://"),
              let actualSchemeRange = actual.range(of: "://") else {
            return false
        }
        let patternScheme = pattern[..<patternSchemeRange.lowerBound]
        let actualScheme = actual[..<actualSchemeRange.lowerBound]
        if patternScheme != actualScheme {
            return false
        }
        let patternHost = pattern[patternSchemeRange.upperBound...]
        let actualHost = actual[actualSchemeRange.upperBound...]

        if patternHost.hasPrefix("*.") {
            let rootDomain = patternHost.dropFirst(2)
            if actualHost == rootDomain {
                return true
            }
            if actualHost.hasSuffix("." + rootDomain) {
                return true
            }
        }
        return false
    }
}
