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

    // MARK: - ActionOptionsInfo Tests

    func testActionOptionsInfoDefaultInitialization() {
        let options = ActionOptionsInfo()
        XCTAssertFalse(options.traverseBefore)
        XCTAssertFalse(options.traverseAfter)
        XCTAssertFalse(options.showDiff)
        XCTAssertFalse(options.onlyVisibleElements)
        XCTAssertTrue(options.showAnimation)
        XCTAssertEqual(options.animationDuration, 0.8)
        XCTAssertEqual(options.delayAfterAction, 0.2)
    }

    func testActionOptionsInfoCustomInitialization() {
        let options = ActionOptionsInfo(
            traverseBefore: true,
            traverseAfter: true,
            showDiff: true,
            onlyVisibleElements: true,
            showAnimation: false,
            animationDuration: 1.5,
            delayAfterAction: 0.5,
        )
        XCTAssertTrue(options.traverseBefore)
        XCTAssertTrue(options.traverseAfter)
        XCTAssertTrue(options.showDiff)
        XCTAssertTrue(options.onlyVisibleElements)
        XCTAssertFalse(options.showAnimation)
        XCTAssertEqual(options.animationDuration, 1.5)
        XCTAssertEqual(options.delayAfterAction, 0.5)
    }

    // MARK: - InputActionInfo Tests

    func testInputActionInfoClickType() {
        let action = InputActionInfo.click(x: 100, y: 200)
        if case let .click(x, y) = action.type {
            XCTAssertEqual(x, 100)
            XCTAssertEqual(y, 200)
        } else {
            XCTFail("Expected click type")
        }
    }

    func testInputActionInfoDoubleClickType() {
        let action = InputActionInfo.doubleClick(x: 150, y: 250)
        if case let .doubleClick(x, y) = action.type {
            XCTAssertEqual(x, 150)
            XCTAssertEqual(y, 250)
        } else {
            XCTFail("Expected doubleClick type")
        }
    }

    func testInputActionInfoRightClickType() {
        let action = InputActionInfo.rightClick(x: 300, y: 400)
        if case let .rightClick(x, y) = action.type {
            XCTAssertEqual(x, 300)
            XCTAssertEqual(y, 400)
        } else {
            XCTFail("Expected rightClick type")
        }
    }

    func testInputActionInfoTypeTextType() {
        let action = InputActionInfo.typeText("Hello World")
        if case let .typeText(text) = action.type {
            XCTAssertEqual(text, "Hello World")
        } else {
            XCTFail("Expected typeText type")
        }
    }

    func testInputActionInfoPressKeyType() {
        let action = InputActionInfo.pressKey("cmd+c")
        if case let .pressKey(combo) = action.type {
            XCTAssertEqual(combo, "cmd+c")
        } else {
            XCTFail("Expected pressKey type")
        }
    }

    func testInputActionInfoMoveToType() {
        let action = InputActionInfo.moveTo(x: 500, y: 600)
        if case let .moveTo(x, y) = action.type {
            XCTAssertEqual(x, 500)
            XCTAssertEqual(y, 600)
        } else {
            XCTFail("Expected moveTo type")
        }
    }

    // MARK: - PrimaryActionInfo Tests

    func testPrimaryActionInfoInput() {
        let inputAction = InputActionInfo.click(x: 100, y: 200)
        let primaryAction = PrimaryActionInfo.input(inputAction)

        if case let .input(wrapped) = primaryAction {
            if case let .click(x, y) = wrapped.type {
                XCTAssertEqual(x, 100)
                XCTAssertEqual(y, 200)
            } else {
                XCTFail("Expected click type")
            }
        } else {
            XCTFail("Expected input case")
        }
    }

    func testPrimaryActionInfoTraverseOnly() {
        let primaryAction = PrimaryActionInfo.traverseOnly
        if case .traverseOnly = primaryAction {
            // Success
        } else {
            XCTFail("Expected traverseOnly case")
        }
    }

    // MARK: - ActionResultInfo Tests

    func testActionResultInfoInitialization() {
        let result = ActionResultInfo(
            pid: 12345,
            appName: "TestApp",
            traversalPid: 12345,
            primaryActionError: nil,
            traversalBeforeError: nil,
            traversalAfterError: nil,
        )

        XCTAssertEqual(result.pid, 12345)
        XCTAssertEqual(result.appName, "TestApp")
        XCTAssertEqual(result.traversalPid, 12345)
        XCTAssertNil(result.primaryActionError)
        XCTAssertNil(result.traversalBeforeError)
        XCTAssertNil(result.traversalAfterError)
    }

    func testActionResultInfoWithErrors() {
        let result = ActionResultInfo(
            pid: 0,
            appName: "",
            traversalPid: 0,
            primaryActionError: "Click failed",
            traversalBeforeError: "Traversal before failed",
            traversalAfterError: "Traversal after failed",
        )

        XCTAssertEqual(result.primaryActionError, "Click failed")
        XCTAssertEqual(result.traversalBeforeError, "Traversal before failed")
        XCTAssertEqual(result.traversalAfterError, "Traversal after failed")
    }

    func testActionResultInfoIsSendable() {
        // Compile-time verification that ActionResultInfo conforms to Sendable
        let result = ActionResultInfo(
            pid: 1,
            appName: "App",
            traversalPid: 1,
            primaryActionError: nil,
            traversalBeforeError: nil,
            traversalAfterError: nil,
        )

        Task {
            _ = result // Using Sendable type in async context should compile
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
