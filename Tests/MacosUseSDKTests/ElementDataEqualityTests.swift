@testable import MacosUseSDK
import XCTest

/// Tests for ElementData's Hashable and Equatable conformance.
///
/// ElementData has custom implementations for:
/// - `hash(into:)` - combines role, text, x, y, width, height, path
/// - `==` - compares the same 7 fields
///
/// Notably, `axElement`, `enabled`, `focused`, and `attributes` are NOT
/// included in equality/hashing, which is intentional for set-based diff logic.
final class ElementDataEqualityTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeElement(
        role: String = "AXButton",
        text: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        attributes: [String: String] = [:],
        path: [Int32] = [],
    ) -> ElementData {
        ElementData(
            role: role,
            text: text,
            x: x,
            y: y,
            width: width,
            height: height,
            axElement: nil,
            enabled: enabled,
            focused: focused,
            attributes: attributes,
            path: path,
        )
    }

    // MARK: - Equality Tests (== operator)

    func testEquality_identicalElements_areEqual() {
        let e1 = makeElement(role: "AXButton", text: "Click", x: 10, y: 20, width: 100, height: 50, path: [0, 1])
        let e2 = makeElement(role: "AXButton", text: "Click", x: 10, y: 20, width: 100, height: 50, path: [0, 1])

        XCTAssertEqual(e1, e2)
    }

    func testEquality_differentRole_notEqual() {
        let e1 = makeElement(role: "AXButton")
        let e2 = makeElement(role: "AXTextField")

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentText_notEqual() {
        let e1 = makeElement(text: "Hello")
        let e2 = makeElement(text: "World")

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_textNilVsEmpty_notEqual() {
        let e1 = makeElement(text: nil)
        let e2 = makeElement(text: "")

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentX_notEqual() {
        let e1 = makeElement(x: 10)
        let e2 = makeElement(x: 20)

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentY_notEqual() {
        let e1 = makeElement(y: 10)
        let e2 = makeElement(y: 20)

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentWidth_notEqual() {
        let e1 = makeElement(width: 100)
        let e2 = makeElement(width: 200)

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentHeight_notEqual() {
        let e1 = makeElement(height: 50)
        let e2 = makeElement(height: 100)

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentPath_notEqual() {
        let e1 = makeElement(path: [0, 1, 2])
        let e2 = makeElement(path: [0, 1, 3])

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_differentPathLength_notEqual() {
        let e1 = makeElement(path: [0, 1])
        let e2 = makeElement(path: [0, 1, 2])

        XCTAssertNotEqual(e1, e2)
    }

    // MARK: - Equality ignores non-key fields

    func testEquality_differentEnabled_stillEqual() {
        let e1 = makeElement(role: "A", text: "X", x: 0, y: 0, width: 10, height: 10, enabled: true, path: [0])
        let e2 = makeElement(role: "A", text: "X", x: 0, y: 0, width: 10, height: 10, enabled: false, path: [0])

        XCTAssertEqual(e1, e2)
    }

    func testEquality_differentFocused_stillEqual() {
        let e1 = makeElement(role: "A", text: "X", x: 0, y: 0, width: 10, height: 10, focused: true, path: [0])
        let e2 = makeElement(role: "A", text: "X", x: 0, y: 0, width: 10, height: 10, focused: false, path: [0])

        XCTAssertEqual(e1, e2)
    }

    func testEquality_differentAttributes_stillEqual() {
        let e1 = makeElement(
            role: "A",
            text: "X",
            x: 0, y: 0, width: 10, height: 10,
            attributes: ["key": "value1"],
            path: [0],
        )
        let e2 = makeElement(
            role: "A",
            text: "X",
            x: 0, y: 0, width: 10, height: 10,
            attributes: ["key": "value2"],
            path: [0],
        )

        XCTAssertEqual(e1, e2)
    }

    // MARK: - Hashable Tests

    func testHashable_equalElements_sameHash() {
        let e1 = makeElement(role: "AXButton", text: "OK", x: 10, y: 20, width: 80, height: 30, path: [1, 2])
        let e2 = makeElement(role: "AXButton", text: "OK", x: 10, y: 20, width: 80, height: 30, path: [1, 2])

        XCTAssertEqual(e1.hashValue, e2.hashValue)
    }

    func testHashable_inSet_deduplicatesEqualElements() {
        let e1 = makeElement(role: "AXButton", text: "OK", x: 10, y: 20, width: 80, height: 30, path: [0])
        let e2 = makeElement(role: "AXButton", text: "OK", x: 10, y: 20, width: 80, height: 30, path: [0])
        let e3 = makeElement(role: "AXButton", text: "OK", x: 10, y: 20, width: 80, height: 30, path: [0])

        let set: Set<ElementData> = [e1, e2, e3]
        XCTAssertEqual(set.count, 1)
    }

    func testHashable_inSet_retainsDifferentElements() {
        let e1 = makeElement(role: "AXButton", path: [0])
        let e2 = makeElement(role: "AXTextField", path: [0])
        let e3 = makeElement(role: "AXButton", path: [1])

        let set: Set<ElementData> = [e1, e2, e3]
        XCTAssertEqual(set.count, 3)
    }

    func testHashable_differentNonKeyFields_sameHash() {
        let e1 = makeElement(
            role: "A", text: nil, x: 0, y: 0, width: 10, height: 10,
            enabled: true, focused: true, attributes: ["a": "b"],
            path: [0],
        )
        let e2 = makeElement(
            role: "A", text: nil, x: 0, y: 0, width: 10, height: 10,
            enabled: false, focused: false, attributes: ["c": "d"],
            path: [0],
        )

        XCTAssertEqual(e1.hashValue, e2.hashValue)
    }

    // MARK: - Edge Cases

    func testEquality_allNilOptionals_equal() {
        let e1 = makeElement(text: nil, x: nil, y: nil, width: nil, height: nil)
        let e2 = makeElement(text: nil, x: nil, y: nil, width: nil, height: nil)

        XCTAssertEqual(e1, e2)
    }

    func testEquality_emptyPath_equal() {
        let e1 = makeElement(path: [])
        let e2 = makeElement(path: [])

        XCTAssertEqual(e1, e2)
    }

    func testEquality_negativePathValues_handled() {
        // Negative path values are valid (window indices encoded as -(index+1))
        let e1 = makeElement(path: [-1, 0, 2])
        let e2 = makeElement(path: [-1, 0, 2])

        XCTAssertEqual(e1, e2)
    }

    func testEquality_specialMainWindowPath_handled() {
        // -10000 is a special value for main window
        let e1 = makeElement(path: [-10000, 0])
        let e2 = makeElement(path: [-10000, 0])

        XCTAssertEqual(e1, e2)
    }

    func testEquality_floatingPointPrecision() {
        // Exact same Double values should be equal
        let e1 = makeElement(x: 123.456789, y: 987.654321)
        let e2 = makeElement(x: 123.456789, y: 987.654321)

        XCTAssertEqual(e1, e2)
    }

    func testEquality_slightlyDifferentDouble_notEqual() {
        let e1 = makeElement(x: 100.0)
        let e2 = makeElement(x: 100.0000001)

        XCTAssertNotEqual(e1, e2)
    }

    func testEquality_unicodeText_handled() {
        let e1 = makeElement(text: "日本語テキスト 🍎")
        let e2 = makeElement(text: "日本語テキスト 🍎")

        XCTAssertEqual(e1, e2)
    }

    func testEquality_unicodeText_differentNormalizationForms() {
        // é as single character vs e + combining accent
        let e1 = makeElement(text: "caf\u{00E9}") // é (precomposed)
        let e2 = makeElement(text: "cafe\u{0301}") // e + combining acute accent

        // Swift string equality handles normalization
        XCTAssertEqual(e1, e2)
    }

    // MARK: - Set Operations (real-world usage)

    func testSetDifference_findsRemovedElements() {
        let before: Set<ElementData> = [
            makeElement(role: "AXButton", text: "A", path: [0]),
            makeElement(role: "AXButton", text: "B", path: [1]),
        ]
        let after: Set<ElementData> = [
            makeElement(role: "AXButton", text: "A", path: [0]),
        ]

        let removed = before.subtracting(after)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.text, "B")
    }

    func testSetDifference_findsAddedElements() {
        let before: Set<ElementData> = [
            makeElement(role: "AXButton", text: "A", path: [0]),
        ]
        let after: Set<ElementData> = [
            makeElement(role: "AXButton", text: "A", path: [0]),
            makeElement(role: "AXButton", text: "B", path: [1]),
        ]

        let added = after.subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.text, "B")
    }
}
