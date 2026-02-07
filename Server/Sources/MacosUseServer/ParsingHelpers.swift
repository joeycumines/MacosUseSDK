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

    // MARK: - Page Token Encoding (AIP-158)

    /// Encode an offset into an opaque page token per AIP-158.
    /// The token is base64-encoded to prevent clients from relying on its structure.
    ///
    /// - Parameter offset: The offset value to encode.
    /// - Returns: An opaque base64-encoded page token string.
    static func encodePageToken(offset: Int) -> String {
        let tokenString = "offset:\(offset)"
        return Data(tokenString.utf8).base64EncodedString()
    }

    /// Decode an opaque page token to retrieve the offset per AIP-158.
    ///
    /// - Parameter token: The opaque page token string.
    /// - Returns: The decoded offset value.
    /// - Throws: RPCError with .invalidArgument if the token is malformed.
    static func decodePageToken(_ token: String) throws -> Int {
        guard let data = Data(base64Encoded: token),
              let tokenString = String(data: data, encoding: .utf8)
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }

        let components = tokenString.split(separator: ":")
        guard components.count == 2, components[0] == "offset",
              let parsedOffset = Int(components[1]), parsedOffset >= 0
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }
        return parsedOffset
    }
}
