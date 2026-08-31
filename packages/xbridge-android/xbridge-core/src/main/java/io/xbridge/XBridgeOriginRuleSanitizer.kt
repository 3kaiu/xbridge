package io.xbridge

/**
 * Sanitizes and validates origin rules for AndroidX `WebViewCompat.addWebMessageListener`
 * to prevent `IllegalArgumentException` caused by non-compliant origin strings.
 *
 * Chromium `allowedOriginRules` grammar requirements:
 * - Scheme: `"http"`, `"https"`, or `"file"`
 * - Host: exact hostname or wildcard prefix (e.g. `"*.example.com"`)
 * - Must NOT contain paths, query parameters, fragments, or trailing slashes.
 */
object XBridgeOriginRuleSanitizer {

    /**
     * Sanitize a collection of raw origin patterns into valid origin rules.
     * Invalid or malformed entries are omitted safely.
     */
    fun sanitizeRules(rawOrigins: Collection<String>): Set<String> {
        val sanitized = mutableSetOf<String>()
        for (raw in rawOrigins) {
            val rule = sanitizeSingleRule(raw)
            if (rule != null) {
                sanitized.add(rule)
            }
        }
        return sanitized
    }

    /**
     * Sanitize a single origin rule string. Returns `null` if the rule is invalid or unsafe.
     */
    fun sanitizeSingleRule(raw: String): String? {
        var s = raw.trim()
        if (s.isEmpty() || s == "null") return null
        if (s == "*") return "*"

        // Strip trailing slashes
        while (s.endsWith("/")) {
            s = s.dropLast(1)
        }

        // Must contain valid scheme://
        val schemeIdx = s.indexOf("://")
        if (schemeIdx == -1) return null

        val scheme = s.substring(0, schemeIdx).lowercase()
        if (scheme != "http" && scheme != "https" && scheme != "file") return null

        val hostAndPort = s.substring(schemeIdx + 3)
        if (hostAndPort.isEmpty()) return null

        // Ensure no path, query, or fragment is present
        if (hostAndPort.contains("/") || hostAndPort.contains("?") || hostAndPort.contains("#")) {
            return null
        }

        return "$scheme://$hostAndPort"
    }
}
