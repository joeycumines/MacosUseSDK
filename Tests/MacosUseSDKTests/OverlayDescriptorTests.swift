@testable import MacosUseSDK
import XCTest

/// Tests for OverlayDescriptor's failable initializer.
///
/// The initializer `OverlayDescriptor(element:screenHeight:)` is a pure function that:
/// 1. Guards for valid geometry (x, y, width > 0, height > 0)
/// 2. Converts AX coordinates (top-left origin) to AppKit coordinates (bottom-left origin)
/// 3. Falls back from element.text to element.role for display text
final class OverlayDescriptorTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeElement(
        role: String = "AXButton",
        text: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
    ) -> ElementData {
        ElementData(
            role: role,
            text: text,
            x: x,
            y: y,
            width: width,
            height: height,
            axElement: nil,
            enabled: true,
            focused: false,
            attributes: [:],
            path: [],
        )
    }

    // MARK: - Valid Geometry Tests

    func testValidGeometryCreatesDescriptor() {
        let element = makeElement(x: 100, y: 50, width: 200, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNotNil(descriptor)
    }

    func testValidGeometryWithSmallDimensions() {
        let element = makeElement(x: 0, y: 0, width: 1, height: 1)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 100)

        XCTAssertNotNil(descriptor)
    }

    func testValidGeometryWithLargeDimensions() {
        let element = makeElement(x: 0, y: 0, width: 3840, height: 2160)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 2160)

        XCTAssertNotNil(descriptor)
    }

    // MARK: - Missing Geometry Tests (nil values)

    func testMissingXReturnsNil() {
        let element = makeElement(x: nil, y: 50, width: 200, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testMissingYReturnsNil() {
        let element = makeElement(x: 100, y: nil, width: 200, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testMissingWidthReturnsNil() {
        let element = makeElement(x: 100, y: 50, width: nil, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testMissingHeightReturnsNil() {
        let element = makeElement(x: 100, y: 50, width: 200, height: nil)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testAllGeometryMissingReturnsNil() {
        let element = makeElement(x: nil, y: nil, width: nil, height: nil)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    // MARK: - Zero/Invalid Dimension Tests

    func testZeroWidthReturnsNil() {
        let element = makeElement(x: 100, y: 50, width: 0, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testZeroHeightReturnsNil() {
        let element = makeElement(x: 100, y: 50, width: 200, height: 0)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testNegativeWidthReturnsNil() {
        let element = makeElement(x: 100, y: 50, width: -10, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    func testNegativeHeightReturnsNil() {
        let element = makeElement(x: 100, y: 50, width: 200, height: -10)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNil(descriptor)
    }

    // MARK: - Coordinate Conversion Tests

    /// AX uses top-left origin, AppKit uses bottom-left origin.
    /// Formula: convertedY = screenHeight - y - height
    func testCoordinateConversionTopOfScreen() {
        // Element at top of screen (y=0 in AX) should be at bottom in AppKit
        let element = makeElement(x: 100, y: 0, width: 200, height: 50)
        let screenHeight: CGFloat = 800
        let descriptor = OverlayDescriptor(element: element, screenHeight: screenHeight)

        XCTAssertNotNil(descriptor)
        // convertedY = 800 - 0 - 50 = 750
        XCTAssertEqual(descriptor?.frame.origin.y, 750)
    }

    func testCoordinateConversionBottomOfScreen() {
        // Element at bottom of screen (y=750 in AX for height 50) should be at top in AppKit
        let element = makeElement(x: 100, y: 750, width: 200, height: 50)
        let screenHeight: CGFloat = 800
        let descriptor = OverlayDescriptor(element: element, screenHeight: screenHeight)

        XCTAssertNotNil(descriptor)
        // convertedY = 800 - 750 - 50 = 0
        XCTAssertEqual(descriptor?.frame.origin.y, 0)
    }

    func testCoordinateConversionMiddleOfScreen() {
        let element = makeElement(x: 100, y: 375, width: 200, height: 50)
        let screenHeight: CGFloat = 800
        let descriptor = OverlayDescriptor(element: element, screenHeight: screenHeight)

        XCTAssertNotNil(descriptor)
        // convertedY = 800 - 375 - 50 = 375
        XCTAssertEqual(descriptor?.frame.origin.y, 375)
    }

    func testFrameXPreserved() {
        let element = makeElement(x: 123, y: 50, width: 200, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertEqual(descriptor?.frame.origin.x, 123)
    }

    func testFrameWidthPreserved() {
        let element = makeElement(x: 100, y: 50, width: 456, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertEqual(descriptor?.frame.width, 456)
    }

    func testFrameHeightPreserved() {
        let element = makeElement(x: 100, y: 50, width: 200, height: 789)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 1000)

        XCTAssertEqual(descriptor?.frame.height, 789)
    }

    // MARK: - Text Fallback Tests

    func testUsesElementTextWhenPresent() {
        let element = makeElement(role: "AXButton", text: "Click Me", x: 0, y: 0, width: 50, height: 20)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 100)

        XCTAssertNotNil(descriptor)
        if case let .box(text) = descriptor?.type {
            XCTAssertEqual(text, "Click Me")
        } else {
            XCTFail("Expected .box type")
        }
    }

    func testFallsBackToRoleWhenTextIsNil() {
        let element = makeElement(role: "AXTextField", text: nil, x: 0, y: 0, width: 50, height: 20)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 100)

        XCTAssertNotNil(descriptor)
        if case let .box(text) = descriptor?.type {
            XCTAssertEqual(text, "AXTextField")
        } else {
            XCTFail("Expected .box type")
        }
    }

    func testFallsBackToRoleWhenTextIsEmpty() {
        let element = makeElement(role: "AXStaticText", text: "", x: 0, y: 0, width: 50, height: 20)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 100)

        XCTAssertNotNil(descriptor)
        if case let .box(text) = descriptor?.type {
            XCTAssertEqual(text, "AXStaticText")
        } else {
            XCTFail("Expected .box type")
        }
    }

    func testUsesTextWithWhitespaceOnly() {
        // Whitespace-only text is not empty, so it should be used
        let element = makeElement(role: "AXButton", text: "   ", x: 0, y: 0, width: 50, height: 20)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 100)

        XCTAssertNotNil(descriptor)
        if case let .box(text) = descriptor?.type {
            XCTAssertEqual(text, "   ")
        } else {
            XCTFail("Expected .box type")
        }
    }

    // MARK: - Edge Cases

    func testNegativeXCoordinateAllowed() {
        // Multi-monitor setups can have negative x coordinates
        let element = makeElement(x: -500, y: 100, width: 200, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.frame.origin.x, -500)
    }

    func testNegativeYCoordinateAllowed() {
        // Multi-monitor setups can have negative y coordinates (above main display)
        let element = makeElement(x: 100, y: -200, width: 200, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 800)

        XCTAssertNotNil(descriptor)
        // convertedY = 800 - (-200) - 100 = 900
        XCTAssertEqual(descriptor?.frame.origin.y, 900)
    }

    func testVerySmallDimensions() {
        let element = makeElement(x: 0, y: 0, width: 0.001, height: 0.001)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 100)

        XCTAssertNotNil(descriptor)
    }

    func testTypeIsAlwaysBox() {
        let element = makeElement(role: "AXWindow", text: "Test", x: 0, y: 0, width: 100, height: 100)
        let descriptor = OverlayDescriptor(element: element, screenHeight: 200)

        XCTAssertNotNil(descriptor)
        if case .box = descriptor?.type {
            // Expected
        } else {
            XCTFail("Expected .box type, got something else")
        }
    }
}
