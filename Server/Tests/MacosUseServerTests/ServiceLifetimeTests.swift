import CoreGraphics
import Foundation
import MacosUseProto
import MacosUseSDK
@testable import MacosUseServer
import Testing

@Suite(.serialized)
struct ServiceLifetimeTests {
    @Test
    func `composition owns one exact service lifetime graph`() {
        let composition = MacosUseServiceComposition()

        #expect(composition.serviceLifetime.stateStore === composition.stateStore)
        #expect(composition.serviceLifetime.operationStore === composition.operationStore)
        #expect(composition.serviceLifetime.observationManager === composition.observationManager)
        #expect(composition.serviceLifetime.sessionManager === composition.sessionManager)
        #expect(composition.serviceLifetime.scriptExecutor === composition.scriptExecutor)
        #expect(composition.serviceLifetime.macroExecutor === composition.macroExecutor)
        #expect(composition.serviceLifetime.captureWorkOwner === composition.captureWorkOwner)
        #expect(composition.serviceLifetime.elementRegistry === composition.elementRegistry)
        #expect(
            composition.serviceLifetime.automationCoordinator
                === composition.automationCoordinator,
        )
        #expect(
            composition.serviceLifetime.inputOverlayPresenter
                === composition.inputOverlayPresenter,
        )
        #expect(
            composition.serviceLifetime.physicalDesktopMutationGate
                === composition.automationCoordinator.mutationGate,
        )
    }

    @Test
    func `shutdown closes operation admission before advertising draining`() async throws {
        let admissionProbe = BlockingLifetimeOwnerProbe()
        let producerProbe = BlockingLifetimeOwnerProbe()
        let operationStore = OperationStore(
            beginDrainingObserver: { await admissionProbe.run() },
        )
        let composition = MacosUseServiceComposition(
            operationStore: operationStore,
            system: MockSystemOperations(),
        )
        _ = try await operationStore.createOperation(
            name: "operations/lifetime-linearization",
            execution: { await producerProbe.run() },
        )
        try await producerProbe.waitUntilEntered()

        let shutdown = Task { await composition.serviceLifetime.shutdown() }
        try await admissionProbe.waitUntilEntered()
        #expect(await composition.serviceLifetime.lifecycleState() == .accepting)
        do {
            _ = try await operationStore.createOperation(
                name: "operations/after-admission-close",
                execution: {},
            )
            Issue.record("Expected operation admission to be closed")
        } catch let error as OperationStoreError {
            #expect(error == .admissionClosed)
        }

        await admissionProbe.release()
        try await producerProbe.waitUntilCancellationObserved()
        #expect(await composition.serviceLifetime.lifecycleState() == .draining)

        await producerProbe.release()
        await shutdown.value
        #expect(await composition.serviceLifetime.lifecycleState() == .drained)
        #expect(await operationStore.executionTaskCount() == 0)
    }

    @Test
    func `shutdown starts every owner cancellation before joining resistant producers`() async throws {
        let operationProbe = BlockingLifetimeOwnerProbe()
        let stateStore = AppStateStore()
        let registryProbe = BlockingLifetimeOwnerProbe()
        let traversalProbe = BlockingLifetimeOwnerProbe()
        let inputProbe = BlockingLifetimeOwnerProbe()
        let overlayProbe = BlockingLifetimeOwnerProbe()
        let macroProbe = BlockingLifetimeOwnerProbe()
        let operationStore = OperationStore()
        let elementRegistry = ElementRegistry(cleanupOperation: { await registryProbe.run() })
        let mutationGate = PhysicalDesktopMutationGate()
        let automationCoordinator = AutomationCoordinator(
            mutationGate: mutationGate,
            elementRegistry: elementRegistry,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await inputProbe.run()
                try Task.checkCancellation()
                return committedInputExecutionReceipt(for: action, route: route)
            },
            accessibilityTraversalExecutor: { _, _ in
                await traversalProbe.run()
                return AccessibilityTraversalSnapshot(appName: "Injected app")
            },
        )
        let observationManager = ObservationManager(
            windowRegistry: WindowRegistry(),
            automationCoordinator: automationCoordinator,
        )
        let sessionManager = SessionManager()
        let scriptExecutor = ScriptExecutor(mutationGate: mutationGate)
        let inputOverlayPresenter = InputOverlayPresenter { _ in
            await overlayProbe.run()
            try Task.checkCancellation()
        }
        let macroExecutor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(
                stateStore: stateStore,
                automationCoordinator: automationCoordinator,
                inputOverlayPresenter: inputOverlayPresenter,
            ),
            automationCoordinator: automationCoordinator,
            executionBoundaryObserver: { boundary in
                if boundary == .loopIteration {
                    await macroProbe.run()
                }
            },
        )
        let captureWorkOwner = CaptureWorkOwner()
        let lifetime = ServiceLifetime(
            stateStore: stateStore,
            operationStore: operationStore,
            observationManager: observationManager,
            sessionManager: sessionManager,
            scriptExecutor: scriptExecutor,
            macroExecutor: macroExecutor,
            captureWorkOwner: captureWorkOwner,
            elementRegistry: elementRegistry,
            automationCoordinator: automationCoordinator,
            inputOverlayPresenter: inputOverlayPresenter,
            physicalDesktopMutationGate: mutationGate,
        )

        _ = try await operationStore.createOperation(
            name: "operations/service-lifetime",
            execution: { await operationProbe.run() },
        )
        try await elementRegistry.startCleanup()
        let traversal = Task {
            try await automationCoordinator.handleTraverse(
                pid: 8642,
                visibleOnly: false,
            )
        }
        let input = Task {
            _ = try await automationCoordinator.handlePhysicalMutation { context in
                try await context.executeInput(
                    .move(to: CGPoint(x: 100, y: 100)),
                    route: .session,
                )
            }
        }
        let overlayReservation = try await inputOverlayPresenter.reserve(
            InputOverlayPresentation(
                frame: CGRect(x: 10, y: 20, width: 64, height: 64),
                content: .circle,
                duration: 3600,
            ),
        )
        let overlay = Task {
            try await inputOverlayPresenter.present(overlayReservation)
        }
        let macro = Task {
            try await macroExecutor.executeMacro(
                macro: makeLifetimeNestedMacro(),
                parameters: [:],
                parent: "",
                timeout: 3600,
            )
        }
        try await operationProbe.waitUntilEntered()
        try await registryProbe.waitUntilEntered()
        try await traversalProbe.waitUntilEntered()
        try await inputProbe.waitUntilEntered()
        try await overlayProbe.waitUntilEntered()
        try await macroProbe.waitUntilEntered()

        let shutdown = Task { await lifetime.shutdown() }
        try await operationProbe.waitUntilCancellationObserved()
        try await registryProbe.waitUntilCancellationObserved()
        try await traversalProbe.waitUntilCancellationObserved()
        try await inputProbe.waitUntilCancellationObserved()
        try await overlayProbe.waitUntilCancellationObserved()
        try await macroProbe.waitUntilCancellationObserved()

        #expect(await lifetime.lifecycleState() == .draining)
        #expect(await operationStore.executionTaskCount() == 1)
        #expect(await elementRegistry.cleanupTaskCount() == 1)
        #expect(await automationCoordinator.activeTraversalCount() == 1)
        #expect(await automationCoordinator.activeMutationCount() == 1)
        #expect(await inputOverlayPresenter.activeReservationCount() == 1)
        #expect(await macroExecutor.activeExecutionCount() == 1)

        await operationProbe.release()
        #expect(await lifetime.lifecycleState() == .draining)

        await registryProbe.release()
        #expect(await lifetime.lifecycleState() == .draining)

        await traversalProbe.release()
        #expect(await lifetime.lifecycleState() == .draining)

        await inputProbe.release()
        #expect(await lifetime.lifecycleState() == .draining)

        await overlayProbe.release()
        #expect(await lifetime.lifecycleState() == .draining)

        await macroProbe.release()
        await shutdown.value
        do {
            _ = try await traversal.value
            Issue.record("Expected shutdown to cancel the active traversal")
        } catch is CancellationError {
            // Expected.
        }
        do {
            try await overlay.value
            Issue.record("Expected shutdown to cancel the active input overlay")
        } catch is CancellationError {
            // Expected.
        }
        do {
            try await input.value
            Issue.record("Expected shutdown to cancel the active input")
        } catch is CancellationError {
            // Expected.
        }
        do {
            try await macro.value
            Issue.record("Expected shutdown to cancel the nested macro")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await lifetime.lifecycleState() == .drained)
        #expect(await operationStore.executionTaskCount() == 0)
        #expect(await elementRegistry.cleanupTaskCount() == 0)
        #expect(await automationCoordinator.activeTraversalCount() == 0)
        #expect(await automationCoordinator.activeMutationCount() == 0)
        #expect(await inputOverlayPresenter.activeReservationCount() == 0)
        #expect(await inputOverlayPresenter.lifecycleState() == .drained)
        #expect(await macroExecutor.activeExecutionCount() == 0)
        #expect(await mutationGate.lifecycleState() == .drained)

        await lifetime.shutdown()
        #expect(await lifetime.lifecycleState() == .drained)
    }
}

private func makeLifetimeNestedMacro() -> Macosusesdk_V1_Macro {
    let assignment = Macosusesdk_V1_MacroAction.with {
        $0.assign = Macosusesdk_V1_AssignAction.with {
            $0.variable = "iteration"
            $0.literal = "active"
        }
    }
    return Macosusesdk_V1_Macro.with {
        $0.name = "macros/service-lifetime"
        $0.actions = [
            Macosusesdk_V1_MacroAction.with {
                $0.loop = Macosusesdk_V1_LoopAction.with {
                    $0.count = .max
                    $0.actions = [assignment]
                }
            },
        ]
    }
}

private actor BlockingLifetimeOwnerProbe {
    private let cancellationSignal = LifetimeCancellationSignal()
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        await withTaskCancellationHandler {
            entered = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: { [cancellationSignal] in
            cancellationSignal.record()
        }
    }

    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !entered {
            guard clock.now < deadline else {
                throw LifetimeProbeTimeout()
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

private final class LifetimeCancellationSignal: @unchecked Sendable {
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
                throw LifetimeProbeTimeout()
            }
            await Task.yield()
        }
    }

    private func isRecorded() -> Bool {
        lock.withLock { recorded }
    }
}

private struct LifetimeProbeTimeout: Error {}
