import Foundation
import MacosUseSDKProtos
import SwiftProtobuf

/// Thread-safe registry for macro storage and management
public actor MacroRegistry {
    public static let shared = MacroRegistry()

    private var macros: [String: Macosusesdk_V1_Macro] = [:]

    private init() {}

    // MARK: - Macro Management

    /// Create a new macro with generated or provided ID
    public func createMacro(
        macroId: String?,
        displayName: String,
        description: String,
        actions: [Macosusesdk_V1_MacroAction],
        parameters: [Macosusesdk_V1_MacroParameter],
        tags: [String],
    ) -> Macosusesdk_V1_Macro {
        let id = macroId ?? UUID().uuidString
        let name = "macros/\(id)"

        let macro = Macosusesdk_V1_Macro.with {
            $0.name = name
            $0.displayName = displayName
            $0.description_p = description
            $0.actions = actions
            $0.parameters = parameters
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.updateTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.executionCount = 0
            $0.tags = tags
        }

        macros[name] = macro
        return macro
    }

    /// Get macro by resource name
    public func getMacro(name: String) -> Macosusesdk_V1_Macro? {
        macros[name]
    }

    /// List all macros (with pagination support)
    public func listMacros(pageSize: Int, pageToken: String?) -> ([Macosusesdk_V1_Macro], String?) {
        let allMacros = Array(macros.values).sorted { $0.name < $1.name }

        // Parse page token (we'll use it as start index)
        let startIndex = pageToken.flatMap(Int.init) ?? 0
        guard startIndex >= 0, startIndex < allMacros.count else {
            return ([], nil)
        }

        // Apply pagination
        let effectivePageSize = pageSize > 0 ? pageSize : 50
        let endIndex = min(startIndex + effectivePageSize, allMacros.count)
        let page = Array(allMacros[startIndex ..< endIndex])

        // Generate next token
        let nextToken = endIndex < allMacros.count ? String(endIndex) : nil

        return (page, nextToken)
    }

    /// Update an existing macro
    public func updateMacro(
        name: String,
        displayName: String?,
        description: String?,
        actions: [Macosusesdk_V1_MacroAction]?,
        parameters: [Macosusesdk_V1_MacroParameter]?,
        tags: [String]?,
    ) -> Macosusesdk_V1_Macro? {
        guard var macro = macros[name] else {
            return nil
        }

        // Apply updates
        if let displayName {
            macro.displayName = displayName
        }
        if let description {
            macro.description_p = description
        }
        if let actions {
            macro.actions = actions
        }
        if let parameters {
            macro.parameters = parameters
        }
        if let tags {
            macro.tags = tags
        }

        macro.updateTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())

        macros[name] = macro
        return macro
    }

    /// Delete a macro
    public func deleteMacro(name: String) -> Bool {
        macros.removeValue(forKey: name) != nil
    }

    /// Increment execution count for a macro
    public func incrementExecutionCount(name: String) {
        guard var macro = macros[name] else { return }
        macro.executionCount += 1
        macro.updateTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        macros[name] = macro
    }
}
