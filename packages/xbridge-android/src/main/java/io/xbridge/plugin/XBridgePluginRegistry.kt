package io.xbridge.plugin

import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.xbridge.XBridgeNativeBridge
import io.xbridge.XBridgePlugin
import io.xbridge.XBridgeSecurityPolicy
import io.xbridge.XBridgeSyncInterface

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
 *         webView = webView,
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
 */
object XBridgePluginRegistry {

    @Volatile
    private var plugin: XBridgePlugin? = null
    private var syncInterface: XBridgeSyncInterface? = null
    @Volatile
    private var currentBridge: XBridgeNativeBridge? = null
    @Volatile
    private var currentPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.allowAll()
    @Volatile
    private var currentOrigin: String? = null
    @Volatile
    private var attachedEngine: FlutterEngine? = null

    /**
     * Register the XBridge plugin and (optionally) the sync bypass interface.
     *
     * @param flutterEngine The Flutter engine to attach to.
     * @param nativeBridge  The app's delegate that forwards to the legacy
     *                      native bridge (e.g. your existing native bridge). May be `null` if
     *                      the app sets it later via [updateNativeBridge].
     * @param webView       Optional WebView to inject the `XBridgeSync`
     *                      `@JavascriptInterface` into. Pass `null` if the
     *                      sync bypass is not needed or the WebView is not
     *                      yet available — you can call [attachSyncInterface]
     *                      later once the WebView is ready.
     * @param securityPolicy Initial security policy. Defaults to `allowAll`
     *                      for development; set a real allowlist for production.
     */
    @JvmOverloads
    fun register(
        flutterEngine: FlutterEngine,
        nativeBridge: XBridgeNativeBridge? = null,
        webView: WebView? = null,
        securityPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.allowAll(),
    ) {
        currentBridge = nativeBridge
        currentPolicy = securityPolicy

        // Create or reuse the plugin instance.
        var p = plugin
        if (p == null) {
            p = XBridgePlugin()
            plugin = p
        }
        p.setNativeBridge(nativeBridge)
        p.setSecurityPolicy(securityPolicy)

        // If the plugin is already attached to a different engine,
        // remove it from the old engine first to avoid duplicate handlers.
        val oldEngine = attachedEngine
        if (oldEngine != null && oldEngine !== flutterEngine) {
            oldEngine.plugins.remove(p)
        }

        // FlutterEngine.plugins is a PluginRegistry. Calling add() with a
        // FlutterPlugin triggers onAttachedToEngine automatically.
        flutterEngine.plugins.add(p)
        attachedEngine = flutterEngine

        // Attach the sync bypass interface if a WebView is provided.
        if (webView != null) {
            attachSyncInterface(webView)
        }
    }

    /**
     * Attach (or re-attach) the `XBridgeSync` `@JavascriptInterface` to a
     * WebView. Call this once the WebView is available (e.g. after
     * `WebViewController` has created its platform view).
     */
    fun attachSyncInterface(webView: WebView) {
        val sync = XBridgeSyncInterface(
            nativeBridgeProvider = { currentBridge },
            securityPolicyProvider = { currentPolicy },
            originProvider = { currentOrigin },
        )
        sync.attach(webView)
        syncInterface = sync
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
     * Set the current page origin for security policy checks on both
     * the fallback [XBridgePlugin] and the sync bypass interface.
     */
    fun setOrigin(url: String?) {
        currentOrigin = url
        plugin?.setOrigin(url)
    }

    /**
     * Detach and clean up. Call from `MainActivity.onDestroy` or
     * `cleanUpFlutterEngine`.
     */
    fun unregister(flutterEngine: FlutterEngine) {
        plugin?.let {
            flutterEngine.plugins.remove(it)
        }
        plugin = null
        syncInterface = null
        currentBridge = null
        currentOrigin = null
        attachedEngine = null
    }
}
