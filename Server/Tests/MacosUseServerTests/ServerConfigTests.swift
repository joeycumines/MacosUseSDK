@testable import MacosUseServer
import XCTest

/// Tests for ServerConfig
final class ServerConfigTests: XCTestCase {
    func testDefaultConfiguration() {
        // Save original environment
        let originalAddress = ProcessInfo.processInfo.environment["GRPC_LISTEN_ADDRESS"]
        let originalPort = ProcessInfo.processInfo.environment["GRPC_PORT"]
        let originalSocket = ProcessInfo.processInfo.environment["GRPC_UNIX_SOCKET"]

        // Clear environment
        setenv("GRPC_LISTEN_ADDRESS", "", 1)
        setenv("GRPC_PORT", "", 1)
        unsetenv("GRPC_UNIX_SOCKET")

        let config = ServerConfig.fromEnvironment()

        XCTAssertEqual(config.listenAddress, "127.0.0.1")
        XCTAssertEqual(config.port, 8080)
        XCTAssertNil(config.unixSocketPath)

        // Restore environment
        if let addr = originalAddress { setenv("GRPC_LISTEN_ADDRESS", addr, 1) }
        if let port = originalPort { setenv("GRPC_PORT", port, 1) }
        if let sock = originalSocket { setenv("GRPC_UNIX_SOCKET", sock, 1) }
    }

    func testCustomConfiguration() {
        setenv("GRPC_LISTEN_ADDRESS", "0.0.0.0", 1)
        setenv("GRPC_PORT", "9090", 1)
        setenv("GRPC_UNIX_SOCKET", "/tmp/test.sock", 1)

        let config = ServerConfig.fromEnvironment()

        XCTAssertEqual(config.listenAddress, "0.0.0.0")
        XCTAssertEqual(config.port, 9090)
        XCTAssertEqual(config.unixSocketPath, "/tmp/test.sock")

        // Cleanup
        unsetenv("GRPC_LISTEN_ADDRESS")
        unsetenv("GRPC_PORT")
        unsetenv("GRPC_UNIX_SOCKET")
    }
}
