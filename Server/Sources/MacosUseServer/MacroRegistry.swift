import Foundation
import MacosUseProto
import OSLog
import SwiftProtobuf

/// Thread-safe registry for macro storage and management with persistence support
public actor MacroRegistry {
    private let logger = Logger(subsystem: "MacosUseServer", category: "MacroRegistry")
    private var macros: [String: Macosusesdk_V1_Macro] = [:]
    private let persistenceURL: URL?

    public init() {
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
        persist()
        return macro
    }

    /// Get macro by resource name
    public func getMacro(name: String) -> Macosusesdk_V1_Macro? {
        macros[name]
    }

    /// List all macros (with pagination support)
    public func listMacros(pageSize: Int, pageToken: String?) throws -> ([Macosusesdk_V1_Macro], String?) {
        let effectivePageSize = pageSize > 0 ? pageSize : 50
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListMacros",
            parameters: [("page_size", String(effectivePageSize))],
        )
        let offset = try ParsingHelpers.pageOffset(
            token: pageToken ?? "",
            queryBinding: queryBinding,
        )
        let allMacros = Array(macros.values).sorted { $0.name < $1.name }
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: effectivePageSize,
            totalCount: allMacros.count,
        )
        let page = Array(allMacros[range])
        let encodedNextToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: allMacros.count,
            queryBinding: queryBinding,
        )
        let nextToken = encodedNextToken.isEmpty ? nil : encodedNextToken

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
        persist()
        return macro
    }

    /// Delete a macro
    public func deleteMacro(name: String) -> Bool {
        let removed = macros.removeValue(forKey: name) != nil
        if removed {
            persist()
        }
        return removed
    }

    /// Increment execution count for a macro
    public func incrementExecutionCount(name: String) {
        guard var macro = macros[name] else { return }
        macro.executionCount += 1
        macro.updateTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        macros[name] = macro
        persist()
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
            logger.error("Failed to read persisted macros at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            throw PersistenceError.fileOperationFailed("Failed to read file: \(error.localizedDescription)")
        }

        // Decode store
        let store: MacroStore
        do {
            let decoder = JSONDecoder()
            store = try decoder.decode(MacroStore.self, from: data)
        } catch {
            logger.error("Failed to decode persisted macros at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            throw PersistenceError.corruptedFile("Failed to decode store: \(error.localizedDescription)")
        }

        // Version check (for future migrations)
        guard store.version == 1 else {
            logger.error("Unsupported macro store version \(store.version, privacy: .public) at \(url.path, privacy: .private)")
            throw PersistenceError.corruptedFile("Unsupported store version: \(store.version)")
        }

        // Parse macros
        if clearExisting {
            macros.removeAll()
        }

        for jsonString in store.macros {
            guard let jsonData = jsonString.data(using: .utf8) else {
                logger.error("Failed to decode a macro JSON string (invalid UTF-8) at \(url.path, privacy: .private)")
                throw PersistenceError.corruptedFile("Failed to decode macro JSON string")
            }
            do {
                let macro = try Macosusesdk_V1_Macro(jsonUTF8Data: jsonData)
                macros[macro.name] = macro
            } catch {
                logger.error("Failed to parse a macro proto at \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                throw PersistenceError.corruptedFile("Failed to parse macro proto: \(error.localizedDescription)")
            }
        }

        logger.info("Loaded \(self.macros.count, privacy: .public) macros from \(url.path, privacy: .private)")
    }

    /// Persists the current registry state without blocking the mutating call.
    ///
    /// A persistence failure is logged but never surfaced to the caller: an
    /// in-memory mutation has already succeeded and the registry remains
    /// internally consistent; losing durability is preferable to reverting a
    /// completed mutation or failing a write that the caller cannot recover.
    /// `noStorageLocation` (a registry with no persistence URL, e.g. in tests)
    /// is silent and expected.
    private func persist() {
        do {
            try save()
        } catch PersistenceError.noStorageLocation {
            // Expected for in-memory-only registries (tests, no App Support).
        } catch {
            logger.error("Failed to persist macros: \(String(describing: error), privacy: .public)")
        }
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
