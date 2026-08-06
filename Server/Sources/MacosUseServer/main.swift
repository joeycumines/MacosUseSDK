import AppKit
import Darwin
import Foundation
import GRPCCore
import GRPCHealthService
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

// MARK: - Graceful Shutdown

/// Performs graceful shutdown of server resources.
///
/// This function ensures all resources are properly cleaned up in the correct order:
/// 1. Await the composition-owned service lifetime drain started with transport shutdown
/// 2. Remove only the exact Unix-socket identity claimed after bind
///
/// - Parameters:
///   - socketOwner: Optional identity-bound Unix socket path to clean up.
///   - serviceLifetime: The composition-owned producer and mutation lifetime.
@MainActor
private func performGracefulShutdown(
    socketOwner: UnixSocketPathOwner?,
    serviceLifetime: ServiceLifetime,
) async throws {
    logger.info("Initiating graceful shutdown...")

    await serviceLifetime.shutdown()
    logger.info("Composition-owned service work drained")

    // Remove only the exact socket identity claimed after bind.
    if let socketOwner {
        if try socketOwner.cleanup() {
            logger.info("Owned Unix socket file cleaned up: \(socketOwner.path, privacy: .private)")
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
/// │  7. ObservationManager(windowRegistry:, system:, coordinator:)                │
/// │     └─ Composition-owned actor for observation polling/streaming              │
/// │        Depends on: WindowRegistry, ProductionSystemOperations, coordinator    │
/// │                                                                               │
/// │  8. MacosUseService(stateStore:, operationStore:, windowRegistry:, system:)   │
/// │     └─ Owns one exact InputTransactionExecutor and MacroExecutor graph         │
/// │        Depends on: state, window, system, topology, and mutation ownership     │
/// │                                                                               │
/// │  9. ServiceLifetime(service-owned executors and all producer owners)           │
/// │     └─ Captures the exact service-owned macro/input authority graph            │
/// │        Depends on: MacosUseService and every composition-owned work owner      │
/// │                                                                               │
/// │ 10. GRPCServer.serve()                                                         │
/// │     └─ Start accepting connections - ALL singletons MUST be initialized      │
/// └─────────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Why Order Matters
///
/// 1. **NSApplication.shared**: macOS accessibility APIs (AXUIElement) require
///    an active AppKit runloop. Without this, AX calls may hang or return errors.
///
/// 2. **Composition ownership**: Observation and macro handlers use the exact
///    instances injected into `MacosUseService`, so every physical producer shares
///    the service coordinator and mutation gate.
///
/// 3. **WindowRegistry sharing**: ObservationManager, MacroExecutor, and MacosUseService
///    all share the SAME WindowRegistry instance for consistent window state.
///    This avoids cache inconsistencies and duplicate CG queries.
@MainActor
func main() async throws {
    logger.info("MacosUseServer starting...")

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
    let socketOwner: UnixSocketPathOwner? = try config.unixSocketPath.map { socketPath in
        let owner = UnixSocketPathOwner(path: socketPath)
        try owner.prepareForBind()
        return owner
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 3: AppStateStore
    // Copy-on-write state container for query isolation (CQRS pattern)
    // ═══════════════════════════════════════════════════════════════════════════
    let composition = MacosUseServiceComposition()
    try await composition.sessionManager.startCleanup()
    try await composition.elementRegistry.startCleanup()
    // Hydrate the composition-owned macro registry so previously created macros
    // survive a server restart. Failures are logged and swallowed inside the
    // composition so a bad persisted file cannot block startup.
    await composition.loadPersistedMacros()
    logger.info("State store initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4: OperationStore
    // LRO (Long-Running Operation) store for async operations like OpenApplication
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("Operation store initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4.5: HealthService
    // gRPC health check service for load balancer integration
    // ═══════════════════════════════════════════════════════════════════════════
    let healthService = HealthService()
    logger.info("Health service initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 5-6: ProductionSystemOperations + WindowRegistry
    // System adapter for AX/CG APIs, and window state tracking
    // WindowRegistry depends on SystemOperations for AX queries
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("Shared window registry created")

    // Load descriptor sets for reflection service
    let descriptorSetPaths = ResourceBundleHelper.bundle.paths(
        forResourcesOfType: "pb",
        inDirectory: "DescriptorSets",
    )
    if descriptorSetPaths.isEmpty {
        logger.warning("No descriptor sets found for reflection service. Reflection will not be enabled.")
    } else {
        logger.info("Found \(descriptorSetPaths.count, privacy: .public) descriptor set(s) for reflection: \(descriptorSetPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), privacy: .public)")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 7-8: Composition-owned actors
    // The service, observation manager, and macro executor already share the exact
    // registry, system adapter, coordinator, and mutation gate.
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("Composition-owned actors initialized with shared mutation runtime")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 9: MacosUseService + OperationsProvider
    // Main gRPC service providers - depend on ALL above components
    // ═══════════════════════════════════════════════════════════════════════════
    let macosUseService = composition.macosUseService
    logger.info("Service provider created")

    let operationsProvider = composition.operationsProvider
    logger.info("Operations provider created")

    // Build services array - all services must conform to GRPCCore.RegistrableRPCService
    var services: [any GRPCCore.RegistrableRPCService] = [macosUseService, operationsProvider, healthService]

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
        address = .unixDomainSocket(path: socketPath)
        logger.info("Binding to Unix Domain Socket: \(socketPath, privacy: .private)")
    } else {
        address = .ipv4(host: config.listenAddress, port: config.port)
        logger.info("Binding to TCP: \(config.listenAddress, privacy: .public):\(config.port, privacy: .public)")
    }

    let grpcTransport: HTTP2ServerTransport.Posix = .http2NIOPosix(
        address: address,
        transportSecurity: .plaintext,
    )
    let server = GRPCServer(
        transport: productionServerTransport(grpcTransport),
        services: services,
        interceptors: productionServerInterceptors(),
    )

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 10: Start gRPC Server
    // At this point every composition-owned dependency is initialized.
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("gRPC server starting")

    let signalSource = ShutdownSignalSource()
    let serverTask = Task {
        try await server.serve()
    }
    var lifecycleError: (any Error)?
    do {
        // A Unix listener is not admitted until its exact owner-private socket
        // identity has appeared. This replaces the fixed startup sleep.
        try await socketOwner?.claimCreatedSocket()

        healthService.provider.updateStatus(.serving, forService: "macosusesdk.v1.MacosUse")
        healthService.provider.updateStatus(.serving, forService: "")
        logger.info("Health service status set to SERVING")

        try await waitForServerTermination(
            serverTask: serverTask,
            shutdownSignals: signalSource.stream,
            beginGracefulShutdown: {
                healthService.provider.updateStatus(.notServing, forService: "macosusesdk.v1.MacosUse")
                healthService.provider.updateStatus(.notServing, forService: "")
                server.beginGracefulShutdown()
                await composition.serviceLifetime.shutdown()
            },
        )
        logger.info("gRPC server stopped normally")
    } catch {
        lifecycleError = error
        logger.error("gRPC server error: \(error.localizedDescription, privacy: .public)")
        healthService.provider.updateStatus(.notServing, forService: "macosusesdk.v1.MacosUse")
        healthService.provider.updateStatus(.notServing, forService: "")
        server.beginGracefulShutdown()
        await composition.serviceLifetime.shutdown()
        _ = try? await serverTask.value
    }

    healthService.provider.updateStatus(.notServing, forService: "macosusesdk.v1.MacosUse")
    healthService.provider.updateStatus(.notServing, forService: "")
    logger.info("Health service status set to NOT_SERVING")

    var cleanupError: (any Error)?
    do {
        try await performGracefulShutdown(
            socketOwner: socketOwner,
            serviceLifetime: composition.serviceLifetime,
        )
    } catch {
        cleanupError = error
        logger.error("Graceful shutdown failed: \(error.localizedDescription, privacy: .public)")
    }

    if let lifecycleError, let cleanupError {
        throw ServerLifecycleError.lifecycleAndCleanup(
            lifecycle: lifecycleError,
            cleanup: cleanupError,
        )
    }
    if let lifecycleError {
        throw lifecycleError
    }
    if let cleanupError {
        throw cleanupError
    }
}

try await main()
