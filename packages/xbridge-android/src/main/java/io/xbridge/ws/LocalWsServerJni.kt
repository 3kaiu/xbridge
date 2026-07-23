package io.xbridge.ws

import android.util.Log

/**
 * JNI bridge to the Rust `xbridge_core` native library.
 *
 * The Rust crate exposes three C-ABI functions (see
 * `rust/xbridge_core/src/bridge.rs`):
 *
 * - `xbridge_ws_start(port: u16) -> i32` — starts a local WS server on
 *   `127.0.0.1:port`. If `port == 0`, the OS assigns a free port. Returns
 *   the bound port (positive) or `-1` on error.
 * - `xbridge_ws_stop() -> i32` — stops the server. Returns `0` on success,
 *   `-1` if no server is running.
 * - `xbridge_ws_set_binary_callback(cb: Option<extern "C" fn(*const u8, usize)>) -> i32`
 *   — registers a callback for binary frames. **Not wired** in this SDK
 *   (see "Binary Callback Limitation" below).
 *
 * ## Native library placement
 *
 * The Rust crate must be cross-compiled for each target ABI (arm64-v8a,
 * armeabi-v7a, x86_64) and placed as `libxbridge_core.so` in:
 *
 * ```
 * packages/xbridge-android/src/main/jniLibs/<abi>/libxbridge_core.so
 * ```
 *
 * or, for app consumers, added to the app's `jniLibs` directory.
 *
 * ## JNI Symbol Resolution
 *
 * The Rust crate exports JNI-named wrapper functions
 * (`Java_io_xbridge_ws_LocalWsServerJni_nativeStart` and
 * `..._nativeStop`) that delegate to the canonical `xbridge_ws_start` /
 * `xbridge_ws_stop` C-ABI functions. This means `System.loadLibrary`
 * + `external fun` resolves correctly without a separate C/C++ JNI shim.
 *
 * ## Binary Callback Limitation (known)
 *
 * The Rust `xbridge_ws_set_binary_callback` expects a raw C function
 * pointer (`extern "C" fn(*const u8, usize)`). JNI cannot directly pass a
 * Kotlin/Java function as a C `extern "C" fn` — it requires a JNI
 * registration shim: a static Java method that the Rust side calls back
 * into, which then fans out to registered Kotlin listeners.
 *
 * Implementing this shim requires a native (.c/.cpp) JNI bridge layer
 * (a `registerNatives` call or a `JNI_OnLoad` with method table). This is
 * substantial and left as a follow-up. For now, `nativeStart`/`nativeStop`
 * are fully functional — H5 can connect to the WS server and exchange text
 * frames; binary frame callback forwarding to Kotlin is the missing piece.
 *
 * Consumers needing binary callback support should:
 * 1. Add a small JNI `.c` shim that registers a `Java_io_xbridge_ws_*`
 *    callback method.
 * 2. Or use `xbridge_ws_set_binary_callback` directly from C++ code in
 *    their own JNI layer.
 */
object LocalWsServerJni {

    private const val TAG = "LocalWsServerJni"

    /**
     * Start the local WebSocket server.
     *
     * @param port The desired port. `0` lets the OS assign a free port.
     * @return The actual bound port (positive), or `-1` on error.
     * @throws UnsatisfiedLinkError if `libxbridge_core.so` is not loaded.
     */
    external fun nativeStart(port: Int): Int

    /**
     * Stop the local WebSocket server.
     *
     * @return `0` on success, `-1` if no server is running.
     * @throws UnsatisfiedLinkError if `libxbridge_core.so` is not loaded.
     */
    external fun nativeStop(): Int

    // ── Kotlin-level convenience wrappers ───────────────────────────────────

    /**
     * Start the WS server. Returns the bound port or `-1`.
     * Catches [UnsatisfiedLinkError] and returns `-1` if the native library
     * is missing, so callers don't crash — WS features are degraded gracefully.
     */
    fun start(port: Int): Int {
        return try {
            nativeStart(port)
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "libxbridge_core.so not loaded — WS server unavailable: ${e.message}")
            -1
        }
    }

    /**
     * Stop the WS server. Returns `0` on success, `-1` if no server or
     * the native library is missing.
     */
    fun stop(): Int {
        return try {
            nativeStop()
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "libxbridge_core.so not loaded — WS server unavailable: ${e.message}")
            -1
        }
    }

    /**
     * Whether the native library was successfully loaded at init time.
     */
    val isLoaded: Boolean

    init {
        isLoaded = try {
            System.loadLibrary("xbridge_core")
            Log.i(TAG, "libxbridge_core.so loaded successfully")
            true
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "libxbridge_core.so not found — WS server features degraded. " +
                "Place the .so in jniLibs/<abi>/ to enable local WebSocket streaming.")
            false
        }
    }
}
