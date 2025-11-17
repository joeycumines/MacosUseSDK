import Foundation
import GRPCCore

/// Shared parsing utilities for resource names and identifiers.
enum ParsingHelpers {
    /// Parses a PID from an application resource name of the format "applications/{pid}".
    ///
    /// - Parameter name: The application resource name (e.g., "applications/12345").
    /// - Returns: The extracted PID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parsePID(fromName name: String) throws -> pid_t {
        let components = name.split(separator: "/").map(String.init)
        guard components.count >= 2,
              components[0] == "applications",
              let pidInt = Int32(components[1])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid application name: \(name)")
        }
        return pid_t(pidInt)
    }
}
