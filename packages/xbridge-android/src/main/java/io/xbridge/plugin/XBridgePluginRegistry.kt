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
    @Volatile
    private var syncInterface: XBridgeSyncInterface? = null
    @Volatile
    private var currentBridge: XBridgeNativeBridge? = null
    @Volatile
    private var currentPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.denyAll()
    @Volatile
    private var currentOrigin: String? = null
    @Volatile
    private var attachedEngine: FlutterEngine? = null
    @Volatile
    private var attachedWebView: WebView? = null

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
     * @param securityPolicy Initial security policy. Defaults to **deny-all**
     *                      for production safety; set `allowAll()` for development
     *                      or an allowlist for production.
     */
    @JvmOverloads
    fun register(
        flutterEngine: FlutterEngine,
        nativeBridge: XBridgeNativeBridge? = null,
        webView: WebView? = null,
        securityPolicy: XBridgeSecurityPolicy = XBridgeSecurityPolicy.denyAll(),
    ) {
        // If already registered with the same engine, no-op (prevents duplicate handlers).
        if (plugin != null && attachedEngine === flutterEngine) {
            // Update the bridge and policy in-place.
            currentBridge = nativeBridge
            currentPolicy = securityPolicy
            plugin?.setNativeBridge(nativeBridge)
            plugin?.setSecurityPolicy(securityPolicy)
            if (webView != null) {
                attachSyncInterface(webView)
            }
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
        // Remove old interface from previous WebView if any.
        attachedWebView?.removeJavascriptInterface("XBridgeSync")
        val sync = XBridgeSyncInterface(
            nativeBridgeProvider = { currentBridge },
            securityPolicyProvider = { currentPolicy },
            originProvider = { currentOrigin },
        )
        sync.attach(webView)
        syncInterface = sync
        attachedWebView = webView
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
        // Remove the JavascriptInterface from the WebView to prevent leaks.
        attachedWebView?.removeJavascriptInterface("XBridgeSync")
        plugin = null
        syncInterface = null
        currentBridge = null
        currentOrigin = null
        currentPolicy = XBridgeSecurityPolicy.denyAll()
        attachedEngine = null
        attachedWebView = null
    }
}
