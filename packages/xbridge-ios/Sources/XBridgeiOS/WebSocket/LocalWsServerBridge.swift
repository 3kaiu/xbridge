// SPDX-License-Identifier: MIT
//
// LocalWsServerBridge.swift
// XBridgeiOS
//
// Created by XBridge SDK on 2024-01-01.
//

import Foundation

#if canImport(XBridgeCoreC)
import XBridgeCoreC
#endif

/// Errors that can occur when interacting with the local WebSocket server.
public enum XBridgeWsError: Error, LocalizedError {
    /// The Rust core library (xbridge_core.xcframework) is not linked.
    case rustCoreNotLinked
    /// The server failed to start (Rust returned -1).
    case startFailed
    /// The server failed to stop (Rust returned -1).
    case stopFailed

    public var errorDescription: String? {
        switch self {
        case .rustCoreNotLinked:
            return "Rust xbridge_core library is not linked. Add xbridge_core.xcframework to your Xcode project."
        case .startFailed:
            return "Local WebSocket server failed to start."
        case .stopFailed:
            return "Local WebSocket server failed to stop."
        }
    }
}

/// A singleton bridge to the Rust `xbridge_core` C-ABI for controlling the
/// local WebSocket server.
///
/// The Rust crate exposes three C functions:
/// - `xbridge_ws_start(port: u16) -> i32` — starts the server on 127.0.0.1,
///   returns the bound port or -1.
/// - `xbridge_ws_stop() -> i32` — stops the server, returns 0 or -1.
/// - `xbridge_ws_set_binary_callback(cb) -> i32` — registers a binary
///   frame callback (not yet wired from Swift; see README).
///
/// ## Linking the Rust core
///
/// The Rust `xbridge_core` crate must be built as an `.xcframework` and added
/// to the consumer's Xcode project. The C functions are declared in
/// `xbridge_core.h` and exposed to Swift via `module.modulemap`.
///
/// If the library is not linked at runtime, `start()` returns
/// `.failure(.rustCoreNotLinked)`.
public final class LocalWsServerBridge {

    /// Shared singleton instance.
    public static let shared = LocalWsServerBridge()

    private init() {}

    // MARK: - Public API

    /// Start the local WebSocket server on `127.0.0.1:port`.
    ///
    /// - Parameters:
    ///   - port: The desired port. Use `0` for OS-assigned.
    ///   - completion: Called with `.success(actualPort)` or `.failure(error)`.
    public func start(port: Int = 0, completion: @escaping (Result<Int, Error>) -> Void) {
        // Dispatch to a background queue to avoid blocking the caller,
        // since the Rust side uses `blocking_lock` internally.
        DispatchQueue.global(qos: .utility).async {
            #if canImport(XBridgeCoreC)
            let result = xbridge_ws_start(UInt16(port))
            if result >= 0 {
                DispatchQueue.main.async {
                    completion(.success(Int(result)))
                }
            } else {
                DispatchQueue.main.async {
                    completion(.failure(XBridgeWsError.startFailed))
                }
            }
            #else
            // The module is not available — the Rust core is not linked.
            DispatchQueue.main.async {
                completion(.failure(XBridgeWsError.rustCoreNotLinked))
            }
            #endif
        }
    }

    /// Stop the local WebSocket server.
    ///
    /// - Parameter completion: Called with `.success(())` or `.failure(error)`.
    public func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            #if canImport(XBridgeCoreC)
            let result = xbridge_ws_stop()
            DispatchQueue.main.async {
                if result == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(XBridgeWsError.stopFailed))
                }
            }
            #else
            DispatchQueue.main.async {
                completion(.failure(XBridgeWsError.rustCoreNotLinked))
            }
            #endif
        }
    }

    // MARK: - Binary callback (documented limitation)

    /// Register a binary frame callback.
    ///
    /// - Note: This is currently a **documented limitation**. Wiring a Swift
    ///   closure to a C `extern "C" fn` pointer requires a persistent
    ///   trampoline that bridges the C calling convention to Swift's
    ///   closure model. This is non-trivial and left as a future enhancement.
    ///   For now, binary frames received by the Rust server are consumed
    ///   server-side (the Rust `subscribe_receiver` API). Apps that need
    ///   binary data should connect to `ws://127.0.0.1:port` directly from
    ///   JavaScript rather than relying on a native callback.
    public func setBinaryCallback(_ callback: @escaping (Data) -> Void) {
        // TODO: Implement a C-compatible trampoline using a persistent
        // global closure context. The Rust side expects:
        //   extern "C" fn(*const u8, usize)
        // which cannot be a Swift closure directly. Options:
        //   1. Use @_cdecl to expose a Swift function as a C symbol.
        //   2. Store the Swift closure in a global and call it from the
        //      @_cdecl trampoline.
        // This is left as a documented enhancement.
    }
}
