import Foundation

/// Constructs the core production service graph from one system-operations
/// boundary. The installed executable uses the default production adapter;
/// tests may supply a non-posting implementation while exercising the same
/// service and operation providers.
struct ExactMacServiceComposition {
    let stateStore: AppStateStore
    let applicationCatalogProvider: any ApplicationCatalogProvider
    let operationStore: OperationStore
    let windowRegistry: WindowRegistry
    let system: SystemOperations
    let displayTopologyProvider: any DisplayTopologyProviding
    let screenshotCapture: any ScreenshotCapturing
    let captureWorkOwner: CaptureWorkOwner
    let elementRegistry: ElementRegistry
    let elementLocator: ElementLocator
    let automationCoordinator: AutomationCoordinator
    let inputOverlayPresenter: InputOverlayPresenter
    let inputTransactionExecutor: InputTransactionExecutor
    let observationManager: ObservationManager
    let macroExecutor: MacroExecutor
    let sessionManager: SessionManager
    let scriptExecutor: ScriptExecutor
    let clipboardHistoryManager: ClipboardHistoryManager
    let clipboardManager: ClipboardManager
    let serviceLifetime: ServiceLifetime
    let exactMacService: ExactMacService
    let operationsProvider: OperationsProvider
    /// The composition-owned macro registry. Exposed so tests can assert against
    /// the exact registry the service mutates (defect C5), rather than a
    /// standalone instance whose state the service never touches.
    let macroRegistry: MacroRegistry

    init(
        stateStore: AppStateStore = AppStateStore(),
        operationStore: OperationStore = OperationStore(),
        system: SystemOperations = ProductionSystemOperations.shared,
        applicationCatalogProvider: any ApplicationCatalogProvider = ProductionApplicationCatalogProvider(),
        legacyPIDResourceNamesForTests: Bool = false,
        automationCoordinator: AutomationCoordinator? = nil,
        inputOverlayPresenter: InputOverlayPresenter = InputOverlayPresenter(),
        sessionManager: SessionManager = SessionManager(),
        clipboardPasteboard: any ClipboardPasteboard = SystemClipboardPasteboard(),
        displayTopologyProvider: any DisplayTopologyProviding = ProductionDisplayTopologyProvider(),
        screenshotCapture: any ScreenshotCapturing = ProductionScreenshotCapturer(),
        captureWorkOwner: CaptureWorkOwner = CaptureWorkOwner(),
        windowMutationConvergencePolicy: WindowMutationConvergencePolicy = .production,
        macroRegistry: MacroRegistry = MacroRegistry(),
        macroDeadlineWaiter: @escaping MacroDeadlineWaiter = {
            try await ContinuousClock().sleep(until: $0)
        },
    ) {
        let windowRegistry = WindowRegistry(system: system)
        let elementRegistry = automationCoordinator?.elementRegistry ?? ElementRegistry()
        let automationCoordinator = automationCoordinator ?? AutomationCoordinator(
            elementRegistry: elementRegistry,
            activationSystem: system,
        )
        let elementLocator = ElementLocator(
            elementRegistry: elementRegistry,
            stateStore: stateStore,
            windowRegistry: windowRegistry,
            legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            system: system,
            automationCoordinator: automationCoordinator,
        )
        let observationManager = ObservationManager(
            windowRegistry: windowRegistry,
            system: system,
            automationCoordinator: automationCoordinator,
        )
        let scriptExecutor = ScriptExecutor(
            mutationGate: automationCoordinator.mutationGate,
        )
        let clipboardHistoryManager = ClipboardHistoryManager()
        let clipboardManager = ClipboardManager(
            mutationGate: automationCoordinator.mutationGate,
            historyManager: clipboardHistoryManager,
            pasteboard: clipboardPasteboard,
        )
        let exactMacService = ExactMacService(
            stateStore: stateStore,
            operationStore: operationStore,
            windowRegistry: windowRegistry,
            applicationCatalogProvider: applicationCatalogProvider,
            legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            system: system,
            displayTopologyProvider: displayTopologyProvider,
            screenshotCapture: screenshotCapture,
            captureWorkOwner: captureWorkOwner,
            automationCoordinator: automationCoordinator,
            inputOverlayPresenter: inputOverlayPresenter,
            elementLocator: elementLocator,
            observationManager: observationManager,
            macroRegistry: macroRegistry,
            macroDeadlineWaiter: macroDeadlineWaiter,
            sessionManager: sessionManager,
            scriptExecutor: scriptExecutor,
            clipboardHistoryManager: clipboardHistoryManager,
            clipboardManager: clipboardManager,
            windowMutationConvergencePolicy: windowMutationConvergencePolicy,
        )
        let inputTransactionExecutor = exactMacService.inputTransactionExecutor
        let macroExecutor = exactMacService.macroExecutor
        let serviceLifetime = ServiceLifetime(
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
            physicalDesktopMutationGate: automationCoordinator.mutationGate,
        )

        self.stateStore = stateStore
        self.applicationCatalogProvider = applicationCatalogProvider
        self.operationStore = operationStore
        self.windowRegistry = windowRegistry
        self.system = system
        self.displayTopologyProvider = displayTopologyProvider
        self.screenshotCapture = screenshotCapture
        self.captureWorkOwner = captureWorkOwner
        self.elementRegistry = elementRegistry
        self.elementLocator = elementLocator
        self.automationCoordinator = automationCoordinator
        self.inputOverlayPresenter = inputOverlayPresenter
        self.inputTransactionExecutor = inputTransactionExecutor
        self.observationManager = observationManager
        self.macroExecutor = macroExecutor
        self.sessionManager = sessionManager
        self.scriptExecutor = scriptExecutor
        self.clipboardHistoryManager = clipboardHistoryManager
        self.clipboardManager = clipboardManager
        self.serviceLifetime = serviceLifetime
        self.exactMacService = exactMacService
        self.macroRegistry = macroRegistry
        operationsProvider = OperationsProvider(operationStore: operationStore)
    }

    /// Hydrates the composition-owned macro registry from durable storage.
    ///
    /// Call once during server startup, before serving requests, so previously
    /// created macros survive a restart (defect C2). A missing file is not an
    /// error: the registry starts empty. Corrupt or unreadable storage is logged
    /// and swallowed so a bad persisted file never prevents server startup; the
    /// registry remains empty and durable writes resume on the next mutation.
    func loadPersistedMacros() async {
        do {
            try await macroRegistry.load()
        } catch {
            // Logged inside MacroRegistry.load() (where the private persistence
            // path is known) at every throw path; the composition must not abort
            // server startup over an unreadable or corrupt macro file.
        }
    }
}
