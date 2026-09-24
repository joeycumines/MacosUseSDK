import CryptoKit
import ExactMacProto
import Foundation
import GRPCCore
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
        guard components.count == 2,
              components[0] == "applications",
              let pidInt = Int32(components[1]),
              pidInt > 0
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
        guard components.count == 2,
              components[0] == "applications"
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid application name: \(name)")
        }
        // AIP-159: "-" means "all resources" at this collection level (wildcard).
        if components[1] == "-" {
            return nil
        }
        guard let pidInt = Int32(components[1]), pidInt > 0 else {
            throw RPCError(code: .invalidArgument, message: "Invalid application name: \(name)")
        }
        return pid_t(pidInt)
    }

    /// Constant-time string comparison for the authenticated query-binding hash.
    /// Returns true only if both strings have identical length and every character matches.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }

        var result: UInt8 = 0
        for index in aBytes.indices {
            result |= aBytes[index] ^ bBytes[index]
        }
        return result == 0
    }

    // MARK: - Page Token Encoding (AIP-158)

    /// Per-process 256-bit key for the one public page-token format.
    private static let tokenSecret = SymmetricKey(size: .bits256)
    private static let pageTokenVersion = "v2"
    private static let pageTokenNonceLength = 12
    private static let pageTokenTagLength = 16

    /// Builds an unambiguous query identity. Length-prefixing prevents values
    /// containing delimiters from colliding with another field layout.
    static func pageTokenQuery(
        method: String,
        parameters: [(String, String)] = [],
    ) -> String {
        var components = [("method", method)]
        components.append(contentsOf: parameters)
        return components.map { name, value in
            "\(name.utf8.count):\(name)\(value.utf8.count):\(value)"
        }.joined()
    }

    /// Builds a stable semantic identity for an element selector. Protobuf map
    /// fields have no wire-order guarantee, so serializing a selector directly
    /// would make an equivalent continuation depend on map iteration order.
    static func selectorQueryIdentity(
        _ selector: Exactmac_Type_ElementSelector,
    ) -> String {
        let parameters: [(String, String)]
        switch selector.criteria {
        case let .role(value):
            parameters = [("criteria", "role"), ("value", value)]
        case let .text(value):
            parameters = [("criteria", "text"), ("value", value)]
        case let .textSubstring(value):
            parameters = [("criteria", "text_substring"), ("value", value)]
        case let .textRegex(value):
            parameters = [("criteria", "text_regex"), ("value", value)]
        case let .position(value):
            parameters = [
                ("criteria", "position"),
                ("has_x", value.hasX ? "1" : "0"),
                ("x", canonicalDouble(value.x)),
                ("has_y", value.hasY ? "1" : "0"),
                ("y", canonicalDouble(value.y)),
                ("tolerance", canonicalDouble(value.tolerance)),
            ]
        case let .attributes(value):
            var attributes = [("criteria", "attributes")]
            attributes.append(contentsOf: value.attributes.keys.sorted().map { key in
                ("attribute.\(key)", value.attributes[key] ?? "")
            })
            parameters = attributes
        case let .compound(value):
            var compound: [(String, String)] = [
                ("criteria", "compound"),
                ("logical_operator", String(value.logicalOperator.rawValue)),
                ("count", String(value.selectors.count)),
            ]
            compound.append(contentsOf: value.selectors.enumerated().map { index, child in
                ("selector.\(index)", selectorQueryIdentity(child))
            })
            parameters = compound
        case nil:
            parameters = [("criteria", "none")]
        }
        return pageTokenQuery(method: "ElementSelector", parameters: parameters)
    }

    private static func canonicalDouble(_ value: Double) -> String {
        String(UInt64(value.bitPattern), radix: 16)
    }

    /// Encode an offset into an authenticated-encrypted token bound to the
    /// non-pagination parameters of one list query. Reusing the token with a
    /// different query fails closed. The URL-safe token contains only the
    /// encrypted payload, nonce, and authentication tag.
    static func encodePageToken(offset: Int, queryBinding: String) -> String {
        let queryHash = SHA256.hash(data: Data(queryBinding.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let payload = Data("\(pageTokenVersion):\(offset):\(queryHash)".utf8)
        guard let sealed = try? AES.GCM.seal(payload, using: tokenSecret) else {
            return ""
        }
        let combined = Data(sealed.nonce) + sealed.ciphertext + sealed.tag
        return base64URLEncode(combined)
    }

    /// Decode an authenticated-encrypted query-bound page token and verify its
    /// exact query identity before returning the offset.
    static func decodePageToken(_ token: String, queryBinding: String) throws -> Int {
        guard let combined = base64URLDecode(token),
              combined.count > pageTokenNonceLength + pageTokenTagLength,
              let nonce = try? AES.GCM.Nonce(data: combined.prefix(pageTokenNonceLength)),
              let box = try? AES.GCM.SealedBox(
                  nonce: nonce,
                  ciphertext: combined.dropFirst(pageTokenNonceLength).dropLast(pageTokenTagLength),
                  tag: combined.suffix(pageTokenTagLength),
              ),
              let plaintext = try? AES.GCM.open(box, using: tokenSecret),
              let tokenString = String(data: plaintext, encoding: .utf8)
        else {
            throw invalidPageToken()
        }
        let parts = tokenString.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == pageTokenVersion,
              let parsedOffset = Int(parts[1]),
              parsedOffset >= 0
        else {
            throw invalidPageToken()
        }
        let expectedQueryHash = SHA256.hash(data: Data(queryBinding.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard constantTimeEquals(String(parts[2]), expectedQueryHash) else {
            throw invalidPageToken(message: "page_token does not match this query")
        }
        return parsedOffset
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) ||
                      (byte >= 48 && byte <= 57) ||
                      byte == 45 ||
                      byte == 95
              })
        else {
            return nil
        }
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized),
              base64URLEncode(data) == value
        else {
            return nil
        }
        return data
    }

    struct PageCursor {
        let tokenOffset: Int
        let offset: Int
    }

    static func pageCursor(
        token: String,
        skip: Int,
        queryBinding: String,
    ) throws -> PageCursor {
        guard skip >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "skip must not be negative",
                reason: "INVALID_SKIP",
                field: "skip",
                value: String(skip),
            )
        }
        let tokenOffset = try pageOffset(token: token, queryBinding: queryBinding)
        let (offset, overflow) = tokenOffset.addingReportingOverflow(skip)
        guard !overflow else {
            throw RPCErrorHelpers.validationError(
                message: "page_token offset plus skip overflows",
                reason: "INVALID_SKIP",
                field: "skip",
            )
        }
        return PageCursor(tokenOffset: tokenOffset, offset: offset)
    }

    static func pageOffset(
        token: String,
        queryBinding: String,
    ) throws -> Int {
        token.isEmpty ? 0 : try decodePageToken(token, queryBinding: queryBinding)
    }

    static func pageRange(
        cursor: PageCursor,
        pageSize: Int,
        totalCount: Int,
    ) throws -> Range<Int> {
        guard pageSize > 0,
              totalCount >= 0,
              cursor.tokenOffset >= 0,
              cursor.offset >= cursor.tokenOffset
        else {
            throw invalidPageToken()
        }
        guard cursor.tokenOffset <= totalCount else {
            throw invalidPageToken(message: "page_token offset is outside the current collection")
        }
        guard cursor.offset < totalCount else {
            return totalCount ..< totalCount
        }
        let (candidateEnd, overflow) = cursor.offset.addingReportingOverflow(pageSize)
        let upperBound = overflow ? totalCount : min(candidateEnd, totalCount)
        return cursor.offset ..< upperBound
    }

    static func pageRange(
        offset: Int,
        pageSize: Int,
        totalCount: Int,
    ) throws -> Range<Int> {
        guard offset <= totalCount else {
            throw invalidPageToken(message: "page_token offset is outside the current collection")
        }
        let (candidateEnd, overflow) = offset.addingReportingOverflow(pageSize)
        guard !overflow else {
            throw invalidPageToken()
        }
        return offset ..< min(candidateEnd, totalCount)
    }

    static func nextPageToken(
        endOffset: Int,
        totalCount: Int,
        queryBinding: String,
    ) -> String {
        endOffset < totalCount
            ? encodePageToken(offset: endOffset, queryBinding: queryBinding)
            : ""
    }

    private static func invalidPageToken(
        message: String = "Invalid page_token format",
    ) -> RPCError {
        RPCErrorHelpers.validationError(
            message: message,
            reason: "INVALID_PAGE_TOKEN",
            field: "page_token",
        )
    }

    // MARK: - Resource Name Types (AIP-122)

    /// Parsed application resource name containing the extracted PID.
    struct ApplicationResource {
        let pid: pid_t
    }

    struct OpaqueApplicationResource {
        let name: String
        let resourceID: String
    }

    struct ApplicationBundleResource {
        let name: String
        let resourceID: String
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

    /// Parsed display resource name containing the exact Core Graphics display ID.
    struct DisplayResource {
        let displayID: UInt32
    }

    enum InputResourceOwner {
        case desktop
        case application(name: String)
    }

    struct InputResource {
        let owner: InputResourceOwner
        let inputID: String
    }

    // MARK: - Resource Name Parsing (AIP-122)

    static func parseOpaqueApplicationName(_ name: String) throws -> OpaqueApplicationResource {
        let resourceID = try parseOpaqueSHA256ResourceName(
            name,
            collection: "applications",
            field: "name",
        )
        return OpaqueApplicationResource(name: name, resourceID: resourceID)
    }

    static func parseApplicationBundleName(_ name: String) throws -> ApplicationBundleResource {
        let resourceID = try parseOpaqueSHA256ResourceName(
            name,
            collection: "applicationBundles",
            field: "name",
        )
        return ApplicationBundleResource(name: name, resourceID: resourceID)
    }

    private static func parseOpaqueSHA256ResourceName(
        _ name: String,
        collection: String,
        field: String,
    ) throws -> String {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == Substring(collection),
              components[1].count == 64,
              components[1].allSatisfy({ ("0" ... "9").contains($0) || ("a" ... "f").contains($0) })
        else {
            throw RPCErrorHelpers.validationError(
                message: "\(field) must be a canonical \(collection)/{opaque_id} resource name",
                reason: "INVALID_RESOURCE_NAME",
                field: field,
                value: name,
            )
        }
        return String(components[1])
    }

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
        try SessionResource(sessionId: parseSimpleResourceID(name, collection: "sessions"))
    }

    /// Parses a macro resource name of the format "macros/{id}".
    ///
    /// - Parameter name: The macro resource name (e.g., "macros/abc123").
    /// - Returns: A MacroResource containing the extracted macro ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseMacroName(_ name: String) throws -> MacroResource {
        try MacroResource(macroId: parseSimpleResourceID(name, collection: "macros"))
    }

    /// Parses an operation resource name of the format "operations/{id}".
    ///
    /// - Parameter name: The operation resource name (e.g., "operations/abc123").
    /// - Returns: An OperationResource containing the extracted operation ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseOperationName(_ name: String) throws -> OperationResource {
        try OperationResource(operationId: parseSimpleResourceID(name, collection: "operations"))
    }

    /// Parses either canonical Input resource pattern.
    static func parseInputName(_ name: String, field: String = "name") throws -> InputResource {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 4,
           components[0] == "applications",
           components[2] == "inputs"
        {
            let applicationID = try validateResourceID(String(components[1]), field: field)
            let inputID = try validateResourceID(String(components[3]), field: field)
            if applicationID == "-" {
                return InputResource(owner: .desktop, inputID: inputID)
            }
            return InputResource(
                owner: .application(name: "applications/\(applicationID)"),
                inputID: inputID,
            )
        }
        throw RPCErrorHelpers.validationError(
            message: "Invalid Input resource name. Expected applications/{application}/inputs/{input}",
            reason: "INVALID_RESOURCE_NAME",
            field: field,
            value: name,
        )
    }

    /// Validates one resource-ID segment using the canonical public grammar.
    @discardableResult
    static func validateResourceID(
        _ resourceID: String,
        field: String,
    ) throws -> String {
        let scalars = resourceID.unicodeScalars
        let isCanonical = !resourceID.isEmpty && resourceID.count <= 128 && scalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_" || scalar == "." || scalar == "~"
            )
        }
        guard isCanonical else {
            throw RPCErrorHelpers.validationError(
                message: "\(field) must be a canonical resource identifier",
                reason: "INVALID_RESOURCE_NAME",
                field: field,
                value: resourceID,
            )
        }
        return resourceID
    }

    private static func parseSimpleResourceID(
        _ name: String,
        collection: String,
    ) throws -> String {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        let resourceID = components.count == 2 ? String(components[1]) : ""
        guard components.count == 2,
              components[0] == Substring(collection)
        else {
            throw RPCErrorHelpers.validationError(
                message: "Invalid resource name. Expected canonical \(collection)/{id}",
                reason: "INVALID_RESOURCE_NAME",
                field: "name",
                value: name,
            )
        }
        do {
            return try validateResourceID(resourceID, field: "name")
        } catch {
            throw RPCErrorHelpers.validationError(
                message: "Invalid resource name. Expected canonical \(collection)/{id}",
                reason: "INVALID_RESOURCE_NAME",
                field: "name",
                value: name,
            )
        }
    }

    /// Parses a canonical display resource name of the format "displays/{display_id}".
    ///
    /// - Parameters:
    ///   - name: The display resource name (e.g., "displays/12345").
    ///   - field: The request field containing the resource name.
    /// - Returns: A DisplayResource containing the extracted positive UInt32 ID.
    /// - Throws: RPCError with .invalidArgument if the name format is invalid.
    static func parseDisplayName(_ name: String, field: String = "name") throws -> DisplayResource {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "displays",
              let displayID = UInt32(components[1]),
              displayID > 0,
              String(displayID) == components[1]
        else {
            throw RPCErrorHelpers.validationError(
                message: "Invalid display resource name: \(name). Expected canonical displays/{display_id}",
                reason: "INVALID_RESOURCE_NAME",
                field: field,
                value: name,
            )
        }
        return DisplayResource(displayID: displayID)
    }

    // MARK: - FieldMask Helpers (AIP-157)

    static func validateWindowReadMask(
        _ readMask: SwiftProtobuf.Google_Protobuf_FieldMask,
    ) throws {
        let supported: Set = [
            "bounds",
            "bundle_id",
            "layer",
            "name",
            "title",
            "visible",
        ]
        if readMask.paths.isEmpty {
            return
        }
        if readMask.paths.contains("*") {
            guard readMask.paths.count == 1 else {
                throw invalidFieldMask(readMask)
            }
            return
        }
        guard readMask.paths.allSatisfy(supported.contains) else {
            throw invalidFieldMask(readMask)
        }
    }

    private static func invalidFieldMask(
        _ readMask: SwiftProtobuf.Google_Protobuf_FieldMask,
    ) -> RPCError {
        RPCErrorHelpers.validationError(
            message: "read_mask contains an unsupported or malformed path",
            reason: "INVALID_FIELD_MASK",
            field: "read_mask",
            value: readMask.paths.joined(separator: ","),
        )
    }

    /// Applies a read_mask to a Window response per AIP-157.
    /// If the mask is empty, all fields are returned.
    /// Otherwise, only the specified fields are included (others are default values).
    ///
    /// Supported field paths: name, title, bounds, layer, visible, bundle_id
    ///
    /// - Parameters:
    ///   - window: The full window response with all fields populated.
    ///   - readMask: The FieldMask specifying which fields to return.
    /// - Returns: A new Window with only the requested fields populated.
    static func applyFieldMask(
        to window: Exactmac_V1_Window,
        readMask: SwiftProtobuf.Google_Protobuf_FieldMask,
    ) -> Exactmac_V1_Window {
        // If read_mask is empty or contains "*", return all fields per AIP-157
        if readMask.paths.isEmpty || readMask.paths.contains("*") {
            return window
        }

        // Create a new window with only requested fields
        var result = Exactmac_V1_Window()

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
            case "layer":
                result.layer = window.layer
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
        to application: Exactmac_V1_Application,
        readMask: SwiftProtobuf.Google_Protobuf_FieldMask,
    ) -> Exactmac_V1_Application {
        // If read_mask is empty or contains "*", return all fields per AIP-157
        if readMask.paths.isEmpty || readMask.paths.contains("*") {
            return application
        }

        // Create a new application with only requested fields
        var result = Exactmac_V1_Application()

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
