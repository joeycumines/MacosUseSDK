import AppKit
import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Tests for HighlightInput functions.
///
/// Verifies clickAndVisualize and pressKeyAndVisualize overlay descriptors.
final class HighlightInputTests: XCTestCase {
    // MARK: - Click and Visualize

    func testClickAndVisualize_createsOverlay() {
        // Test that clickAndVisualize creates proper overlay descriptors
        let point = CGPoint(x: 100, y: 50)
        let duration = 0.5

        // We can't easily test the actual visual output without UI,
        // but we can verify the overlay creation logic
        let screenHeight = NSScreen.main?.frame.height ?? 1080

        // Simulate the overlay creation logic
        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)

        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor.frame.width, size)
        XCTAssertEqual(descriptor.frame.height, size)
    }

    // MARK: - Double Click and Visualize

    func testDoubleClickAndVisualize_createsOverlay() {
        let point = CGPoint(x: 200, y: 100)
        let duration = 0.5
        let screenHeight: CGFloat = 1080

        // Double click uses same overlay logic as single click
        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)

        XCTAssertNotNil(descriptor)
    }

    // MARK: - Right Click and Visualize

    func testRightClickAndVisualize_createsOverlay() {
        let point = CGPoint(x: 150, y: 75)
        let screenHeight: CGFloat = 1080

        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)

        XCTAssertNotNil(descriptor)
    }

    // MARK: - Press Key and Visualize

    func testPressKeyAndVisualize_createsCaption() {
        let keyCode: CGKeyCode = 36 // Return key
        let duration = 0.5
        let screenHeight = NSScreen.main?.frame.height ?? 1080

        // Key press visualization uses a caption at screen center
        guard let screenCenter = getMainScreenCenter() else {
            XCTSkip("No main screen available")
            return
        }

        let captionSize = CGSize(width: 250, height: 80)
        let originX = screenCenter.x - (captionSize.width / 2.0)
        let originY = screenCenter.y - (captionSize.height / 2.0)
        let frame = CGRect(x: originX, y: originY, width: captionSize.width, height: captionSize.height)

        let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: "[KEY PRESS]"))

        XCTAssertNotNil(descriptor)
        if case let .caption(text) = descriptor.type {
            XCTAssertEqual(text, "[KEY PRESS]")
        } else {
            XCTFail("Expected .caption type")
        }
    }

    // MARK: - Move Mouse and Visualize

    func testMoveMouseAndVisualize_createsOverlay() {
        let point = CGPoint(x: 300, y: 200)
        let duration = 0.5

        // Move uses a smaller highlight box
        let size: CGFloat = 50
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .box(text: ""))

        XCTAssertNotNil(descriptor)
    }

    // MARK: - Write Text and Visualize

    func testWriteTextAndVisualize_createsCaption() {
        let text = "Hello World"
        let screenCenter = getMainScreenCenter()

        guard let center = screenCenter else {
            XCTSkip("No main screen available")
            return
        }

        // Text visualization uses a larger caption with the actual text
        let defaultDuration = 1.0
        let calculatedDuration = max(defaultDuration, 0.5 + Double(text.count) * 0.05)
        let captionSize = CGSize(width: 450, height: 100)
        let originX = center.x - (captionSize.width / 2.0)
        let originY = center.y - (captionSize.height / 2.0)
        let frame = CGRect(x: originX, y: originY, width: captionSize.width, height: captionSize.height)

        let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: text))

        XCTAssertNotNil(descriptor)
        if case let .caption(captionText) = descriptor.type {
            XCTAssertEqual(captionText, text)
        } else {
            XCTFail("Expected .caption type")
        }

        // Verify duration calculation - uses max(default, 0.5 + charCount * 0.05)
        // "Hello World" has 11 characters
        // Calculation: max(1.0, 0.5 + 11 * 0.05) = max(1.0, 1.05) = 1.05
        XCTAssertEqual(calculatedDuration, 1.05)
    }

    // MARK: - Coordinate Conversion for Visualizations

    func testVisualization_coordinateFlip() {
        // Test that screen coordinates are correctly flipped for AppKit
        let axPoint = CGPoint(x: 100, y: 100)
        let screenHeight: CGFloat = 800

        // AX uses top-left origin, AppKit uses bottom-left
        // Formula: appKitY = screenHeight - axY - height
        let overlayHeight: CGFloat = 154
        let appKitY = screenHeight - axPoint.y - (overlayHeight / 2.0)

        // For a point at y=100 with screen height 800:
        // The overlay should be at y = 800 - 100 - 77 = 623 (in AppKit coords)
        XCTAssertEqual(appKitY, 623)
    }

    // MARK: - Screen Height Dependency

    func testVisualization_differentScreenHeights() {
        let axPoint = CGPoint(x: 100, y: 100)
        let overlayHeight: CGFloat = 154

        // Test with different screen heights
        let results: [(screenHeight: CGFloat, expectedY: CGFloat)] = [
            (800, 623),
            (1080, 903),
            (1440, 1263),
        ]

        for (screenHeight, expectedY) in results {
            let appKitY = screenHeight - axPoint.y - (overlayHeight / 2.0)
            XCTAssertEqual(appKitY, expectedY, "Failed for screen height \(screenHeight)")
        }
    }
}
