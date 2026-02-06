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

// MARK: - Signal Handling

/// C-compatible signal handler for graceful shutdown
/// Converts SIGTERM to SIGINT which Swift runtime handles for task cancellation
private let signalHandler: @convention(c) (Int32) -> Void = { _ in
    // Send SIGINT to trigger Swift runtime cancellation
    kill(getpid(), SIGINT)
}

/// Install signal handlers for graceful shutdown
private func installSignalHandlers() {
    // Install SIGTERM handler (converted to SIGINT for Swift runtime)
    _ = signal(SIGTERM, signalHandler)
    logger.info("Installed SIGTERM handler")

    // SIGINT (Ctrl+C) is automatically handled by Swift runtime
    // for Task cancellation, no need to install handler
}

// MARK: - Main Entry Point

/// Main entry point for the MacosUseServer
@MainActor
func main() async throws {
    logger.info("MacosUseServer starting...")

    // Install signal handlers for graceful shutdown
    installSignalHandlers()

    // CRITICAL: Initialize NSApplication before any SDK calls
    // This is mandatory for the MacosUseSDK to function properly
    _ = await NSApplication.shared
    logger.info("NSApplication initialized")

    // Load configuration from environment
    let config = ServerConfig.fromEnvironment()
    logger.info("Configuration loaded")
    if let socketPath = config.unixSocketPath {
        logger.info("Will listen on Unix socket: \(socketPath, privacy: .private)")
    } else {
        logger.info("Will listen on \(config.listenAddress, privacy: .public):\(config.port, privacy: .public)")
    }

    // Create the state store
    let stateStore = AppStateStore()
    logger.info("State store initialized")

    // Create the operation store
    let operationStore = OperationStore()

    // Create the shared SystemOperations adapter and window registry
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
        logger.info("Found \(descriptorSetPaths.count) descriptor set(s) for reflection: \(descriptorSetPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), privacy: .public)")
    }

    // Initialize singleton actors with the shared registry
    ObservationManager.shared = ObservationManager(windowRegistry: sharedWindowRegistry, system: system)
    MacroExecutor.shared = MacroExecutor(windowRegistry: sharedWindowRegistry)
    logger.info("Singleton actors initialized with shared registry")

    // Create the single, correct service provider
    let macosUseService = MacosUseService(
        stateStore: stateStore,
        operationStore: operationStore,
        windowRegistry: sharedWindowRegistry,
        system: system,
    )
    logger.info("Service provider created")

    // Create Operations provider and register it so clients may poll LROs
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

    logger.info("gRPC server starting")

    try await server.serve()
}

try await main()
