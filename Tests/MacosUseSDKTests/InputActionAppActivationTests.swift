import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Tests for `InputAction.requiresAppActivation`.
///
/// `requiresAppActivation` is the single source of truth for which input
/// actions need the target app to be the frontmost application before the
/// event is posted. It must return `true` for every action whose CGEvent
/// would otherwise be misrouted (consumed by the wrong app or window) and
/// `false` for actions the caller may legitimately want to issue without
/// disturbing the current focus.
///
/// Coverage:
/// - `.press`, `.pressHold`, `.type` → `true` (keyboard events route to the
///   focused app, so the target must be frontmost).
/// - `.click`, `.doubleClick`, `.rightClick` → `true` (clicks on background
///   windows are silently consumed by the frontmost app).
/// - `.move`, `.mouseDown`, `.mouseUp`, `.drag` → `false` (callers may need
///   to compose these primitives with their own activation sequence).
///
/// Exhaustiveness matters: a future `InputAction` case would force a
/// compile error in the SDK's `requiresAppActivation` switch (which has
/// no `default` branch) — and the only way to make it compile would be
/// to add a `default`, which would silently weaken this contract.
final class InputActionAppActivationTests: XCTestCase {
    // MARK: - True Cases (require app activation)

    func testRequiresAppActivation_forPress_returnsTrue() {
        let action = InputAction.press(keyName: "a", flags: [])
        XCTAssertTrue(action.requiresAppActivation)
    }

    func testRequiresAppActivation_forType_returnsTrue() {
        let action = InputAction.type(text: "hello")
        XCTAssertTrue(action.requiresAppActivation)
    }

    func testRequiresAppActivation_forPressHold_returnsTrue() {
        let action = InputAction.pressHold(keyName: "a", flags: [], duration: 1.0)
        XCTAssertTrue(action.requiresAppActivation)
    }

    func testRequiresAppActivation_forClick_returnsTrue() {
        let action = InputAction.click(point: CGPoint(x: 100, y: 100))
        XCTAssertTrue(
            action.requiresAppActivation,
            "Click should activate the target app for reliable hit testing",
        )
    }

    func testRequiresAppActivation_forDoubleClick_returnsTrue() {
        let action = InputAction.doubleClick(point: CGPoint(x: 100, y: 100))
        XCTAssertTrue(
            action.requiresAppActivation,
            "Double-click should activate the target app",
        )
    }

    func testRequiresAppActivation_forRightClick_returnsTrue() {
        let action = InputAction.rightClick(point: CGPoint(x: 100, y: 100))
        XCTAssertTrue(
            action.requiresAppActivation,
            "Right-click should activate the target app",
        )
    }

    // MARK: - False Cases (caller-managed activation)

    func testRequiresAppActivation_forMove_returnsFalse() {
        let action = InputAction.move(to: CGPoint(x: 100, y: 100))
        XCTAssertFalse(action.requiresAppActivation)
    }

    func testRequiresAppActivation_forMouseDown_returnsFalse() {
        let action = InputAction.mouseDown(point: CGPoint(x: 100, y: 100), button: .left, modifiers: [])
        XCTAssertFalse(action.requiresAppActivation)
    }

    func testRequiresAppActivation_forMouseUp_returnsFalse() {
        let action = InputAction.mouseUp(point: CGPoint(x: 100, y: 100), button: .left, modifiers: [])
        XCTAssertFalse(action.requiresAppActivation)
    }

    func testRequiresAppActivation_forDrag_returnsFalse() {
        let action = InputAction.drag(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 200, y: 200),
            button: .left,
            duration: 0,
        )
        XCTAssertFalse(action.requiresAppActivation)
    }
}
