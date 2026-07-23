package io.xbridge

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import org.json.JSONObject

/**
 * `@JavascriptInterface` injected into the WebView as `XBridgeSync`.
 *
 * This provides the **sync bypass** channel (audit Risk 1): H5 code that
 * requires a truly synchronous return value (blocking until the native
 * handler completes) calls `window.XBridgeSync.callSync(method, paramsJson)`
 * instead of going through the async Flutter MethodChannel.
 *
 * ## Threading
 *
 * Android `@JavascriptInterface` methods execute on a private WebKit thread,
 * not the UI thread. Many legacy native bridge handlers require the UI thread
 * (they touch `Activity`, `WebView`, etc.). To satisfy both:
 *
 * 1. If the current thread IS the main thread, invoke the delegate directly.
 * 2. If off-main, post to the main thread and block with a [CountDownLatch]
 *    until the result (or exception) is captured. The latch has a 3-second
 *    timeout to avoid infinite hangs.
 *
 * ## Return format
 *
 * Returns a JSON string: `{"result": <value>}` on success,
 * `{"error": {"code": "...", "message": "..."}}` on failure. This matches
 * the contract expected by `xbridge-js`'s `callSync` adapter.
 *
 * ## Security
 *
 * The [XBridgeSecurityPolicy] is checked if the origin can be determined.
 * In practice, the Flutter `BridgeController` is the primary security gate;
 * this native check is defense-in-depth for the sync bypass path.
 */
class XBridgeSyncInterface(
    private val nativeBridgeProvider: () -> XBridgeNativeBridge?,
    private val securityPolicyProvider: () -> XBridgeSecurityPolicy,
    private val originProvider: () -> String? = { null },
) {

    companion object {
        private const val TAG = "XBridgeSync"
        private const val SYNC_TIMEOUT_SECONDS = 1L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Inject this interface into [webView] under the name `XBridgeSync`.
     * H5 code calls `window.XBridgeSync.callSync(method, paramsJson)`.
     *
     * **Security note**: Android's `addJavascriptInterface` exposes the
     * object to **all frames**, including subframes and iframes. Unlike
     * iOS's `forMainFrameOnly: true`, there is no API to restrict to the
     * main frame. The [securityPolicyProvider] and [originProvider] checks
     * in [callSync] are the mitigation — they evaluate the main frame's
     * origin (set via `XBridgePluginRegistry.setOrigin`). Apps should also
     * override `WebViewClient.shouldOverrideUrlLoading` to block navigation
     * to untrusted origins.
     */
    fun attach(webView: WebView) {
        webView.addJavascriptInterface(this, "XBridgeSync")
        Log.i(TAG, "XBridgeSync interface attached to WebView (exposed to all frames — origin check is the mitigation)")
    }

    /**
     * H5 probes this to know whether the sync bypass is available.
     * Returns `true` when a [XBridgeNativeBridge] delegate is set.
     */
    @JavascriptInterface
    fun isAvailable(): Boolean {
        return nativeBridgeProvider() != null
    }

    /**
     * Synchronously invoke a native bridge method and return the result as
     * a JSON string.
     *
     * @param method     The business method name (e.g. `"getAppInfo"`).
     * @param paramsJson JSON-encoded parameters (or empty string for none).
     * @return JSON string `{"result": ...}` or `{"error": {code, message}}`.
     */
    @JavascriptInterface
    fun callSync(method: String, paramsJson: String): String {
        // Validate method before any other processing.
        if (method.isBlank()) {
            return errorJson("INVALID_METHOD", "Method name must be a non-empty string")
        }

        val bridge = nativeBridgeProvider()
        if (bridge == null) {
            return errorJson("NO_NATIVE_BRIDGE", "XBridgeNativeBridge not set")
        }

        // Security policy check (defense-in-depth).
        val policy = securityPolicyProvider()
        val origin = originProvider()
        if (!policy.allows(origin)) {
            return errorJson(
                "ORIGIN_NOT_ALLOWED",
                "Origin '$origin' is not permitted by the security policy",
            )
        }

        // Parse paramsJson — empty or null string means null params.
        val params: Any? = if (paramsJson.isBlank() || paramsJson == "null") {
            null
        } else {
            try {
                jsonParse(paramsJson)
            } catch (e: Exception) {
                return errorJson("PARAMS_PARSE_ERROR", e.message ?: "Failed to parse params JSON")
            }
        }

        // If we're already on the main thread, invoke directly.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return invokeAndWrap(bridge, method, params)
        }

        // Off-main: dispatch to main thread and block with a latch.
        val latch = java.util.concurrent.CountDownLatch(1)
        val resultHolder = arrayOfNulls<Any>(1) // [resultJson | Exception]

        mainHandler.post {
            try {
                resultHolder[0] = invokeAndWrap(bridge, method, params)
            } catch (e: Throwable) {
                resultHolder[0] = e
            } finally {
                latch.countDown()
            }
        }

        try {
            if (!latch.await(SYNC_TIMEOUT_SECONDS, java.util.concurrent.TimeUnit.SECONDS)) {
                return errorJson(
                    "SYNC_TIMEOUT",
                    "Native bridge did not respond within ${SYNC_TIMEOUT_SECONDS}s",
                )
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            return errorJson("SYNC_INTERRUPTED", "Thread interrupted while waiting for native bridge")
        }

        // Unpack the result holder.
        val outcome = resultHolder[0]
        return when (outcome) {
            is Throwable -> errorJson("NATIVE_BRIDGE_ERROR", outcome.message ?: "Unknown error")
            is String -> outcome
            else -> errorJson("UNKNOWN_RESULT", "Native bridge returned an unexpected result type")
        }
    }

    // ── Internal helpers ───────────────────────────────────────────────────

    private fun invokeAndWrap(bridge: XBridgeNativeBridge, method: String, params: Any?): String {
        return try {
            val value = bridge.invoke(method, params)
            successJson(value)
        } catch (e: Throwable) {
            Log.e(TAG, "callSync '$method' failed", e)
            errorJson("NATIVE_BRIDGE_ERROR", e.message ?: "Unknown error")
        }
    }

    /**
     * Wrap a successful result into `{"result": <value>}`.
     * Non-JSON-serializable values are converted to strings.
     */
    private fun successJson(value: Any?): String {
        val json = JSONObject()
        // JSONObject.wrap handles Map, List, Array, primitives, null.
        json.put("result", jsonWrap(value))
        return json.toString()
    }

    private fun errorJson(code: String, message: String): String {
        val json = JSONObject()
        val err = JSONObject()
        err.put("code", code)
        err.put("message", message)
        json.put("error", err)
        return json.toString()
    }

    // ── JSON helpers ───────────────────────────────────────────────────────

    /**
     * Parse a JSON string into a Kotlin object: JSONObject → Map, JSONArray
     * → List, primitives → their boxed types.
     */
    private fun jsonParse(json: String): Any? {
        val trimmed = json.trim()
        return if (trimmed.startsWith("{")) {
            jsonToMap(org.json.JSONObject(trimmed))
        } else if (trimmed.startsWith("[")) {
            jsonToList(org.json.JSONArray(trimmed))
        } else {
            // Primitive literal — wrap in a JSON object so that org.json
            // handles all escape sequences (\n, \", \\, \/, etc.) correctly
            // instead of naively trimming quotes.
            org.json.JSONObject("{\"v\":$trimmed}").get("v")
        }
    }

    private fun jsonToMap(jo: org.json.JSONObject): Map<String, Any?> {
        val map = HashMap<String, Any?>()
        val keys = jo.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            map[key] = jsonUnwrap(jo.get(key))
        }
        return map
    }

    private fun jsonToList(ja: org.json.JSONArray): List<Any?> {
        val list = ArrayList<Any?>(ja.length())
        for (i in 0 until ja.length()) {
            list.add(jsonUnwrap(ja.get(i)))
        }
        return list
    }

    private fun jsonUnwrap(value: Any): Any? {
        return when (value) {
            is org.json.JSONObject -> jsonToMap(value)
            is org.json.JSONArray -> jsonToList(value)
            org.json.JSONObject.NULL -> null
            else -> value
        }
    }

    /**
     * Wrap a Kotlin value into a JSON-safe type for [JSONObject.put].
     */
    private fun jsonWrap(value: Any?): Any? {
        if (value == null) return JSONObject.NULL
        return when (value) {
            is Boolean, is Int, is Long, is Double, is String -> value
            is Float -> value.toDouble()
            is Short, is Byte -> value.toInt()
            is Char -> value.toString()
            is Map<*, *> -> {
                val jo = org.json.JSONObject()
                for ((k, v) in value) {
                    jo.put(k.toString(), jsonWrap(v))
                }
                jo
            }
            is List<*> -> {
                val ja = org.json.JSONArray()
                for (item in value) {
                    ja.put(jsonWrap(item))
                }
                ja
            }
            is Array<*> -> {
                val ja = org.json.JSONArray()
                for (item in value) {
                    ja.put(jsonWrap(item))
                }
                ja
            }
            is ByteArray -> {
                val ja = org.json.JSONArray()
                for (b in value) {
                    ja.put(b.toInt() and 0xFF)
                }
                ja
            }
            else -> org.json.JSONObject.valueToString(value)
        }
    }
}
