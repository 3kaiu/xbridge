/// A common platform interface for the XBridge cross-platform bridge SDK.
///
/// This barrel re-exports the abstract platform contract ([XBridgePlatform])
/// and the shared security policy ([XBridgeSecurityPolicy]) that platform
/// implementations (Android, iOS, HarmonyOS, …) must honor.
library xbridge_platform_interface;

export 'src/security_policy.dart';
export 'src/xbridge_platform.dart';
