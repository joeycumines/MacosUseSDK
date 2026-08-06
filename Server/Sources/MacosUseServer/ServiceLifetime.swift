import Foundation

enum ServiceLifetimeState: Sendable {
    case accepting
    case draining
    case drained
}

/// Owns the service-level producers that must stop before process cleanup.
///
/// Transport shutdown and this drain run concurrently: the transport rejects
/// new RPCs while these exact composition-owned stores finish streams, cancel
/// producer tasks, and wait for physical work admitted before the signal.
actor ServiceLifetime {
    nonisolated let stateStore: AppStateStore
    nonisolated let operationStore: OperationStore
    nonisolated let observationManager: ObservationManager
    nonisolated let sessionManager: SessionManager
    nonisolated let scriptExecutor: ScriptExecutor
    nonisolated let macroExecutor: MacroExecutor
    nonisolated let captureWorkOwner: CaptureWorkOwner
    nonisolated let elementRegistry: ElementRegistry
    nonisolated let automationCoordinator: AutomationCoordinator
    nonisolated let inputOverlayPresenter: InputOverlayPresenter
    nonisolated let physicalDesktopMutationGate: PhysicalDesktopMutationGate

    private var state = ServiceLifetimeState.accepting
    private var operationAdmissionTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    init(
        stateStore: AppStateStore,
        operationStore: OperationStore,
        observationManager: ObservationManager,
        sessionManager: SessionManager,
        scriptExecutor: ScriptExecutor,
        macroExecutor: MacroExecutor,
        captureWorkOwner: CaptureWorkOwner,
        elementRegistry: ElementRegistry,
        automationCoordinator: AutomationCoordinator,
        inputOverlayPresenter: InputOverlayPresenter,
        physicalDesktopMutationGate: PhysicalDesktopMutationGate,
    ) {
        self.stateStore = stateStore
        self.operationStore = operationStore
        self.observationManager = observationManager
        self.sessionManager = sessionManager
        self.scriptExecutor = scriptExecutor
        self.macroExecutor = macroExecutor
        self.captureWorkOwner = captureWorkOwner
        self.elementRegistry = elementRegistry
        self.automationCoordinator = automationCoordinator
        self.inputOverlayPresenter = inputOverlayPresenter
        self.physicalDesktopMutationGate = physicalDesktopMutationGate
    }

    func lifecycleState() -> ServiceLifetimeState {
        state
    }

    /// Closes producer admission and joins all currently composition-owned
    /// service work. Concurrent and repeated callers await the same drain.
    func shutdown() async {
        let task: Task<Void, Never>
        if let shutdownTask {
            task = shutdownTask
        } else {
            let admissionTask: Task<Void, Never>
            if let operationAdmissionTask {
                admissionTask = operationAdmissionTask
            } else {
                admissionTask = Task { [operationStore] in
                    await operationStore.beginDraining()
                }
                operationAdmissionTask = admissionTask
            }
            task = Task {
                await admissionTask.value
                self.markDraining()
                await Self.drainOwnedWork(
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
                    physicalDesktopMutationGate: physicalDesktopMutationGate,
                )
                self.markDrained()
            }
            shutdownTask = task
        }

        await task.value
    }

    private func markDraining() {
        if state == .accepting {
            state = .draining
        }
    }

    private func markDrained() {
        state = .drained
    }

    private nonisolated static func drainOwnedWork(
        stateStore: AppStateStore,
        operationStore: OperationStore,
        observationManager: ObservationManager,
        sessionManager: SessionManager,
        scriptExecutor: ScriptExecutor,
        macroExecutor: MacroExecutor,
        captureWorkOwner: CaptureWorkOwner,
        elementRegistry: ElementRegistry,
        automationCoordinator: AutomationCoordinator,
        inputOverlayPresenter: InputOverlayPresenter,
        physicalDesktopMutationGate: PhysicalDesktopMutationGate,
    ) async {
        // Close these independent front doors before awaiting any producer.
        await stateStore.beginInputDraining()
        await scriptExecutor.beginDraining()
        await macroExecutor.beginDraining()
        await captureWorkOwner.beginDraining()
        await inputOverlayPresenter.beginDraining()
        await automationCoordinator.beginMutationDraining()
        await automationCoordinator.beginTraversalDraining()
        await physicalDesktopMutationGate.beginDraining()

        // Each owner closes its own remaining admission before its first
        // suspension. Run them together so one resistant producer cannot keep
        // another owner accepting new work during shutdown.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [observationManager] in
                _ = await observationManager.cancelAllObservations()
            }
            group.addTask { [sessionManager] in
                _ = await sessionManager.invalidateAllSessions()
            }
            group.addTask { [scriptExecutor] in
                await scriptExecutor.shutdown()
            }
            group.addTask { [macroExecutor] in
                await macroExecutor.shutdown()
            }
            group.addTask { [captureWorkOwner] in
                await captureWorkOwner.shutdown()
            }
            group.addTask { [operationStore] in
                _ = await operationStore.drainAllOperations()
            }
            group.addTask { [elementRegistry] in
                await elementRegistry.shutdown()
            }
            group.addTask { [automationCoordinator] in
                await automationCoordinator.shutdownMutations()
            }
            group.addTask { [inputOverlayPresenter] in
                await inputOverlayPresenter.shutdown()
            }
            group.addTask { [automationCoordinator] in
                await automationCoordinator.shutdownTraversals()
            }
            group.addTask { [physicalDesktopMutationGate] in
                await physicalDesktopMutationGate.waitUntilDrained()
            }
            await group.waitForAll()
        }
    }
}
