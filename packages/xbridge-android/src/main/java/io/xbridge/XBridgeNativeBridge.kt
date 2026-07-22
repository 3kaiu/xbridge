package io.xbridge

/**
 * Delegate interface that the host app implements to forward XBridge method
 * calls to its existing native bridge (e.g. a DsBridge plugin instance).
 *
 * This is the **seam** that keeps XBridge business-free: the SDK itself has
 * zero knowledge of any business method. The app
 * supplies a single implementation that routes every `method` string to the
 * appropriate legacy handler.
 *
 * ## Threading
 *
 * [invoke] may be called from:
 * - The Flutter platform thread (MethodChannel callback thread).
 * - The WebView's JS thread (via [XBridgeSyncInterface.callSync]).
 *
 * Implementations must be thread-safe or must dispatch to their own preferred
 * thread internally. If the legacy bridge requires the UI thread, the
 * implementation should handle that dispatch itself.
 */
interface XBridgeNativeBridge {

    /**
     * Synchronously invoke the native bridge handler for [method].
     *
     * @param method  The business method name (e.g. `"getDeviceInfo"`).
     * @param params  The raw parameters — may be `null`, a primitive, a
     *                `Map<String, Any?>`, or a `List<Any?>` depending on what
     *                the H5 side sent. Implementations interpret this.
     * @return        The result value, or `null` if the method has no return.
     */
    fun invoke(method: String, params: Any?): Any?
}
