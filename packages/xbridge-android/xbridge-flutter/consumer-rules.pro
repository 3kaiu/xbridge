# XBridge Android SDK — Consumer ProGuard Rules
#
# These rules are applied automatically to apps that depend on this library
# via `consumerProguardFiles` in build.gradle.

# ── Keep the XBridge public API ──────────────────────────────────────────────

# Keep all public classes in io.xbridge — they form the SDK's API surface.
-keep public class io.xbridge.** { public *; }

# ── Keep @JavascriptInterface methods ─────────────────────────────────────────
# Android's JS bridge uses reflection to discover @JavascriptInterface methods.
# ProGuard may strip them otherwise.
-keepclassmembers class io.xbridge.XBridgeSyncInterface {
    @android.webkit.JavascriptInterface <methods>;
}

# ── Keep JNI external declarations ────────────────────────────────────────────
# Native methods are called by name from JNI; do not let ProGuard rename them.
-keepclasseswithmembernames class io.xbridge.ws.LocalWsServerJni {
    native <methods>;
}

# ── Keep the XBridgeNativeBridge interface ────────────────────────────────────
# App implementations of this interface are loaded reflectively in some setups.
-keep interface io.xbridge.XBridgeNativeBridge { *; }
