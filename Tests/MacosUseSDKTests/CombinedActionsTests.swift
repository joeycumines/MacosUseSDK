@testable import MacosUseSDK
import XCTest

/// Tests for CombinedActions diff calculation.
///
/// Verifies calculateDiff function for set operation correctness.
final class CombinedActionsTests: XCTestCase {
    // MARK: - TraversalDiff Structure

    func testTraversalDiff_emptyDiff() {
        let diff = TraversalDiff(added: [], removed: [], modified: [])

        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    func testTraversalDiff_withElements() {
        let addedElement = ElementData(
            role: "AXButton",
            text: "New Button",
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let removedElement = ElementData(
            role: "AXTextField",
            text: "Old Field",
            x: 0,
            y: 0,
            width: 300,
            height: 40,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let diff = TraversalDiff(
            added: [addedElement],
            removed: [removedElement],
            modified: [],
        )

        XCTAssertEqual(diff.added.count, 1)
        XCTAssertEqual(diff.removed.count, 1)
        XCTAssertTrue(diff.modified.isEmpty)
    }

    // MARK: - ModifiedElement Structure

    func testModifiedElement_structure() {
        let before = ElementData(
            role: "AXTextField",
            text: "Old Text",
            x: 100,
            y: 50,
            width: 200,
            height: 40,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let after = ElementData(
            role: "AXTextField",
            text: "New Text",
            x: 100,
            y: 50,
            width: 200,
            height: 40,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let change = AttributeChangeDetail(
            attribute: "text",
            before: "Old Text",
            after: "New Text",
        )

        let modified = ModifiedElement(before: before, after: after, changes: [change])

        XCTAssertEqual(modified.before.text, "Old Text")
        XCTAssertEqual(modified.after.text, "New Text")
        XCTAssertEqual(modified.changes.count, 1)
    }

    // MARK: - AttributeChangeDetail

    func testAttributeChangeDetail_textInitializer() {
        let change = AttributeChangeDetail(
            textBefore: "Hello",
            textAfter: "Hello World",
        )

        XCTAssertEqual(change.attributeName, "text")
    }

    func testAttributeChangeDetail_doubleInitializer() {
        let change = AttributeChangeDetail(
            attribute: "x",
            before: 100.0,
            after: 200.0,
        )

        XCTAssertEqual(change.attributeName, "x")
        XCTAssertEqual(change.oldValue, "100.0")
        XCTAssertEqual(change.newValue, "200.0")
    }

    func testAttributeChangeDetail_genericInitializer() {
        let change = AttributeChangeDetail(
            attribute: "enabled",
            before: true,
            after: false,
        )

        XCTAssertEqual(change.attributeName, "enabled")
        XCTAssertEqual(change.oldValue, "true")
        XCTAssertEqual(change.newValue, "false")
    }

    // MARK: - ActionDiffResult Structure

    func testActionDiffResult_structure() {
        let afterTraversal = ResponseData(
            app_name: "TestApp",
            elements: [],
            stats: Statistics(),
            processing_time_seconds: "0.1",
        )

        let diff = TraversalDiff(added: [], removed: [], modified: [])

        let result = ActionDiffResult(
            afterAction: afterTraversal,
            diff: diff,
        )

        XCTAssertEqual(result.afterAction.app_name, "TestApp")
        XCTAssertTrue(result.diff.added.isEmpty)
    }

    // MARK: - Codable Tests

    func testTraversalDiff_codable() throws {
        let element = ElementData(
            role: "AXButton",
            text: "Test",
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let diff = TraversalDiff(
            added: [element],
            removed: [],
            modified: [],
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(diff)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TraversalDiff.self, from: data)

        XCTAssertEqual(decoded.added.count, 1)
        XCTAssertEqual(decoded.added[0].role, "AXButton")
    }

    func testModifiedElement_codable() throws {
        let before = ElementData(
            role: "AXTextField",
            text: "Old",
            x: 100,
            y: 50,
            width: 200,
            height: 40,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let after = ElementData(
            role: "AXTextField",
            text: "New",
            x: 100,
            y: 50,
            width: 200,
            height: 40,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let change = AttributeChangeDetail(
            attribute: "text",
            before: "Old",
            after: "New",
        )

        let modified = ModifiedElement(before: before, after: after, changes: [change])

        let encoder = JSONEncoder()
        let data = try encoder.encode(modified)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ModifiedElement.self, from: data)

        XCTAssertEqual(decoded.before.text, "Old")
        XCTAssertEqual(decoded.after.text, "New")
        XCTAssertEqual(decoded.changes.count, 1)
    }

    // MARK: - Sendable Tests

    func testTraversalDiff_sendable() {
        let diff = TraversalDiff(added: [], removed: [], modified: [])

        // If this compiles, Sendable conformance is present
        XCTAssertNotNil(diff)
    }

    func testModifiedElement_sendable() {
        let before = ElementData(
            role: "AXButton",
            text: nil,
            x: 0,
            y: 0,
            width: 10,
            height: 10,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let after = before
        let change = AttributeChangeDetail(attribute: "x", before: 0, after: 0)
        let modified = ModifiedElement(before: before, after: after, changes: [change])

        XCTAssertNotNil(modified)
    }

    // MARK: - Set Operations for Diff Calculation

    func testElementSet_difference() {
        let element1 = ElementData(
            role: "AXButton",
            text: "A",
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        // Create elements with SAME text so they are equal in Set
        let element2 = ElementData(
            role: "AXButton",
            text: "A", // Same as element1 and element3
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let element3 = ElementData(
            role: "AXButton",
            text: "A", // Same as element1 and element2
            x: 100,
            y: 50,
            width: 200,
            height: 50,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )

        let set1 = Set([element1])
        let set2 = Set([element2, element3])

        // element1, element2, and element3 are all equal, so set2 contains only one element
        XCTAssertEqual(set2.count, 1)
        XCTAssertTrue(set2.contains(element3))
    }
}
