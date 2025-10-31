import AppKit
import Darwin
import Foundation
// Note: GRPC imports will be added once the server implementation is complete
import GRPC
import MacosUseSDKProtos  // Import the generated proto definitions
import NIOCore
import NIOPosix

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
    stateStore: stateStore, operationStore: operationStore)
  fputs("info: [MacosUseServer] Service provider created\n", stderr)

  // Create Operations provider and register it so clients may poll LROs
  let operationsProvider = OperationsProvider(operationStore: operationStore)
  fputs("info: [MacosUseServer] Operations provider created\n", stderr)

  // Set up and start gRPC server
  let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

  let serverBuilder = Server.insecure(group: group)
    .withServiceProviders([macosUseService, operationsProvider])

  let server: Server
  if let socketPath = config.unixSocketPath {
    // Clean up old socket file if it exists
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: socketPath, isDirectory: &isDir) {
      try FileManager.default.removeItem(atPath: socketPath)
    }
    server = try await serverBuilder.bind(unixDomainSocketPath: socketPath).get()
  } else {
    server = try await serverBuilder.bind(host: config.listenAddress, port: config.port).get()
  }

  fputs("info: [MacosUseServer] gRPC server started\n", stderr)

  // Wait for the server to stop (which will be forever unless interrupted)
  try await server.onClose.get()
}

try await main()
