import AppKit
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCReflectionService
import MacosUseProto
import MacosUseSDK
import NIOCore
import OSLog

private let logger = MacosUseSDK.sdkLogger(category: "Main")

/// Restrictive umask for secure socket creation (0600 - owner read/write only)
/// This ensures Unix domain sockets are not world-readable or world-writable
private let secureUmask: mode_t = 0o177

/// Set umask for secure socket/file creation
/// Returns the previous umask value
private func setSecureUmask() -> mode_t {
    umask(secureUmask)
}

// MARK: - Signal Handling

/// C-compatible signal handler for graceful shutdown.
///
/// ## Thread Safety (nonisolated(unsafe))
///
/// This closure uses `nonisolated(unsafe)` because:
/// 1. It is a C function pointer required by signal() API
/// 2. It is a module-level constant initialized at load time (before main())
/// 3. It only reads static data (getpid()) and calls async-signal-safe functions
/// 4. It contains no mutable state or closures capturing external variables
///
/// The handler converts SIGTERM to SIGINT which Swift runtime handles for task cancellation.
private nonisolated(unsafe) let signalHandler: @convention(c) (Int32) -> Void = { _ in
    // Send SIGINT to trigger Swift runtime cancellation
    kill(getpid(), SIGINT)
}

/// Install signal handlers for graceful shutdown
/// MUST be nonisolated to call signal() C API
private nonisolated func installSignalHandlers() {
    // Install SIGTERM handler (converted to SIGINT for Swift runtime)
    _ = signal(SIGTERM, signalHandler)
    // Log after installation (in MainActor context)
    Task { @MainActor in
        logger.info("Installed SIGTERM handler")
    }

    // SIGINT (Ctrl+C) is automatically handled by Swift runtime
    // for Task cancellation, no need to install handler
}

// MARK: - Graceful Shutdown

/// Performs graceful shutdown of server resources.
///
/// This function ensures all resources are properly cleaned up in the correct order:
/// 1. Cancel all active observations (stops polling tasks, finishes event streams)
/// 2. Invalidate all sessions (marks sessions expired, cleans up resources)
/// 3. Drain operation store (cancels pending LROs)
///
/// - Parameters:
///   - socketPath: Optional Unix socket path to clean up.
///   - operationStore: The operation store to drain.
@MainActor
private func performGracefulShutdown(socketPath: String?, operationStore: OperationStore) async {
    logger.info("Initiating graceful shutdown...")

    // Step 1: Cancel all active observations
    // This stops polling tasks and finishes all event stream continuations
    logger.info("Cancelling all active observations...")
    await ObservationManager.shared.cancelAllObservations()
    logger.info("All observations cancelled")

    // Step 2: Invalidate all sessions
    // This marks sessions as expired and removes them from the store
    logger.info("Invalidating all sessions...")
    await SessionManager.shared.invalidateAllSessions()
    logger.info("All sessions invalidated")

    // Step 3: Drain operation store (cancel pending operations)
    logger.info("Draining operation store...")
    await operationStore.drainAllOperations()
    logger.info("Operation store drained")

    // Step 4: Clean up Unix socket file if it exists
    if let socketPath {
        do {
            if FileManager.default.fileExists(atPath: socketPath) {
                try FileManager.default.removeItem(atPath: socketPath)
                logger.info("Unix socket file cleaned up: \(socketPath, privacy: .private)")
            }
        } catch {
            logger.warning("Failed to clean up Unix socket file: \(error.localizedDescription, privacy: .public)")
        }
    }

    logger.info("Graceful shutdown complete")
}

// MARK: - Main Entry Point

/// Main entry point for the MacosUseServer.
///
/// ## Initialization Order (Dependency Graph)
///
/// The server components MUST be initialized in a specific order due to their dependencies.
/// Violating this order will cause runtime failures or undefined behavior.
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────────┐
/// │                        INITIALIZATION ORDER                                   │
/// │                                                                               │
/// │  1. NSApplication.shared                                                      │
/// │     └─ REQUIRED FIRST: AppKit runloop foundation for accessibility/UI        │
/// │        Must be initialized before ANY MacosUseSDK or AX API calls            │
/// │                                                                               │
/// │  2. ServerConfig.fromEnvironment()                                           │
/// │     └─ Loads environment variables for socket paths, ports, addresses        │
/// │        No dependencies, but needed early for logging config state            │
/// │                                                                               │
/// │  3. AppStateStore()                                                           │
/// │     └─ Copy-on-write state container for query isolation                      │
/// │        No dependencies                                                        │
/// │                                                                               │
/// │  4. OperationStore()                                                          │
/// │     └─ LRO (Long-Running Operation) store for async operations               │
/// │        No dependencies                                                        │
/// │                                                                               │
/// │  5. ProductionSystemOperations.shared                                        │
/// │     └─ System API adapter for AX, CG, etc.                                   │
/// │        Depends on: NSApplication.shared                                      │
/// │                                                                               │
/// │  6. WindowRegistry(system:)                                                   │
/// │     └─ Window state tracking via Quartz/AX                                   │
/// │        Depends on: ProductionSystemOperations                                 │
/// │                                                                               │
/// │  7. ObservationManager.shared = ObservationManager(windowRegistry:, system:) │
/// │     └─ Singleton actor for observation polling/streaming                      │
/// │        Depends on: WindowRegistry, ProductionSystemOperations                 │
/// │        MUST be set before gRPC server starts (RPC handlers access it)        │
/// │                                                                               │
/// │  8. MacroExecutor.shared = MacroExecutor(windowRegistry:)                     │
/// │     └─ Singleton actor for macro execution                                   │
/// │        Depends on: WindowRegistry                                            │
/// │        MUST be set before gRPC server starts (RPC handlers access it)        │
/// │                                                                               │
/// │  9. MacosUseService(stateStore:, operationStore:, windowRegistry:, system:)  │
/// │     └─ Main gRPC service provider                                            │
/// │        Depends on: All of the above                                          │
/// │                                                                               │
/// │ 10. GRPCServer.serve()                                                        │
/// │     └─ Start accepting connections - ALL singletons MUST be initialized      │
/// └─────────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Why Order Matters
///
/// 1. **NSApplication.shared**: macOS accessibility APIs (AXUIElement) require
///    an active AppKit runloop. Without this, AX calls may hang or return errors.
///
/// 2. **Singleton initialization**: `ObservationManager.shared` and `MacroExecutor.shared`
///    are accessed from gRPC RPC handlers which can execute on any thread/actor.
///    They MUST be initialized before `GRPCServer.serve()` or handlers will hit
///    preconditionFailure guards.
///
/// 3. **WindowRegistry sharing**: ObservationManager, MacroExecutor, and MacosUseService
///    all share the SAME WindowRegistry instance for consistent window state.
///    This avoids cache inconsistencies and duplicate CG queries.
@MainActor
func main() async throws {
    logger.info("MacosUseServer starting...")

    // Install signal handlers for graceful shutdown
    installSignalHandlers()

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 1: NSApplication.shared
    // CRITICAL: Must be initialized FIRST before any SDK or AccessibilityAPI calls
    // Reason: AppKit runloop is required for macOS accessibility APIs to function
    // ═══════════════════════════════════════════════════════════════════════════
    _ = NSApplication.shared
    logger.info("NSApplication initialized")

    // Set secure umask BEFORE creating any sockets (owner read/write only: 0600)
    _ = setSecureUmask()
    logger.info("Set secure umask: \(secureUmask, privacy: .public)")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 2: ServerConfig
    // Load configuration from environment variables for socket paths, ports
    // ═══════════════════════════════════════════════════════════════════════════
    let config = ServerConfig.fromEnvironment()
    logger.info("Configuration loaded")
    if let socketPath = config.unixSocketPath {
        logger.info("Will listen on Unix socket: \(socketPath, privacy: .private)")
    } else {
        logger.info("Will listen on \(config.listenAddress, privacy: .public):\(config.port, privacy: .public)")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 3: AppStateStore
    // Copy-on-write state container for query isolation (CQRS pattern)
    // ═══════════════════════════════════════════════════════════════════════════
    let stateStore = AppStateStore()
    logger.info("State store initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4: OperationStore
    // LRO (Long-Running Operation) store for async operations like OpenApplication
    // ═══════════════════════════════════════════════════════════════════════════
    let operationStore = OperationStore()
    logger.info("Operation store initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 5-6: ProductionSystemOperations + WindowRegistry
    // System adapter for AX/CG APIs, and window state tracking
    // WindowRegistry depends on SystemOperations for AX queries
    // ═══════════════════════════════════════════════════════════════════════════
    let system = ProductionSystemOperations.shared
    let sharedWindowRegistry = WindowRegistry(system: system)
    logger.info("Shared window registry created")

    // Load descriptor sets for reflection service
    let descriptorSetPaths = Bundle.module.paths(
        forResourcesOfType: "pb",
        inDirectory: "DescriptorSets",
    )
    if descriptorSetPaths.isEmpty {
        logger.warning("No descriptor sets found for reflection service. Reflection will not be enabled.")
    } else {
        logger.info("Found \(descriptorSetPaths.count, privacy: .public) descriptor set(s) for reflection: \(descriptorSetPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), privacy: .public)")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 7-8: Singleton Actor Initialization
    // CRITICAL: Must happen BEFORE GRPCServer.serve()
    // RPC handlers access these singletons; if not set, preconditionFailure fires
    // ═══════════════════════════════════════════════════════════════════════════
    ObservationManager.shared = ObservationManager(windowRegistry: sharedWindowRegistry, system: system)
    MacroExecutor.shared = MacroExecutor(windowRegistry: sharedWindowRegistry)
    logger.info("Singleton actors initialized with shared registry")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 9: MacosUseService + OperationsProvider
    // Main gRPC service providers - depend on ALL above components
    // ═══════════════════════════════════════════════════════════════════════════
    let macosUseService = MacosUseService(
        stateStore: stateStore,
        operationStore: operationStore,
        windowRegistry: sharedWindowRegistry,
        system: system,
    )
    logger.info("Service provider created")

    let operationsProvider = OperationsProvider(operationStore: operationStore)
    logger.info("Operations provider created")

    // Build services array - all services must conform to GRPCCore.RegistrableRPCService
    var services: [any GRPCCore.RegistrableRPCService] = [macosUseService, operationsProvider]

    if !descriptorSetPaths.isEmpty {
        do {
            let reflectionService = try ReflectionService(descriptorSetFilePaths: descriptorSetPaths)
            services.append(reflectionService)
            logger.info("Reflection service registered")
        } catch {
            logger.error("Failed to initialize reflection service: \(error.localizedDescription, privacy: .public)")
            logger.warning("Continuing without reflection service")
        }
    }

    // Set up and start gRPC server using the HTTP/2 NIO transport
    let address: GRPCNIOTransportCore.SocketAddress

    if let socketPath = config.unixSocketPath {
        // Clean up old socket file if it exists
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: socketPath, isDirectory: &isDir) {
            try FileManager.default.removeItem(atPath: socketPath)
        }
        address = .unixDomainSocket(path: socketPath)
        logger.info("Binding to Unix Domain Socket: \(socketPath, privacy: .private)")
    } else {
        address = .ipv4(host: config.listenAddress, port: config.port)
        logger.info("Binding to TCP: \(config.listenAddress, privacy: .public):\(config.port, privacy: .public)")
    }

    let server = GRPCServer(
        transport: .http2NIOPosix(
            address: address,
            transportSecurity: .plaintext,
        ),
        services: services,
    )

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 10: Start gRPC Server
    // At this point ALL singletons are initialized and safe to access
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("gRPC server starting")

    // Start server in background to allow explicit socket permission setting
    async let serverTask: Void = server.serve()

    // For Unix sockets, explicitly set restrictive permissions (defense in depth)
    // This ensures the socket is owner-readable/writable only, even if umask failed
    if let socketPath = config.unixSocketPath {
        // Small delay to allow socket creation
        try await Task.sleep(for: .milliseconds(100))
        let permissions: mode_t = 0o600 // owner read/write only
        if chmod(socketPath, permissions) == 0 {
            logger.info("Set Unix socket permissions: 0\(String(permissions, radix: 8), privacy: .public)")
        } else {
            logger.error("Failed to set Unix socket permissions: \(errno, privacy: .public)")
        }
    }

    // Wait for server completion (SIGINT/SIGTERM triggers task cancellation)
    do {
        try await serverTask
        logger.info("gRPC server stopped normally")
    } catch is CancellationError {
        logger.info("gRPC server received shutdown signal")
    } catch {
        logger.error("gRPC server error: \(error.localizedDescription, privacy: .public)")
    }

    // Perform graceful shutdown - cleanup resources in correct order
    await performGracefulShutdown(socketPath: config.unixSocketPath, operationStore: operationStore)
}

try await main()
