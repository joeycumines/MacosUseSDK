import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for InputMethods types and proto-related input handling.
/// These tests focus on input action types and state transitions.
final class InputMethodsTests: XCTestCase {
    // MARK: - Proto InputAction Type Tests

    func testInputActionClickConstruction() {
        var action = Macosusesdk_V1_InputAction()
        var click = Macosusesdk_V1_MouseClick()
        click.position = Macosusesdk_Type_Point.with {
            $0.x = 100.0
            $0.y = 200.0
        }
        click.clickType = .left
        click.clickCount = 1
        action.click = click

        if case let .click(mouseClick) = action.inputType {
            XCTAssertEqual(mouseClick.position.x, 100.0)
            XCTAssertEqual(mouseClick.position.y, 200.0)
            XCTAssertEqual(mouseClick.clickType, .left)
            XCTAssertEqual(mouseClick.clickCount, 1)
        } else {
            XCTFail("Expected click input type")
        }
    }

    func testInputActionDoubleClickConstruction() {
        var action = Macosusesdk_V1_InputAction()
        var click = Macosusesdk_V1_MouseClick()
        click.position = Macosusesdk_Type_Point.with {
            $0.x = 150.0
            $0.y = 250.0
        }
        click.clickType = .left
        click.clickCount = 2
        action.click = click

        if case let .click(mouseClick) = action.inputType {
            XCTAssertEqual(mouseClick.clickCount, 2)
        } else {
            XCTFail("Expected click input type")
        }
    }

    func testInputActionRightClickConstruction() {
        var action = Macosusesdk_V1_InputAction()
        var click = Macosusesdk_V1_MouseClick()
        click.clickType = .right
        action.click = click

        if case let .click(mouseClick) = action.inputType {
            XCTAssertEqual(mouseClick.clickType, .right)
        } else {
            XCTFail("Expected click input type")
        }
    }

    func testInputActionTypeTextConstruction() {
        var action = Macosusesdk_V1_InputAction()
        var textInput = Macosusesdk_V1_TextInput()
        textInput.text = "Hello, World!"
        action.typeText = textInput

        if case let .typeText(input) = action.inputType {
            XCTAssertEqual(input.text, "Hello, World!")
        } else {
            XCTFail("Expected typeText input type")
        }
    }

    func testInputActionPressKeyConstruction() {
        var action = Macosusesdk_V1_InputAction()
        var keyPress = Macosusesdk_V1_KeyPress()
        keyPress.key = "Return"
        keyPress.modifiers = [.command, .shift]
        action.pressKey = keyPress

        if case let .pressKey(press) = action.inputType {
            XCTAssertEqual(press.key, "Return")
            XCTAssertEqual(press.modifiers.count, 2)
            XCTAssertTrue(press.modifiers.contains(.command))
            XCTAssertTrue(press.modifiers.contains(.shift))
        } else {
            XCTFail("Expected pressKey input type")
        }
    }

    func testInputActionMoveMouseConstruction() {
        var action = Macosusesdk_V1_InputAction()
        var move = Macosusesdk_V1_MouseMove()
        move.position = Macosusesdk_Type_Point.with {
            $0.x = 500.0
            $0.y = 600.0
        }
        action.moveMouse = move

        if case let .moveMouse(mouseMove) = action.inputType {
            XCTAssertEqual(mouseMove.position.x, 500.0)
            XCTAssertEqual(mouseMove.position.y, 600.0)
        } else {
            XCTFail("Expected moveMouse input type")
        }
    }

    // MARK: - Input State Tests

    func testInputStatePending() {
        let state = Macosusesdk_V1_Input.State.pending
        XCTAssertEqual(state.rawValue, 1)
    }

    func testInputStateExecuting() {
        let state = Macosusesdk_V1_Input.State.executing
        XCTAssertEqual(state.rawValue, 2)
    }

    func testInputStateCompleted() {
        let state = Macosusesdk_V1_Input.State.completed
        XCTAssertEqual(state.rawValue, 3)
    }

    func testInputStateFailed() {
        let state = Macosusesdk_V1_Input.State.failed
        XCTAssertEqual(state.rawValue, 4)
    }

    func testInputStateUnspecified() {
        let state = Macosusesdk_V1_Input.State.unspecified
        XCTAssertEqual(state.rawValue, 0)
    }

    // MARK: - Input Resource Naming Tests

    func testInputResourceNameGlobal() {
        // For desktop-level inputs (no parent)
        let inputId = "abc123"
        let name = "desktopInputs/\(inputId)"
        XCTAssertEqual(name, "desktopInputs/abc123")
    }

    func testInputResourceNameWithParent() {
        // For application-specific inputs
        let parent = "applications/12345"
        let inputId = "xyz789"
        let name = "\(parent)/inputs/\(inputId)"
        XCTAssertEqual(name, "applications/12345/inputs/xyz789")
    }

    // MARK: - Mouse Click Type Tests

    func testMouseClickTypeLeft() {
        let clickType = Macosusesdk_V1_MouseClick.ClickType.left
        XCTAssertEqual(clickType.rawValue, 1)
    }

    func testMouseClickTypeRight() {
        let clickType = Macosusesdk_V1_MouseClick.ClickType.right
        XCTAssertEqual(clickType.rawValue, 2)
    }

    func testMouseClickTypeMiddle() {
        let clickType = Macosusesdk_V1_MouseClick.ClickType.middle
        XCTAssertEqual(clickType.rawValue, 3)
    }

    // MARK: - Point Type Tests

    func testPointTypeConstruction() {
        let point = Macosusesdk_Type_Point.with {
            $0.x = 123.45
            $0.y = 678.90
        }
        XCTAssertEqual(point.x, 123.45, accuracy: 0.001)
        XCTAssertEqual(point.y, 678.90, accuracy: 0.001)
    }

    func testPointDefaultValues() {
        let point = Macosusesdk_Type_Point()
        XCTAssertEqual(point.x, 0.0)
        XCTAssertEqual(point.y, 0.0)
    }

    func testPointNegativeCoordinates() {
        // Multi-monitor setups can have negative coordinates
        let point = Macosusesdk_Type_Point.with {
            $0.x = -1920.0
            $0.y = -100.0
        }
        XCTAssertEqual(point.x, -1920.0)
        XCTAssertEqual(point.y, -100.0)
    }

    // MARK: - KeyPress Modifier Combination Tests

    func testKeyPressEmptyModifiers() {
        var keyPress = Macosusesdk_V1_KeyPress()
        keyPress.key = "a"
        keyPress.modifiers = []

        XCTAssertTrue(keyPress.modifiers.isEmpty)
    }

    func testKeyPressSingleModifier() {
        var keyPress = Macosusesdk_V1_KeyPress()
        keyPress.key = "c"
        keyPress.modifiers = [.command]

        XCTAssertEqual(keyPress.modifiers.count, 1)
        XCTAssertEqual(keyPress.modifiers[0], .command)
    }

    func testKeyPressMultipleModifiers() {
        var keyPress = Macosusesdk_V1_KeyPress()
        keyPress.key = "z"
        keyPress.modifiers = [.command, .shift, .option]

        XCTAssertEqual(keyPress.modifiers.count, 3)
        XCTAssertTrue(keyPress.modifiers.contains(.command))
        XCTAssertTrue(keyPress.modifiers.contains(.shift))
        XCTAssertTrue(keyPress.modifiers.contains(.option))
    }

    func testKeyPressAllModifiers() {
        var keyPress = Macosusesdk_V1_KeyPress()
        keyPress.key = "f"
        keyPress.modifiers = [.command, .option, .control, .shift, .function]

        XCTAssertEqual(keyPress.modifiers.count, 5)
    }

    // MARK: - MouseClick HasPosition Tests

    func testMouseClickHasPositionTrue() {
        var click = Macosusesdk_V1_MouseClick()
        click.position = Macosusesdk_Type_Point.with {
            $0.x = 100.0
            $0.y = 200.0
        }

        XCTAssertTrue(click.hasPosition)
    }

    func testMouseClickHasPositionFalse() {
        let click = Macosusesdk_V1_MouseClick()
        XCTAssertFalse(click.hasPosition)
    }

    // MARK: - MouseMove HasPosition Tests

    func testMouseMoveHasPositionTrue() {
        var move = Macosusesdk_V1_MouseMove()
        move.position = Macosusesdk_Type_Point.with {
            $0.x = 300.0
            $0.y = 400.0
        }

        XCTAssertTrue(move.hasPosition)
    }

    func testMouseMoveHasPositionFalse() {
        let move = Macosusesdk_V1_MouseMove()
        XCTAssertFalse(move.hasPosition)
    }

    // MARK: - InputAction Animation Fields Tests

    func testInputActionShowAnimationDefault() {
        let action = Macosusesdk_V1_InputAction()
        XCTAssertFalse(action.showAnimation)
        XCTAssertEqual(action.animationDuration, 0.0)
    }

    func testInputActionShowAnimationCustom() {
        var action = Macosusesdk_V1_InputAction()
        action.showAnimation = true
        action.animationDuration = 1.5

        XCTAssertTrue(action.showAnimation)
        XCTAssertEqual(action.animationDuration, 1.5, accuracy: 0.001)
    }
}
