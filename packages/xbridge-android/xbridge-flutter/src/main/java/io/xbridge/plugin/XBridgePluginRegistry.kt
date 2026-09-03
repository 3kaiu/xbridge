package io.xbridge.plugin

import io.flutter.embedding.engine.FlutterEngine
import io.xbridge.XBridgeNativeBridge
import io.xbridge.XBridgePlugin
import io.xbridge.XBridgeSecurityPolicy

/**
 * One-call registration helper for the host app's `MainActivity`.
 *
 * Typical usage in `MainActivity.configureFlutterEngine`:
 *
 * ```kotlin
 * override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
 *     super.configureFlutterEngine(flutterEngine)
 *     XBridgePluginRegistry.register(
 *         flutterEngine = flutterEngine,
 *         nativeBridge = YourBridgeAdapter(existingBridge), // app-provided
 *     )
 * }
 * ```
 *
 * The app provides the [XBridgeNativeBridge] implementation that forwards
 * to its existing native bridge handler — XBridge itself has zero business
 * coupling.
 *
 * **Note**: This registry holds a static reference to the [XBridgePlugin].
 * If the host app destroys and recreates the Flutter engine (e.g. on
 * configuration change), call [unregister] first, then [register] again.
 *
 * The bridge is strictly async JSON-RPC. H5 calls flow
 * `window.XBridge.postMessage` → JavaScriptChannel → Dart method handler →
 * this native bridge. No synchronous `@JavascriptInterface` bypass is used.
 */
object XBridgePluginRegistry {

    @Volatile
    private var plugin: XBridgePlugin? = null
    @Volatile
    private var currentBridge: XBridgeNativeBridge? = null
    @Volatile
    private var currentPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.denyAll()
    @Volatile
    private var currentOrigin: String? = null
    @Volatile
    private var attachedEngine: FlutterEngine? = null

    /**
     * Register the XBridge plugin.
     *
     * @param flutterEngine The Flutter engine to attach to.
     * @param nativeBridge  The app's delegate that forwards to the legacy
     *                      native bridge (e.g. your existing native bridge). May be `null` if
     *                      the app sets it later via [updateNativeBridge].
     * @param securityPolicy Initial security policy. Defaults to **deny-all**
     *                      for production safety; set `allowAll()` for development
     *                      or an allowlist for production.
     */
    @JvmOverloads
    fun register(
        flutterEngine: FlutterEngine,
        nativeBridge: XBridgeNativeBridge? = null,
        securityPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.denyAll(),
    ) {
        // If already registered with the same engine, no-op (prevents duplicate handlers).
        if (plugin != null && attachedEngine === flutterEngine) {
            // Update the bridge and policy in-place.
            currentBridge = nativeBridge
            currentPolicy = securityPolicy
            plugin?.setNativeBridge(nativeBridge)
            plugin?.setSecurityPolicy(securityPolicy)
            return
        }

        // If a previous registration is still active with a different engine,
        // auto-unregister first to avoid leaking the old Activity/WebView.
        val oldEngine = attachedEngine
        if (plugin != null && oldEngine != null && oldEngine !== flutterEngine) {
            android.util.Log.w(
                "XBridgePluginRegistry",
                "register() called with a new engine while a previous registration is active. " +
                    "Auto-unregistering the previous registration to avoid leaks.",
            )
            unregister(oldEngine!!)
        }

        currentBridge = nativeBridge
        currentPolicy = securityPolicy

        // Create a new plugin instance for this engine.
        val p = XBridgePlugin()
        plugin = p
        p.setNativeBridge(nativeBridge)
        p.setSecurityPolicy(securityPolicy)

        // FlutterEngine.plugins is a PluginRegistry. Calling add() with a
        // FlutterPlugin triggers onAttachedToEngine automatically.
        flutterEngine.plugins.add(p)
        attachedEngine = flutterEngine
    }

    /**
     * Update the [XBridgeNativeBridge] delegate after registration. Useful
     * when the legacy bridge is created asynchronously.
     */
    fun updateNativeBridge(nativeBridge: XBridgeNativeBridge?) {
        currentBridge = nativeBridge
        plugin?.setNativeBridge(nativeBridge)
    }

    /**
     * Update the [XBridgeSecurityPolicy] after registration.
     */
    fun updateSecurityPolicy(policy: XBridgeSecurityPolicy) {
        currentPolicy = policy
        plugin?.setSecurityPolicy(policy)
    }

    /**
     * Set the current page origin for security policy checks on
     * the [XBridgePlugin].
     */
    fun setOrigin(url: String?) {
        currentOrigin = url
        plugin?.setOrigin(url)
    }

    /**
     * Detach and clean up. Call from `MainActivity.onDestroy` or
     * `cleanUpFlutterEngine`.
     *
     * The plugin is only removed if [flutterEngine] is the same engine it was
     * registered against ([attachedEngine]). Passing a different engine is a
     * no-op: we must not tear down a plugin owned by another engine.
     */
    fun unregister(flutterEngine: FlutterEngine) {
        val attached = attachedEngine
        if (attached == null || attached !== flutterEngine) {
            android.util.Log.w(
                "XBridgePluginRegistry",
                "unregister() ignored: engine does not match the registered engine " +
                    "(expected ${attached?.hashCode() ?: "none"}, got ${flutterEngine.hashCode()}).",
            )
            return
        }
        plugin?.let {
            flutterEngine.plugins.remove(it.javaClass)
        }
        plugin = null
        currentBridge = null
        currentOrigin = null
        currentPolicy = XBridgeSecurityPolicy.denyAll()
        attachedEngine = null
    }
}