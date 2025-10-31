import Foundation

/// Server configuration loaded from environment variables
public struct ServerConfig {
  /// The address to listen on (e.g., "127.0.0.1" or "0.0.0.0")
  public let listenAddress: String

  /// The port to listen on
  public let port: Int

  /// Optional unix socket path to listen on instead of TCP
  public let unixSocketPath: String?

  /// Initialize configuration from environment variables
  public static func fromEnvironment() -> ServerConfig {
    let host = ProcessInfo.processInfo.environment["GRPC_LISTEN_ADDRESS"]
    let hostValue = host?.isEmpty == false ? host : "127.0.0.1"
    let portStr = ProcessInfo.processInfo.environment["GRPC_PORT"]
    let portValue = portStr?.isEmpty == false ? Int(portStr!) : nil
    let port = portValue ?? 8080
    let socket = ProcessInfo.processInfo.environment["GRPC_UNIX_SOCKET"]

    return ServerConfig(
      listenAddress: hostValue!,
      port: port,
      unixSocketPath: socket
    )
  }

  public init(listenAddress: String, port: Int, unixSocketPath: String? = nil) {
    self.listenAddress = listenAddress
    self.port = port
    self.unixSocketPath = unixSocketPath
  }
}
