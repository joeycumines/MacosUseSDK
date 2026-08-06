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
    var operationID: String = ""
    var nextPhysicalOrdinal: UInt64 = 0
    var applicationGeneration: AppStateStore.ApplicationProcessGenerationLease?

    var pid: pid_t? {
        applicationGeneration?.pid
    }
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

enum MacroExecutionBoundary: Equatable, Sendable {
    case action
    case condition
    case loopIteration
    case forEachItem
    case waitPoll
    case completion
}

typealias MacroExecutionBoundaryObserver = @Sendable (MacroExecutionBoundary) async -> Void
typealias MacroDeadlineWaiter = @Sendable (ContinuousClock.Instant) async throws -> Void
typealias MacroDeadlineOutcomeObserver = @Sendable () async -> Void

enum MacroExecutionRaceWinner: Equatable, Sendable {
    case body
    case deadline
}

typealias MacroExecutionRaceWinnerObserver = @Sendable (MacroExecutionRaceWinner) async -> Void

private struct MacroExecutionControl: Sendable {
    let clock: ContinuousClock
    let deadline: ContinuousClock.Instant
    let observer: MacroExecutionBoundaryObserver
    let validateGeneration: @Sendable () async throws -> Void

    func checkpoint(_ boundary: MacroExecutionBoundary) async throws {
        await Task.yield()
        try Task.checkCancellation()
        guard clock.now <= deadline else {
            throw MacroExecutionError.timeout
        }
        await observer(boundary)
        try Task.checkCancellation()
        try await validateGeneration()
        guard clock.now <= deadline else {
            throw MacroExecutionError.timeout
        }
    }

    func sleep(for requested: Duration, boundary: MacroExecutionBoundary) async throws {
        try await checkpoint(boundary)
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw MacroExecutionError.timeout
        }
        let bounded = min(requested, remaining)
        if bounded > .zero {
            try await clock.sleep(for: bounded)
        }
        try await checkpoint(boundary)
        if requested > remaining {
            throw MacroExecutionError.timeout
        }
    }

    func sleep(seconds: Double, boundary: MacroExecutionBoundary) async throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw MacroExecutionError.invalidAction("Wait duration must be finite and non-negative")
        }
        try await sleep(for: .seconds(seconds), boundary: boundary)
    }
}

private enum MacroExecutionRaceEvent: @unchecked Sendable {
    case body(Result<Void, any Error>)
    case deadline(Result<Void, any Error>)

    var winner: MacroExecutionRaceWinner {
        switch self {
        case .body:
            .body
        case .deadline:
            .deadline
        }
    }

    func get() throws {
        switch self {
        case let .body(result), let .deadline(result):
            try result.get()
        }
    }
}

private func staleApplicationGenerationError() -> RPCError {
    RPCError(
        code: .notFound,
        message: "Application not found or process identity is stale",
    )
}

/// Actor for executing macros with support for all action types.
public actor MacroExecutor {
    /// Shared window registry for consistent window tracking
    private let windowRegistry: WindowRegistry
    nonisolated let inputTransactionExecutor: InputTransactionExecutor
    nonisolated let automationCoordinator: AutomationCoordinator
    nonisolated let elementRegistry: ElementRegistry
    nonisolated let elementLocator: ElementLocator
    private let executionBoundaryObserver: MacroExecutionBoundaryObserver
    private let deadlineWaiter: MacroDeadlineWaiter
    private let deadlineOutcomeObserver: MacroDeadlineOutcomeObserver
    private let raceWinnerObserver: MacroExecutionRaceWinnerObserver
    private var acceptingExecutions = true
    private var executionTasks: [UUID: Task<Void, any Error>] = [:]

    init(
        windowRegistry: WindowRegistry,
        inputTransactionExecutor: InputTransactionExecutor,
        automationCoordinator: AutomationCoordinator? = nil,
        elementRegistry: ElementRegistry? = nil,
        elementLocator: ElementLocator? = nil,
        executionBoundaryObserver: @escaping MacroExecutionBoundaryObserver = { _ in },
        deadlineWaiter: @escaping MacroDeadlineWaiter = {
            try await ContinuousClock().sleep(until: $0)
        },
        deadlineOutcomeObserver: @escaping MacroDeadlineOutcomeObserver = {},
        raceWinnerObserver: @escaping MacroExecutionRaceWinnerObserver = { _ in },
    ) {
        let automationCoordinator = automationCoordinator ?? AutomationCoordinator()
        let elementRegistry = elementRegistry ?? automationCoordinator.elementRegistry
        self.windowRegistry = windowRegistry
        self.inputTransactionExecutor = inputTransactionExecutor
        self.automationCoordinator = automationCoordinator
        self.elementRegistry = elementRegistry
        self.elementLocator = elementLocator ?? ElementLocator(
            elementRegistry: elementRegistry,
            automationCoordinator: automationCoordinator,
        )
        self.executionBoundaryObserver = executionBoundaryObserver
        self.deadlineWaiter = deadlineWaiter
        self.deadlineOutcomeObserver = deadlineOutcomeObserver
        self.raceWinnerObserver = raceWinnerObserver
    }

    /// Execute a macro with given parameters
    func executeMacro(
        macro: Macosusesdk_V1_Macro,
        operationName: String? = nil,
        parameters: [String: String],
        parent: String,
        applicationGeneration: AppStateStore.ApplicationProcessGenerationLease? = nil,
        timeout: Double,
    ) async throws {
        guard acceptingExecutions else {
            throw MacroExecutionError.executionFailed("Macro execution admission is closed")
        }
        try Task.checkCancellation()
        guard timeout.isFinite, timeout >= 0 else {
            throw MacroExecutionError.invalidAction("Macro timeout must be finite and non-negative")
        }
        guard (parent.isEmpty && applicationGeneration == nil)
            || (!parent.isEmpty && applicationGeneration?.name == parent)
        else {
            throw staleApplicationGenerationError()
        }

        let id = UUID()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let task = Task {
            try await self.executeMacroBeforeDeadline(
                macro: macro,
                operationName: operationName ?? "operations/\(UUID().uuidString)",
                parameters: parameters,
                parent: parent,
                applicationGeneration: applicationGeneration,
                clock: clock,
                deadline: deadline,
            )
        }
        executionTasks[id] = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            executionTasks.removeValue(forKey: id)
        } catch {
            executionTasks.removeValue(forKey: id)
            throw error
        }
    }

    func activeExecutionCount() -> Int {
        executionTasks.count
    }

    func beginDraining() {
        guard acceptingExecutions else { return }
        acceptingExecutions = false
        for task in executionTasks.values {
            task.cancel()
        }
    }

    func shutdown() async {
        beginDraining()
        let tasks = Array(executionTasks.values)
        for task in tasks {
            _ = try? await task.value
        }
        executionTasks.removeAll(keepingCapacity: false)
    }

    private func executeMacroBody(
        macro: Macosusesdk_V1_Macro,
        operationName: String,
        parameters: [String: String],
        parent: String,
        applicationGeneration: AppStateStore.ApplicationProcessGenerationLease?,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
    ) async throws {
        logger.info("Executing macro: \(macro.name, privacy: .public)")

        // Validate required parameters
        for param in macro.parameters where param.required {
            guard parameters[param.key] != nil else {
                throw MacroExecutionError.executionFailed("Missing required parameter: \(param.key)")
            }
        }

        // Build execution context
        let operationID = try ParsingHelpers.parseOperationName(operationName).operationId
        var context = MacroContext(
            parameters: parameters,
            parent: parent,
            operationID: operationID,
            applicationGeneration: applicationGeneration,
        )

        // Apply default values for missing optional parameters
        for param in macro.parameters where !param.required && !param.defaultValue.isEmpty {
            if context.parameters[param.key] == nil {
                context.parameters[param.key] = param.defaultValue
            }
        }

        // Set timeout
        let control = MacroExecutionControl(
            clock: clock,
            deadline: deadline,
            observer: executionBoundaryObserver,
            validateGeneration: { [inputTransactionExecutor, applicationGeneration] in
                guard let applicationGeneration else { return }
                guard await inputTransactionExecutor.stateStore
                    .applicationProcessGenerationLease(name: applicationGeneration.name)
                    == applicationGeneration,
                    inputTransactionExecutor.system.isApplicationProcessRunning(
                        applicationGeneration.identity,
                    )
                else {
                    throw staleApplicationGenerationError()
                }
            },
        )

        // Execute all actions
        for action in macro.actions {
            try await executeAction(action, context: &context, control: control)
        }
        try await control.checkpoint(.completion)

        logger.info("Macro execution completed: \(macro.name, privacy: .public)")
    }

    private func executeMacroBeforeDeadline(
        macro: Macosusesdk_V1_Macro,
        operationName: String,
        parameters: [String: String],
        parent: String,
        applicationGeneration: AppStateStore.ApplicationProcessGenerationLease?,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
    ) async throws {
        let deadlineWaiter = deadlineWaiter
        let deadlineOutcomeObserver = deadlineOutcomeObserver
        let raceWinnerObserver = raceWinnerObserver
        let selected = await withTaskGroup(
            of: MacroExecutionRaceEvent.self,
            returning: MacroExecutionRaceEvent.self,
        ) { group in
            group.addTask {
                do {
                    try await self.executeMacroBody(
                        macro: macro,
                        operationName: operationName,
                        parameters: parameters,
                        parent: parent,
                        applicationGeneration: applicationGeneration,
                        clock: clock,
                        deadline: deadline,
                    )
                    return .body(.success(()))
                } catch {
                    return .body(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await deadlineWaiter(deadline)
                    try Task.checkCancellation()
                    await deadlineOutcomeObserver()
                    return .deadline(.failure(MacroExecutionError.timeout))
                } catch {
                    return .deadline(.failure(error))
                }
            }

            let first = await group.next()!
            await raceWinnerObserver(first.winner)
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
        try selected.get()
    }

    private func executeAction(
        _ action: Macosusesdk_V1_MacroAction,
        context: inout MacroContext,
        control: MacroExecutionControl,
    ) async throws {
        try await control.checkpoint(.action)
        switch action.action {
        case let .input(inputAction):
            try await executeInputAction(inputAction, context: &context)

        case let .wait(waitAction):
            try await executeWaitAction(waitAction, context: context, control: control)

        case let .conditional(conditionalAction):
            try await executeConditionalAction(conditionalAction, context: &context, control: control)

        case let .loop(loopAction):
            try await executeLoopAction(loopAction, context: &context, control: control)

        case let .assign(assignAction):
            try executeAssignAction(assignAction, context: &context)

        case let .methodCall(methodCall):
            try await executeMethodCall(methodCall, context: &context)

        case .none:
            throw MacroExecutionError.invalidAction("Empty action")
        }
    }

    private func executeInputAction(
        _ inputAction: Macosusesdk_V1_InputAction,
        context: inout MacroContext,
    ) async throws {
        // Substitute variables in input action
        var processedAction = inputAction
        processedAction = try substituteVariables(in: processedAction, context: context)

        let ordinal = context.nextPhysicalOrdinal
        let (nextOrdinal, overflow) = ordinal.addingReportingOverflow(1)
        guard !overflow else {
            throw MacroExecutionError.executionFailed("Physical macro action ordinal overflow")
        }
        context.nextPhysicalOrdinal = nextOrdinal
        try await executePhysicalInput(processedAction, ordinal: ordinal, context: context)
    }

    private func executeWaitAction(
        _ waitAction: Macosusesdk_V1_WaitAction,
        context: MacroContext,
        control: MacroExecutionControl,
    ) async throws {
        // Simple delay
        if !waitAction.hasCondition {
            try await control.sleep(seconds: waitAction.duration, boundary: .waitPoll)
            return
        }

        // Wait for condition
        let timeout = waitAction.condition.timeout > 0 ? waitAction.condition.timeout : 30.0
        guard timeout.isFinite else {
            throw MacroExecutionError.invalidAction(
                "Wait condition timeout must be finite",
            )
        }
        let conditionDeadline = min(
            control.deadline,
            control.clock.now.advanced(by: .seconds(timeout)),
        )
        let pollInterval = Duration.milliseconds(500)

        while control.clock.now < conditionDeadline {
            try await control.checkpoint(.waitPoll)
            if try await evaluateWaitCondition(waitAction.condition, context: context) {
                return
            }
            let remaining = control.clock.now.duration(to: conditionDeadline)
            guard remaining > .zero else { break }
            try await control.sleep(
                for: min(pollInterval, remaining),
                boundary: .waitPoll,
            )
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
            let elementsWithPaths = try await elementLocator.findElements(
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
        control: MacroExecutionControl,
    ) async throws {
        let conditionMet = try await evaluateCondition(
            conditionalAction.condition,
            context: context,
            control: control,
        )

        if conditionMet {
            for action in conditionalAction.thenActions {
                try await executeAction(action, context: &context, control: control)
            }
        } else {
            for action in conditionalAction.elseActions {
                try await executeAction(action, context: &context, control: control)
            }
        }
    }

    private func evaluateCondition(
        _ condition: Macosusesdk_V1_MacroCondition,
        context: MacroContext,
        control: MacroExecutionControl,
    ) async throws -> Bool {
        try await control.checkpoint(.condition)
        switch condition.condition {
        case let .elementExists(selectorString):
            // Parse string to determine selector type
            let selector = parseSelectorString(selectorString)
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await elementLocator.findElements(
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
            return try await evaluateCompoundCondition(
                compoundCondition,
                context: context,
                control: control,
            )

        case .none:
            return false
        }
    }

    private func evaluateCompoundCondition(
        _ compound: Macosusesdk_V1_CompoundCondition,
        context: MacroContext,
        control: MacroExecutionControl,
    ) async throws -> Bool {
        switch compound.operator {
        case .and:
            for condition in compound.conditions
                where try await !evaluateCondition(condition, context: context, control: control)
            {
                return false
            }
            return true

        case .or:
            for condition in compound.conditions
                where try await evaluateCondition(condition, context: context, control: control)
            {
                return true
            }
            return false

        case .not:
            guard compound.conditions.count == 1 else {
                throw MacroExecutionError.invalidAction("NOT operator requires exactly one condition")
            }
            return try await !evaluateCondition(
                compound.conditions[0],
                context: context,
                control: control,
            )

        case .unspecified, .UNRECOGNIZED:
            throw MacroExecutionError.invalidAction("Unspecified compound operator")
        }
    }

    private func executeLoopAction(
        _ loopAction: Macosusesdk_V1_LoopAction,
        context: inout MacroContext,
        control: MacroExecutionControl,
    ) async throws {
        switch loopAction.loopType {
        case let .count(count):
            guard count >= 0 else {
                throw MacroExecutionError.invalidAction("Loop count must be non-negative")
            }
            for _ in 0 ..< count {
                try await control.checkpoint(.loopIteration)
                for action in loopAction.actions {
                    try await executeAction(action, context: &context, control: control)
                }
            }

        case let .whileCondition(condition):
            while try await evaluateCondition(condition, context: context, control: control) {
                try await control.checkpoint(.loopIteration)
                for action in loopAction.actions {
                    try await executeAction(action, context: &context, control: control)
                }
            }

        case let .foreach(forEachLoop):
            try await executeForEachLoop(
                forEachLoop,
                actions: loopAction.actions,
                context: &context,
                control: control,
            )

        case .none:
            throw MacroExecutionError.invalidAction("Loop type not specified")
        }
    }

    private func executeForEachLoop(
        _ forEach: Macosusesdk_V1_ForEachLoop,
        actions: [Macosusesdk_V1_MacroAction],
        context: inout MacroContext,
        control: MacroExecutionControl,
    ) async throws {
        var items: [String] = []

        switch forEach.collection {
        case let .elementSelector(selectorString):
            // Get all matching elements
            // Parse string to determine selector type
            let selector = parseSelectorString(selectorString)
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await elementLocator.findElements(
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
            try await control.checkpoint(.forEachItem)
            context.variables[forEach.itemVariable] = item
            for action in actions {
                try await executeAction(action, context: &context, control: control)
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
        context: inout MacroContext,
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
            guard let element = await elementRegistry.getElement(elementId) else {
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
            let clickOrdinal = context.nextPhysicalOrdinal
            let (clickNextOrdinal, clickOverflow) = clickOrdinal.addingReportingOverflow(1)
            guard !clickOverflow else {
                throw MacroExecutionError.executionFailed("Physical macro action ordinal overflow")
            }
            context.nextPhysicalOrdinal = clickNextOrdinal
            try await executePhysicalInput(
                Macosusesdk_V1_InputAction.with {
                    $0.click = Macosusesdk_V1_MouseClick.with {
                        $0.position = Macosusesdk_Type_Point.with {
                            $0.x = centerX
                            $0.y = centerY
                        }
                        $0.clickType = .left
                        $0.clickCount = 1
                    }
                },
                ordinal: clickOrdinal,
                context: context,
            )

        case "TypeText":
            guard let text = processedArgs["text"] else {
                throw MacroExecutionError.invalidAction("TypeText requires text argument")
            }

            let typeOrdinal = context.nextPhysicalOrdinal
            let (typeNextOrdinal, typeOverflow) = typeOrdinal.addingReportingOverflow(1)
            guard !typeOverflow else {
                throw MacroExecutionError.executionFailed("Physical macro action ordinal overflow")
            }
            context.nextPhysicalOrdinal = typeNextOrdinal
            try await executePhysicalInput(
                Macosusesdk_V1_InputAction.with {
                    $0.typeText = Macosusesdk_V1_TextInput.with {
                        $0.text = text
                    }
                },
                ordinal: typeOrdinal,
                context: context,
            )

        default:
            throw MacroExecutionError.invalidAction("Unknown method: \(methodCall.method)")
        }
    }

    private func executePhysicalInput(
        _ action: Macosusesdk_V1_InputAction,
        ordinal: UInt64,
        context: MacroContext,
    ) async throws {
        guard let applicationGeneration = context.applicationGeneration,
              applicationGeneration.name == context.parent,
              applicationGeneration.pid == context.pid
        else {
            throw MacroExecutionError.executionFailed(
                "Physical macro action requires one exact application generation",
            )
        }

        let inputID = "macro-\(context.operationID)-\(ordinal)"
        let request = Macosusesdk_V1_CreateInputRequest.with {
            $0.parent = applicationGeneration.name
            $0.inputID = inputID
            $0.input = Macosusesdk_V1_Input.with {
                $0.action = action
                $0.target.application = applicationGeneration.name
            }
        }
        let input = try await inputTransactionExecutor.execute(
            request,
            expectedApplicationGeneration: applicationGeneration,
        )
        let expectedName = "\(applicationGeneration.name)/inputs/\(inputID)"
        guard input.name == expectedName,
              input.action == action,
              input.target.application == applicationGeneration.name,
              input.state == .completed,
              input.error.isEmpty,
              input.hasDeliveryResult,
              input.deliveryResult.commitment == .committedAndSettled,
              input.deliveryResult.postedEventCount > 0,
              input.deliveryResult.routedDeliveryObserved
        else {
            throw MacroExecutionError.executionFailed(
                "Physical macro Input did not settle with exact committed delivery truth",
            )
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
