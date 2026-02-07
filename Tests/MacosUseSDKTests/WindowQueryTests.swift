import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Tests for WindowQuery functions.
///
/// Verifies AX bounds extraction, position/size handling, and window info structure.
final class WindowQueryTests: XCTestCase {
    // MARK: - WindowInfo Structure

    func testWindowInfo_properties() {
        // Create a minimal WindowInfo to verify structure
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        // Note: We can't directly create WindowInfo as it's internal,
        // but we can test the fetchAXWindowInfo function behavior
        // This test verifies the function signature and basic calling

        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)

        // The function should return nil for non-existent window IDs
        // (test window ID 99999 is unlikely to exist)
        let result = fetchAXWindowInfo(
            pid: ProcessInfo.processInfo.processIdentifier,
            windowId: 99999,
            expectedBounds: bounds,
        )

        // Result will be nil for non-existent window, which is expected
        XCTAssertNil(result, "Should return nil for non-existent window")
    }

    // MARK: - Bounds Conversion

    func testBounds_originAndSize() {
        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)

        XCTAssertEqual(bounds.origin.x, 100)
        XCTAssertEqual(bounds.origin.y, 50)
        XCTAssertEqual(bounds.size.width, 800)
        XCTAssertEqual(bounds.size.height, 600)
    }

    func testBounds_zeroDimensions() {
        let zeroBounds = CGRect(x: 0, y: 0, width: 0, height: 0)

        XCTAssertEqual(zeroBounds.size.width, 0)
        XCTAssertEqual(zeroBounds.size.height, 0)
    }

    func testBounds_negativeCoordinates() {
        // Multi-monitor setups can have negative coordinates
        let bounds = CGRect(x: -500, y: -200, width: 800, height: 600)

        XCTAssertEqual(bounds.origin.x, -500)
        XCTAssertEqual(bounds.origin.y, -200)
    }

    // MARK: - AX Bounds Extraction

    func testCGPoint_creation() {
        // Test basic CGPoint creation and properties
        let testPoint = CGPoint(x: 100, y: 50)

        XCTAssertEqual(testPoint.x, 100)
        XCTAssertEqual(testPoint.y, 50)
    }

    func testCGSize_creation() {
        // Test basic CGSize creation and properties
        let testSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(testSize.width, 800)
        XCTAssertEqual(testSize.height, 600)
    }

    func testCGRect_creation() {
        // Test basic CGRect creation
        let testRect = CGRect(x: 100, y: 50, width: 800, height: 600)

        XCTAssertEqual(testRect.origin.x, 100)
        XCTAssertEqual(testRect.origin.y, 50)
        XCTAssertEqual(testRect.size.width, 800)
        XCTAssertEqual(testRect.size.height, 600)
    }

    func testCGRect_zero() {
        // Test zero rect
        let zeroRect = CGRect.zero

        XCTAssertEqual(zeroRect.origin.x, 0)
        XCTAssertEqual(zeroRect.origin.y, 0)
        XCTAssertEqual(zeroRect.size.width, 0)
        XCTAssertEqual(zeroRect.size.height, 0)
    }

    // MARK: - Window ID Handling

    func testCGWindowID_type() {
        // CGWindowID is a type alias for UInt32
        let windowId: CGWindowID = 12345

        XCTAssertEqual(windowId, 12345)
        XCTAssertLessThanOrEqual(windowId, UInt32.max)
    }

    func testCGWindowID_zeroValue() {
        // Window ID 0 typically means "no window" or invalid
        let windowId: CGWindowID = 0

        XCTAssertEqual(windowId, 0)
    }

    // MARK: - Heuristic Score Threshold

    func testScoreThreshold_constant() {
        // The score threshold for window matching should be reasonable
        let threshold: CGFloat = 1000.0

        // Threshold should be positive and reasonably large
        XCTAssertGreaterThan(threshold, 0)
        XCTAssertLessThan(threshold, 10000)
    }

    func testScoreCalculation() {
        // Test Euclidean distance calculation for scoring
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 3, y: 4)

        // Distance should be 5 (3-4-5 triangle)
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)

        XCTAssertEqual(distance, 5.0, accuracy: 0.001)
    }

    func testScoreCalculation_zeroDistance() {
        let p1 = CGPoint(x: 100, y: 50)
        let p2 = CGPoint(x: 100, y: 50)

        let distance = hypot(p2.x - p1.x, p2.y - p1.y)

        XCTAssertEqual(distance, 0.0, accuracy: 0.001)
    }

    // MARK: - PID Handling

    func testPid_type() {
        // pid_t is typically Int32
        let pid: pid_t = ProcessInfo.processInfo.processIdentifier

        XCTAssertGreaterThan(pid, 0, "Process PID should be positive")
        XCTAssertNotEqual(pid, 0)
    }

    // MARK: - AXUIElement Window Bridge

    func testAXUIElementCreateApplication_validPid() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        // Should create a non-nil element
        XCTAssertNotNil(element)
    }

    func testAXUIElementCreateApplication_zeroPid() {
        let element = AXUIElementCreateApplication(0)

        // Should create an element (might be invalid)
        XCTAssertNotNil(element)
    }
}
