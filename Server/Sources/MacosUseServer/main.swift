import AppKit
import Darwin
import Foundation

import GRPCCore
import GRPCNIOTransportHTTP2
import MacosUseSDKProtos // Import the generated proto definitions

// Main entry point for the MacosUseServer
func main() async throws {
    fputs("info: [MacosUseServer] Starting...\n", stderr)

    // CRITICAL: Initialize NSApplication before any SDK calls
    // This is mandatory for the MacosUseSDK to function properly
    _ = await NSApplication.shared
    fputs("info: [MacosUseServer] NSApplication initialized\n", stderr)

    // Load configuration from environment
    let config = ServerConfig.fromEnvironment()
    fputs("info: [MacosUseServer] Configuration loaded\n", stderr)
    if let socketPath = config.unixSocketPath {
        fputs("info: [MacosUseServer] Will listen on Unix socket: \(socketPath)\n", stderr)
    } else {
        fputs("info: [MacosUseServer] Will listen on \(config.listenAddress):\(config.port)\n", stderr)
    }

    // Create the state store
    let stateStore = AppStateStore()
    fputs("info: [MacosUseServer] State store initialized\n", stderr)

    // Create the operation store
    let operationStore = OperationStore()

    // Create the single, correct service provider
    let macosUseService = MacosUseServiceProvider(
        stateStore: stateStore, operationStore: operationStore,
    )
    fputs("info: [MacosUseServer] Service provider created\n", stderr)

    // Create Operations provider and register it so clients may poll LROs
    let operationsProvider = OperationsProvider(operationStore: operationStore)
    fputs("info: [MacosUseServer] Operations provider created\n", stderr)

    // Set up and start gRPC server using the HTTP/2 NIO transport
    let server = GRPCServer(
        transport: .http2NIOPosix(
            address: .ipv4(host: config.listenAddress, port: config.port),
            transportSecurity: .plaintext,
        ),
        services: [macosUseService, operationsProvider],
    )

    fputs("info: [MacosUseServer] gRPC server starting\n", stderr)

    try await server.serve()
}

try await main()
