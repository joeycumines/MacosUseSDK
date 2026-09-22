import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import XCTest

/// Unit tests for MacroExecutor error types and supporting structures.
final class MacroExecutorTests: XCTestCase {
    func testInputActionPreservesAnimationIntentThroughMacroExecution() async throws {
        let recorder = MacroInputIntentRecorder()
        let inputOverlayPresenter = InputOverlayPresenter { presentation in
            await recorder.record(presentation: presentation)
        }
        let identity = ApplicationProcessIdentity(
            pid: 6811,
            startTimeSeconds: 68,
            startTimeMicroseconds: 11,
            bundleIdentifier: "com.example.MacroIntent",
            executablePath: "/Applications/MacroIntent.app/Contents/MacOS/MacroIntent",
        )
        let applicationName = applicationResourceName(for: identity)
        let system = MockSystemOperations(
            applicationIdentities: [identity.pid: identity],
            runningPIDs: [identity.pid],
            runningApplicationIdentities: [identity],
        )
        let stateStore = AppStateStore()
        await stateStore.addTarget(
            Exactmac_V1_Application.with {
                $0.name = applicationName
                $0.pid = Int32(identity.pid)
            },
            processIdentity: identity,
        )
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action: action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let windowRegistry = WindowRegistry(system: system)
        let executor = MacroExecutor(
            windowRegistry: windowRegistry,
            inputTransactionExecutor: makeTestInputTransactionExecutor(
                stateStore: stateStore,
                windowRegistry: windowRegistry,
                system: system,
                automationCoordinator: coordinator,
                inputOverlayPresenter: inputOverlayPresenter,
            ),
            automationCoordinator: coordinator,
        )
        let macro = Exactmac_V1_Macro.with {
            $0.name = "macros/animation-intent"
            $0.actions = [
                Exactmac_V1_MacroAction.with {
                    $0.input = Exactmac_V1_InputAction.with {
                        $0.showAnimation = true
                        $0.animationDuration = 0.625
                        $0.moveMouse = Exactmac_V1_MouseMove.with {
                            $0.position = Exactmac_Type_Point.with {
                                $0.x = 10
                                $0.y = 20
                            }
                        }
                    }
                },
            ]
        }

        let generation = await stateStore.applicationProcessGenerationLease(
            name: applicationName,
        )
        let applicationGeneration = try XCTUnwrap(generation)
        try await executor.executeMacro(
            macro: macro,
            operationName: "operations/animation-intent",
            parameters: [:],
            parent: applicationName,
            applicationGeneration: applicationGeneration,
            timeout: 1,
        )

        let entries = await recorder.snapshot()
        XCTAssertEqual(entries.count, 1)
        let presentations = await recorder.presentationSnapshot()
        XCTAssertEqual(presentations.count, 1)
        XCTAssertEqual(presentations.first?.duration, 0.625)
        XCTAssertEqual(presentations.first?.content, .circle)
        if let entry = entries.first,
           case let .movePointer(point, duration, _) = entry.action
        {
            XCTAssertEqual(point, CGPoint(x: 10, y: 20))
            XCTAssertEqual(duration, 0)
        } else {
            XCTFail("Expected one prepared animated move")
        }
    }

    func testStaleApplicationIdentityIsRejectedAtEveryActionBoundary() async throws {
        let identity = ApplicationProcessIdentity(
            pid: 123,
            startTimeSeconds: 1,
            startTimeMicroseconds: 2,
            bundleIdentifier: "com.example.StaleMacro",
            executablePath: "/Applications/StaleMacro.app/Contents/MacOS/StaleMacro",
        )
        let applicationName = applicationResourceName(for: identity)
        let generation = AppStateStore.ApplicationProcessGenerationLease(
            name: applicationName,
            pid: identity.pid,
            identity: identity,
        )
        let executor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(),
        )
        let macro = Exactmac_V1_Macro.with {
            $0.name = "macros/stale-application"
            $0.actions = [
                Exactmac_V1_MacroAction.with {
                    $0.wait = Exactmac_V1_WaitAction.with { $0.duration = 0 }
                },
            ]
        }

        do {
            try await executor.executeMacro(
                macro: macro,
                parameters: [:],
                parent: applicationName,
                applicationGeneration: generation,
                timeout: 1,
            )
            XCTFail("Expected stale application identity rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "Application not found or process identity is stale")
        }
    }

    func testNestedMacroCancellationIsOwnedAndJoined() async throws {
        let probe = BlockingMacroBoundaryProbe()
        let executor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(),
            executionBoundaryObserver: { boundary in
                await probe.observe(boundary)
            },
        )
        let macro = makeNestedLoopMacro()

        let execution = Task {
            try await executor.executeMacro(
                macro: macro,
                parameters: [:],
                parent: "",
                timeout: 3600,
            )
        }
        try await probe.waitUntilNestedLoopEntered()
        let initialActiveExecutionCount = await executor.activeExecutionCount()
        XCTAssertEqual(initialActiveExecutionCount, 1)

        let shutdown = Task { await executor.shutdown() }
        try await probe.waitUntilCancellationObserved()
        let cancellingActiveExecutionCount = await executor.activeExecutionCount()
        XCTAssertEqual(cancellingActiveExecutionCount, 1)

        await probe.release()
        await shutdown.value
        do {
            try await execution.value
            XCTFail("Expected shutdown to cancel nested macro execution")
        } catch is CancellationError {
            // Expected.
        }
        let finalActiveExecutionCount = await executor.activeExecutionCount()
        XCTAssertEqual(finalActiveExecutionCount, 0)

        do {
            try await executor.executeMacro(
                macro: macro,
                parameters: [:],
                parent: "",
                timeout: 1,
            )
            XCTFail("Expected macro admission to remain closed")
        } catch let error as MacroExecutionError {
            XCTAssertEqual(error.description, "Execution failed: Macro execution admission is closed")
        }
    }

    func testNestedLoopHonorsMacroTimeoutAndReleasesOwnership() async throws {
        let deadline = MacroDeadlineTrigger()
        let probe = BlockingMacroBoundaryProbe()
        let executor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(),
            executionBoundaryObserver: { boundary in
                await probe.observe(boundary)
            },
            deadlineWaiter: { _ in try await deadline.wait() },
        )

        let execution = Task {
            try await executor.executeMacro(
                macro: makeNestedLoopMacro(),
                parameters: [:],
                parent: "",
                timeout: 3600,
            )
        }
        try await probe.waitUntilNestedLoopEntered()
        deadline.fire()
        try await probe.waitUntilCancellationObserved()
        let activeWhileCleanupIsOwned = await executor.activeExecutionCount()
        XCTAssertEqual(activeWhileCleanupIsOwned, 1)
        await probe.release()

        do {
            try await execution.value
            XCTFail("Expected nested execution to honor the macro timeout")
        } catch let error as MacroExecutionError {
            XCTAssertEqual(error.description, "Macro execution timed out")
        }

        let activeExecutionCount = await executor.activeExecutionCount()
        XCTAssertEqual(activeExecutionCount, 0)
    }

    func testBodySuccessRemainsAuthoritativeWhenDeadlineLoserFinishesDuringDrain() async throws {
        let deadline = MacroDeadlineTrigger()
        let deadlineCommitted = MacroDeadlineCommitProbe()
        let executor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(),
            deadlineWaiter: { _ in try await deadline.wait() },
            deadlineOutcomeObserver: {
                await deadlineCommitted.record()
            },
            raceWinnerObserver: { winner in
                if winner == .body {
                    deadline.fire()
                    do {
                        try await deadlineCommitted.waitUntilRecorded()
                    } catch {
                        XCTFail("Deadline loser did not commit its timeout outcome")
                    }
                    await Task.yield()
                }
            },
        )
        let macro = Exactmac_V1_Macro.with {
            $0.name = "macros/body-wins"
            $0.actions = [
                Exactmac_V1_MacroAction.with {
                    $0.assign.variable = "result"
                    $0.assign.literal = "complete"
                },
            ]
        }

        try await executor.executeMacro(
            macro: macro,
            parameters: [:],
            parent: "",
            timeout: 3600,
        )

        let activeExecutionCount = await executor.activeExecutionCount()
        XCTAssertEqual(activeExecutionCount, 0)
    }

    func testGenerationRetiredDuringSkippedPhysicalConditionCannotPublishSuccess() async throws {
        let identity = ApplicationProcessIdentity(
            pid: 6812,
            startTimeSeconds: 69,
            startTimeMicroseconds: 12,
            bundleIdentifier: "com.example.MacroCondition",
            executablePath: "/Applications/MacroCondition.app/Contents/MacOS/MacroCondition",
        )
        let applicationName = applicationResourceName(for: identity)
        let stateStore = AppStateStore()
        await stateStore.addTarget(
            Exactmac_V1_Application.with {
                $0.name = applicationName
                $0.pid = Int32(identity.pid)
            },
            processIdentity: identity,
        )
        let system = MockSystemOperations(
            applicationIdentities: [identity.pid: identity],
            runningPIDs: [identity.pid],
            runningApplicationIdentities: [identity],
        )
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
        )
        let windowRegistry = WindowRegistry(system: system)
        let executor = MacroExecutor(
            windowRegistry: windowRegistry,
            inputTransactionExecutor: makeTestInputTransactionExecutor(
                stateStore: stateStore,
                windowRegistry: windowRegistry,
                system: system,
                automationCoordinator: coordinator,
            ),
            automationCoordinator: coordinator,
            executionBoundaryObserver: { boundary in
                if boundary == .condition {
                    _ = await stateStore.removeTarget(name: applicationName)
                }
            },
        )
        let capturedGeneration = await stateStore.applicationProcessGenerationLease(
            name: applicationName,
        )
        let generation = try XCTUnwrap(capturedGeneration)
        let macro = Exactmac_V1_Macro.with {
            $0.name = "macros/retired-empty-branch"
            $0.actions = [
                Exactmac_V1_MacroAction.with {
                    $0.conditional.condition.variableEquals.variable = "missing"
                    $0.conditional.condition.variableEquals.value = "true"
                    $0.conditional.thenActions = [
                        Exactmac_V1_MacroAction.with {
                            $0.input.moveMouse.position = Exactmac_Type_Point.with {
                                $0.x = 10
                                $0.y = 20
                            }
                        },
                    ]
                },
            ]
        }

        do {
            try await executor.executeMacro(
                macro: macro,
                parameters: [:],
                parent: applicationName,
                applicationGeneration: generation,
                timeout: 1,
            )
            XCTFail("Expected retired generation to fail at the condition boundary")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "Application not found or process identity is stale")
        }
        let mutationCount = await coordinator.activeMutationCount()
        let identityCount = await stateStore.activeInputIdentityCount()
        XCTAssertEqual(mutationCount, 0)
        XCTAssertEqual(identityCount, 0)
    }

    func testNegativeLoopCountAndWaitDurationFailWithoutTrapping() async throws {
        let executor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(),
        )

        do {
            try await executor.executeMacro(
                macro: makeNestedLoopMacro(count: -1),
                parameters: [:],
                parent: "",
                timeout: 1,
            )
            XCTFail("Expected negative loop count rejection")
        } catch let error as MacroExecutionError {
            XCTAssertEqual(error.description, "Invalid action: Loop count must be non-negative")
        }

        let invalidWait = Exactmac_V1_Macro.with {
            $0.name = "macros/invalid-wait"
            $0.actions = [
                Exactmac_V1_MacroAction.with {
                    $0.wait = Exactmac_V1_WaitAction.with {
                        $0.duration = -1
                    }
                },
            ]
        }
        do {
            try await executor.executeMacro(
                macro: invalidWait,
                parameters: [:],
                parent: "",
                timeout: 1,
            )
            XCTFail("Expected negative wait duration rejection")
        } catch let error as MacroExecutionError {
            XCTAssertEqual(
                error.description,
                "Invalid action: Wait duration must be finite and non-negative",
            )
        }
    }

    // MARK: - MacroExecutionError Description Tests

    func testMacroExecutionError_macroNotFound_description() {
        let error = MacroExecutionError.macroNotFound("TestMacro")
        XCTAssertEqual(error.description, "Macro not found: TestMacro")
    }

    func testMacroExecutionError_invalidAction_description() {
        let error = MacroExecutionError.invalidAction("Missing parameter")
        XCTAssertEqual(error.description, "Invalid action: Missing parameter")
    }

    func testMacroExecutionError_conditionFailed_description() {
        let error = MacroExecutionError.conditionFailed("Element not visible")
        XCTAssertEqual(error.description, "Condition failed: Element not visible")
    }

    func testMacroExecutionError_variableNotFound_description() {
        let error = MacroExecutionError.variableNotFound("myVar")
        XCTAssertEqual(error.description, "Variable not found: myVar")
    }

    func testMacroExecutionError_elementNotFound_description() {
        let error = MacroExecutionError.elementNotFound("role:Button")
        XCTAssertEqual(error.description, "Element not found: role:Button")
    }

    func testMacroExecutionError_executionFailed_description() {
        let error = MacroExecutionError.executionFailed("Click failed")
        XCTAssertEqual(error.description, "Execution failed: Click failed")
    }

    func testMacroExecutionError_timeout_description() {
        let error = MacroExecutionError.timeout
        XCTAssertEqual(error.description, "Macro execution timed out")
    }

    func testMacroExecutionError_allCasesHaveNonEmptyDescription() {
        let errors: [MacroExecutionError] = [
            .macroNotFound("test"),
            .invalidAction("test"),
            .conditionFailed("test"),
            .variableNotFound("test"),
            .elementNotFound("test"),
            .executionFailed("test"),
            .timeout,
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) has empty description")
        }
    }

    // MARK: - MacroContext Tests

    func testMacroContext_defaultInitialization() {
        let context = MacroContext()

        XCTAssertEqual(context.variables.count, 0)
        XCTAssertEqual(context.parameters.count, 0)
        XCTAssertEqual(context.parent, "")
        XCTAssertNil(context.pid)
    }

    func testMacroContext_initWithValues() {
        var context = MacroContext()
        context.variables = ["key1": "value1"]
        context.parameters = ["param1": "paramValue1"]
        context.parent = "applications/com.apple.Calculator"
        let identity = ApplicationProcessIdentity(
            pid: 1234,
            startTimeSeconds: 12,
            startTimeMicroseconds: 34,
            bundleIdentifier: "com.apple.Calculator",
            executablePath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator",
        )
        context.applicationGeneration = AppStateStore.ApplicationProcessGenerationLease(
            name: context.parent,
            pid: identity.pid,
            identity: identity,
        )

        XCTAssertEqual(context.variables["key1"], "value1")
        XCTAssertEqual(context.parameters["param1"], "paramValue1")
        XCTAssertEqual(context.parent, "applications/com.apple.Calculator")
        XCTAssertEqual(context.pid, 1234)
    }

    func testMacroContext_variablesMutable() {
        var context = MacroContext()

        context.variables["a"] = "1"
        context.variables["b"] = "2"

        XCTAssertEqual(context.variables.count, 2)
        XCTAssertEqual(context.variables["a"], "1")
        XCTAssertEqual(context.variables["b"], "2")

        context.variables["a"] = "updated"
        XCTAssertEqual(context.variables["a"], "updated")
    }

    func testMacroContext_parametersMutable() {
        var context = MacroContext()

        context.parameters["input"] = "hello"
        context.parameters["output"] = "world"

        XCTAssertEqual(context.parameters.count, 2)
    }

    // MARK: - MacroExecutionError Conformance Tests

    func testMacroExecutionError_conformsToError() {
        let error: Error = MacroExecutionError.timeout

        // Verify it can be caught as Error
        XCTAssertNotNil(error)
    }

    func testMacroExecutionError_conformsToCustomStringConvertible() {
        let error: CustomStringConvertible = MacroExecutionError.macroNotFound("Test")

        // String(describing:) uses description property
        let desc = String(describing: error)
        XCTAssertEqual(desc, "Macro not found: Test")
    }

    func testMacroExecutionError_canBeUsedInStringInterpolation() {
        let error = MacroExecutionError.executionFailed("Failed to click")
        let message = "Error occurred: \(error)"

        XCTAssertTrue(message.contains("Execution failed: Failed to click"))
    }

    func testMacroExecutionError_emptyStringHandledGracefully() {
        let error = MacroExecutionError.invalidAction("")

        // Empty message should still produce valid description
        XCTAssertEqual(error.description, "Invalid action: ")
    }

    func testMacroExecutionError_specialCharactersInMessage() {
        let error = MacroExecutionError.executionFailed("Failed: <button id=\"submit\">")

        XCTAssertTrue(error.description.contains("<button"))
        XCTAssertTrue(error.description.contains("submit"))
    }

    func testMacroExecutionError_unicodeInMessage() {
        let error = MacroExecutionError.macroNotFound("マクロ")

        XCTAssertTrue(error.description.contains("マクロ"))
    }
}

private struct MacroInputIntentEntry: Sendable {
    let action: ExactMac.InputAction
}

private actor MacroInputIntentRecorder {
    private var entries: [MacroInputIntentEntry] = []
    private var presentations: [InputOverlayPresentation] = []

    func record(action: ExactMac.InputAction) {
        entries.append(
            MacroInputIntentEntry(
                action: action,
            ),
        )
    }

    func record(presentation: InputOverlayPresentation) {
        presentations.append(presentation)
    }

    func snapshot() -> [MacroInputIntentEntry] {
        entries
    }

    func presentationSnapshot() -> [InputOverlayPresentation] {
        presentations
    }
}

private func makeNestedLoopMacro(count: Int32 = .max) -> Exactmac_V1_Macro {
    let assignment = Exactmac_V1_MacroAction.with {
        $0.assign = Exactmac_V1_AssignAction.with {
            $0.variable = "iteration"
            $0.literal = "active"
        }
    }
    return Exactmac_V1_Macro.with {
        $0.name = "macros/nested-cancellation"
        $0.actions = [
            Exactmac_V1_MacroAction.with {
                $0.loop = Exactmac_V1_LoopAction.with {
                    $0.count = count
                    $0.actions = [assignment]
                }
            },
        ]
    }
}

private actor MacroBoundaryRecorder {
    private var boundaries: Set<MacroExecutionBoundary> = []

    func record(_ boundary: MacroExecutionBoundary) {
        boundaries.insert(boundary)
    }

    func contains(_ boundary: MacroExecutionBoundary) -> Bool {
        boundaries.contains(boundary)
    }
}

private actor BlockingMacroBoundaryProbe {
    private let cancellationSignal = MacroCancellationSignal()
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func observe(_ boundary: MacroExecutionBoundary) async {
        guard boundary == .loopIteration else { return }
        await withTaskCancellationHandler {
            entered = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: { [cancellationSignal] in
            cancellationSignal.record()
        }
    }

    func waitUntilNestedLoopEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !entered {
            guard clock.now < deadline else {
                throw MacroExecutorProbeTimeout()
            }
            await Task.yield()
        }
    }

    func waitUntilCancellationObserved() async throws {
        try await cancellationSignal.waitUntilRecorded()
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class MacroCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false

    func record() {
        lock.lock()
        guard !recorded else {
            lock.unlock()
            return
        }
        recorded = true
        lock.unlock()
    }

    func waitUntilRecorded() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !isRecorded() {
            guard clock.now < deadline else {
                throw MacroExecutorProbeTimeout()
            }
            await Task.yield()
        }
    }

    private func isRecorded() -> Bool {
        lock.withLock { recorded }
    }
}

private struct MacroExecutorProbeTimeout: Error {}

private actor MacroDeadlineCommitProbe {
    private var recorded = false

    func record() {
        recorded = true
    }

    func waitUntilRecorded() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !recorded {
            guard clock.now < deadline else {
                throw MacroExecutorProbeTimeout()
            }
            await Task.yield()
        }
    }
}

private final class MacroDeadlineTrigger: @unchecked Sendable {
    private struct State {
        var fired = false
        var cancelled = false
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let result = lock.withLock { () -> Result<Void, any Error>? in
                    if state.fired {
                        return .success(())
                    }
                    if state.cancelled {
                        return .failure(CancellationError())
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func fire() {
        resolve(.success(()))
    }

    private func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Void, any Error>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard !state.fired, !state.cancelled else { return [] }
            switch result {
            case .success:
                state.fired = true
            case .failure:
                state.cancelled = true
            }
            defer { state.waiters.removeAll(keepingCapacity: false) }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
