// SPDX-License-Identifier: MIT
//
// xbridge_core.h
// XBridgeiOS
//
// C bridging header for the Rust `xbridge_core` C-ABI.
//
// This header declares the three C functions exported by the Rust crate
// `xbridge_core` (built as a cdylib / .xcframework). The Swift side imports
// them via `module.modulemap` and calls them through `LocalWsServerBridge`.
//
// The Rust source lives at: rust/xbridge_core/src/bridge.rs
//

#ifndef XBRIDGE_CORE_H
#define XBRIDGE_CORE_H

#include <stdint.h>
#include <stddef.h>   // size_t

#ifdef __cplusplus
extern "C" {
#endif

/// Start the local WebSocket server on `127.0.0.1:port`.
///
/// If `port == 0`, the OS assigns a free port, which is returned.
///
/// @param port The desired port number (host byte order).
/// @return The actual bound port (positive), or `-1` on error.
int xbridge_ws_start(unsigned short port);

/// Stop the local WebSocket server.
///
/// @return `0` on success, `-1` if no server is running.
int xbridge_ws_stop(void);

/// Register a callback invoked for every binary frame the server receives.
///
/// The callback receives a raw pointer + length. The buffer is valid only
/// for the duration of the call — the native side MUST copy before returning.
///
/// @param cb A function pointer of type `void (*)(const uint8_t*, size_t)`,
///           or NULL to unregister.
/// @return `0` on success, `-1` on error.
typedef void (*xbridge_binary_callback_t)(const uint8_t* data, size_t len);
int xbridge_ws_set_binary_callback(xbridge_binary_callback_t cb);

#ifdef __cplusplus
}
#endif

#endif // XBRIDGE_CORE_H
