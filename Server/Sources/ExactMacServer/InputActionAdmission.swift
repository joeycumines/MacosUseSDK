import CoreGraphics
import ExactMac
import ExactMacProto

struct ValidatedInputAction: Sendable {
    let action: ExactMac.InputAction
    let visualFeedback: Bool
    let animationDuration: Double

    var requiresKeyboardFocus: Bool {
        switch action {
        case .type, .typeText, .press, .pressHold, .pressKeyCode, .pressKeyCodeHold:
            true
        case .click, .doubleClick, .rightClick, .clickSequence, .move,
             .movePointer, .drag, .dragPath, .scroll, .hover:
            false
        }
    }
}

struct PreparedInputAction: Sendable {
    let action: ExactMac.InputAction
    let visualFeedback: Bool
    let animationDuration: Double
    let keyboardSourceIdentity: ExactMac.KeyboardInputSourceIdentity?
    let textPasteKeyCode: CGKeyCode?

    init(
        action: ExactMac.InputAction,
        visualFeedback: Bool,
        animationDuration: Double,
        keyboardSourceIdentity: ExactMac.KeyboardInputSourceIdentity? = nil,
        textPasteKeyCode: CGKeyCode? = nil,
    ) {
        self.action = action
        self.visualFeedback = visualFeedback
        self.animationDuration = animationDuration
        self.keyboardSourceIdentity = keyboardSourceIdentity
        self.textPasteKeyCode = textPasteKeyCode
    }
}

enum InputActionAdmission {
    static func validate(
        protoAction: Exactmac_V1_InputAction,
        sdkAction: ExactMac.InputAction,
    ) throws -> ValidatedInputAction {
        let visualFeedback = protoAction.visualFeedback
        let animationDuration = protoAction.animationDuration

        guard animationDuration.isFinite, animationDuration >= 0, animationDuration <= 3600 else {
            throw CoordinatorError.invalidKeyCombo(
                "animation_duration must be between 0 and 3600 seconds",
            )
        }
        guard visualFeedback || animationDuration == 0 else {
            throw CoordinatorError.invalidKeyCombo(
                "animation_duration requires visual_feedback",
            )
        }

        switch sdkAction {
        case .type, .typeText:
            guard !visualFeedback || animationDuration == 0 else {
                throw CoordinatorError.invalidKeyCombo(
                    "custom animation_duration is not supported for text_input",
                )
            }
        case .pressHold, .pressKeyCodeHold:
            guard !visualFeedback else {
                throw CoordinatorError.invalidKeyCombo(
                    "visual_feedback is not supported for a held key",
                )
            }
        case .drag, .dragPath:
            guard !visualFeedback else {
                throw CoordinatorError.invalidKeyCombo(
                    "visual_feedback is not supported for drag",
                )
            }
        case .scroll:
            guard !visualFeedback else {
                throw CoordinatorError.invalidKeyCombo(
                    "visual_feedback is not supported for scroll",
                )
            }
        case .hover:
            guard !visualFeedback else {
                throw CoordinatorError.invalidKeyCombo(
                    "visual_feedback is not supported for hover",
                )
            }
        case .click, .doubleClick, .rightClick, .clickSequence, .press,
             .pressKeyCode, .move, .movePointer:
            break
        }

        return ValidatedInputAction(
            action: sdkAction,
            visualFeedback: visualFeedback,
            animationDuration: animationDuration,
        )
    }
}
