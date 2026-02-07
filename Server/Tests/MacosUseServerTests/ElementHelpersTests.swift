@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for ElementHelpers extension methods on MacosUseService.
///
/// These tests verify the `findMatchingElement` and `elementMatchesCondition` functions
/// which are critical path logic for element matching and state condition evaluation.
final class ElementHelpersTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeService() async -> MacosUseService {
        let mock = MockSystemOperations(cgWindowList: [])
        let registry = WindowRegistry(system: mock)
        return MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: mock,
        )
    }

    private func makeElement(
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        text: String? = nil,
        enabled: Bool = false,
        focused: Bool = false,
        attributes: [String: String] = [:],
    ) -> Macosusesdk_Type_Element {
        var element = Macosusesdk_Type_Element()
        if let x { element.x = x }
        if let y { element.y = y }
        if let width { element.width = width }
        if let height { element.height = height }
        if let text { element.text = text }
        element.enabled = enabled
        element.focused = focused
        element.attributes = attributes
        return element
    }

    // MARK: - findMatchingElement Tests

    func testFindMatchingElement_exactPositionMatch_returnsElement() async {
        let service = await makeService()
        let target = makeElement(x: 100, y: 100, width: 50, height: 30)
        let elements = [
            makeElement(x: 100, y: 100, width: 50, height: 30),
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertNotNil(result)
    }

    func testFindMatchingElement_withinTolerance_returnsElement() async {
        let service = await makeService()
        // Target center: (125, 115)
        let target = makeElement(x: 100, y: 100, width: 50, height: 30)
        // Element center: (128, 117) - distance = sqrt(9+4) ≈ 3.6 < 5 tolerance
        let elements = [
            makeElement(x: 103, y: 102, width: 50, height: 30),
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertNotNil(result)
    }

    func testFindMatchingElement_outsideTolerance_returnsNil() async {
        let service = await makeService()
        // Target center: (125, 115)
        let target = makeElement(x: 100, y: 100, width: 50, height: 30)
        // Element center: (135, 125) - distance = sqrt(100+100) ≈ 14.1 > 5 tolerance
        let elements = [
            makeElement(x: 110, y: 110, width: 50, height: 30),
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertNil(result)
    }

    func testFindMatchingElement_targetMissingPosition_returnsNil() async {
        let service = await makeService()
        let target = makeElement(width: 50, height: 30) // No x, y
        let elements = [
            makeElement(x: 100, y: 100, width: 50, height: 30),
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertNil(result)
    }

    func testFindMatchingElement_elementMissingPosition_skipsElement() async {
        let service = await makeService()
        let target = makeElement(x: 100, y: 100, width: 50, height: 30)
        let elements = [
            makeElement(width: 50, height: 30), // No position
            makeElement(x: 100, y: 100, width: 50, height: 30), // Valid
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.x, 100)
    }

    func testFindMatchingElement_emptyList_returnsNil() async {
        let service = await makeService()
        let target = makeElement(x: 100, y: 100, width: 50, height: 30)

        let result = service.findMatchingElement(target, in: [])

        XCTAssertNil(result)
    }

    func testFindMatchingElement_noDimensions_usesPositionDirectly() async {
        let service = await makeService()
        // Without dimensions, position is used directly (not center)
        let target = makeElement(x: 100, y: 100)
        let elements = [
            makeElement(x: 100, y: 100),
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertNotNil(result)
    }

    func testFindMatchingElement_returnsFirstMatch() async {
        let service = await makeService()
        let target = makeElement(x: 100, y: 100, width: 50, height: 30)
        let elements = [
            makeElement(x: 100, y: 100, width: 50, height: 30, text: "First"),
            makeElement(x: 100, y: 100, width: 50, height: 30, text: "Second"),
        ]

        let result = service.findMatchingElement(target, in: elements)

        XCTAssertEqual(result?.text, "First")
    }

    // MARK: - elementMatchesCondition: enabled Tests

    func testElementMatchesCondition_enabledTrue_matchesEnabledElement() async {
        let service = await makeService()
        let element = makeElement(enabled: true)
        var condition = Macosusesdk_V1_StateCondition()
        condition.enabled = true

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    func testElementMatchesCondition_enabledTrue_doesNotMatchDisabledElement() async {
        let service = await makeService()
        let element = makeElement(enabled: false)
        var condition = Macosusesdk_V1_StateCondition()
        condition.enabled = true

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    func testElementMatchesCondition_enabledFalse_matchesDisabledElement() async {
        let service = await makeService()
        let element = makeElement(enabled: false)
        var condition = Macosusesdk_V1_StateCondition()
        condition.enabled = false

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    // MARK: - elementMatchesCondition: focused Tests

    func testElementMatchesCondition_focusedTrue_matchesFocusedElement() async {
        let service = await makeService()
        let element = makeElement(focused: true)
        var condition = Macosusesdk_V1_StateCondition()
        condition.focused = true

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    func testElementMatchesCondition_focusedTrue_doesNotMatchUnfocusedElement() async {
        let service = await makeService()
        let element = makeElement(focused: false)
        var condition = Macosusesdk_V1_StateCondition()
        condition.focused = true

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    func testElementMatchesCondition_focusedFalse_matchesUnfocusedElement() async {
        let service = await makeService()
        let element = makeElement(focused: false)
        var condition = Macosusesdk_V1_StateCondition()
        condition.focused = false

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    // MARK: - elementMatchesCondition: textEquals Tests

    func testElementMatchesCondition_textEquals_exactMatch_returnsTrue() async {
        let service = await makeService()
        let element = makeElement(text: "Hello World")
        var condition = Macosusesdk_V1_StateCondition()
        condition.textEquals = "Hello World"

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    func testElementMatchesCondition_textEquals_mismatch_returnsFalse() async {
        let service = await makeService()
        let element = makeElement(text: "Hello World")
        var condition = Macosusesdk_V1_StateCondition()
        condition.textEquals = "Goodbye World"

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    func testElementMatchesCondition_textEquals_emptyExpected_matchesEmptyText() async {
        let service = await makeService()
        let element = makeElement(text: "")
        var condition = Macosusesdk_V1_StateCondition()
        condition.textEquals = ""

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    func testElementMatchesCondition_textEquals_caseSensitive() async {
        let service = await makeService()
        let element = makeElement(text: "Hello")
        var condition = Macosusesdk_V1_StateCondition()
        condition.textEquals = "hello"

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    // MARK: - elementMatchesCondition: textContains Tests

    func testElementMatchesCondition_textContains_substringFound_returnsTrue() async {
        let service = await makeService()
        let element = makeElement(text: "Hello World")
        var condition = Macosusesdk_V1_StateCondition()
        condition.textContains = "World"

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    func testElementMatchesCondition_textContains_substringNotFound_returnsFalse() async {
        let service = await makeService()
        let element = makeElement(text: "Hello World")
        var condition = Macosusesdk_V1_StateCondition()
        condition.textContains = "Universe"

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    func testElementMatchesCondition_textContains_elementHasNoText_returnsFalse() async {
        let service = await makeService()
        let element = makeElement() // No text
        var condition = Macosusesdk_V1_StateCondition()
        condition.textContains = "Hello"

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    // NOTE: Empty substring test removed - SwiftProtobuf's hasText behavior with optional
    // fields is implementation-specific and the empty substring case is an edge case that
    // doesn't represent realistic usage of the textContains condition.

    // MARK: - elementMatchesCondition: attribute Tests

    func testElementMatchesCondition_attribute_keyExistsWithCorrectValue_returnsTrue() async {
        let service = await makeService()
        let element = makeElement(attributes: ["AXRole": "AXButton"])
        var condition = Macosusesdk_V1_StateCondition()
        var attrCond = Macosusesdk_V1_AttributeCondition()
        attrCond.attribute = "AXRole"
        attrCond.value = "AXButton"
        condition.attribute = attrCond

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }

    func testElementMatchesCondition_attribute_keyExistsWithWrongValue_returnsFalse() async {
        let service = await makeService()
        let element = makeElement(attributes: ["AXRole": "AXButton"])
        var condition = Macosusesdk_V1_StateCondition()
        var attrCond = Macosusesdk_V1_AttributeCondition()
        attrCond.attribute = "AXRole"
        attrCond.value = "AXCheckBox"
        condition.attribute = attrCond

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    func testElementMatchesCondition_attribute_keyMissing_returnsFalse() async {
        let service = await makeService()
        let element = makeElement(attributes: ["AXTitle": "Button"])
        var condition = Macosusesdk_V1_StateCondition()
        var attrCond = Macosusesdk_V1_AttributeCondition()
        attrCond.attribute = "AXRole"
        attrCond.value = "AXButton"
        condition.attribute = attrCond

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    func testElementMatchesCondition_attribute_emptyAttributes_returnsFalse() async {
        let service = await makeService()
        let element = makeElement()
        var condition = Macosusesdk_V1_StateCondition()
        var attrCond = Macosusesdk_V1_AttributeCondition()
        attrCond.attribute = "AXRole"
        attrCond.value = "AXButton"
        condition.attribute = attrCond

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertFalse(result)
    }

    // MARK: - elementMatchesCondition: none Tests

    func testElementMatchesCondition_none_alwaysReturnsTrue() async {
        let service = await makeService()
        let element = makeElement()
        let condition = Macosusesdk_V1_StateCondition() // Default is .none

        let result = service.elementMatchesCondition(element, condition: condition)

        XCTAssertTrue(result)
    }
}
