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
     *
     * 采用 **fail-closed** 语义：
     * - 只有显式白名单命中才放行——公共白名单 [publicMethods]，或按来源细分的
     *   [originMethodRules]（含通配 `*`）命中的方法。
     * - 其余一律拒绝。这删除了旧版「[originMethodRules] 为空即放行全部方法」的
     *   宽松兜底；否则只配置 [allowedOrigins] + [publicMethods] 时，来源被放行的
     *   页面仍可调用任意方法，能力级鉴权形同虚设。
     *
     * 注意：本实现**不包含 frame 归因**。Android 的 `addJavascriptInterface`
     * 会暴露给 WebView 的所有 frame，且平台不提供「校验调用 frame」的公开机制
     * （见 [XBridgeSyncInterface] 类 KDoc）。因此这里仅以 origin + method
     * allowlist 作为有效闸门；iOS 侧才具备 `frameInfo.isMainFrame` 的强归因。
     */
    fun isMethodAllowed(origin: String?, method: String): Boolean {
        if (allowAll) return true
        if (!allows(origin)) return false
        // 显式公共白名单命中即放行。
        if (publicMethods.contains(method)) return true
        // 按来源细分的方法规则；规则非空时才参与判决。
        if (originMethodRules.isNotEmpty()) {
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
        }
        // 未命中任何白名单：默认拒绝。
        return false
    }

    /**
     * Safely match pattern with wildcard support, e.g. a wildcard subdomain
     * such as a https URL whose host begins with "*." .
     * Adheres to strict DNS label boundaries to prevent suffix-match spoofing.
     * 注意：Kotlin K2 词法器会把「斜杠紧邻星号」的字符组当成嵌套块注释起始，
     * 若在注释里写出这类 URL 会导致 "Unclosed comment" 而无法编译，
     * 因此这里刻意用空格与反引号拆开，不直接写出该字符组。
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
