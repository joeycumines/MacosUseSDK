import Foundation
import MacosUseProto
@testable import MacosUseServer
import Testing

/// Tests for MacroRegistry persistence functionality.
///
/// These tests verify save/load operations, error handling for corrupted files,
/// missing files, and concurrent persistence safety.
@Suite("MacroRegistry Persistence Tests", .serialized)
struct MacroRegistryPersistenceTests {
    // MARK: - Test Fixture

    /// Creates a unique temporary directory for each test.
    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacroRegistryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Cleans up a temporary directory.
    private func cleanupTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Save Tests

    @Test("save writes macros to file")
    func saveWritesToFile() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")
        let registry = MacroRegistry(persistenceURL: persistenceURL)

        // Create some macros
        _ = await registry.createMacro(
            macroId: "test-macro-1",
            displayName: "Test Macro 1",
            description: "First test macro",
            actions: [],
            parameters: [],
            tags: ["test"],
        )
        _ = await registry.createMacro(
            macroId: "test-macro-2",
            displayName: "Test Macro 2",
            description: "Second test macro",
            actions: [],
            parameters: [],
            tags: ["test", "example"],
        )

        // Save
        try await registry.save()

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: persistenceURL.path))

        // Verify file content is valid JSON
        let data = try Data(contentsOf: persistenceURL)
        let decoded = try JSONDecoder().decode(TestMacroStore.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.macros.count == 2)
    }

    @Test("save with empty registry creates empty store")
    func saveEmptyRegistry() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")
        let registry = MacroRegistry(persistenceURL: persistenceURL)

        // Save empty registry
        try await registry.save()

        // Verify file exists with empty array
        let data = try Data(contentsOf: persistenceURL)
        let decoded = try JSONDecoder().decode(TestMacroStore.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.macros.isEmpty)
    }

    @Test("save creates parent directories if missing")
    func saveCreatesDirectories() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let nestedDir = tempDir.appendingPathComponent("nested/deep/path", isDirectory: true)
        let persistenceURL = nestedDir.appendingPathComponent("macros.json")
        let registry = MacroRegistry(persistenceURL: persistenceURL)

        _ = await registry.createMacro(
            macroId: "nested-test",
            displayName: "Nested Test",
            description: "Test",
            actions: [],
            parameters: [],
            tags: [],
        )

        try await registry.save()

        #expect(FileManager.default.fileExists(atPath: persistenceURL.path))
    }

    @Test("save throws when no storage location")
    func saveThrowsNoStorageLocation() async throws {
        let registry = MacroRegistry(persistenceURL: nil)

        _ = await registry.createMacro(
            macroId: "test",
            displayName: "Test",
            description: "Test",
            actions: [],
            parameters: [],
            tags: [],
        )

        do {
            try await registry.save()
            Issue.record("Expected PersistenceError.noStorageLocation")
        } catch MacroRegistry.PersistenceError.noStorageLocation {
            // Expected
        }
    }

    // MARK: - Load Tests

    @Test("load restores macros from file")
    func loadRestoresFromFile() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Create and save with first registry
        let registry1 = MacroRegistry(persistenceURL: persistenceURL)
        _ = await registry1.createMacro(
            macroId: "persisted-macro",
            displayName: "Persisted Macro",
            description: "Should survive load",
            actions: [],
            parameters: [],
            tags: ["persisted"],
        )
        try await registry1.save()

        // Load with new registry
        let registry2 = MacroRegistry(persistenceURL: persistenceURL)
        try await registry2.load()

        // Verify macro was restored
        let retrieved = await registry2.getMacro(name: "macros/persisted-macro")
        #expect(retrieved != nil)
        #expect(retrieved?.displayName == "Persisted Macro")
        #expect(retrieved?.description_p == "Should survive load")
        #expect(retrieved?.tags == ["persisted"])
    }

    @Test("load with missing file starts empty")
    func loadMissingFileStartsEmpty() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("nonexistent.json")
        let registry = MacroRegistry(persistenceURL: persistenceURL)

        // Should not throw
        try await registry.load()

        // Should have no macros
        let count = await registry.count()
        #expect(count == 0)
    }

    @Test("load clears existing macros by default")
    func loadClearsExisting() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Create empty persisted state
        let emptyRegistry = MacroRegistry(persistenceURL: persistenceURL)
        try await emptyRegistry.save()

        // Registry with in-memory data
        let registry = MacroRegistry(persistenceURL: persistenceURL)
        _ = await registry.createMacro(
            macroId: "memory-only",
            displayName: "Memory Only",
            description: "Should be cleared",
            actions: [],
            parameters: [],
            tags: [],
        )

        // Load (should clear)
        try await registry.load(clearExisting: true)

        // Memory-only macro should be gone
        let retrieved = await registry.getMacro(name: "macros/memory-only")
        #expect(retrieved == nil)
    }

    @Test("load with clearExisting false preserves memory")
    func loadPreservesMemory() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Create persisted state with one macro
        let registry1 = MacroRegistry(persistenceURL: persistenceURL)
        _ = await registry1.createMacro(
            macroId: "persisted",
            displayName: "Persisted",
            description: "From disk",
            actions: [],
            parameters: [],
            tags: [],
        )
        try await registry1.save()

        // Registry with in-memory data
        let registry2 = MacroRegistry(persistenceURL: persistenceURL)
        _ = await registry2.createMacro(
            macroId: "memory",
            displayName: "Memory",
            description: "In memory",
            actions: [],
            parameters: [],
            tags: [],
        )

        // Load without clearing
        try await registry2.load(clearExisting: false)

        // Both should exist
        let persisted = await registry2.getMacro(name: "macros/persisted")
        let memory = await registry2.getMacro(name: "macros/memory")
        #expect(persisted != nil)
        #expect(memory != nil)
    }

    @Test("load throws when no storage location")
    func loadThrowsNoStorageLocation() async throws {
        let registry = MacroRegistry(persistenceURL: nil)

        do {
            try await registry.load()
            Issue.record("Expected PersistenceError.noStorageLocation")
        } catch MacroRegistry.PersistenceError.noStorageLocation {
            // Expected
        }
    }

    // MARK: - Corrupted File Tests

    @Test("load throws on corrupted JSON structure")
    func loadThrowsOnCorruptedJSON() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Write invalid JSON
        try "not valid json {{{".write(to: persistenceURL, atomically: true, encoding: .utf8)

        let registry = MacroRegistry(persistenceURL: persistenceURL)

        do {
            try await registry.load()
            Issue.record("Expected PersistenceError.corruptedFile")
        } catch MacroRegistry.PersistenceError.corruptedFile {
            // Expected
        }
    }

    @Test("load throws on invalid store version")
    func loadThrowsOnInvalidVersion() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Write store with future version
        let futureStore = TestMacroStore(version: 999, macros: [])
        let data = try JSONEncoder().encode(futureStore)
        try data.write(to: persistenceURL)

        let registry = MacroRegistry(persistenceURL: persistenceURL)

        do {
            try await registry.load()
            Issue.record("Expected PersistenceError.corruptedFile for version mismatch")
        } catch MacroRegistry.PersistenceError.corruptedFile {
            // Expected - version mismatch triggers corruptedFile error
        }
    }

    @Test("load throws on invalid proto JSON in macros array")
    func loadThrowsOnInvalidProtoJSON() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Write store with invalid proto JSON
        let brokenStore = TestMacroStore(version: 1, macros: ["not valid proto json"])
        let data = try JSONEncoder().encode(brokenStore)
        try data.write(to: persistenceURL)

        let registry = MacroRegistry(persistenceURL: persistenceURL)

        do {
            try await registry.load()
            Issue.record("Expected PersistenceError.corruptedFile for invalid proto")
        } catch MacroRegistry.PersistenceError.corruptedFile {
            // Expected
        }
    }

    @Test("load throws on empty string in macros array")
    func loadThrowsOnEmptyMacroString() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Write store with empty string
        let brokenStore = TestMacroStore(version: 1, macros: [""])
        let data = try JSONEncoder().encode(brokenStore)
        try data.write(to: persistenceURL)

        let registry = MacroRegistry(persistenceURL: persistenceURL)

        do {
            try await registry.load()
            Issue.record("Expected PersistenceError.corruptedFile for empty proto")
        } catch MacroRegistry.PersistenceError.corruptedFile {
            // Expected
        }
    }

    // MARK: - Concurrent Safety Tests

    @Test("concurrent save operations complete without data loss")
    func concurrentSaveOperations() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")
        let registry = MacroRegistry(persistenceURL: persistenceURL)

        // Create initial macros
        for i in 0 ..< 10 {
            _ = await registry.createMacro(
                macroId: "concurrent-\(i)",
                displayName: "Concurrent \(i)",
                description: "Test \(i)",
                actions: [],
                parameters: [],
                tags: [],
            )
        }

        // Perform concurrent saves
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    try? await registry.save()
                }
            }
        }

        // Verify file is valid after concurrent writes
        let newRegistry = MacroRegistry(persistenceURL: persistenceURL)
        try await newRegistry.load()
        let count = await newRegistry.count()
        #expect(count == 10)
    }

    @Test("save and load roundtrip preserves all macro fields")
    func roundtripPreservesAllFields() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")
        let registry1 = MacroRegistry(persistenceURL: persistenceURL)

        // Create macro with fields populated (use empty actions/parameters for simplicity)
        _ = await registry1.createMacro(
            macroId: "full-macro",
            displayName: "Full Macro",
            description: "A macro with all fields",
            actions: [],
            parameters: [],
            tags: ["full", "complete", "test"],
        )

        // Increment execution count
        await registry1.incrementExecutionCount(name: "macros/full-macro")

        // Save and reload
        try await registry1.save()

        let registry2 = MacroRegistry(persistenceURL: persistenceURL)
        try await registry2.load()

        // Verify all fields
        let retrieved = await registry2.getMacro(name: "macros/full-macro")
        #expect(retrieved != nil)
        #expect(retrieved?.displayName == "Full Macro")
        #expect(retrieved?.description_p == "A macro with all fields")
        #expect(retrieved?.tags == ["full", "complete", "test"])
        #expect(retrieved?.executionCount == 1)
        // Verify timestamps are present
        #expect((retrieved?.createTime.seconds ?? 0) > 0)
        #expect((retrieved?.updateTime.seconds ?? 0) > 0)
    }

    // MARK: - Helper Types

    /// Mirror of MacroRegistry.MacroStore for test decoding.
    private struct TestMacroStore: Codable {
        let version: Int
        let macros: [String]
    }
}
