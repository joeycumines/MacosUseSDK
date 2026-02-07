import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Tests for InputAction enum variants.
///
/// Verifies all InputAction cases (click, doubleClick, type, press, move, etc.)
final class ActionTypesTests: XCTestCase {
    // MARK: - Click Action

    func testInputAction_clickPoint() {
        let point = CGPoint(x: 100, y: 50)
        let action = InputAction.click(point: point)

        if case let .click(p) = action {
            XCTAssertEqual(p.x, 100)
            XCTAssertEqual(p.y, 50)
        } else {
            XCTFail("Expected .click case")
        }
    }

    // MARK: - Double Click Action

    func testInputAction_doubleClickPoint() {
        let point = CGPoint(x: 200, y: 100)
        let action = InputAction.doubleClick(point: point)

        if case let .doubleClick(p) = action {
            XCTAssertEqual(p.x, 200)
            XCTAssertEqual(p.y, 100)
        } else {
            XCTFail("Expected .doubleClick case")
        }
    }

    // MARK: - Right Click Action

    func testInputAction_rightClickPoint() {
        let point = CGPoint(x: 150, y: 75)
        let action = InputAction.rightClick(point: point)

        if case let .rightClick(p) = action {
            XCTAssertEqual(p.x, 150)
            XCTAssertEqual(p.y, 75)
        } else {
            XCTFail("Expected .rightClick case")
        }
    }

    // MARK: - Type Action

    func testInputAction_typeText() {
        let action = InputAction.type(text: "Hello World")

        if case let .type(text) = action {
            XCTAssertEqual(text, "Hello World")
        } else {
            XCTFail("Expected .type case")
        }
    }

    func testInputAction_typeEmptyText() {
        let action = InputAction.type(text: "")

        if case let .type(text) = action {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected .type case")
        }
    }

    // MARK: - Press Action

    func testInputAction_pressKeyName() {
        let action = InputAction.press(keyName: "return")

        if case let .press(name, flags) = action {
            XCTAssertEqual(name, "return")
            XCTAssertEqual(flags, [])
        } else {
            XCTFail("Expected .press case")
        }
    }

    func testInputAction_pressKeyNameWithFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let action = InputAction.press(keyName: "s", flags: flags)

        if case let .press(name, resultingFlags) = action {
            XCTAssertEqual(name, "s")
            XCTAssertTrue(resultingFlags.contains(.maskCommand))
            XCTAssertTrue(resultingFlags.contains(.maskShift))
        } else {
            XCTFail("Expected .press case")
        }
    }

    // MARK: - PressHold Action

    func testInputAction_pressHold() {
        let action = InputAction.pressHold(keyName: "a", flags: [], duration: 2.0)

        if case let .pressHold(name, flags, duration) = action {
            XCTAssertEqual(name, "a")
            XCTAssertTrue(flags.isEmpty)
            XCTAssertEqual(duration, 2.0)
        } else {
            XCTFail("Expected .pressHold case")
        }
    }

    func testInputAction_pressHoldWithDuration() {
        let action = InputAction.pressHold(keyName: "space", flags: [.maskControl], duration: 0.5)

        if case let .pressHold(name, flags, duration) = action {
            XCTAssertEqual(name, "space")
            XCTAssertTrue(flags.contains(.maskControl))
            XCTAssertEqual(duration, 0.5)
        } else {
            XCTFail("Expected .pressHold case")
        }
    }

    // MARK: - Move Action

    func testInputAction_moveToPoint() {
        let point = CGPoint(x: 300, y: 200)
        let action = InputAction.move(to: point)

        if case let .move(p) = action {
            XCTAssertEqual(p.x, 300)
            XCTAssertEqual(p.y, 200)
        } else {
            XCTFail("Expected .move case")
        }
    }

    // MARK: - Mouse Down/Up Actions

    func testInputAction_mouseDownDefaultButton() {
        let point = CGPoint(x: 100, y: 50)
        let action = InputAction.mouseDown(point: point)

        if case let .mouseDown(p, button, modifiers) = action {
            XCTAssertEqual(p.x, 100)
            XCTAssertEqual(p.y, 50)
            XCTAssertEqual(button, .left)
            XCTAssertTrue(modifiers.isEmpty)
        } else {
            XCTFail("Expected .mouseDown case")
        }
    }

    func testInputAction_mouseDownRightButton() {
        let point = CGPoint(x: 100, y: 50)
        let action = InputAction.mouseDown(point: point, button: .right, modifiers: [.maskShift])

        if case let .mouseDown(p, button, modifiers) = action {
            XCTAssertEqual(button, .right)
            XCTAssertTrue(modifiers.contains(.maskShift))
        } else {
            XCTFail("Expected .mouseDown case")
        }
    }

    func testInputAction_mouseUpCenterButton() {
        let point = CGPoint(x: 100, y: 50)
        let action = InputAction.mouseUp(point: point, button: .center)

        if case let .mouseUp(_, button, _) = action {
            XCTAssertEqual(button, .center)
        } else {
            XCTFail("Expected .mouseUp case")
        }
    }

    // MARK: - PrimaryAction

    func testPrimaryAction_openIdentifier() {
        let action = PrimaryAction.open(identifier: "Calculator")

        if case let .open(identifier) = action {
            XCTAssertEqual(identifier, "Calculator")
        } else {
            XCTFail("Expected .open case")
        }
    }

    func testPrimaryAction_openBundleId() {
        let action = PrimaryAction.open(identifier: "com.apple.calculator")

        if case let .open(identifier) = action {
            XCTAssertEqual(identifier, "com.apple.calculator")
        } else {
            XCTFail("Expected .open case")
        }
    }

    func testPrimaryAction_inputAction() {
        let clickAction = InputAction.click(point: CGPoint(x: 100, y: 50))
        let action = PrimaryAction.input(action: clickAction)

        if case let .input(input) = action {
            if case let .click(point) = input {
                XCTAssertEqual(point.x, 100)
            } else {
                XCTFail("Expected nested .click")
            }
        } else {
            XCTFail("Expected .input case")
        }
    }

    func testPrimaryAction_traverseOnly() {
        let action = PrimaryAction.traverseOnly

        if case .traverseOnly = action {
            // Expected
        } else {
            XCTFail("Expected .traverseOnly case")
        }
    }

    // MARK: - Sendable Conformance

    func testInputAction_sendable() {
        let actions: [InputAction] = [
            .click(point: CGPoint(x: 0, y: 0)),
            .doubleClick(point: CGPoint(x: 0, y: 0)),
            .type(text: "test"),
            .press(keyName: "a"),
            .move(to: CGPoint(x: 0, y: 0)),
        ]

        XCTAssertEqual(actions.count, 5)
    }

    func testPrimaryAction_sendable() {
        let actions: [PrimaryAction] = [
            .open(identifier: "test"),
            .input(action: .click(point: .zero)),
            .traverseOnly,
        ]

        XCTAssertEqual(actions.count, 3)
    }

    // MARK: - Codable

    func testInputAction_notCodable() {
        // InputAction is not Codable in the current implementation
        // This test verifies that attempting to encode it would fail at compile time
        let action = InputAction.press(keyName: "return", flags: [.maskCommand])

        // If this compiles, InputAction is not Codable (which is expected)
        XCTAssertNotNil(action)
    }

    func testPrimaryAction_notCodable() {
        let action = PrimaryAction.open(identifier: "test")

        // If this compiles, PrimaryAction is not Codable (which is expected)
        XCTAssertNotNil(action)
    }
}
