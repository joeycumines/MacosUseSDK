import Foundation
import AppKit
// Note: GRPC imports will be added once the server implementation is complete
import GRPC
import NIOCore
import NIOPosix
import MacosUseSDKProtos // Import the generated proto definitions
import Darwin

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
    let macosUseService = MacosUseServiceProvider(stateStore: stateStore, operationStore: operationStore)
    fputs("info: [MacosUseServer] Service provider created\n", stderr)

    // Create Operations provider and register it so clients may poll LROs
    let operationsProvider = OperationsProvider(operationStore: operationStore)
    fputs("info: [MacosUseServer] Operations provider created\n", stderr)

    // TODO: Set up and start gRPC server once proto stubs are generated
    // The server setup will look like:
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    let serverBuilder = Server.insecure(group: group)
        .withServiceProviders([macosUseService, operationsProvider])
    
    if let socketPath = config.unixSocketPath {
        // Clean up old socket file if it exists
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: socketPath, isDirectory: &isDir) {
            try FileManager.default.removeItem(atPath: socketPath)
        }
        _ = try await serverBuilder.bind(unixDomainSocketPath: socketPath).get()
    } else {
        _ = try await serverBuilder.bind(host: config.listenAddress, port: config.port).get()
    }
    
    fputs("info: [MacosUseServer] gRPC server started\n", stderr)
    
    // Keep the server running
    try await Task.sleep(nanoseconds: UInt64.max)
}

try await main()
