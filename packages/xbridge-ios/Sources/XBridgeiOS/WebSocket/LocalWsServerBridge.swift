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
    /// The requested port is outside the valid range (0...65535).
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .rustCoreNotLinked:
            return "Rust xbridge_core library is not linked. Add xbridge_core.xcframework to your Xcode project."
        case .startFailed:
            return "Local WebSocket server failed to start."
        case .stopFailed:
            return "Local WebSocket server failed to stop."
        case .invalidPort:
            return "Port must be in the range 0...65535."
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

    /// Lock protecting `cachedPort` against concurrent start/stop races.
    private let portLock = NSLock()

    /// Cached port of the running WS server, or `nil` if not running.
    /// Access is synchronized via `portLock` because `start`/`stop` run on
    /// a background queue while `isRunning`/`endpoint` may be read from any
    /// thread.
    private var _cachedPort: Int?
    private var cachedPort: Int? {
        get { portLock.lock(); defer { portLock.unlock() }; return _cachedPort }
        set { portLock.lock(); defer { portLock.unlock() }; _cachedPort = newValue }
    }

    // MARK: - Public API

    /// Start the local WebSocket server on `127.0.0.1:port`.
    ///
    /// - Parameters:
    ///   - port: The desired port. Use `0` for OS-assigned.
    ///   - completion: Called with `.success(actualPort)` or `.failure(error)`.
    public func start(port: Int = 0, completion: @escaping (Result<Int, Error>) -> Void) {
        // Validate port range before casting to UInt16.
        guard port >= 0, port <= 65535 else {
            completion(.failure(XBridgeWsError.invalidPort))
            return
        }

        // Dispatch to a background queue to avoid blocking the caller,
        // since the Rust side uses `blocking_lock` internally.
        DispatchQueue.global(qos: .utility).async {
            #if canImport(XBridgeCoreC)
            let result = xbridge_ws_start(UInt16(port))
            DispatchQueue.main.async {
                if result >= 0 {
                    self.cachedPort = Int(result)
                    completion(.success(Int(result)))
                } else {
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
                    self.cachedPort = nil
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

    // MARK: - State queries

    /// Returns `true` when the local WebSocket server is currently running.
    public var isRunning: Bool {
        cachedPort != nil
    }

    /// Returns `ws://127.0.0.1:<port>` when running, or `nil` when stopped.
    public var endpoint: String? {
        guard let port = cachedPort else { return nil }
        return "ws://127.0.0.1:\(port)"
    }

    // MARK: - Binary callback (documented limitation)

    /// Register a binary frame callback.
    ///
    /// - Warning: This is currently a **documented limitation**. The method
    ///   logs a warning and does nothing — binary frames received by the Rust
    ///   server are consumed server-side. Apps that need binary data should
    ///   connect to `ws://127.0.0.1:port` directly from JavaScript.
    public func setBinaryCallback(_ callback: @escaping (Data) -> Void) {
        #if DEBUG
        print("[XBridge] WARNING: setBinaryCallback is not yet implemented. "
            + "Binary frames are consumed by the Rust server. "
            + "Connect to ws://127.0.0.1:<port> directly from JavaScript instead.")
        #endif
    }
}
