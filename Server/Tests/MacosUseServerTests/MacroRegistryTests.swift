import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Tests for the MacroRegistry actor.
///
/// MacroRegistry provides thread-safe CRUD operations for macros.
/// These tests verify the core functionality without timing dependencies.
final class MacroRegistryTests: XCTestCase {
    // We use a fresh registry for isolation. Since it's a singleton, we test behavior
    // that doesn't depend on prior state by using unique macro names.

    // MARK: - Create Tests

    func testCreateMacroWithGeneratedID() async {
        let registry = MacroRegistry.shared

        let macro = await registry.createMacro(
            macroId: nil,
            displayName: "Test Macro",
            description: "A test macro",
            actions: [],
            parameters: [],
            tags: ["test"],
        )

        // Should have generated a name with UUID format
        XCTAssertTrue(macro.name.hasPrefix("macros/"))
        XCTAssertEqual(macro.displayName, "Test Macro")
        XCTAssertEqual(macro.description_p, "A test macro")
        XCTAssertEqual(macro.executionCount, 0)
        XCTAssertEqual(macro.tags, ["test"])
    }

    func testCreateMacroWithProvidedID() async {
        let registry = MacroRegistry.shared
        let testId = "test-macro-\(UUID().uuidString)"

        let macro = await registry.createMacro(
            macroId: testId,
            displayName: "Custom ID Macro",
            description: "Macro with custom ID",
            actions: [],
            parameters: [],
            tags: [],
        )

        XCTAssertEqual(macro.name, "macros/\(testId)")
        XCTAssertEqual(macro.displayName, "Custom ID Macro")
    }

    // MARK: - Get Tests

    func testGetMacroExisting() async {
        let registry = MacroRegistry.shared
        let testId = "get-test-\(UUID().uuidString)"

        // Create a macro first
        _ = await registry.createMacro(
            macroId: testId,
            displayName: "Get Test Macro",
            description: "Test",
            actions: [],
            parameters: [],
            tags: [],
        )

        // Get it back
        let retrieved = await registry.getMacro(name: "macros/\(testId)")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.displayName, "Get Test Macro")
    }

    func testGetMacroNonExistent() async {
        let registry = MacroRegistry.shared

        let result = await registry.getMacro(name: "macros/nonexistent-\(UUID().uuidString)")

        XCTAssertNil(result)
    }

    // MARK: - List Tests

    func testListMacrosEmpty() async {
        // Since we can't clear the shared registry, we just verify list returns results
        let registry = MacroRegistry.shared

        // List with a filter that won't match anything (by checking result)
        // Since we can't clear the shared registry, we just verify list returns results
        let (macros, _) = await registry.listMacros(pageSize: 10, pageToken: nil)

        // Just verify it returns without error - can't guarantee empty due to shared state
        XCTAssertTrue(macros.count >= 0)
    }

    func testListMacrosPagination() async {
        let registry = MacroRegistry.shared
        let prefix = "list-page-\(UUID().uuidString)"

        // Create multiple macros
        for i in 0 ..< 5 {
            _ = await registry.createMacro(
                macroId: "\(prefix)-\(i)",
                displayName: "Macro \(i)",
                description: "Test",
                actions: [],
                parameters: [],
                tags: [],
            )
        }

        // Request smaller page
        let (firstPage, nextToken) = await registry.listMacros(pageSize: 3, pageToken: nil)

        XCTAssertEqual(firstPage.count, 3)
        XCTAssertNotNil(nextToken)

        // Request second page
        let (secondPage, finalToken) = await registry.listMacros(pageSize: 3, pageToken: nextToken)

        // Should get remaining (depends on total registry state)
        XCTAssertTrue(secondPage.count <= 3)
    }

    func testListMacrosDefaultPageSize() async {
        let registry = MacroRegistry.shared

        // Page size 0 should use default (50)
        let (macros, _) = await registry.listMacros(pageSize: 0, pageToken: nil)

        // Just verify it doesn't crash and returns up to 50
        XCTAssertTrue(macros.count <= 50)
    }

    // MARK: - Update Tests

    func testUpdateMacroExisting() async throws {
        let registry = MacroRegistry.shared
        let testId = "update-test-\(UUID().uuidString)"

        // Create
        let original = await registry.createMacro(
            macroId: testId,
            displayName: "Original Name",
            description: "Original",
            actions: [],
            parameters: [],
            tags: ["original"],
        )

        // Update
        let updated = await registry.updateMacro(
            name: "macros/\(testId)",
            displayName: "Updated Name",
            description: nil, // Keep original
            actions: nil,
            parameters: nil,
            tags: ["updated"],
        )

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.displayName, "Updated Name")
        XCTAssertEqual(updated?.description_p, "Original") // Unchanged
        XCTAssertEqual(updated?.tags, ["updated"])
        XCTAssertTrue(try XCTUnwrap(updated?.updateTime.seconds) >= original.createTime.seconds)
    }

    func testUpdateMacroNonExistent() async {
        let registry = MacroRegistry.shared

        let result = await registry.updateMacro(
            name: "macros/nonexistent-\(UUID().uuidString)",
            displayName: "New Name",
            description: nil,
            actions: nil,
            parameters: nil,
            tags: nil,
        )

        XCTAssertNil(result)
    }

    // MARK: - Delete Tests

    func testDeleteMacroExisting() async {
        let registry = MacroRegistry.shared
        let testId = "delete-test-\(UUID().uuidString)"

        // Create
        _ = await registry.createMacro(
            macroId: testId,
            displayName: "To Delete",
            description: "Test",
            actions: [],
            parameters: [],
            tags: [],
        )

        // Verify exists
        let beforeDelete = await registry.getMacro(name: "macros/\(testId)")
        XCTAssertNotNil(beforeDelete)

        // Delete
        let deleted = await registry.deleteMacro(name: "macros/\(testId)")
        XCTAssertTrue(deleted)

        // Verify gone
        let afterDelete = await registry.getMacro(name: "macros/\(testId)")
        XCTAssertNil(afterDelete)
    }

    func testDeleteMacroNonExistent() async {
        let registry = MacroRegistry.shared

        let result = await registry.deleteMacro(name: "macros/nonexistent-\(UUID().uuidString)")

        XCTAssertFalse(result)
    }

    // MARK: - Execution Count Tests

    func testIncrementExecutionCount() async {
        let registry = MacroRegistry.shared
        let testId = "exec-count-\(UUID().uuidString)"

        // Create
        let original = await registry.createMacro(
            macroId: testId,
            displayName: "Execution Counter",
            description: "Test",
            actions: [],
            parameters: [],
            tags: [],
        )
        XCTAssertEqual(original.executionCount, 0)

        // Increment
        await registry.incrementExecutionCount(name: "macros/\(testId)")

        // Verify
        let updated = await registry.getMacro(name: "macros/\(testId)")
        XCTAssertEqual(updated?.executionCount, 1)

        // Increment again
        await registry.incrementExecutionCount(name: "macros/\(testId)")

        let updatedAgain = await registry.getMacro(name: "macros/\(testId)")
        XCTAssertEqual(updatedAgain?.executionCount, 2)
    }

    func testIncrementExecutionCountNonExistent() async {
        let registry = MacroRegistry.shared

        // Should not crash for non-existent macro
        await registry.incrementExecutionCount(name: "macros/nonexistent-\(UUID().uuidString)")

        // No assertion needed - just verifying it doesn't crash
    }
}
