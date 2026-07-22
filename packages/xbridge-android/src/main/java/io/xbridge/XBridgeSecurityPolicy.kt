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
     */
    fun allows(origin: String?): Boolean {
        if (allowAll) return true
        if (origin == null) return false
        return allowedOrigins.contains(origin)
    }
}
