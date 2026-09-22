import ExactMacProto
@testable import ExactMacServer
import Foundation
import Testing

/// Tests for MacroRegistry persistence functionality.
///
/// These tests verify save/load operations, error handling for corrupted files,
/// missing files, and concurrent persistence safety.
@Suite(.serialized)
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

    @Test
    func `save writes macros to file`() async throws {
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

    @Test
    func `save with empty registry creates empty store`() async throws {
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

    @Test
    func `save creates parent directories if missing`() async throws {
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

    @Test
    func `save throws when no storage location`() async throws {
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

    @Test
    func `load restores macros from file`() async throws {
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

    @Test
    func `load with missing file starts empty`() async throws {
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

    @Test
    func `load clears existing macros by default`() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // A registry creates a macro. createMacro now auto-persists, so the
        // macro is present both in memory and on disk.
        let registry = MacroRegistry(persistenceURL: persistenceURL)
        _ = await registry.createMacro(
            macroId: "memory-only",
            displayName: "Memory Only",
            description: "Should be cleared",
            actions: [],
            parameters: [],
            tags: [],
        )
        #expect(await registry.getMacro(name: "macros/memory-only") != nil)

        // Remove the persisted file out-of-band so the macro survives only in
        // memory. load(clearExisting: true) must then clear that in-memory state
        // because the file (the source of truth) no longer contains it.
        try FileManager.default.removeItem(at: persistenceURL)

        try await registry.load(clearExisting: true)

        let retrieved = await registry.getMacro(name: "macros/memory-only")
        #expect(retrieved == nil)
    }

    @Test
    func `load with clearExisting false preserves memory`() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // registry holds "memory" in-memory (createMacro auto-persists it to the
        // shared file, so the file currently contains only "memory").
        let registry = MacroRegistry(persistenceURL: persistenceURL)
        _ = await registry.createMacro(
            macroId: "memory",
            displayName: "Memory",
            description: "In memory",
            actions: [],
            parameters: [],
            tags: [],
        )

        // A second registry with a DIFFERENT URL writes "persisted" to its own
        // file, then we copy that file over the shared URL so the shared file
        // contains only "persisted" while registry still holds "memory" in
        // memory. (registry2's auto-persist cannot touch the shared URL.)
        let otherURL = tempDir.appendingPathComponent("other.json")
        let registry2 = MacroRegistry(persistenceURL: otherURL)
        _ = await registry2.createMacro(
            macroId: "persisted",
            displayName: "Persisted",
            description: "From disk",
            actions: [],
            parameters: [],
            tags: [],
        )
        // Replace the shared file with registry2's persisted store.
        try FileManager.default.removeItem(at: persistenceURL)
        try FileManager.default.copyItem(at: otherURL, to: persistenceURL)

        // load(clearExisting: false) must merge the file's "persisted" into
        // registry's memory WITHOUT dropping the in-memory "memory".
        try await registry.load(clearExisting: false)

        let persisted = await registry.getMacro(name: "macros/persisted")
        let memory = await registry.getMacro(name: "macros/memory")
        #expect(persisted != nil)
        #expect(memory != nil)
    }

    @Test
    func `load throws when no storage location`() async throws {
        let registry = MacroRegistry(persistenceURL: nil)

        do {
            try await registry.load()
            Issue.record("Expected PersistenceError.noStorageLocation")
        } catch MacroRegistry.PersistenceError.noStorageLocation {
            // Expected
        }
    }

    // MARK: - Corrupted File Tests

    @Test
    func `load throws on corrupted JSON structure`() async throws {
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

    @Test
    func `load throws on invalid store version`() async throws {
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

    @Test
    func `load throws on invalid proto JSON in macros array`() async throws {
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

    @Test
    func `load throws on empty string in macros array`() async throws {
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

    @Test
    func `concurrent save operations complete without data loss`() async throws {
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

    @Test
    func `save and load roundtrip preserves all macro fields`() async throws {
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

    // MARK: - Restart Survival (defect C2)

    @Test
    func `macros survive a simulated server restart through the composition`() async throws {
        // The production contract (defect C2): mutating the composition-owned
        // registry must durably persist so a fresh server process — constructing
        // a new composition over the same persistence URL and calling
        // loadPersistedMacros() on startup — observes the previously created
        // macro. Before C2, save()/load() were dead code and every macro was
        // lost on restart.
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }
        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        // Simulate the first server process: create a macro through the
        // composition-owned registry.
        let firstRegistry = MacroRegistry(persistenceURL: persistenceURL)
        let created = await firstRegistry.createMacro(
            macroId: "survives-restart",
            displayName: "Survives Restart",
            description: "Must persist across processes",
            actions: [],
            parameters: [],
            tags: ["restart"],
        )
        // createMacro now auto-persists; the file must exist and be non-empty.
        #expect(FileManager.default.fileExists(atPath: persistenceURL.path))

        // Simulate a restart: a brand-new registry bound to the same URL, with
        // no in-memory state, hydrates from disk exactly as the composition's
        // loadPersistedMacros() does on startup.
        let restartedRegistry = MacroRegistry(persistenceURL: persistenceURL)
        #expect(await restartedRegistry.count() == 0) // empty before load
        try await restartedRegistry.load()

        let recovered = await restartedRegistry.getMacro(name: created.name)
        #expect(recovered != nil)
        #expect(recovered?.name == created.name)
        #expect(recovered?.displayName == "Survives Restart")
        #expect(recovered?.tags == ["restart"])
    }

    @Test
    func `mutation methods persist durably across registry instances`() async throws {
        // Each mutating path (create/update/delete/incrementExecutionCount)
        // must persist so the change is visible to a fresh registry over the
        // same URL. Guards against a regression that reverts any single
        // persist() call.
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }
        let persistenceURL = tempDir.appendingPathComponent("macros.json")

        let writer = MacroRegistry(persistenceURL: persistenceURL)
        let created = await writer.createMacro(
            macroId: "mutated",
            displayName: "Original",
            description: "",
            actions: [],
            parameters: [],
            tags: [],
        )
        _ = await writer.updateMacro(
            name: created.name,
            displayName: "Updated",
            description: nil,
            actions: nil,
            parameters: nil,
            tags: ["t1"],
        )

        // A fresh registry must observe the update (proves updateMacro persisted).
        let reader = MacroRegistry(persistenceURL: persistenceURL)
        try await reader.load()
        let afterUpdate = await reader.getMacro(name: created.name)
        #expect(afterUpdate?.displayName == "Updated")
        #expect(afterUpdate?.tags == ["t1"])

        // incrementExecutionCount must persist.
        await writer.incrementExecutionCount(name: created.name)
        let reader2 = MacroRegistry(persistenceURL: persistenceURL)
        try await reader2.load()
        #expect(await reader2.getMacro(name: created.name)?.executionCount == 1)

        // deleteMacro must persist.
        _ = await writer.deleteMacro(name: created.name)
        let reader3 = MacroRegistry(persistenceURL: persistenceURL)
        try await reader3.load()
        #expect(await reader3.getMacro(name: created.name) == nil)
    }

    // MARK: - Helper Types

    /// Mirror of MacroRegistry.MacroStore for test decoding.
    private struct TestMacroStore: Codable {
        let version: Int
        let macros: [String]
    }
}
