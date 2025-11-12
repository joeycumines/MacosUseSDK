import AppKit
import Foundation
import GRPC
import MacosUseSDKProtos
import SwiftProtobuf

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
    case .macroNotFound(let name):
      return "Macro not found: \(name)"
    case .invalidAction(let msg):
      return "Invalid action: \(msg)"
    case .conditionFailed(let msg):
      return "Condition failed: \(msg)"
    case .variableNotFound(let name):
      return "Variable not found: \(name)"
    case .elementNotFound(let selector):
      return "Element not found: \(selector)"
    case .executionFailed(let msg):
      return "Execution failed: \(msg)"
    case .timeout:
      return "Macro execution timed out"
    }
  }
}

/// Actor for executing macros with support for all action types
public actor MacroExecutor {
  public static let shared = MacroExecutor()

  private init() {}

  // MARK: - Execution Entry Point

  /// Execute a macro with given parameters
  public func executeMacro(
    macro: Macrosusesdk_V1_Macro,
    parameters: [String: String],
    parent: String,
    timeout: Double
  ) async throws {
    fputs("info: [MacroExecutor] Executing macro: \(macro.name)\n", stderr)

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

    fputs("info: [MacroExecutor] Macro execution completed: \(macro.name)\n", stderr)
  }

  // MARK: - Action Execution

  private func executeAction(
    _ action: Macrosusesdk_V1_MacroAction,
    context: inout MacroContext
  ) async throws {
    switch action.action {
    case .input(let inputAction):
      try await executeInputAction(inputAction, context: context)

    case .wait(let waitAction):
      try await executeWaitAction(waitAction, context: context)

    case .conditional(let conditionalAction):
      try await executeConditionalAction(conditionalAction, context: &context)

    case .loop(let loopAction):
      try await executeLoopAction(loopAction, context: &context)

    case .assign(let assignAction):
      try executeAssignAction(assignAction, context: &context)

    case .methodCall(let methodCall):
      try await executeMethodCall(methodCall, context: context)

    case .none:
      throw MacroExecutionError.invalidAction("Empty action")
    }
  }

  // MARK: - Input Action Execution

  private func executeInputAction(
    _ inputAction: Macosusesdk_V1_InputAction,
    context: MacroContext
  ) async throws {
    // Substitute variables in input action
    var processedAction = inputAction
    processedAction = try substituteVariables(in: processedAction, context: context)

    // Execute via AutomationCoordinator
    try await AutomationCoordinator.shared.handleExecuteInput(
      action: processedAction,
      pid: context.pid,
      showAnimation: false,
      animationDuration: 0
    )
  }

  // MARK: - Wait Action Execution

  private func executeWaitAction(
    _ waitAction: Macrosusesdk_V1_WaitAction,
    context: MacroContext
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
    _ condition: Macrosusesdk_V1_WaitCondition,
    context: MacroContext
  ) async throws -> Bool {
    switch condition.condition {
    case .elementSelector(let selector):
      // Check if element exists
      let validatedSelector = try SelectorParser.shared.parseSelector(selector)
      let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: validatedSelector,
        parent: context.parent,
        visibleOnly: true,
        maxResults: 1
      )
      return !elementsWithPaths.isEmpty

    case .windowTitle(let title):
      // Check if window with title exists
      guard let pid = context.pid else { return false }
      let registry = WindowRegistry()
      try await registry.refreshWindows(forPID: pid)
      let windows = try await registry.listWindows(forPID: pid)
      return windows.contains { $0.title.contains(title) }

    case .application(let bundleId):
      // Check if application is running
      let workspace = NSWorkspace.shared
      let runningApps = workspace.runningApplications
      return runningApps.contains { $0.bundleIdentifier == bundleId }

    case .none:
      return false
    }
  }

  // MARK: - Conditional Action Execution

  private func executeConditionalAction(
    _ conditionalAction: Macrosusesdk_V1_ConditionalAction,
    context: inout MacroContext
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
    _ condition: Macrosusesdk_V1_MacroCondition,
    context: MacroContext
  ) async throws -> Bool {
    switch condition.condition {
    case .elementExists(let selector):
      let validatedSelector = try SelectorParser.shared.parseSelector(selector)
      let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: validatedSelector,
        parent: context.parent,
        visibleOnly: true,
        maxResults: 1
      )
      return !elementsWithPaths.isEmpty

    case .windowExists(let title):
      guard let pid = context.pid else { return false }
      let registry = WindowRegistry()
      try await registry.refreshWindows(forPID: pid)
      let windows = try await registry.listWindows(forPID: pid)
      return windows.contains { $0.title.contains(title) }

    case .applicationRunning(let bundleId):
      let workspace = NSWorkspace.shared
      let runningApps = workspace.runningApplications
      return runningApps.contains { $0.bundleIdentifier == bundleId }

    case .variableEquals(let varCondition):
      guard let value = context.variables[varCondition.variable] else {
        return false
      }
      return value == varCondition.value

    case .compound(let compoundCondition):
      return try await evaluateCompoundCondition(compoundCondition, context: context)

    case .none:
      return false
    }
  }

  private func evaluateCompoundCondition(
    _ compound: Macrosusesdk_V1_CompoundCondition,
    context: MacroContext
  ) async throws -> Bool {
    switch compound.operator {
    case .and:
      for condition in compound.conditions {
        if try await !evaluateCondition(condition, context: context) {
          return false
        }
      }
      return true

    case .or:
      for condition in compound.conditions {
        if try await evaluateCondition(condition, context: context) {
          return true
        }
      }
      return false

    case .not:
      guard compound.conditions.count == 1 else {
        throw MacroExecutionError.invalidAction("NOT operator requires exactly one condition")
      }
      return try await !evaluateCondition(compound.conditions[0], context: context)

    case .unspecified, .UNRECOGNIZED(_):
      throw MacroExecutionError.invalidAction("Unspecified compound operator")
    }
  }

  // MARK: - Loop Action Execution

  private func executeLoopAction(
    _ loopAction: Macrosusesdk_V1_LoopAction,
    context: inout MacroContext
  ) async throws {
    switch loopAction.loopType {
    case .count(let count):
      for _ in 0..<count {
        for action in loopAction.actions {
          try await executeAction(action, context: &context)
        }
      }

    case .whileCondition(let condition):
      while try await evaluateCondition(condition, context: context) {
        for action in loopAction.actions {
          try await executeAction(action, context: &context)
        }
      }

    case .foreach(let forEachLoop):
      try await executeForEachLoop(forEachLoop, actions: loopAction.actions, context: &context)

    case .none:
      throw MacroExecutionError.invalidAction("Loop type not specified")
    }
  }

  private func executeForEachLoop(
    _ forEach: Macrosusesdk_V1_ForEachLoop,
    actions: [Macrosusesdk_V1_MacroAction],
    context: inout MacroContext
  ) async throws {
    var items: [String] = []

    switch forEach.collection {
    case .elementSelector(let selector):
      // Get all matching elements
      let validatedSelector = try SelectorParser.shared.parseSelector(selector)
      let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: validatedSelector,
        parent: context.parent,
        visibleOnly: true,
        maxResults: 100
      )
      items = elementsWithPaths.map { $0.element.elementID }

    case .windowPattern(let pattern):
      // Get all matching windows
      guard let pid = context.pid else {
        throw MacroExecutionError.executionFailed("No PID in context for window pattern")
      }
      let registry = WindowRegistry()
      try await registry.refreshWindows(forPID: pid)
      let windows = try await registry.listWindows(forPID: pid)
      items = windows.filter { $0.title.contains(pattern) }.map { String($0.windowID) }

    case .values(let valuesString):
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

  // MARK: - Assign Action Execution

  private func executeAssignAction(
    _ assignAction: Macrosusesdk_V1_AssignAction,
    context: inout MacroContext
  ) throws {
    let value: String

    switch assignAction.value {
    case .literal(let literalValue):
      value = literalValue

    case .parameter(let paramKey):
      guard let paramValue = context.parameters[paramKey] else {
        throw MacroExecutionError.variableNotFound("Parameter '\(paramKey)' not found")
      }
      value = paramValue

    case .expression(let expr):
      // Simple expression evaluation (just variable substitution for now)
      value = substituteVariablesInString(expr, context: context)

    case .elementAttribute(_):
      // Would need async, skip for now
      throw MacroExecutionError.invalidAction("Element attribute assignment not yet supported")

    case .none:
      throw MacroExecutionError.invalidAction("Assignment value not specified")
    }

    context.variables[assignAction.variable] = value
  }

  // MARK: - Method Call Execution

  private func executeMethodCall(
    _ methodCall: Macrosusesdk_V1_MethodCall,
    context: MacroContext
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

      // Click the element
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macrosusesdk_V1_InputAction.with {
          $0.inputType = .click(
            Macrosusesdk_V1_MouseClick.with {
              // Would need to get element position here
              $0.clickType = .left
              $0.clickCount = 1
            })
        },
        pid: context.pid,
        showAnimation: false,
        animationDuration: 0
      )

    case "TypeText":
      guard let text = processedArgs["text"] else {
        throw MacroExecutionError.invalidAction("TypeText requires text argument")
      }

      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macrosusesdk_V1_InputAction.with {
          $0.inputType = .typeText(
            Macrosusesdk_V1_TextInput.with {
              $0.text = text
            })
        },
        pid: context.pid,
        showAnimation: false,
        animationDuration: 0
      )

    default:
      throw MacroExecutionError.invalidAction("Unknown method: \(methodCall.method)")
    }
  }

  // MARK: - Variable Substitution

  private func substituteVariables(
    in action: Macrosusesdk_V1_InputAction,
    context: MacroContext
  ) throws -> Macrosusesdk_V1_InputAction {
    var result = action

    // Substitute in text input
    switch result.inputType {
    case .typeText(var textInput):
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
        continue  // Keep original ${var} if not found
      }

      // Replace ${var} with value
      guard let fullRange = Range(match.range, in: result) else { continue }
      result.replaceSubrange(fullRange, with: value)
    }

    return result
  }
}

// Helper function to parse PID from resource name
private func parsePID(fromName name: String) throws -> pid_t {
  let components = name.split(separator: "/")
  guard components.count >= 2,
    components[0] == "applications",
    let pid = pid_t(components[1])
  else {
    throw MacroExecutionError.invalidAction("Invalid parent resource name: \(name)")
  }
  return pid
}
