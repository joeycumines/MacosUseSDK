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

    // MARK: - Resource Name Types (AIP-122)

    /// Parsed application resource name containing the extracted PID.
    struct ApplicationResource {
        let pid: pid_t
    }

    /// Parsed window resource name containing the extracted PID and window ID.
    struct WindowResource {
        let pid: pid_t
        let windowId: Int
    }

    /// Parsed observation resource name containing the extracted PID and observation ID.
    struct ObservationResource {
        let pid: pid_t
        let observationId: String
    }

    /// Parsed element resource name containing the extracted PID and element ID.
    struct ElementResource {
        let pid: pid_t
        let elementId: String
    }

    /// Parsed session resource name containing the extracted session ID.
    struct SessionResource {
        let sessionId: String
    }

    /// Parsed macro resource name containing the extracted macro ID.
    struct MacroResource {
        let macroId: String
    }

    /// Parsed operation resource name containing the extracted operation ID.
    struct OperationResource {
        let operationId: String
    }

    /// Parsed display resource name containing the extracted display name.
    struct DisplayResource {
        let displayName: String
    }

    // MARK: - Resource Name Parsing (AIP-122)

    /// Parses an application resource name of the format "applications/{pid}".
    ///
    /// - Parameter name: The application resource name (e.g., "applications/12345").
    /// - Returns: An ApplicationResource containing the extracted PID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseApplicationName(_ name: String) throws -> ApplicationResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[0] == "applications",
              let pidInt = Int32(components[1]),
              pidInt > 0
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid application name format. Expected 'applications/{pid}', got '\(name)'",
            )
        }
        return ApplicationResource(pid: pid_t(pidInt))
    }

    /// Parses a window resource name of the format "applications/{pid}/windows/{windowId}".
    ///
    /// - Parameter name: The window resource name (e.g., "applications/12345/windows/67890").
    /// - Returns: A WindowResource containing the extracted PID and window ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseWindowName(_ name: String) throws -> WindowResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              let pidInt = Int32(components[1]),
              pidInt > 0,
              components[2] == "windows",
              let windowId = Int(components[3]),
              windowId > 0
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid window name format. Expected 'applications/{pid}/windows/{windowId}', got '\(name)'",
            )
        }
        return WindowResource(pid: pid_t(pidInt), windowId: windowId)
    }

    /// Parses an observation resource name of the format "applications/{pid}/observations/{id}".
    ///
    /// - Parameter name: The observation resource name (e.g., "applications/12345/observations/abc123").
    /// - Returns: An ObservationResource containing the extracted PID and observation ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseObservationName(_ name: String) throws -> ObservationResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              let pidInt = Int32(components[1]),
              pidInt > 0,
              components[2] == "observations",
              !components[3].isEmpty
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid observation name format. Expected 'applications/{pid}/observations/{id}', got '\(name)'",
            )
        }
        return ObservationResource(pid: pid_t(pidInt), observationId: components[3])
    }

    /// Parses an element resource name of the format "applications/{pid}/elements/{id}".
    ///
    /// - Parameter name: The element resource name (e.g., "applications/12345/elements/abc123").
    /// - Returns: An ElementResource containing the extracted PID and element ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseElementName(_ name: String) throws -> ElementResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              let pidInt = Int32(components[1]),
              pidInt > 0,
              components[2] == "elements",
              !components[3].isEmpty
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid element name format. Expected 'applications/{pid}/elements/{id}', got '\(name)'",
            )
        }
        return ElementResource(pid: pid_t(pidInt), elementId: components[3])
    }

    /// Parses a session resource name of the format "sessions/{id}".
    ///
    /// - Parameter name: The session resource name (e.g., "sessions/abc123").
    /// - Returns: A SessionResource containing the extracted session ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseSessionName(_ name: String) throws -> SessionResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[0] == "sessions",
              !components[1].isEmpty
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid session name format. Expected 'sessions/{id}', got '\(name)'",
            )
        }
        return SessionResource(sessionId: components[1])
    }

    /// Parses a macro resource name of the format "macros/{id}".
    ///
    /// - Parameter name: The macro resource name (e.g., "macros/abc123").
    /// - Returns: A MacroResource containing the extracted macro ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseMacroName(_ name: String) throws -> MacroResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[0] == "macros",
              !components[1].isEmpty
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid macro name format. Expected 'macros/{id}', got '\(name)'",
            )
        }
        return MacroResource(macroId: components[1])
    }

    /// Parses an operation resource name of the format "operations/{id}".
    ///
    /// - Parameter name: The operation resource name (e.g., "operations/abc123").
    /// - Returns: An OperationResource containing the extracted operation ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseOperationName(_ name: String) throws -> OperationResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[0] == "operations",
              !components[1].isEmpty
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid operation name format. Expected 'operations/{id}', got '\(name)'",
            )
        }
        return OperationResource(operationId: components[1])
    }

    /// Parses a display resource name of the format "displays/{name}".
    ///
    /// - Parameter name: The display resource name (e.g., "displays/main").
    /// - Returns: A DisplayResource containing the extracted display name.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseDisplayName(_ name: String) throws -> DisplayResource {
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 2,
              components[0] == "displays",
              !components[1].isEmpty
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid display name format. Expected 'displays/{name}', got '\(name)'",
            )
        }
        return DisplayResource(displayName: components[1])
    }
}
