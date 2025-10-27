import Foundation
import AppKit
// Note: GRPC imports will be added once the server implementation is complete
// import GRPC
// import NIOCore
// import NIOPosix

/// Main entry point for the MacosUseServer
@main
struct MacosUseServer {
    static func main() async throws {
        fputs("info: [MacosUseServer] Starting...\n", stderr)
        
        // CRITICAL: Initialize NSApplication before any SDK calls
        // This is mandatory for the MacosUseSDK to function properly
        let app = NSApplication.shared
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
        
        // Create service providers
        let desktopService = DesktopServiceProvider(stateStore: stateStore)
        let targetsService = TargetApplicationsServiceProvider(stateStore: stateStore)
        fputs("info: [MacosUseServer] Service providers created\n", stderr)
        
        // TODO: Set up and start gRPC server once proto stubs are generated
        // The server setup will look like:
        //
        // let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        // defer {
        //     try! group.syncShutdownGracefully()
        // }
        //
        // var serverBuilder = Server.insecure(group: group)
        //     .withServiceProviders([desktopService, targetsService])
        //
        // let server: Server
        // if let socketPath = config.unixSocketPath {
        //     server = try await serverBuilder.bind(unixDomainSocketPath: socketPath).get()
        // } else {
        //     server = try await serverBuilder.bind(host: config.listenAddress, port: config.port).get()
        // }
        //
        // fputs("info: [MacosUseServer] gRPC server started\n", stderr)
        //
        // // Park the main thread - this keeps the RunLoop active for @MainActor
        // RunLoop.main.run()
        //
        // // Shutdown (only reached on termination)
        // try await server.close().get()
        
        fputs("info: [MacosUseServer] Server implementation pending proto stub generation\n", stderr)
        fputs("info: [MacosUseServer] Run 'buf generate' to generate gRPC stubs\n", stderr)
        
        // For now, just keep the app running to demonstrate the structure
        fputs("info: [MacosUseServer] Keeping main thread alive...\n", stderr)
        RunLoop.main.run()
    }
}
