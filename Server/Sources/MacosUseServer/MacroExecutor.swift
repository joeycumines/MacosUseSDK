import AppKit
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

private let logger = MacosUseSDK.sdkLogger(category: "MacroExecutor")

/// Execution context for macro operations
public struct MacroContext {
    var variables: [String: String] = [:]
    var parameters: [String: String] = [:]
    var parent: String = ""
    var pid: pid_t?
}

/// Error types for macro execution
public enum MacroExecutionError: Error, CustomStringConvertible {
    case macroNotFound(String)
    case invalidAction(String)
    case conditionFailed(String)
    case variableNotFound(String)
    case elementNotFound(String)
    case executionFailed(String)
    case timeout

    public var description: String {
        switch self {
        case let .macroNotFound(name):
            "Macro not found: \(name)"
        case let .invalidAction(msg):
            "Invalid action: \(msg)"
        case let .conditionFailed(msg):
            "Condition failed: \(msg)"
        case let .variableNotFound(name):
            "Variable not found: \(name)"
        case let .elementNotFound(selector):
            "Element not found: \(selector)"
        case let .executionFailed(msg):
            "Execution failed: \(msg)"
        case .timeout:
            "Macro execution timed out"
        }
    }
}

/// Actor for executing macros with support for all action types
public actor MacroExecutor {
    public nonisolated(unsafe) static var shared: MacroExecutor!

    /// Shared window registry for consistent window tracking
    private let windowRegistry: WindowRegistry

    init(windowRegistry: WindowRegistry) {
        self.windowRegistry = windowRegistry
    }

    /// Execute a macro with given parameters
    public func executeMacro(
        macro: Macosusesdk_V1_Macro,
        parameters: [String: String],
        parent: String,
        timeout: Double,
    ) async throws {
        logger.info("Executing macro: \(macro.name, privacy: .public)")

        // Validate required parameters
        for param in macro.parameters where param.required {
            guard parameters[param.key] != nil else {
                throw MacroExecutionError.executionFailed("Missing required parameter: \(param.key)")
            }
        }

        // Build execution context
        let pid = try? parsePID(fromName: parent)
        var context = MacroContext(parameters: parameters, parent: parent, pid: pid)

        // Apply default values for missing optional parameters
        for param in macro.parameters where !param.required && !param.defaultValue.isEmpty {
            if context.parameters[param.key] == nil {
                context.parameters[param.key] = param.defaultValue
            }
        }

        // Set timeout
        let deadline = Date().addingTimeInterval(timeout)

        // Execute all actions
        for action in macro.actions {
            // Check timeout
            if Date() > deadline {
                throw MacroExecutionError.timeout
            }

            try await executeAction(action, context: &context)
        }

        logger.info("Macro execution completed: \(macro.name, privacy: .public)")
    }

    private func executeAction(
        _ action: Macosusesdk_V1_MacroAction,
        context: inout MacroContext,
    ) async throws {
        switch action.action {
        case let .input(inputAction):
            try await executeInputAction(inputAction, context: context)

        case let .wait(waitAction):
            try await executeWaitAction(waitAction, context: context)

        case let .conditional(conditionalAction):
            try await executeConditionalAction(conditionalAction, context: &context)

        case let .loop(loopAction):
            try await executeLoopAction(loopAction, context: &context)

        case let .assign(assignAction):
            try executeAssignAction(assignAction, context: &context)

        case let .methodCall(methodCall):
            try await executeMethodCall(methodCall, context: context)

        case .none:
            throw MacroExecutionError.invalidAction("Empty action")
        }
    }

    private func executeInputAction(
        _ inputAction: Macosusesdk_V1_InputAction,
        context: MacroContext,
    ) async throws {
        // Substitute variables in input action
        var processedAction = inputAction
        processedAction = try substituteVariables(in: processedAction, context: context)

        // Execute via AutomationCoordinator
        try await AutomationCoordinator.shared.handleExecuteInput(
            action: processedAction,
            pid: context.pid,
            showAnimation: false,
            animationDuration: 0,
        )
    }

    private func executeWaitAction(
        _ waitAction: Macosusesdk_V1_WaitAction,
        context: MacroContext,
    ) async throws {
        // Simple delay
        if !waitAction.hasCondition {
            let nanoseconds = UInt64(waitAction.duration * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            return
        }

        // Wait for condition
        let timeout = waitAction.condition.timeout > 0 ? waitAction.condition.timeout : 30.0
        let endTime = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.5

        while Date() < endTime {
            if try await evaluateWaitCondition(waitAction.condition, context: context) {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        throw MacroExecutionError.timeout
    }

    private func evaluateWaitCondition(
        _ condition: Macosusesdk_V1_WaitCondition,
        context: MacroContext,
    ) async throws -> Bool {
        switch condition.condition {
        case let .elementSelector(selectorString):
            // Check if element exists
            // Parse string to determine selector type
            let selector = parseSelectorString(selectorString)
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await ElementLocator.shared.findElements(
                selector: validatedSelector,
                parent: context.parent,
                visibleOnly: true,
                maxResults: 1,
            )
            return !elementsWithPaths.isEmpty

        case let .windowTitle(title):
            // Check if window with title exists
            guard let pid = context.pid else { return false }
            try await windowRegistry.refreshWindows(forPID: pid)
            let windows = try await windowRegistry.listWindows(forPID: pid)
            return windows.contains { $0.title.contains(title) }

        case let .application(bundleId):
            // Check if application is running
            let workspace = NSWorkspace.shared
            let runningApps = workspace.runningApplications
            return runningApps.contains { $0.bundleIdentifier == bundleId }

        case .none:
            return false
        }
    }

    private func executeConditionalAction(
        _ conditionalAction: Macosusesdk_V1_ConditionalAction,
        context: inout MacroContext,
    ) async throws {
        let conditionMet = try await evaluateCondition(conditionalAction.condition, context: context)

        if conditionMet {
            for action in conditionalAction.thenActions {
                try await executeAction(action, context: &context)
            }
        } else {
            for action in conditionalAction.elseActions {
                try await executeAction(action, context: &context)
            }
        }
    }

    private func evaluateCondition(
        _ condition: Macosusesdk_V1_MacroCondition,
        context: MacroContext,
    ) async throws -> Bool {
        switch condition.condition {
        case let .elementExists(selectorString):
            // Parse string to determine selector type
            let selector = parseSelectorString(selectorString)
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await ElementLocator.shared.findElements(
                selector: validatedSelector,
                parent: context.parent,
                visibleOnly: true,
                maxResults: 1,
            )
            return !elementsWithPaths.isEmpty

        case let .windowExists(title):
            guard let pid = context.pid else { return false }
            try await windowRegistry.refreshWindows(forPID: pid)
            let windows = try await windowRegistry.listWindows(forPID: pid)
            return windows.contains { $0.title.contains(title) }

        case let .applicationRunning(bundleId):
            let workspace = NSWorkspace.shared
            let runningApps = workspace.runningApplications
            return runningApps.contains { $0.bundleIdentifier == bundleId }

        case let .variableEquals(varCondition):
            guard let value = context.variables[varCondition.variable] else {
                return false
            }
            return value == varCondition.value

        case let .compound(compoundCondition):
            return try await evaluateCompoundCondition(compoundCondition, context: context)

        case .none:
            return false
        }
    }

    private func evaluateCompoundCondition(
        _ compound: Macosusesdk_V1_CompoundCondition,
        context: MacroContext,
    ) async throws -> Bool {
        switch compound.operator {
        case .and:
            for condition in compound.conditions where try await !evaluateCondition(condition, context: context) {
                return false
            }
            return true

        case .or:
            for condition in compound.conditions where try await evaluateCondition(condition, context: context) {
                return true
            }
            return false

        case .not:
            guard compound.conditions.count == 1 else {
                throw MacroExecutionError.invalidAction("NOT operator requires exactly one condition")
            }
            return try await !evaluateCondition(compound.conditions[0], context: context)

        case .unspecified, .UNRECOGNIZED:
            throw MacroExecutionError.invalidAction("Unspecified compound operator")
        }
    }

    private func executeLoopAction(
        _ loopAction: Macosusesdk_V1_LoopAction,
        context: inout MacroContext,
    ) async throws {
        switch loopAction.loopType {
        case let .count(count):
            for _ in 0 ..< count {
                for action in loopAction.actions {
                    try await executeAction(action, context: &context)
                }
            }

        case let .whileCondition(condition):
            while try await evaluateCondition(condition, context: context) {
                for action in loopAction.actions {
                    try await executeAction(action, context: &context)
                }
            }

        case let .foreach(forEachLoop):
            try await executeForEachLoop(forEachLoop, actions: loopAction.actions, context: &context)

        case .none:
            throw MacroExecutionError.invalidAction("Loop type not specified")
        }
    }

    private func executeForEachLoop(
        _ forEach: Macosusesdk_V1_ForEachLoop,
        actions: [Macosusesdk_V1_MacroAction],
        context: inout MacroContext,
    ) async throws {
        var items: [String] = []

        switch forEach.collection {
        case let .elementSelector(selectorString):
            // Get all matching elements
            // Parse string to determine selector type
            let selector = parseSelectorString(selectorString)
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await ElementLocator.shared.findElements(
                selector: validatedSelector,
                parent: context.parent,
                visibleOnly: true,
                maxResults: 100,
            )
            items = elementsWithPaths.map(\.element.elementID)

        case let .windowPattern(pattern):
            // Get all matching windows
            guard let pid = context.pid else {
                throw MacroExecutionError.executionFailed("No PID in context for window pattern")
            }
            try await windowRegistry.refreshWindows(forPID: pid)
            let windows = try await windowRegistry.listWindows(forPID: pid)
            items = windows.filter { $0.title.contains(pattern) }.map { String($0.windowID) }

        case let .values(valuesString):
            // Split by newline or comma
            items = valuesString.split(separator: "\n").flatMap { line in
                line.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            }

        case .none:
            throw MacroExecutionError.invalidAction("For-each collection not specified")
        }

        // Execute actions for each item
        for item in items {
            context.variables[forEach.itemVariable] = item
            for action in actions {
                try await executeAction(action, context: &context)
            }
        }
    }

    private func executeAssignAction(
        _ assignAction: Macosusesdk_V1_AssignAction,
        context: inout MacroContext,
    ) throws {
        let value: String

        switch assignAction.value {
        case let .literal(literalValue):
            value = literalValue

        case let .parameter(paramKey):
            guard let paramValue = context.parameters[paramKey] else {
                throw MacroExecutionError.variableNotFound("Parameter '\(paramKey)' not found")
            }
            value = paramValue

        case let .expression(expr):
            // Simple expression evaluation (just variable substitution for now)
            value = substituteVariablesInString(expr, context: context)

        case .elementAttribute:
            // Would need async, skip for now
            throw MacroExecutionError.invalidAction("Element attribute assignment not yet supported")

        case .none:
            throw MacroExecutionError.invalidAction("Assignment value not specified")
        }

        context.variables[assignAction.variable] = value
    }

    private func executeMethodCall(
        _ methodCall: Macosusesdk_V1_MethodCall,
        context: MacroContext,
    ) async throws {
        // Substitute variables in arguments
        var processedArgs: [String: String] = [:]
        for (key, value) in methodCall.args {
            processedArgs[key] = substituteVariablesInString(value, context: context)
        }

        // Execute common methods
        switch methodCall.method {
        case "ClickElement":
            guard let elementId = processedArgs["elementId"] else {
                throw MacroExecutionError.invalidAction("ClickElement requires elementId argument")
            }

            // Retrieve element from registry to get coordinates
            guard let element = await ElementRegistry.shared.getElement(elementId) else {
                throw MacroExecutionError.elementNotFound(elementId)
            }

            // Validate element has position data
            guard element.hasX, element.hasY, element.hasWidth, element.hasHeight else {
                throw MacroExecutionError.executionFailed("Element \(elementId) missing position data")
            }

            // Calculate center point of element
            let centerX = element.x + (element.width / 2)
            let centerY = element.y + (element.height / 2)

            // Click the element at its center
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .click(
                        Macosusesdk_V1_MouseClick.with {
                            $0.position = Macosusesdk_Type_Point.with {
                                $0.x = centerX
                                $0.y = centerY
                            }
                            $0.clickType = .left
                            $0.clickCount = 1
                        },
                    )
                },
                pid: context.pid,
                showAnimation: false,
                animationDuration: 0,
            )

        case "TypeText":
            guard let text = processedArgs["text"] else {
                throw MacroExecutionError.invalidAction("TypeText requires text argument")
            }

            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .typeText(
                        Macosusesdk_V1_TextInput.with {
                            $0.text = text
                        },
                    )
                },
                pid: context.pid,
                showAnimation: false,
                animationDuration: 0,
            )

        default:
            throw MacroExecutionError.invalidAction("Unknown method: \(methodCall.method)")
        }
    }

    private func substituteVariables(
        in action: Macosusesdk_V1_InputAction,
        context: MacroContext,
    ) throws -> Macosusesdk_V1_InputAction {
        var result = action

        // Substitute in text input
        switch result.inputType {
        case var .typeText(textInput):
            textInput.text = substituteVariablesInString(textInput.text, context: context)
            result.inputType = .typeText(textInput)
        default:
            break
        }

        return result
    }

    private func substituteVariablesInString(_ str: String, context: MacroContext) -> String {
        var result = str

        // Substitute ${var} patterns
        let pattern = "\\$\\{([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }

        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        // Process in reverse to maintain correct indices
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result) else { continue }
            let varName = String(result[varRange])

            // Look up variable
            let value: String
            if let varValue = context.variables[varName] {
                value = varValue
            } else if let paramValue = context.parameters[varName] {
                value = paramValue
            } else {
                continue // Keep original ${var} if not found
            }

            // Replace ${var} with value
            guard let fullRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(fullRange, with: value)
        }

        return result
    }
}

/// Helper function to parse selector string into ElementSelector proto
/// Supports formats:
/// - "role:Button" -> role selector
/// - "text:OK" -> exact text match
/// - "textContains:Submit" -> text contains
/// - "Button" -> defaults to role selector (backward compatible)
private func parseSelectorString(_ str: String) -> Macosusesdk_Type_ElementSelector {
    if str.hasPrefix("role:") {
        Macosusesdk_Type_ElementSelector.with {
            $0.role = String(str.dropFirst(5))
        }
    } else if str.hasPrefix("text:") {
        Macosusesdk_Type_ElementSelector.with {
            $0.text = String(str.dropFirst(5))
        }
    } else if str.hasPrefix("textContains:") {
        Macosusesdk_Type_ElementSelector.with {
            $0.textContains = String(str.dropFirst(13))
        }
    } else if str.hasPrefix("textRegex:") {
        Macosusesdk_Type_ElementSelector.with {
            $0.textRegex = String(str.dropFirst(10))
        }
    } else {
        // Default to role selector for backward compatibility
        Macosusesdk_Type_ElementSelector.with {
            $0.role = str
        }
    }
}

/// Helper function to parse PID from resource name - now uses shared ParsingHelpers
private func parsePID(fromName name: String) throws -> pid_t {
    do {
        return try ParsingHelpers.parsePID(fromName: name)
    } catch {
        throw MacroExecutionError.invalidAction("Invalid parent resource name: \(name)")
    }
}
