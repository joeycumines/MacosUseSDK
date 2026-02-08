import CoreGraphics
import GRPCCore
import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for AutomationCoordinator pure functions and conversions.
/// These tests focus on testable logic without external dependencies.
final class AutomationCoordinatorTests: XCTestCase {
    // MARK: - CoordinatorError Tests

    func testCoordinatorErrorInvalidKeyNameDescription() {
        let error = CoordinatorError.invalidKeyName("badKey")
        XCTAssertEqual(error.errorDescription, "Invalid key name: badKey")
    }

    func testCoordinatorErrorInvalidKeyComboDescription() {
        let error = CoordinatorError.invalidKeyCombo("cmd+")
        XCTAssertEqual(error.errorDescription, "Invalid key combo: cmd+")
    }

    func testCoordinatorErrorUnknownModifierDescription() {
        let error = CoordinatorError.unknownModifier("meta")
        XCTAssertEqual(error.errorDescription, "Unknown modifier: meta")
    }

    func testCoordinatorErrorConformsToLocalizedError() throws {
        // Verify all cases conform to LocalizedError properly
        let errors: [CoordinatorError] = [
            .invalidKeyName("test"),
            .invalidKeyCombo("test"),
            .unknownModifier("test"),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(try XCTUnwrap(error.errorDescription?.isEmpty))
        }
    }

    // MARK: - Modifier Conversion Tests (via Proto Types)

    func testModifierConversionCommand() {
        // Test that the Modifier enum is accessible and has expected cases
        let modifier = Macosusesdk_V1_KeyPress.Modifier.command
        XCTAssertEqual(modifier.rawValue, 1)
    }

    func testModifierConversionOption() {
        let modifier = Macosusesdk_V1_KeyPress.Modifier.option
        XCTAssertEqual(modifier.rawValue, 2)
    }

    func testModifierConversionControl() {
        let modifier = Macosusesdk_V1_KeyPress.Modifier.control
        XCTAssertEqual(modifier.rawValue, 3)
    }

    func testModifierConversionShift() {
        let modifier = Macosusesdk_V1_KeyPress.Modifier.shift
        XCTAssertEqual(modifier.rawValue, 4)
    }

    func testModifierConversionFunction() {
        let modifier = Macosusesdk_V1_KeyPress.Modifier.function
        XCTAssertEqual(modifier.rawValue, 5)
    }

    // MARK: - Point Conversion Tests

    func testCGPointFromProtoPosition() {
        // Verify CGPoint construction from proto-like values
        let protoX = 123.5
        let protoY = 456.7
        let point = CGPoint(x: protoX, y: protoY)

        XCTAssertEqual(point.x, 123.5)
        XCTAssertEqual(point.y, 456.7)
    }

    func testCGPointNegativeCoordinates() {
        // Multi-monitor setups can have negative coordinates
        let point = CGPoint(x: -100, y: -50)
        XCTAssertEqual(point.x, -100)
        XCTAssertEqual(point.y, -50)
    }

    func testCGPointLargeCoordinates() {
        // Large display coordinates should work
        let point = CGPoint(x: 5120, y: 2880)
        XCTAssertEqual(point.x, 5120)
        XCTAssertEqual(point.y, 2880)
    }
}
