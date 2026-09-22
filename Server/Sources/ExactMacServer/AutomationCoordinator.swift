import AppKit
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

private let logger = ExactMac.sdkLogger(category: "AutomationCoordinator")
private let unscopedInputExecutionBoundary = ExactMac.InputExecutionBoundary(
    validateEffect: { _ in },
    validateProcessRoute: { _ in },
)

typealias InputActionExecutor = @MainActor @Sendable (
    ExactMac.InputAction,
    ExactMac.InputDeliveryRoute,
    ExactMac.InputExecutionBoundary,
) async throws -> ExactMac.InputExecutionReceipt

typealias InputPostAccessChecker = @Sendable () -> Bool
typealias InputKeyResolver = @Sendable (String) -> ExactMac.ResolvedInputKey?
typealias KeyboardInputSourceIdentityProvider =
    @Sendable () -> ExactMac.KeyboardInputSourceIdentity?

typealias ApplicationOpenExecutor = @MainActor @Sendable (
    URL,
    Bool,
    ExactMac.AppLaunchMode,
) async throws -> ExactMac.AppOpenerResult

struct AccessibilityTraversalSnapshot: Sendable {
    let appName: String
    let elements: [ExactMac.ElementData]
    let count: Int
    let excludedCount: Int
    let excludedNonInteractable: Int
    let excludedNoText: Int
    let textElementsCount: Int
    let nonTextElementsCount: Int
    let visibleElementsCount: Int
    let roleCounts: [String: Int]

    init(
        appName: String,
        elements: [ExactMac.ElementData] = [],
        count: Int = 0,
        excludedCount: Int = 0,
        excludedNonInteractable: Int = 0,
        excludedNoText: Int = 0,
        textElementsCount: Int = 0,
        nonTextElementsCount: Int = 0,
        visibleElementsCount: Int = 0,
        roleCounts: [String: Int] = [:],
    ) {
        self.appName = appName
        self.elements = elements
        self.count = count
        self.excludedCount = excludedCount
        self.excludedNonInteractable = excludedNonInteractable
        self.excludedNoText = excludedNoText
        self.textElementsCount = textElementsCount
        self.nonTextElementsCount = nonTextElementsCount
        self.visibleElementsCount = visibleElementsCount
        self.roleCounts = roleCounts
    }

    init(_ response: ExactMac.ResponseData) {
        self.init(
            appName: response.app_name,
            elements: response.elements,
            count: response.stats.count,
            excludedCount: response.stats.excluded_count,
            excludedNonInteractable: response.stats.excluded_non_interactable,
            excludedNoText: response.stats.excluded_no_text,
            textElementsCount: response.stats.with_text_count,
            nonTextElementsCount: response.stats.without_text_count,
            visibleElementsCount: response.stats.visible_elements_count,
            roleCounts: response.stats.role_counts,
        )
    }
}

typealias AccessibilityTraversalExecutor = @Sendable (
    pid_t,
    Bool,
) async throws -> AccessibilityTraversalSnapshot

private struct OwnedCoordinatedMutation: Sendable {
    let cancel: @Sendable () -> Void
    let join: @Sendable () async -> Void
}

private actor CoordinatedMutationStartGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct OwnedTraversalStream: Sendable {
    let cancel: @Sendable () -> Void
    let join: @Sendable () async -> Void
}

private struct OwnedTraversalWork: Sendable {
    let cancel: @Sendable () -> Void
    let join: @Sendable () async -> Void
}

/// Capabilities available only while the caller owns the physical-desktop
/// mutation gate. Keeping element resolution and every AX/input sink behind
/// this value prevents callers from accidentally splitting one mutation across
/// multiple independently scheduled gate leases.
struct PhysicalDesktopMutationContext: Sendable {
    let system: SystemOperations
    private let elementRegistry: ElementRegistry
    private let inputPostAccessChecker: InputPostAccessChecker
    private let inputActionExecutor: InputActionExecutor?

    init(
        system: SystemOperations,
        elementRegistry: ElementRegistry,
        inputPostAccessChecker: @escaping InputPostAccessChecker,
        inputActionExecutor: InputActionExecutor?,
    ) {
        self.system = system
        self.elementRegistry = elementRegistry
        self.inputPostAccessChecker = inputPostAccessChecker
        self.inputActionExecutor = inputActionExecutor
    }

    @MainActor
    func resolveElement(
        id: String,
        expectedPID: pid_t,
        expectedScope: String,
    ) async throws -> RegisteredElementMutationTarget {
        do {
            return try await elementRegistry.resolveElementForMutation(
                id,
                expectedPID: expectedPID,
                expectedScope: expectedScope,
            )
        } catch let error as ElementMutationResolutionError {
            switch error {
            case .admissionClosed:
                throw RPCError(
                    code: .unavailable,
                    message: "Element registry admission is closed",
                )
            case .notFound:
                throw RPCError(code: .notFound, message: "Element not found")
            case let .ownerMismatch(expectedPID, actualPID):
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element belongs to PID \(actualPID), not request PID \(expectedPID)",
                )
            case let .scopeMismatch(expected, actual):
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element belongs to scope \(actual), not request scope \(expected)",
                )
            }
        }
    }

    @MainActor
    func activateTarget(pid: pid_t) async throws {
        try await AutomationCoordinator.activateTargetApplication(
            pid: pid,
            system: system,
        )
    }

    /// Focuses the exact registered element's containing AX window and waits
    /// for Accessibility readback convergence. No WindowServer or AppKit
    /// liveness pre-check is used because those views may lag AX state.
    @MainActor
    func focusElementWindow(
        target: RegisteredElementMutationTarget,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(25),
    ) async throws {
        guard var currentElement = target.axElement else {
            throw RPCError(code: .notFound, message: "Element reference not available")
        }

        var windowElement: AXUIElement?
        for _ in 0 ... 20 {
            try Task.checkCancellation()
            if system.copyAXAttribute(
                element: currentElement as AnyObject,
                attribute: kAXRoleAttribute as String,
            ) as? String == kAXWindowRole as String {
                windowElement = currentElement
                break
            }

            guard let parent = system.copyAXAttribute(
                element: currentElement as AnyObject,
                attribute: kAXParentAttribute as String,
            ) as AnyObject? else {
                break
            }
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element parent chain contains a non-AX element",
                )
            }
            currentElement = unsafeDowncast(parent, to: AXUIElement.self)
        }

        guard let windowElement else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Element is not attached to an AX window",
            )
        }

        let windowIsFocused = {
            self.system.copyAXAttribute(
                element: windowElement as AnyObject,
                attribute: kAXMainAttribute as String,
            ) as? Bool == true || self.system.copyAXAttribute(
                element: windowElement as AnyObject,
                attribute: kAXFocusedAttribute as String,
            ) as? Bool == true
        }
        if windowIsFocused() {
            return
        }

        let setMainResult = system.setAXAttribute(
            element: windowElement as AnyObject,
            attribute: kAXMainAttribute as String,
            value: true,
        )
        let setFocusedResult = system.setAXAttribute(
            element: windowElement as AnyObject,
            attribute: kAXFocusedAttribute as String,
            value: true,
        )
        guard setMainResult == AXError.success.rawValue ||
            setFocusedResult == AXError.success.rawValue
        else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Unable to focus element window: AXMainError=\(setMainResult), AXFocusedError=\(setFocusedResult)",
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if windowIsFocused() {
                return
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for element window focus",
                )
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    @MainActor
    func executeInput(
        _ action: ExactMac.InputAction,
        route: ExactMac.InputDeliveryRoute,
        executionBoundary: ExactMac.InputExecutionBoundary =
            unscopedInputExecutionBoundary,
        accessPreflighted: Bool = false,
        backendOperation: (@MainActor @Sendable (any ExactMac.InputEventBackend) async throws -> Void)? = nil,
    ) async throws -> ExactMac.InputExecutionReceipt {
        if !accessPreflighted {
            try Self.requireInputPostAccess(using: inputPostAccessChecker)
        }
        let receipt: ExactMac.InputExecutionReceipt = if let inputActionExecutor {
            try await inputActionExecutor(
                action,
                route,
                executionBoundary,
            )
        } else {
            try await AutomationCoordinator.executeInputAction(
                action,
                route: route,
                executionBoundary: executionBoundary,
                backendOperation: backendOperation,
            )
        }
        let expectedPostedEventCount = action.expectedPostedEventCount
        guard expectedPostedEventCount > 0,
              receipt.route == route,
              receipt.postedEventCount == expectedPostedEventCount,
              receipt.routedDeliveryObserved
        else {
            let conservativePostedEventCount = max(
                receipt.routedDeliveryObserved ? 1 : 0,
                max(0, receipt.postedEventCount),
            )
            throw ExactMac.InputExecutionFailure(
                underlying: RPCError(
                    code: .internalError,
                    message: "Input executor returned an incomplete or malformed delivery receipt",
                ),
                route: receipt.route,
                postedEventCount: conservativePostedEventCount,
                routedDeliveryObserved: receipt.route == route
                    && receipt.routedDeliveryObserved,
                physicalEffectOccurred: true,
            )
        }
        return receipt
    }

    private static func requireInputPostAccess(
        using checker: InputPostAccessChecker,
    ) throws {
        guard checker() else {
            throw RPCError(
                code: .permissionDenied,
                message: "Input event posting permission is not granted",
            )
        }
    }
}

/// Gives one already-registered transaction access to the shared physical
/// mutation gate without creating a second owner. This lets the transaction
/// reserve public state before queueing while keeping terminal persistence
/// inside the exact task that service drain joins.
struct OwnedPhysicalMutationRunner: Sendable {
    private let mutationGate: PhysicalDesktopMutationGate
    private let elementRegistry: ElementRegistry
    private let inputPostAccessChecker: InputPostAccessChecker
    private nonisolated let inputActionExecutor: InputActionExecutor?

    init(
        mutationGate: PhysicalDesktopMutationGate,
        elementRegistry: ElementRegistry,
        inputPostAccessChecker: @escaping InputPostAccessChecker,
        inputActionExecutor: InputActionExecutor?,
    ) {
        self.mutationGate = mutationGate
        self.elementRegistry = elementRegistry
        self.inputPostAccessChecker = inputPostAccessChecker
        self.inputActionExecutor = inputActionExecutor
    }

    @MainActor
    func run<Result: Sendable>(
        authoritySystem: SystemOperations,
        _ operation: @escaping @MainActor @Sendable (
            PhysicalDesktopMutationContext,
        ) async throws -> Result,
    ) async throws -> Result {
        try await mutationGate.withExclusiveOperation {
            let context = PhysicalDesktopMutationContext(
                system: authoritySystem,
                elementRegistry: elementRegistry,
                inputPostAccessChecker: inputPostAccessChecker,
                inputActionExecutor: inputActionExecutor,
            )
            return try await operation(context)
        }
    }

    /// Same exclusive gate as run, but threads the mutation-owner UUID into the
    /// operation so callers that reserve durable Input identities (C6) bind them
    /// to the exact owner the mutation gate tracks.
    @MainActor
    func runWithOwner<Result: Sendable>(
        authoritySystem: SystemOperations,
        ownerID: UUID,
        _ operation: @escaping @MainActor @Sendable (
            PhysicalDesktopMutationContext,
            UUID,
        ) async throws -> Result,
    ) async throws -> Result {
        try await mutationGate.withExclusiveOperation {
            let context = PhysicalDesktopMutationContext(
                system: authoritySystem,
                elementRegistry: elementRegistry,
                inputPostAccessChecker: inputPostAccessChecker,
                inputActionExecutor: inputActionExecutor,
            )
            return try await operation(context, ownerID)
        }
    }
}

/// Actor that coordinates all SDK interactions on the main thread.
/// This is critical because the ExactMac requires main thread execution
/// for all UI-related operations.
public actor AutomationCoordinator {
    nonisolated let mutationGate: PhysicalDesktopMutationGate
    nonisolated let elementRegistry: ElementRegistry
    private let activationSystem: SystemOperations
    private nonisolated let inputPostAccessChecker: InputPostAccessChecker
    private nonisolated let inputKeyResolver: InputKeyResolver
    private nonisolated let keyboardInputSourceIdentityProvider: KeyboardInputSourceIdentityProvider
    private let inputActionExecutor: InputActionExecutor?
    private let applicationOpenExecutor: ApplicationOpenExecutor?
    private let accessibilityTraversalExecutor: AccessibilityTraversalExecutor?
    private var acceptingMutations = true
    private var mutationTasks: [UUID: OwnedCoordinatedMutation] = [:]
    private var acceptingTraversals = true
    private var traversalTasks: [UUID: OwnedTraversalWork] = [:]
    private var traversalStreamTasks: [UUID: OwnedTraversalStream] = [:]

    init(
        mutationGate: PhysicalDesktopMutationGate = PhysicalDesktopMutationGate(),
        elementRegistry: ElementRegistry = ElementRegistry(),
        activationSystem: SystemOperations = ProductionSystemOperations.shared,
        inputKeyResolver: @escaping InputKeyResolver = ExactMac.resolveInputKey,
        keyboardInputSourceIdentityProvider: @escaping KeyboardInputSourceIdentityProvider =
            ExactMac.currentKeyboardInputSourceIdentity,
        inputPostAccessChecker: @escaping InputPostAccessChecker = {
            CGPreflightPostEventAccess()
        },
        inputActionExecutor: InputActionExecutor? = nil,
        applicationOpenExecutor: ApplicationOpenExecutor? = nil,
        accessibilityTraversalExecutor: AccessibilityTraversalExecutor? = nil,
    ) {
        self.mutationGate = mutationGate
        self.elementRegistry = elementRegistry
        self.activationSystem = activationSystem
        self.inputKeyResolver = inputKeyResolver
        self.keyboardInputSourceIdentityProvider = keyboardInputSourceIdentityProvider
        self.inputPostAccessChecker = inputPostAccessChecker
        self.inputActionExecutor = inputActionExecutor
        self.applicationOpenExecutor = applicationOpenExecutor
        self.accessibilityTraversalExecutor = accessibilityTraversalExecutor
        logger.info("Initialized")
    }

    nonisolated var usesInjectedInputActionExecutor: Bool {
        inputActionExecutor != nil
    }

    /// Opens one exact application bundle and returns the observed result.
    /// - Parameter applicationURL: Exact canonical bundle file URL.
    /// - Parameter background: If true, opens without activating (stealing focus)
    /// - Parameter mode: Controls how the application is launched (launchOrActivate, forceNewInstance, activateOnly)
    @MainActor
    public func handleOpenApplication(
        applicationURL: URL,
        background: Bool = false,
        mode: ExactMac.AppLaunchMode = .launchOrActivate,
    ) async throws -> ExactMac.AppOpenerResult {
        logger.info("Opening exact application bundle: \(applicationURL.path, privacy: .private(mask: .hash)) background=\(background, privacy: .public) mode=\(mode.rawValue, privacy: .public)")

        if let applicationOpenExecutor {
            return try await applicationOpenExecutor(applicationURL, background, mode)
        } else {
            return try await ExactMac.openApplication(
                applicationURL: applicationURL,
                background: background,
                mode: mode,
            )
        }
    }

    nonisolated func validateInputAction(_ action: Exactmac_V1_InputAction) throws
        -> ValidatedInputAction
    {
        try InputActionAdmission.validate(
            protoAction: action,
            sdkAction: convertFromProtoInputAction(action),
        )
    }

    nonisolated func admitInputAction(
        _ validatedAction: ValidatedInputAction,
    ) throws -> PreparedInputAction {
        let executionAction: ExactMac.InputAction
        let sourceIdentity: ExactMac.KeyboardInputSourceIdentity?
        let textPasteKeyCode: CGKeyCode?
        switch validatedAction.action {
        case let .press(keyName, flags):
            guard let resolved = inputKeyResolver(keyName) else {
                throw CoordinatorError.invalidKeyName(keyName)
            }
            guard ExactMac.layoutIndependentKeyCode(for: keyName) != nil
                || resolved.sourceIdentity != nil
            else {
                throw CoordinatorError.invalidKeyCombo(
                    "layout-dependent key resolution requires an exact input-source fingerprint",
                )
            }
            executionAction = .pressKeyCode(
                keyCode: resolved.keyCode,
                flags: flags,
            )
            sourceIdentity = resolved.sourceIdentity
            textPasteKeyCode = nil
        case let .pressHold(keyName, flags, duration):
            guard let resolved = inputKeyResolver(keyName) else {
                throw CoordinatorError.invalidKeyName(keyName)
            }
            guard ExactMac.layoutIndependentKeyCode(for: keyName) != nil
                || resolved.sourceIdentity != nil
            else {
                throw CoordinatorError.invalidKeyCombo(
                    "layout-dependent key resolution requires an exact input-source fingerprint",
                )
            }
            executionAction = .pressKeyCodeHold(
                keyCode: resolved.keyCode,
                flags: flags,
                duration: duration,
            )
            sourceIdentity = resolved.sourceIdentity
            textPasteKeyCode = nil
        case .type, .typeText:
            guard let resolved = inputKeyResolver("v"),
                  resolved.sourceIdentity != nil
            else {
                throw CoordinatorError.invalidKeyCombo(
                    "physical text input requires an exact current-layout paste key",
                )
            }
            executionAction = validatedAction.action
            sourceIdentity = resolved.sourceIdentity
            textPasteKeyCode = resolved.keyCode
        case .pressKeyCode, .pressKeyCodeHold:
            throw CoordinatorError.invalidKeyCombo(
                "resolved key actions are internal execution plans",
            )
        default:
            executionAction = validatedAction.action
            sourceIdentity = nil
            textPasteKeyCode = nil
        }
        guard inputPostAccessChecker() else {
            throw RPCError(
                code: .permissionDenied,
                message: "Input event posting permission is not granted",
            )
        }
        return PreparedInputAction(
            action: executionAction,
            showAnimation: validatedAction.showAnimation,
            animationDuration: validatedAction.animationDuration,
            keyboardSourceIdentity: sourceIdentity,
            textPasteKeyCode: textPasteKeyCode,
        )
    }

    nonisolated func revalidateInputAction(_ preparedAction: PreparedInputAction) throws {
        if let expected = preparedAction.keyboardSourceIdentity {
            guard keyboardInputSourceIdentityProvider() == expected else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Keyboard input source changed while input was queued",
                )
            }
        }
        guard inputPostAccessChecker() else {
            throw RPCError(
                code: .permissionDenied,
                message: "Input event posting permission is no longer granted",
            )
        }
    }

    /// Registers one complete mutation owner before its first suspension. The
    /// supplied transaction may reserve public state before acquiring the
    /// physical gate and must persist terminal state before returning.
    func withOwnedMutationTask<Result: Sendable>(
        cancellation: ServerContext.RPCCancellationHandle? = nil,
        onAdmissionClosed: (@Sendable () async -> RPCError)? = nil,
        _ transaction: @escaping @MainActor @Sendable (
            OwnedPhysicalMutationRunner,
            UUID,
        ) async throws -> Result,
    ) async throws -> Result {
        guard acceptingMutations else {
            if let onAdmissionClosed {
                throw await onAdmissionClosed()
            }
            throw RPCError(code: .unavailable, message: "Mutation admission is closed")
        }
        guard !Task.isCancelled, cancellation?.isCancelled != true else {
            throw CancellationError()
        }

        let runner = OwnedPhysicalMutationRunner(
            mutationGate: mutationGate,
            elementRegistry: elementRegistry,
            inputPostAccessChecker: inputPostAccessChecker,
            inputActionExecutor: inputActionExecutor,
        )
        let id = UUID()
        let startGate = CoordinatedMutationStartGate()
        let task = Task<Result, any Error> { @MainActor in
            await startGate.wait()
            try Task.checkCancellation()
            return try await transaction(runner, id)
        }
        let cancellationWatcher = cancellation.map { cancellation in
            Task<Void, Never> {
                do {
                    try await cancellation.cancelled
                    task.cancel()
                } catch {
                    // The supervisor cancels and joins this watcher after the
                    // exact transaction settles.
                }
            }
        }
        let supervisor = Task<Void, Never> {
            _ = try? await task.value
            cancellationWatcher?.cancel()
            if let cancellationWatcher {
                await cancellationWatcher.value
            }
            self.finishOwnedMutation(id: id)
        }
        mutationTasks[id] = OwnedCoordinatedMutation(
            cancel: { task.cancel() },
            join: { await supervisor.value },
        )

        do {
            let result = try await withTaskCancellationHandler {
                await startGate.open()
                if Task.isCancelled || cancellation?.isCancelled == true {
                    task.cancel()
                }
                return try await task.value
            } onCancel: {
                task.cancel()
            }
            await supervisor.value
            return result
        } catch {
            await supervisor.value
            throw error
        }
    }

    private func finishOwnedMutation(id: UUID) {
        mutationTasks.removeValue(forKey: id)
    }

    func handlePhysicalMutation<Result: Sendable>(
        _ operation: @escaping @MainActor @Sendable (
            PhysicalDesktopMutationContext,
        ) async throws -> Result,
    ) async throws -> Result {
        try await withOwnedMutationTask { runner, _ in
            try await runner.run(
                authoritySystem: self.activationSystem,
                operation,
            )
        }
    }

    /// Variant of handlePhysicalMutation that surfaces the exact mutation-owner
    /// UUID to the operation. Element methods that publish a real, retrievable
    /// Input resource (C6) need the ownerID so the reserved Input identity is
    /// bound to the same owner the mutation gate tracks for drain/cleanup.
    func handlePhysicalMutationWithOwner<Result: Sendable>(
        _ operation: @escaping @MainActor @Sendable (
            PhysicalDesktopMutationContext,
            UUID,
        ) async throws -> Result,
    ) async throws -> Result {
        try await withOwnedMutationTask { runner, ownerID in
            try await runner.runWithOwner(
                authoritySystem: self.activationSystem,
                ownerID: ownerID,
                operation,
            )
        }
    }

    func activeMutationCount() -> Int {
        mutationTasks.count
    }

    func beginMutationDraining() {
        guard acceptingMutations else { return }
        acceptingMutations = false
        for mutation in mutationTasks.values {
            mutation.cancel()
        }
    }

    func shutdownMutations() async {
        beginMutationDraining()
        let mutations = Array(mutationTasks.values)
        for mutation in mutations {
            await mutation.join()
        }
        mutationTasks.removeAll(keepingCapacity: false)
    }

    /// Brings an exact PID to the foreground through Accessibility and waits
    /// until AX reports convergence. This deliberately attempts AX directly:
    /// NSRunningApplication and WindowServer process views can lag the
    /// Accessibility server and are not safe liveness guards for input.
    @MainActor
    static func activateTargetApplication(
        pid: pid_t,
        system: SystemOperations,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(25),
    ) async throws {
        guard let application = system.createAXApplication(pid: pid) else {
            throw InputTargetActivationError.applicationUnavailable(pid: pid)
        }

        let setResult = system.setAXAttribute(
            element: application,
            attribute: kAXFrontmostAttribute as String,
            value: true,
        )
        guard setResult == AXError.success.rawValue else {
            throw InputTargetActivationError.setFrontmostFailed(
                pid: pid,
                axErrorCode: setResult,
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if let isFrontmost = system.copyAXAttribute(
                element: application,
                attribute: kAXFrontmostAttribute as String,
            ) as? Bool, isFrontmost {
                logger.info("AX frontmost converged for application PID \(pid, privacy: .public)")
                return
            }
            guard clock.now < deadline else {
                throw InputTargetActivationError.convergenceTimedOut(pid: pid)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Traverses the accessibility tree for a given PID
    /// - Parameters:
    ///   - pid: The process identifier to traverse.
    ///   - visibleOnly: When true, only geometrically visible elements are collected.
    ///   - shouldActivate: When true, the target app is activated (brought to foreground) before
    ///     traversal. Defaults to false so background polling (ObservationManager) never steals focus.
    public func handleTraverse(
        pid: pid_t,
        visibleOnly: Bool,
        shouldActivate: Bool = false,
        applicationName: String? = nil,
    ) async throws
        -> Exactmac_V1_TraverseAccessibilityResponse
    {
        logger.info("Traversing accessibility tree for PID \(pid, privacy: .public) (shouldActivate=\(shouldActivate, privacy: .public))")
        let executor = accessibilityTraversalExecutor
        let activationSystem = activationSystem
        let elementRegistry = elementRegistry
        let mutationGate = mutationGate
        do {
            return try await withOwnedTraversal {
                try await Self.executeTraversal(
                    pid: pid,
                    visibleOnly: visibleOnly,
                    shouldActivate: shouldActivate,
                    executor: executor,
                    activationSystem: activationSystem,
                    elementRegistry: elementRegistry,
                    mutationGate: mutationGate,
                    applicationName: applicationName,
                )
            }
        } catch {
            throw Self.mapTraversalError(error)
        }
    }

    func withOwnedTraversal<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result,
    ) async throws -> Result {
        guard acceptingTraversals else {
            throw RPCError(code: .unavailable, message: "Traversal admission is closed")
        }
        try Task.checkCancellation()

        let id = UUID()
        let task = Task { try await operation() }
        traversalTasks[id] = OwnedTraversalWork(
            cancel: { task.cancel() },
            join: { _ = try? await task.value },
        )

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            traversalTasks.removeValue(forKey: id)
            return result
        } catch {
            traversalTasks.removeValue(forKey: id)
            throw Self.mapTraversalError(error)
        }
    }

    func activeTraversalCount() -> Int {
        traversalTasks.count
    }

    func createTraversalStreamTask(
        operation: @escaping @Sendable () async throws -> Metadata,
    ) throws -> (id: UUID, task: Task<Metadata, any Error>) {
        guard acceptingTraversals else {
            throw RPCError(code: .unavailable, message: "Traversal admission is closed")
        }
        let id = UUID()
        let task = Task { try await operation() }
        traversalStreamTasks[id] = OwnedTraversalStream(
            cancel: { task.cancel() },
            join: { _ = try? await task.value },
        )
        return (id, task)
    }

    func finishTraversalStream(id: UUID) {
        traversalStreamTasks.removeValue(forKey: id)
    }

    func activeTraversalStreamCount() -> Int {
        traversalStreamTasks.count
    }

    func beginTraversalDraining() {
        guard acceptingTraversals else { return }
        acceptingTraversals = false
        for work in traversalTasks.values {
            work.cancel()
        }
        for stream in traversalStreamTasks.values {
            stream.cancel()
        }
    }

    func shutdownTraversals() async {
        beginTraversalDraining()
        let work = Array(traversalTasks.values)
        let streams = Array(traversalStreamTasks.values)
        for traversal in work {
            await traversal.join()
        }
        for stream in streams {
            await stream.join()
        }
        traversalTasks.removeAll(keepingCapacity: false)
        traversalStreamTasks.removeAll(keepingCapacity: false)
    }

    private nonisolated static func executeTraversal(
        pid: pid_t,
        visibleOnly: Bool,
        shouldActivate: Bool,
        executor: AccessibilityTraversalExecutor?,
        activationSystem: SystemOperations,
        elementRegistry: ElementRegistry,
        mutationGate: PhysicalDesktopMutationGate,
        applicationName: String?,
    ) async throws -> Exactmac_V1_TraverseAccessibilityResponse {
        let traversal: @Sendable () async throws -> Exactmac_V1_TraverseAccessibilityResponse = {
            let snapshot: AccessibilityTraversalSnapshot = if let executor {
                try await executor(pid, visibleOnly)
            } else {
                try await executeSDKTraversal(pid: pid, visibleOnly: visibleOnly)
            }
            try Task.checkCancellation()

            let elements = try await elementRegistry.registerTraversalElements(
                snapshot.elements,
                pid: pid,
                scope: applicationName,
                applicationName: applicationName,
            )
            try Task.checkCancellation()
            let statistics = Exactmac_Type_TraversalStats.with {
                $0.count = Int32(snapshot.count)
                $0.excludedCount = Int32(snapshot.excludedCount)
                $0.excludedNonInteractable = Int32(snapshot.excludedNonInteractable)
                $0.excludedNoText = Int32(snapshot.excludedNoText)
                $0.textElementsCount = Int32(snapshot.textElementsCount)
                $0.nonTextElementsCount = Int32(snapshot.nonTextElementsCount)
                $0.visibleElementsCount = Int32(snapshot.visibleElementsCount)
                $0.roleCounts = snapshot.roleCounts.mapValues(Int32.init)
            }

            return Exactmac_V1_TraverseAccessibilityResponse.with {
                $0.app = snapshot.appName
                $0.elements = elements
                $0.stats = statistics
                $0.processingTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            }
        }

        if shouldActivate {
            return try await mutationGate.withExclusiveOperation {
                try await activateTargetApplication(pid: pid, system: activationSystem)
                return try await traversal()
            }
        }
        return try await traversal()
    }

    private nonisolated static func executeSDKTraversal(
        pid: pid_t,
        visibleOnly: Bool,
    ) async throws -> AccessibilityTraversalSnapshot {
        let task = Task.detached(priority: .userInitiated) {
            try AccessibilityTraversalSnapshot(
                ExactMac.traverseAccessibilityTree(
                    pid: pid,
                    onlyVisibleElements: visibleOnly,
                    shouldActivate: false,
                ),
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func mapTraversalError(_ error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let rpcError = error as? RPCError {
            return rpcError
        }
        if let mutationError = error as? PhysicalDesktopMutationError {
            return switch mutationError {
            case .queueFull:
                RPCError(code: .resourceExhausted, message: mutationError.localizedDescription)
            case .admissionClosed:
                RPCError(code: .unavailable, message: mutationError.localizedDescription)
            }
        }
        if let registryError = error as? ElementRegistryError {
            return switch registryError {
            case .admissionClosed:
                RPCError(code: .unavailable, message: "Element registry admission is closed")
            case .applicationBindingMismatch:
                RPCError(code: .notFound, message: "Application process identity became stale during traversal")
            case .duplicateTraversalIdentity:
                RPCError(code: .failedPrecondition, message: "Traversal returned a duplicate element identity")
            case .identifierExhausted:
                RPCError(code: .resourceExhausted, message: "Element identifier allocation was exhausted")
            }
        }
        if let limitError = error as? AccessibilityTraversalLimitError {
            return switch limitError {
            case .depthExceeded, .nodeLimitExceeded:
                RPCError(code: .resourceExhausted, message: limitError.localizedDescription)
            case .deadlineExceeded:
                RPCError(code: .deadlineExceeded, message: limitError.localizedDescription)
            }
        }
        if let sdkError = error as? ExactMac.ExactMacError {
            logger.error("SDK error during traversal: \(sdkError.localizedDescription, privacy: .public)")
            return switch sdkError {
            case .accessibilityDenied:
                RPCError(code: .permissionDenied, message: sdkError.localizedDescription)
            case let .appNotFound(pid):
                RPCError(code: .notFound, message: "Application with PID \(pid) not found")
            case let .jsonEncodingFailed(underlyingError):
                RPCError(code: .internalError, message: "JSON encoding failed: \(underlyingError.localizedDescription)")
            case let .internalError(message):
                RPCError(code: .internalError, message: message)
            }
        }

        logger.error("Unexpected error during traversal: \(String(describing: error), privacy: .public)")
        return RPCError(code: .unknown, message: "Unexpected error: \(error.localizedDescription)")
    }

    @MainActor
    fileprivate static func executeInputAction(
        _ action: ExactMac.InputAction,
        route: ExactMac.InputDeliveryRoute,
        executionBoundary: ExactMac.InputExecutionBoundary,
        backendOperation: (@MainActor @Sendable (any ExactMac.InputEventBackend) async throws -> Void)? = nil,
    ) async throws -> ExactMac.InputExecutionReceipt {
        try await ExactMac.executeObservedInputAction(
            action,
            route: route,
            executionBoundary: executionBoundary,
            backendOperation: backendOperation,
        )
    }
}

extension AutomationCoordinator {
    /// Validates that a coordinate value is finite (not NaN or ±Infinity).
    /// CGEvent behavior with non-finite coordinates is undefined and dangerous.
    private nonisolated func validateCoordinate(
        _ value: Double, field: String, inputType: String,
    ) throws {
        guard value.isFinite else {
            throw CoordinatorError.invalidCoordinate(
                "\(inputType) has non-finite \(field) coordinate: \(value)",
            )
        }
    }

    private nonisolated func convertFromProtoInputAction(_ action: Exactmac_V1_InputAction) throws
        -> ExactMac.InputAction
    {
        guard action.unknownFields.data.isEmpty else {
            throw CoordinatorError.invalidKeyCombo("input action contains unknown fields")
        }
        switch action.inputType {
        case let .click(mouseClick):
            guard mouseClick.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("click contains unknown fields")
            }
            guard mouseClick.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("click missing position")
            }
            try validateCoordinate(mouseClick.position.x, field: "x", inputType: "click")
            try validateCoordinate(mouseClick.position.y, field: "y", inputType: "click")
            let clickCount = mouseClick.hasClickCount ? Int(mouseClick.clickCount) : 1
            guard (1 ... 10).contains(clickCount) else {
                throw CoordinatorError.invalidKeyCombo("click_count must be between 1 and 10")
            }
            let point = CGPoint(x: mouseClick.position.x, y: mouseClick.position.y)
            return try .clickSequence(
                point: point,
                button: convertButtonType(
                    mouseClick.clickType,
                    supplied: mouseClick.hasClickType,
                ),
                clickCount: clickCount,
                modifiers: convertModifiers(mouseClick.modifiers),
            )
        case let .typeText(textInput):
            guard textInput.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("type_text contains unknown fields")
            }
            guard !textInput.text.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("type_text text is required")
            }
            try validateDuration(
                textInput.charDelay,
                maximum: 60,
                field: "char_delay",
                allowZero: true,
            )
            return .typeText(text: textInput.text, charDelay: textInput.charDelay)
        case let .pressKey(keyPress):
            guard keyPress.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("press_key contains unknown fields")
            }
            guard !keyPress.key.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("press_key key is required")
            }
            guard ExactMac.layoutIndependentKeyCode(for: keyPress.key) != nil
                || keyPress.key.count == 1
            else {
                throw CoordinatorError.invalidKeyName(keyPress.key)
            }
            try validateDuration(
                keyPress.holdDuration,
                maximum: 3600,
                field: "hold_duration",
                allowZero: true,
            )
            let flags = try convertModifiers(keyPress.modifiers)
            if keyPress.holdDuration > 0 {
                return .pressHold(keyName: keyPress.key, flags: flags, duration: keyPress.holdDuration)
            }
            return .press(keyName: keyPress.key, flags: flags)
        case let .moveMouse(mouseMove):
            guard mouseMove.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("move_mouse contains unknown fields")
            }
            guard mouseMove.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("move missing position")
            }
            try validateCoordinate(mouseMove.position.x, field: "x", inputType: "move")
            try validateCoordinate(mouseMove.position.y, field: "y", inputType: "move")
            try validateDuration(
                mouseMove.duration,
                maximum: 60,
                field: "move duration",
                allowZero: true,
            )
            return try .movePointer(
                to: CGPoint(x: mouseMove.position.x, y: mouseMove.position.y),
                duration: mouseMove.duration,
                modifiers: convertModifiers(mouseMove.modifiers),
            )
        case let .drag(mouseDrag):
            guard mouseDrag.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("drag contains unknown fields")
            }
            try validateDuration(
                mouseDrag.duration,
                maximum: 60,
                field: "drag duration",
                allowZero: true,
            )
            let points: [CGPoint]
            if !mouseDrag.path.isEmpty {
                guard (2 ... 100).contains(mouseDrag.path.count) else {
                    throw CoordinatorError.invalidKeyCombo("drag path must contain between 2 and 100 points")
                }
                points = try mouseDrag.path.enumerated().map { index, point in
                    guard point.unknownFields.data.isEmpty else {
                        throw CoordinatorError.invalidKeyCombo("drag path[\(index)] contains unknown fields")
                    }
                    try validateCoordinate(point.x, field: "path[\(index)].x", inputType: "drag")
                    try validateCoordinate(point.y, field: "path[\(index)].y", inputType: "drag")
                    return CGPoint(x: point.x, y: point.y)
                }
                if mouseDrag.hasStartPosition {
                    let start = CGPoint(
                        x: mouseDrag.startPosition.x,
                        y: mouseDrag.startPosition.y,
                    )
                    guard start == points.first else {
                        throw CoordinatorError.invalidKeyCombo("drag start_position contradicts path")
                    }
                }
                if mouseDrag.hasEndPosition {
                    let end = CGPoint(
                        x: mouseDrag.endPosition.x,
                        y: mouseDrag.endPosition.y,
                    )
                    guard end == points.last else {
                        throw CoordinatorError.invalidKeyCombo("drag end_position contradicts path")
                    }
                }
            } else {
                guard mouseDrag.hasStartPosition, mouseDrag.hasEndPosition else {
                    throw CoordinatorError.invalidKeyCombo("drag requires path or start_position and end_position")
                }
                try validateCoordinate(mouseDrag.startPosition.x, field: "start_x", inputType: "drag")
                try validateCoordinate(mouseDrag.startPosition.y, field: "start_y", inputType: "drag")
                try validateCoordinate(mouseDrag.endPosition.x, field: "end_x", inputType: "drag")
                try validateCoordinate(mouseDrag.endPosition.y, field: "end_y", inputType: "drag")
                points = [
                    CGPoint(x: mouseDrag.startPosition.x, y: mouseDrag.startPosition.y),
                    CGPoint(x: mouseDrag.endPosition.x, y: mouseDrag.endPosition.y),
                ]
            }
            return try .dragPath(
                points: points,
                button: convertButtonType(
                    mouseDrag.button,
                    supplied: mouseDrag.hasButton,
                ),
                duration: mouseDrag.duration,
                modifiers: convertModifiers(mouseDrag.modifiers),
            )
        case let .scroll(scroll):
            guard scroll.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("scroll contains unknown fields")
            }
            let point: CGPoint? = if scroll.hasPosition {
                try CGPoint(
                    x: validatedCoordinate(scroll.position.x, field: "x", inputType: "scroll"),
                    y: validatedCoordinate(scroll.position.y, field: "y", inputType: "scroll"),
                )
            } else {
                nil
            }
            guard scroll.horizontal.isFinite, scroll.vertical.isFinite else {
                throw CoordinatorError.invalidKeyCombo("scroll deltas must be finite")
            }
            try validateScrollDelta(scroll.horizontal, field: "horizontal")
            try validateScrollDelta(scroll.vertical, field: "vertical")
            guard scroll.horizontal != 0 || scroll.vertical != 0 else {
                throw CoordinatorError.invalidKeyCombo("scroll requires a non-zero delta")
            }
            try validateDuration(
                scroll.duration,
                maximum: 60,
                field: "scroll duration",
                allowZero: true,
            )
            return try .scroll(
                at: point,
                horizontal: scroll.horizontal,
                vertical: scroll.vertical,
                duration: scroll.duration,
                modifiers: convertModifiers(scroll.modifiers),
            )
        case let .hover(hover):
            guard hover.unknownFields.data.isEmpty else {
                throw CoordinatorError.invalidKeyCombo("hover contains unknown fields")
            }
            guard hover.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("hover missing position")
            }
            try validateCoordinate(hover.position.x, field: "x", inputType: "hover")
            try validateCoordinate(hover.position.y, field: "y", inputType: "hover")
            try validateDuration(
                hover.duration,
                maximum: 3600,
                field: "hover duration",
                allowZero: false,
            )
            return .hover(
                at: CGPoint(x: hover.position.x, y: hover.position.y),
                duration: hover.duration,
            )
        case .none:
            throw CoordinatorError.invalidKeyCombo("empty input type")
        }
    }

    private nonisolated func validatedCoordinate(
        _ value: Double,
        field: String,
        inputType: String,
    ) throws -> Double {
        try validateCoordinate(value, field: field, inputType: inputType)
        return value
    }

    private nonisolated func validateDuration(
        _ value: Double,
        maximum: Double,
        field: String,
        allowZero: Bool,
    ) throws {
        guard value.isFinite, value >= 0, value <= maximum, allowZero || value > 0 else {
            throw CoordinatorError.invalidKeyCombo(
                "\(field) must be \(allowZero ? "between 0" : "greater than 0 and at most") \(maximum) seconds",
            )
        }
    }

    private nonisolated func validateScrollDelta(_ value: Double, field: String) throws {
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
            throw CoordinatorError.invalidKeyCombo(
                "scroll \(field) delta is outside the supported range",
            )
        }
        guard value == 0 || Int32(rounded) != 0 else {
            throw CoordinatorError.invalidKeyCombo(
                "scroll \(field) delta magnitude must be at least one pixel",
            )
        }
    }

    private nonisolated func convertButtonType(
        _ buttonType: Exactmac_V1_MouseClick.ClickType,
        supplied: Bool,
    ) throws
        -> CGMouseButton
    {
        switch buttonType {
        case .unspecified where !supplied:
            .left
        case .unspecified:
            throw CoordinatorError.invalidKeyCombo("supplied mouse button must not be unspecified")
        case .left:
            .left
        case .right:
            .right
        case .middle:
            .center
        case let .UNRECOGNIZED(rawValue):
            throw CoordinatorError.invalidKeyCombo("unknown mouse button value \(rawValue)")
        }
    }

    private nonisolated func convertModifiers(_ modifiers: [Exactmac_V1_KeyPress.Modifier]) throws
        -> CGEventFlags
    {
        var flags: CGEventFlags = []
        var seenRawValues: Set<Int> = []
        for modifier in modifiers {
            guard seenRawValues.insert(modifier.rawValue).inserted else {
                throw CoordinatorError.unknownModifier(
                    "duplicate numeric value \(modifier.rawValue)",
                )
            }
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            case .shift:
                flags.insert(.maskShift)
            case .function:
                flags.insert(.maskSecondaryFn)
            case .capsLock:
                flags.insert(.maskAlphaShift)
            case .unspecified:
                throw CoordinatorError.unknownModifier("unspecified")
            case let .UNRECOGNIZED(rawValue):
                throw CoordinatorError.unknownModifier("unknown numeric value \(rawValue)")
            }
        }
        return flags
    }
}

public enum CoordinatorError: Error, LocalizedError {
    case invalidKeyName(String)
    case invalidKeyCombo(String)
    case unknownModifier(String)
    case invalidCoordinate(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidKeyName(name):
            "Invalid key name: \(name)"
        case let .invalidKeyCombo(combo):
            "Invalid key combo: \(combo)"
        case let .unknownModifier(modifier):
            "Unknown modifier: \(modifier)"
        case let .invalidCoordinate(detail):
            "Invalid coordinate: \(detail)"
        }
    }
}

enum InputTargetActivationError: Error, Equatable, LocalizedError {
    case applicationUnavailable(pid: pid_t)
    case setFrontmostFailed(pid: pid_t, axErrorCode: Int32)
    case convergenceTimedOut(pid: pid_t)

    var errorDescription: String? {
        switch self {
        case let .applicationUnavailable(pid):
            "Unable to create an Accessibility application for PID \(pid)"
        case let .setFrontmostFailed(pid, axErrorCode):
            "Unable to make PID \(pid) frontmost: AXErrorCode=\(axErrorCode)"
        case let .convergenceTimedOut(pid):
            "Timed out waiting for PID \(pid) to become frontmost"
        }
    }
}
