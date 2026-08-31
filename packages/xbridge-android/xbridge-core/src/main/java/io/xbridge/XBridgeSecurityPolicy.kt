package io.xbridge

/**
 * Security policy for XBridge bridge calls — a defense-in-depth origin
 * allowlist that supplements the Flutter-side [WebViewBridgePolicy].
 *
 * The **primary** security gate lives in the Flutter `BridgeController`,
 * which checks the page origin before dispatching. This native policy is a
 * secondary check for calls that arrive via the sync bypass
 * ([XBridgeSyncInterface]) or directly via the fallback MethodChannel.
 *
 * @property allowedOrigins  Set of allowed origins (e.g.
 *                            `setOf("https://app.example.com")`).
 * @property allowAll         If `true`, all origins are allowed (use for
 *                            development only).
 */
data class XBridgeSecurityPolicy(
    val allowedOrigins: Set<String> = emptySet(),
    val allowAll: Boolean = false,
    val publicMethods: Set<String> = emptySet(),
    val originMethodRules: Map<String, Set<String>> = emptyMap(),
) {
    companion object {
        /** Deny all origins — secure default. Use allowAll() for development only. */
        fun denyAll(): XBridgeSecurityPolicy = XBridgeSecurityPolicy(allowedOrigins = emptySet(), allowAll = false)

        /** Allow all origins — development convenience. */
        fun allowAll(): XBridgeSecurityPolicy = XBridgeSecurityPolicy(allowAll = true)

        /** Restrict to an explicit allowlist of origins. */
        fun allowlist(origins: Set<String>): XBridgeSecurityPolicy =
            XBridgeSecurityPolicy(allowedOrigins = origins, allowAll = false)

        /** Default: deny all origins except those in the allowlist. */
        fun allowlist(vararg origins: String): XBridgeSecurityPolicy =
            allowlist(origins.toSet())

        /** Capability-based security policy with granular method-level permissions. */
        fun capabilities(
            allowedOrigins: Set<String>,
            publicMethods: Set<String> = emptySet(),
            originMethodRules: Map<String, Set<String>> = emptyMap(),
        ): XBridgeSecurityPolicy = XBridgeSecurityPolicy(
            allowedOrigins = allowedOrigins,
            allowAll = false,
            publicMethods = publicMethods,
            originMethodRules = originMethodRules,
        )
    }

    /**
     * Returns `true` if [origin] is permitted by this policy.
     * An empty allowlist with `allowAll = false` denies everything.
     *
     * Origin comparison is case-insensitive and ignores trailing slashes
     * and default ports (80 for http, 443 for https) to avoid false
     * rejections from minor URL formatting differences.
     */
    fun allows(origin: String?): Boolean {
        if (allowAll) return true
        if (origin == null) return false
        // Reject "null" origin (sandboxed iframes, data: URIs) and wildcard "*"
        // to match the Rust WS server's security checks.
        if (origin == "null" || origin == "*") return false
        val normalized = normalizeOrigin(origin)
        return allowedOrigins.any { pattern ->
            val normPattern = normalizeOrigin(pattern)
            normPattern == normalized || matchesPattern(normPattern, normalized)
        }
    }

    /**
     * Returns `true` if [origin] is allowed to invoke the specific [method].
     */
    fun isMethodAllowed(origin: String?, method: String): Boolean {
        if (allowAll) return true
        if (!allows(origin)) return false
        if (publicMethods.contains(method)) return true
        if (originMethodRules.isEmpty()) return true
        if (origin == null) return false

        val normalized = normalizeOrigin(origin)
        for ((pattern, methods) in originMethodRules) {
            val normPattern = normalizeOrigin(pattern)
            if (normPattern == normalized || matchesPattern(normPattern, normalized)) {
                if (methods.contains(method) || methods.contains("*")) {
                    return true
                }
            }
        }
        return false
    }

    /**
     * Safely match pattern with wildcard support (e.g. `https://*.example.com`).
     * Adheres to strict DNS label boundaries to prevent suffix-match spoofing.
     */
    private fun matchesPattern(pattern: String, actual: String): Boolean {
        if (pattern == actual) return true
        val patternSchemeIndex = pattern.indexOf("://")
        val actualSchemeIndex = actual.indexOf("://")
        if (patternSchemeIndex == -1 || actualSchemeIndex == -1) return false

        val patternScheme = pattern.substring(0, patternSchemeIndex)
        val actualScheme = actual.substring(0, actualSchemeIndex)
        if (patternScheme != actualScheme) return false

        val patternHost = pattern.substring(patternSchemeIndex + 3)
        val actualHost = actual.substring(actualSchemeIndex + 3)

        if (patternHost.startsWith("*.")) {
            val rootDomain = patternHost.removePrefix("*.")
            if (actualHost == rootDomain) return true
            if (actualHost.endsWith(".$rootDomain")) return true
        }
        return false
    }

    /**
     * Normalize an origin string: lowercase, strip trailing slash, strip
     * default ports (443 for https, 80 for http).
     */
    private fun normalizeOrigin(origin: String): String {
        var o = origin.trim().lowercase()
        // Strip trailing slash
        while (o.endsWith("/")) {
            o = o.dropLast(1)
        }
        // Strip default ports
        o = o.removeSuffix(":443")
        if (o.startsWith("https://")) {
            o = o.removePrefix("https://")
            o = "https://${o.removeSuffix(":443")}"
        } else if (o.startsWith("http://")) {
            o = o.removePrefix("http://")
            o = "http://${o.removeSuffix(":80")}"
        }
        return o
    }
}
