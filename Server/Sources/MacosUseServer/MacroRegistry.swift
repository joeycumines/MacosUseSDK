import Foundation
import MacosUseProto
import OSLog
import SwiftProtobuf

/// Thread-safe registry for macro storage and management with persistence support
public actor MacroRegistry {
    public static let shared = MacroRegistry()

    private let logger = Logger(subsystem: "MacosUseServer", category: "MacroRegistry")
    private var macros: [String: Macosusesdk_V1_Macro] = [:]
    private let persistenceURL: URL?

    private init() {
        // Default persistence location: Application Support/MacosUseServer/macros.json
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
        ).first {
            let serverDir = appSupport.appendingPathComponent("MacosUseServer", isDirectory: true)
            self.persistenceURL = serverDir.appendingPathComponent("macros.json")
        } else {
            self.persistenceURL = nil
        }
    }

    /// Initialize with custom persistence URL (for testing)
    public init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
    }

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

    // MARK: - Persistence

    /// Internal representation for JSON persistence.
    /// Uses SwiftProtobuf's JSON encoding for each macro.
    private struct MacroStore: Codable {
        let version: Int
        let macros: [String] // JSON-encoded protos

        init(version: Int = 1, macros: [String]) {
            self.version = version
            self.macros = macros
        }
    }

    /// Persistence error types.
    public enum PersistenceError: Error, Equatable {
        case noStorageLocation
        case encodingFailed(String)
        case fileOperationFailed(String)
        case corruptedFile(String)
    }

    /// Save all macros to persistent storage.
    /// - Throws: `PersistenceError` if serialization or file write fails.
    public func save() throws(PersistenceError) {
        guard let url = persistenceURL else {
            throw .noStorageLocation
        }

        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.fileOperationFailed("Failed to create directory: \(error.localizedDescription)")
        }

        // Serialize each macro to JSON
        var jsonMacros: [String] = []
        for (_, macro) in macros {
            do {
                let jsonData = try macro.jsonUTF8Data()
                guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                    throw PersistenceError.encodingFailed("Failed to encode macro to UTF-8 string")
                }
                jsonMacros.append(jsonString)
            } catch let error as PersistenceError {
                throw error
            } catch {
                throw PersistenceError.encodingFailed("Proto serialization failed: \(error.localizedDescription)")
            }
        }

        // Create store and write
        let store = MacroStore(macros: jsonMacros)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: url, options: .atomic)
            logger.info("Saved \(self.macros.count, privacy: .public) macros to \(url.path, privacy: .private)")
        } catch {
            throw PersistenceError.fileOperationFailed("Failed to write file: \(error.localizedDescription)")
        }
    }

    /// Load macros from persistent storage.
    /// - Parameter clearExisting: If true, clears current macros before loading. Default is true.
    /// - Throws: `PersistenceError` if deserialization or file read fails.
    /// - Note: Missing file is NOT an error - results in empty registry.
    public func load(clearExisting: Bool = true) throws(PersistenceError) {
        guard let url = persistenceURL else {
            throw .noStorageLocation
        }

        // Missing file is OK - just start empty
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No persisted macros file found at \(url.path, privacy: .private), starting empty")
            if clearExisting {
                macros.removeAll()
            }
            return
        }

        // Read file
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PersistenceError.fileOperationFailed("Failed to read file: \(error.localizedDescription)")
        }

        // Decode store
        let store: MacroStore
        do {
            let decoder = JSONDecoder()
            store = try decoder.decode(MacroStore.self, from: data)
        } catch {
            throw PersistenceError.corruptedFile("Failed to decode store: \(error.localizedDescription)")
        }

        // Version check (for future migrations)
        guard store.version == 1 else {
            throw PersistenceError.corruptedFile("Unsupported store version: \(store.version)")
        }

        // Parse macros
        if clearExisting {
            macros.removeAll()
        }

        for jsonString in store.macros {
            guard let jsonData = jsonString.data(using: .utf8) else {
                throw PersistenceError.corruptedFile("Failed to decode macro JSON string")
            }
            do {
                let macro = try Macosusesdk_V1_Macro(jsonUTF8Data: jsonData)
                macros[macro.name] = macro
            } catch {
                throw PersistenceError.corruptedFile("Failed to parse macro proto: \(error.localizedDescription)")
            }
        }

        logger.info("Loaded \(self.macros.count, privacy: .public) macros from \(url.path, privacy: .private)")
    }

    /// Get the number of macros in the registry.
    public func count() -> Int {
        macros.count
    }

    /// Clear all macros from memory (does NOT clear persisted file).
    public func clearAll() {
        macros.removeAll()
    }

    /// Get persistence URL (for testing).
    public func getPersistenceURL() -> URL? {
        persistenceURL
    }
}
