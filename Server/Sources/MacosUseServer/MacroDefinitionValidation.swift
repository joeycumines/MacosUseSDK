import Foundation
import MacosUseProto

struct MacroDefinitionValidationError: Error, LocalizedError {
    let actionPath: String
    let detail: String

    var errorDescription: String? {
        "\(actionPath): \(detail)"
    }
}

enum MacroDefinitionValidator {
    typealias InputActionValidator = (Macosusesdk_V1_InputAction) throws -> Void

    static func containsPhysicalAction(
        _ actions: [Macosusesdk_V1_MacroAction],
    ) -> Bool {
        var pending = actions
        while let action = pending.popLast() {
            switch action.action {
            case .input:
                return true
            case let .methodCall(methodCall):
                if methodCall.method == "ClickElement" || methodCall.method == "TypeText" {
                    return true
                }
            case let .conditional(conditional):
                pending.append(contentsOf: conditional.thenActions)
                pending.append(contentsOf: conditional.elseActions)
            case let .loop(loop):
                pending.append(contentsOf: loop.actions)
            case .wait, .assign, .none:
                break
            }
        }
        return false
    }

    static func validate(
        actions: [Macosusesdk_V1_MacroAction],
        inputActionValidator: InputActionValidator,
    ) throws {
        var pending = actions.enumerated().map { index, action in
            (action: action, path: "macro.actions[\(index)]")
        }
        var pendingConditions: [(condition: Macosusesdk_V1_MacroCondition, path: String)] = []

        while let pendingAction = pending.popLast() {
            switch pendingAction.action.action {
            case let .input(inputAction):
                do {
                    try inputActionValidator(inputAction)
                } catch {
                    throw MacroDefinitionValidationError(
                        actionPath: "\(pendingAction.path).input",
                        detail: error.localizedDescription,
                    )
                }

            case let .wait(waitAction):
                try require(
                    waitAction.duration > 0,
                    path: "\(pendingAction.path).wait.duration",
                    detail: "duration is required",
                )
                if waitAction.hasCondition {
                    try require(
                        waitAction.condition.condition != nil,
                        path: "\(pendingAction.path).wait.condition",
                        detail: "condition type is required",
                    )
                }

            case let .conditional(conditionalAction):
                try require(
                    conditionalAction.hasCondition,
                    path: "\(pendingAction.path).conditional.condition",
                    detail: "condition is required",
                )
                try require(
                    !conditionalAction.thenActions.isEmpty,
                    path: "\(pendingAction.path).conditional.then_actions",
                    detail: "at least one action is required",
                )
                pendingConditions.append((
                    conditionalAction.condition,
                    "\(pendingAction.path).conditional.condition",
                ))
                pending.append(contentsOf: conditionalAction.thenActions.enumerated().map { index, action in
                    (action: action, path: "\(pendingAction.path).conditional.then_actions[\(index)]")
                })
                pending.append(contentsOf: conditionalAction.elseActions.enumerated().map { index, action in
                    (action: action, path: "\(pendingAction.path).conditional.else_actions[\(index)]")
                })

            case let .loop(loopAction):
                guard let loopType = loopAction.loopType else {
                    throw MacroDefinitionValidationError(
                        actionPath: "\(pendingAction.path).loop.loop_type",
                        detail: "loop type is required",
                    )
                }
                try require(
                    !loopAction.actions.isEmpty,
                    path: "\(pendingAction.path).loop.actions",
                    detail: "at least one action is required",
                )
                switch loopType {
                case .count:
                    break
                case let .whileCondition(condition):
                    pendingConditions.append((
                        condition,
                        "\(pendingAction.path).loop.while_condition",
                    ))
                case let .foreach(foreach):
                    try require(
                        foreach.collection != nil,
                        path: "\(pendingAction.path).loop.foreach.collection",
                        detail: "collection is required",
                    )
                    try require(
                        !foreach.itemVariable.isEmpty,
                        path: "\(pendingAction.path).loop.foreach.item_variable",
                        detail: "item variable is required",
                    )
                }
                pending.append(contentsOf: loopAction.actions.enumerated().map { index, action in
                    (action: action, path: "\(pendingAction.path).loop.actions[\(index)]")
                })

            case let .assign(assignAction):
                try require(
                    !assignAction.variable.isEmpty,
                    path: "\(pendingAction.path).assign.variable",
                    detail: "variable is required",
                )
                guard let value = assignAction.value else {
                    throw MacroDefinitionValidationError(
                        actionPath: "\(pendingAction.path).assign.value",
                        detail: "value source is required",
                    )
                }
                if case let .elementAttribute(elementAttribute) = value {
                    try require(
                        !elementAttribute.elementSelector.isEmpty,
                        path: "\(pendingAction.path).assign.element_attribute.element_selector",
                        detail: "element selector is required",
                    )
                    try require(
                        !elementAttribute.attribute.isEmpty,
                        path: "\(pendingAction.path).assign.element_attribute.attribute",
                        detail: "attribute is required",
                    )
                }

            case let .methodCall(methodCall):
                try require(
                    !methodCall.method.isEmpty,
                    path: "\(pendingAction.path).method_call.method",
                    detail: "method is required",
                )

            case .none:
                // An unset action oneof covers two cases: the caller omitted the
                // action entirely, OR the wire payload carried an action variant
                // the server does not recognize (SwiftProtobuf drops unknown
                // oneof field numbers, leaving `action == nil`). Both must be
                // rejected explicitly so an unrecognized variant can never pass
                // validation silently.
                throw MacroDefinitionValidationError(
                    actionPath: pendingAction.path,
                    detail: "action type is required (the action was missing or used an unrecognized variant)",
                )
            }
        }

        while let pendingCondition = pendingConditions.popLast() {
            guard let condition = pendingCondition.condition.condition else {
                throw MacroDefinitionValidationError(
                    actionPath: pendingCondition.path,
                    detail: "condition type is required",
                )
            }
            switch condition {
            case let .variableEquals(variableCondition):
                try require(
                    !variableCondition.variable.isEmpty,
                    path: "\(pendingCondition.path).variable_equals.variable",
                    detail: "variable is required",
                )
                try require(
                    !variableCondition.value.isEmpty,
                    path: "\(pendingCondition.path).variable_equals.value",
                    detail: "value is required",
                )
            case let .compound(compoundCondition):
                try require(
                    compoundCondition.operator != .unspecified,
                    path: "\(pendingCondition.path).compound.operator",
                    detail: "operator is required",
                )
                try require(
                    !compoundCondition.conditions.isEmpty,
                    path: "\(pendingCondition.path).compound.conditions",
                    detail: "at least one condition is required",
                )
                pendingConditions.append(contentsOf: compoundCondition.conditions.enumerated().map { index, nested in
                    (
                        condition: nested,
                        path: "\(pendingCondition.path).compound.conditions[\(index)]",
                    )
                })
            case .elementExists, .windowExists, .applicationRunning:
                break
            }
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        path: String,
        detail: String,
    ) throws {
        guard condition() else {
            throw MacroDefinitionValidationError(actionPath: path, detail: detail)
        }
    }
}
