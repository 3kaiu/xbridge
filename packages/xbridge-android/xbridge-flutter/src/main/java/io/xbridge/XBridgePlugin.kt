package io.xbridge

import android.util.Log
import io.xbridge.plugin.XBridgePluginRegistry
import io.xbridge.ws.LocalWsServerJni
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
/**
 * Flutter plugin that receives unregistered bridge methods forwarded from
 * the Flutter [BridgeController] via the `MethodChannel('xbridge/native_fallback')`.
 *
 * ## How the fallback channel works
 *
 * On the Flutter side, `FallbackChannel.invoke(method, params)` calls
 * `_channel.invokeMethod(method, params)` — so `call.method` on the native
 * side IS the business method name (e.g. `"someMethod"`, not `"invoke"`).
 *
 * This plugin therefore forwards **every** method call to the
 * [XBridgeNativeBridge] delegate, unless the method name is a reserved
 * XBridge control call (prefixed with `"xbridge."`).
 *
 * ## Reserved control methods
 *
 * - `xbridge.setupLocalWebSocket` — `arguments["port"] : Int` → starts the
 *   Rust local WS server, returns the actual bound port (`Int`).
 * - `xbridge.teardownLocalWebSocket` — stops the WS server.
 * - `xbridge.setSecurityPolicy` — `arguments["allowedOrigins"] : List<String>`,
 *   `arguments["allowAll"] : Boolean` → stores the policy.
 *
 * All other method names are forwarded verbatim to [nativeBridge].
 */
class XBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "XBridgePlugin"
        const val CHANNEL = "xbridge/native_fallback"

        const val REVERSE_CHANNEL = "xbridge/native_reverse"

        /** Prefix for XBridge-internal control calls (never forwarded). */
        private const val CONTROL_PREFIX = "xbridge."

        /**
         * Fixed reverse-channel method that Native uses to broadcast an event
         * to H5. The real event name lives in `arguments["method"]` (and `params`
         * in `arguments["params"]`), NOT in the method-name prefix, so no
         * business method name can collide with the event namespace.
         */
        const val EVENT_METHOD = "pushEvent"

        private const val CTRL_SETUP_WS = "xbridge.setupLocalWebSocket"
        private const val CTRL_TEARDOWN_WS = "xbridge.teardownLocalWebSocket"
        private const val CTRL_SET_POLICY = "xbridge.setSecurityPolicy"
        private const val CTRL_IS_WS_RUNNING = "xbridge.isWsRunning"
        private const val CTRL_GET_WS_ENDPOINT = "xbridge.getWsEndpoint"
    }

    @Volatile
    private var nativeBridge: XBridgeNativeBridge? = null
    @Volatile
    private var securityPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.denyAll().also {
        Log.w(TAG, "XBridge security policy defaults to denyAll — set an explicit allowlist via setSecurityPolicy() before accepting bridge calls")
    }
    @Volatile
    private var origin: String? = null
    @Volatile
    private var methodChannel: MethodChannel? = null
    @Volatile
    private var reverseChannel: MethodChannel? = null

    /// Cached port of the running WS server, or -1 if not running.
    @Volatile
    private var wsPort: Int = -1

    // ── Configuration ──────────────────────────────────────────────────────

    /**
     * Set the [XBridgeNativeBridge] delegate that the app provides to forward
     * calls to its legacy native bridge (e.g. your existing native bridge). Must be called before
     * any method call arrives, or calls will error with `NO_NATIVE_BRIDGE`.
     */
    fun setNativeBridge(bridge: XBridgeNativeBridge?) {
        this.nativeBridge = bridge
    }

    /**
     * Set the [XBridgeSecurityPolicy] directly (in addition to the
     * `xbridge.setSecurityPolicy` MethodChannel call).
     */
    fun setSecurityPolicy(policy: XBridgeSecurityPolicy) {
        this.securityPolicy = policy
    }

    /**
     * Set the current page origin (URL) for security policy checks.
     * Called when the WebView navigates to a new page so that bridge
     * calls can be authorized against [XBridgeSecurityPolicy].
     */
    fun setOrigin(url: String?) {
        this.origin = url
    }

    // ── Reverse calls (Native → Flutter / H5) ────────────────────────────────

    /**
     * Invoke a method registered on Flutter or H5 asynchronously from Native.
     */
    fun callH5(method: String, params: Any?, result: MethodChannel.Result? = null) {
        val rc = reverseChannel
        if (rc == null) {
            Log.w(TAG, "callH5('$method') dropped: reverse channel is null (not attached to engine)")
            return
        }
        rc.invokeMethod(method, params, result)
    }

    /**
     * Broadcast an event from Native to H5.
     *
     * Delivered as a fixed method name (`pushEvent`) with the real event name
     * carried in the arguments map — not encoded into the method-name prefix —
     * so a business method can never collide with the event-marker namespace.
     */
    fun pushEvent(method: String, params: Any?) {
        val rc = reverseChannel
        if (rc == null) {
            Log.w(TAG, "pushEvent('$method') dropped: reverse channel is null (not attached to engine)")
            return
        }
        rc.invokeMethod(EVENT_METHOD, mapOf("method" to method, "params" to params))
    }

    // ── FlutterPlugin lifecycle ────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        reverseChannel = MethodChannel(binding.binaryMessenger, REVERSE_CHANNEL)
        Log.i(TAG, "Attached to Flutter engine, listening on channel '$CHANNEL' and '$REVERSE_CHANNEL'")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        reverseChannel = null
        Log.i(TAG, "Detached from Flutter engine")
    }

    // ── MethodCallHandler ──────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method

        // Intercept XBridge control calls.
        if (method.startsWith(CONTROL_PREFIX)) {
            handleControlCall(call, result)
            return
        }

        // All other methods are business calls forwarded from Flutter
        // FallbackChannel — route to the native bridge delegate.

        // Security policy check (defense-in-depth).
        // Snapshot both volatile fields once to avoid TOCTOU: reading
        // securityPolicy and origin separately could interleave with a
        // concurrent setSecurityPolicy/setOrigin call, checking a stale
        // policy against a new origin or vice versa.
        val policy = securityPolicy
        val currentOrigin = origin
        // 安全收紧（fail-closed + 能力级鉴权）：
        // 1) origin 未设置（null）直接拒绝，避免异步 MethodChannel 在未授权
        //    origin 下被放行，架空原生 denyAll 兜底。
        // 2) origin 必须通过 `allows` 的来源级校验。
        // 3) 再通过 `isMethodAllowed` 能力级校验（publicMethods / originMethodRules），
        //    使异步通道具备能力级 gates，而非仅判来源。
        if (currentOrigin == null ||
            !policy.allows(currentOrigin) ||
            !policy.isMethodAllowed(currentOrigin, method)
        ) {
            result.error(
                "ORIGIN_NOT_ALLOWED",
                "Origin '$currentOrigin' is not permitted by the security policy for method '$method'",
                null,
            )
            return
        }

        val bridge = nativeBridge
        if (bridge == null) {
            result.error("NO_NATIVE_BRIDGE", "XBridgeNativeBridge not set", null)
            return
        }

        try {
            val value = bridge.invoke(method, call.arguments)
            result.success(value)
        } catch (e: Exception) {
            // Catch Exception (not Throwable) so serious JVM errors like
            // OutOfMemoryError or StackOverflowError propagate instead of
            // being masked as bridge errors.
            Log.e(TAG, "Native bridge invoke '$method' failed", e)
            result.error(
                "NATIVE_BRIDGE_ERROR",
                e.message ?: "Unknown error",
                null,
            )
        }
    }

    // ── Control call dispatch ───────────────────────────────────────────────

    private fun handleControlCall(call: MethodCall, result: MethodChannel.Result) {
        // Control calls are Flutter-internal (only reachable via MethodChannel,
        // not from H5/WebView). They are trusted and do not go through the
        // security policy check — the policy gates business calls only.
        // The WS server itself is protected by the Rust-side origin allowlist.
        when (call.method) {
            CTRL_SETUP_WS -> {
                // When Flutter calls invokeMethod("xbridge.setupLocalWebSocket", {"port": 0}),
                // call.arguments IS the map itself.
                val port = call.argument<Int>("port") ?: 0
                try {
                    val actualPort = LocalWsServerJni.start(port)
                    if (actualPort < 0) {
                        result.error(
                            "WS_START_FAILED",
                            "LocalWsServerJni.start returned $actualPort — " +
                                "is libxbridge_core.so loaded?",
                            null,
                        )
                    } else {
                        wsPort = actualPort
                        result.success(actualPort)
                    }
                } catch (e: UnsatisfiedLinkError) {
                    result.error(
                        "WS_NATIVE_NOT_LINKED",
                        "libxbridge_core.so not loaded: ${e.message}",
                        null,
                    )
                } catch (e: Throwable) {
                    result.error("WS_START_ERROR", e.message, null)
                }
            }

            CTRL_TEARDOWN_WS -> {
                try {
                    val code = LocalWsServerJni.stop()
                    wsPort = -1
                    result.success(code)
                } catch (e: UnsatisfiedLinkError) {
                    result.error(
                        "WS_NATIVE_NOT_LINKED",
                        "libxbridge_core.so not loaded: ${e.message}",
                        null,
                    )
                } catch (e: Throwable) {
                    result.error("WS_STOP_ERROR", e.message, null)
                }
            }

            CTRL_IS_WS_RUNNING -> {
                result.success(wsPort >= 0)
            }

            CTRL_GET_WS_ENDPOINT -> {
                if (wsPort >= 0) {
                    result.success("ws://127.0.0.1:$wsPort")
                } else {
                    result.success(null)
                }
            }

            CTRL_SET_POLICY -> {
                val origins = call.argument<List<String>>("allowedOrigins") ?: emptyList()
                val allowAll = call.argument<Boolean>("allowAll") ?: false
                val publicMethods = call.argument<List<String>>("publicMethods") ?: emptyList()
                val rulesRaw = call.argument<Map<String, List<String>>>("originMethodRules") ?: emptyMap()
                val originMethodRules = rulesRaw.mapValues { it.value.toSet() }

                val newPolicy = XBridgeSecurityPolicy(
                    allowedOrigins = origins.toSet(),
                    allowAll = allowAll,
                    publicMethods = publicMethods.toSet(),
                    originMethodRules = originMethodRules,
                )
                securityPolicy = newPolicy
                // Keep XBridgePluginRegistry in sync so the async bridge path
                // uses the same policy as the plugin instance.
                XBridgePluginRegistry.updateSecurityPolicy(newPolicy)
                Log.i(TAG, "Security policy updated: allowAll=$allowAll, origins=${origins.size}, publicMethods=${publicMethods.size}")
                result.success(null)
            }

            else -> {
                result.notImplemented()
            }
        }
    }
}
