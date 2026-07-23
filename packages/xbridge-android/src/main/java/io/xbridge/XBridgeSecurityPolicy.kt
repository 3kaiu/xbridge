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
        return allowedOrigins.any { normalizeOrigin(it) == normalized }
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
