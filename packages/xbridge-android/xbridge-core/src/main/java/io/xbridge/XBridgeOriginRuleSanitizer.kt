package io.xbridge

// NOTE (架构治理): 本文件是存量独立工具，属于 xbridge-android（JitPack SDK）。
// 它既不被 xbridge_flutter 引用，也未进入 src/main/kotlin 副本的同步契约
// （见 scripts/sync_native_to_flutter.sh 的白名单映射）。
// 当前仓库内部无任何调用方，仅保留以兼容可能的外部 JitPack 消费者；
// 若无外部依赖，建议在下一次大版本移除。
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
