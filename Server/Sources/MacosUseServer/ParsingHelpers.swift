import Foundation
import GRPCCore
import MacosUseProto
import SwiftProtobuf

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

    /// Parses an optional PID from an application resource name, supporting the AIP-159 wildcard.
    ///
    /// Accepts `"applications/{pid}"` (returns the PID) or `"applications/-"` (returns nil,
    /// meaning "all applications" / desktop-level scope). An empty string also returns nil
    /// for backward compatibility with CreateInput's optional parent field.
    ///
    /// - Parameter name: The application resource name, `"applications/-"`, or empty string.
    /// - Returns: The extracted PID, or nil for wildcard/empty.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseOptionalPID(fromName name: String) throws -> pid_t? {
        if name.isEmpty {
            return nil
        }
        let components = name.split(separator: "/").map(String.init)
        guard components.count >= 2,
              components[0] == "applications"
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid application name: \(name)")
        }
        // AIP-159: "-" means "all resources" at this collection level (wildcard).
        if components[1] == "-" {
            return nil
        }
        guard let pidInt = Int32(components[1]) else {
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

    // MARK: - FieldMask Helpers (AIP-157)

    /// Applies a read_mask to a Window response per AIP-157.
    /// If the mask is empty, all fields are returned.
    /// Otherwise, only the specified fields are included (others are default values).
    ///
    /// Supported field paths: name, title, bounds, z_index, visible, bundle_id
    ///
    /// - Parameters:
    ///   - window: The full window response with all fields populated.
    ///   - readMask: The FieldMask specifying which fields to return.
    /// - Returns: A new Window with only the requested fields populated.
    static func applyFieldMask(
        to window: Macosusesdk_V1_Window,
        readMask: SwiftProtobuf.Google_Protobuf_FieldMask,
    ) -> Macosusesdk_V1_Window {
        // If read_mask is empty or contains "*", return all fields per AIP-157
        if readMask.paths.isEmpty || readMask.paths.contains("*") {
            return window
        }

        // Create a new window with only requested fields
        var result = Macosusesdk_V1_Window()

        // The 'name' field is ALWAYS included per AIP-157 guidance for identifier fields
        result.name = window.name

        for path in readMask.paths {
            switch path {
            case "name":
                // Already included above
                break
            case "title":
                result.title = window.title
            case "bounds":
                result.bounds = window.bounds
            case "z_index":
                result.zIndex = window.zIndex
            case "visible":
                result.visible = window.visible
            case "bundle_id":
                result.bundleID = window.bundleID
            default:
                // Unknown fields are silently ignored per AIP-157
                break
            }
        }

        return result
    }

    /// Applies a read_mask to an Application response per AIP-157.
    /// If the mask is empty, all fields are returned.
    /// Otherwise, only the specified fields are included (others are default values).
    ///
    /// Supported field paths: name, pid, display_name
    ///
    /// - Parameters:
    ///   - application: The full application response with all fields populated.
    ///   - readMask: The FieldMask specifying which fields to return.
    /// - Returns: A new Application with only the requested fields populated.
    static func applyFieldMask(
        to application: Macosusesdk_V1_Application,
        readMask: SwiftProtobuf.Google_Protobuf_FieldMask,
    ) -> Macosusesdk_V1_Application {
        // If read_mask is empty or contains "*", return all fields per AIP-157
        if readMask.paths.isEmpty || readMask.paths.contains("*") {
            return application
        }

        // Create a new application with only requested fields
        var result = Macosusesdk_V1_Application()

        // The 'name' field is ALWAYS included per AIP-157 guidance for identifier fields
        result.name = application.name

        for path in readMask.paths {
            switch path {
            case "name":
                // Already included above
                break
            case "pid":
                result.pid = application.pid
            case "display_name":
                result.displayName = application.displayName
            default:
                // Unknown fields are silently ignored per AIP-157
                break
            }
        }

        return result
    }
}
