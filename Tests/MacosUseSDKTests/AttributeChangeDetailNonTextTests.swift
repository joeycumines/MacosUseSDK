@testable import MacosUseSDK
import XCTest

/// Tests for AttributeChangeDetail's non-text initializers.
///
/// These tests cover:
/// 1. Generic `init<T: CustomStringConvertible>(attribute:before:after:)` - for non-text attributes
/// 2. Double-specific `init(attribute:before:after:format:)` - for position/size attributes
///
/// The text diff initializer is covered in AttributeChangeDetailTextDiffTests.swift
final class AttributeChangeDetailNonTextTests: XCTestCase {
    // MARK: - Generic Initializer Tests

    func testGenericInit_bothValues() {
        let detail = AttributeChangeDetail(attribute: "enabled", before: true, after: false)

        XCTAssertEqual(detail.attributeName, "enabled")
        XCTAssertEqual(detail.oldValue, "true")
        XCTAssertEqual(detail.newValue, "false")
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testGenericInit_nilBefore() {
        let detail = AttributeChangeDetail(attribute: "focused", before: nil as Bool?, after: true)

        XCTAssertEqual(detail.attributeName, "focused")
        XCTAssertNil(detail.oldValue)
        XCTAssertEqual(detail.newValue, "true")
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testGenericInit_nilAfter() {
        let detail = AttributeChangeDetail(attribute: "focused", before: true, after: nil as Bool?)

        XCTAssertEqual(detail.attributeName, "focused")
        XCTAssertEqual(detail.oldValue, "true")
        XCTAssertNil(detail.newValue)
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testGenericInit_bothNil() {
        let detail = AttributeChangeDetail(attribute: "custom", before: nil as String?, after: nil as String?)

        XCTAssertEqual(detail.attributeName, "custom")
        XCTAssertNil(detail.oldValue)
        XCTAssertNil(detail.newValue)
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testGenericInit_withIntValues() {
        let detail = AttributeChangeDetail(attribute: "childCount", before: 5, after: 10)

        XCTAssertEqual(detail.attributeName, "childCount")
        XCTAssertEqual(detail.oldValue, "5")
        XCTAssertEqual(detail.newValue, "10")
    }

    func testGenericInit_withStringValues() {
        let detail = AttributeChangeDetail(attribute: "role", before: "AXButton", after: "AXTextField")

        XCTAssertEqual(detail.attributeName, "role")
        XCTAssertEqual(detail.oldValue, "AXButton")
        XCTAssertEqual(detail.newValue, "AXTextField")
    }

    func testGenericInit_withTextAttribute_setsOldNewValue() {
        // When generic init is called with "text" attribute (not recommended),
        // it falls back to oldValue/newValue and leaves addedText/removedText nil
        let detail = AttributeChangeDetail(attribute: "text", before: "Hello", after: "World")

        XCTAssertEqual(detail.attributeName, "text")
        XCTAssertEqual(detail.oldValue, "Hello")
        XCTAssertEqual(detail.newValue, "World")
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testGenericInit_preservesCustomDescription() {
        struct CustomValue: CustomStringConvertible {
            let value: Int
            var description: String {
                "Custom(\(value))"
            }
        }

        let detail = AttributeChangeDetail(
            attribute: "custom",
            before: CustomValue(value: 1),
            after: CustomValue(value: 2),
        )

        XCTAssertEqual(detail.oldValue, "Custom(1)")
        XCTAssertEqual(detail.newValue, "Custom(2)")
    }

    // MARK: - Double Initializer Tests

    func testDoubleInit_defaultFormat() {
        let detail = AttributeChangeDetail(attribute: "x", before: 123.456, after: 789.012)

        XCTAssertEqual(detail.attributeName, "x")
        XCTAssertEqual(detail.oldValue, "123.5") // Default format is %.1f
        XCTAssertEqual(detail.newValue, "789.0")
        XCTAssertNil(detail.addedText)
        XCTAssertNil(detail.removedText)
    }

    func testDoubleInit_customFormat() {
        let detail = AttributeChangeDetail(
            attribute: "width",
            before: 100.123456,
            after: 200.654321,
            format: "%.3f",
        )

        XCTAssertEqual(detail.oldValue, "100.123")
        XCTAssertEqual(detail.newValue, "200.654")
    }

    func testDoubleInit_integerFormat() {
        let detail = AttributeChangeDetail(
            attribute: "height",
            before: 50.7,
            after: 60.3,
            format: "%.0f",
        )

        XCTAssertEqual(detail.oldValue, "51")
        XCTAssertEqual(detail.newValue, "60")
    }

    func testDoubleInit_nilBefore() {
        let detail = AttributeChangeDetail(attribute: "y", before: nil, after: 100.0)

        XCTAssertNil(detail.oldValue)
        XCTAssertEqual(detail.newValue, "100.0")
    }

    func testDoubleInit_nilAfter() {
        let detail = AttributeChangeDetail(attribute: "y", before: 100.0, after: nil)

        XCTAssertEqual(detail.oldValue, "100.0")
        XCTAssertNil(detail.newValue)
    }

    func testDoubleInit_bothNil() {
        let detail = AttributeChangeDetail(attribute: "width", before: nil as Double?, after: nil)

        XCTAssertNil(detail.oldValue)
        XCTAssertNil(detail.newValue)
    }

    func testDoubleInit_verySmallValues() {
        let detail = AttributeChangeDetail(
            attribute: "x",
            before: 0.001,
            after: 0.009,
            format: "%.3f",
        )

        XCTAssertEqual(detail.oldValue, "0.001")
        XCTAssertEqual(detail.newValue, "0.009")
    }

    func testDoubleInit_negativeValues() {
        let detail = AttributeChangeDetail(attribute: "x", before: -100.5, after: -50.5)

        XCTAssertEqual(detail.oldValue, "-100.5")
        XCTAssertEqual(detail.newValue, "-50.5")
    }

    func testDoubleInit_largeValues() {
        let detail = AttributeChangeDetail(
            attribute: "width",
            before: 3840.0,
            after: 5120.0,
        )

        XCTAssertEqual(detail.oldValue, "3840.0")
        XCTAssertEqual(detail.newValue, "5120.0")
    }

    func testDoubleInit_zeroValue() {
        let detail = AttributeChangeDetail(attribute: "y", before: 0.0, after: 100.0)

        XCTAssertEqual(detail.oldValue, "0.0")
        XCTAssertEqual(detail.newValue, "100.0")
    }

    // MARK: - Codable Conformance Tests

    func testCodable_encodeAndDecode() throws {
        let original = AttributeChangeDetail(attribute: "x", before: 10.0, after: 20.0)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AttributeChangeDetail.self, from: data)

        XCTAssertEqual(decoded.attributeName, original.attributeName)
        XCTAssertEqual(decoded.oldValue, original.oldValue)
        XCTAssertEqual(decoded.newValue, original.newValue)
        XCTAssertEqual(decoded.addedText, original.addedText)
        XCTAssertEqual(decoded.removedText, original.removedText)
    }

    func testCodable_withNilFields() throws {
        let original = AttributeChangeDetail(attribute: "test", before: nil as Double?, after: 100.0)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AttributeChangeDetail.self, from: data)

        XCTAssertEqual(decoded.attributeName, "test")
        XCTAssertNil(decoded.oldValue)
        XCTAssertEqual(decoded.newValue, "100.0")
    }
}
