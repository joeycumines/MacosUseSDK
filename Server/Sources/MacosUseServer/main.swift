import AppKit
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import MacosUseProto
import MacosUseSDK
import NIOCore
import OSLog

private let logger = MacosUseSDK.sdkLogger(category: "Main")

/// Main entry point for the MacosUseServer
func main() async throws {
    logger.info("MacosUseServer starting...")

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
        services: [macosUseService, operationsProvider],
    )

    logger.info("gRPC server starting")

    try await server.serve()
}

try await main()
