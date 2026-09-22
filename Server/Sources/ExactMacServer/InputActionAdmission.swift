import CoreGraphics
import ExactMac
import ExactMacProto

struct ValidatedInputAction: Sendable {
    let action: ExactMac.InputAction
    let showAnimation: Bool
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
    let showAnimation: Bool
    let animationDuration: Double
    let keyboardSourceIdentity: ExactMac.KeyboardInputSourceIdentity?
    let textPasteKeyCode: CGKeyCode?

    init(
        action: ExactMac.InputAction,
        showAnimation: Bool,
        animationDuration: Double,
        keyboardSourceIdentity: ExactMac.KeyboardInputSourceIdentity? = nil,
        textPasteKeyCode: CGKeyCode? = nil,
    ) {
        self.action = action
        self.showAnimation = showAnimation
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
        let showAnimation = protoAction.showAnimation
        let animationDuration = protoAction.animationDuration

        guard animationDuration.isFinite, animationDuration >= 0, animationDuration <= 3600 else {
            throw CoordinatorError.invalidKeyCombo(
                "animation_duration must be between 0 and 3600 seconds",
            )
        }
        guard showAnimation || animationDuration == 0 else {
            throw CoordinatorError.invalidKeyCombo(
                "animation_duration requires show_animation",
            )
        }

        switch sdkAction {
        case .type, .typeText:
            guard !showAnimation || animationDuration == 0 else {
                throw CoordinatorError.invalidKeyCombo(
                    "custom animation_duration is not supported for type_text",
                )
            }
        case .pressHold, .pressKeyCodeHold:
            guard !showAnimation else {
                throw CoordinatorError.invalidKeyCombo(
                    "show_animation is not supported for a held key",
                )
            }
        case .drag, .dragPath:
            guard !showAnimation else {
                throw CoordinatorError.invalidKeyCombo(
                    "show_animation is not supported for drag",
                )
            }
        case .scroll:
            guard !showAnimation else {
                throw CoordinatorError.invalidKeyCombo(
                    "show_animation is not supported for scroll",
                )
            }
        case .hover:
            guard !showAnimation else {
                throw CoordinatorError.invalidKeyCombo(
                    "show_animation is not supported for hover",
                )
            }
        case .click, .doubleClick, .rightClick, .clickSequence, .press,
             .pressKeyCode, .move, .movePointer:
            break
        }

        return ValidatedInputAction(
            action: sdkAction,
            showAnimation: showAnimation,
            animationDuration: animationDuration,
        )
    }
}
