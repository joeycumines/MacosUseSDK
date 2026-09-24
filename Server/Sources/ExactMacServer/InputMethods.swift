import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

private struct InputExecutionTargetLease: Sendable {
    enum ApplicationAuthority: Equatable, Sendable {
        case production(AppStateStore.ApplicationProcessGenerationLease)
        case legacyTestPID(name: String, pid: pid_t)

        var name: String {
            switch self {
            case let .production(lease):
                lease.name
            case let .legacyTestPID(name, _):
                name
            }
        }

        var pid: pid_t {
            switch self {
            case let .production(lease):
                lease.pid
            case let .legacyTestPID(_, pid):
                pid
            }
        }

        var processIdentity: ApplicationProcessIdentity? {
            switch self {
            case let .production(lease):
                lease.identity
            case .legacyTestPID:
                nil
            }
        }
    }

    struct WindowAuthority: Sendable {
        let application: ApplicationAuthority
        let binding: WindowRegistry.WindowBinding
        let privateWindowID: CGWindowID
        let retainedWindow: SendableAXUIElement
        let role: String
        let liveBounds: CGRect
    }

    enum Owner: Sendable {
        case application(ApplicationAuthority)
        case window(WindowAuthority)
        case display(CGDirectDisplayID)
        case desktop
    }

    let owner: Owner
    let topology: [DisplayTopologyDisplay]
    let preparedAction: PreparedInputAction

    var pid: pid_t? {
        switch owner {
        case let .application(application):
            application.pid
        case let .window(window):
            window.application.pid
        case .display, .desktop:
            nil
        }
    }

    var deliveryRoute: ExactMac.InputDeliveryRoute {
        switch owner {
        case let .application(application):
            .process(application.pid)
        case let .window(window):
            .process(window.application.pid)
        case .display, .desktop:
            .session
        }
    }

    var applicationAuthority: ApplicationAuthority? {
        switch owner {
        case let .application(application):
            application
        case let .window(window):
            window.application
        case .display, .desktop:
            nil
        }
    }
}

private enum InputTerminalPersistenceError: Error {
    case leaseLost
    case missingPublishedState
    case alreadyTerminal
}

final class InputTransactionExecutor: Sendable {
    nonisolated let stateStore: AppStateStore
    private let legacyPIDResourceNamesForTests: Bool
    nonisolated let windowRegistry: WindowRegistry
    nonisolated let system: SystemOperations
    nonisolated let displayTopologyProvider: any DisplayTopologyProviding
    nonisolated let automationCoordinator: AutomationCoordinator
    nonisolated let inputOverlayPresenter: InputOverlayPresenter
    nonisolated let clipboardManager: ClipboardManager
    private let windowMutationConvergencePolicy: WindowMutationConvergencePolicy

    init(
        stateStore: AppStateStore,
        legacyPIDResourceNamesForTests: Bool,
        windowRegistry: WindowRegistry,
        system: SystemOperations,
        displayTopologyProvider: any DisplayTopologyProviding,
        automationCoordinator: AutomationCoordinator,
        inputOverlayPresenter: InputOverlayPresenter,
        clipboardManager: ClipboardManager,
        windowMutationConvergencePolicy: WindowMutationConvergencePolicy,
    ) {
        self.stateStore = stateStore
        self.legacyPIDResourceNamesForTests = legacyPIDResourceNamesForTests
        self.windowRegistry = windowRegistry
        self.system = system
        self.displayTopologyProvider = displayTopologyProvider
        self.automationCoordinator = automationCoordinator
        self.inputOverlayPresenter = inputOverlayPresenter
        self.clipboardManager = clipboardManager
        self.windowMutationConvergencePolicy = windowMutationConvergencePolicy
    }

    func execute(
        _ req: Exactmac_V1_CreateInputRequest,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
        expectedApplicationGeneration: AppStateStore.ApplicationProcessGenerationLease? = nil,
    ) async throws -> Exactmac_V1_Input {
        guard req.unknownFields.data.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "CreateInputRequest contains unknown fields")
        }
        guard !req.parent.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "parent is required")
        }
        guard req.hasInput, req.input.hasAction else {
            throw RPCError(code: .invalidArgument, message: "input.action is required")
        }
        guard req.input.hasTarget, req.input.target.destination != nil else {
            throw RPCError(code: .invalidArgument, message: "input.target is required")
        }
        guard req.input.unknownFields.data.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "input contains unknown fields")
        }
        guard req.input.name.isEmpty,
              req.input.state == .unspecified,
              req.input.error.isEmpty,
              !req.input.hasCreateTime,
              !req.input.hasCompleteTime,
              !req.input.hasDeliveryResult
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "output-only Input fields must not be supplied",
            )
        }
        if !req.inputID.isEmpty {
            try ParsingHelpers.validateResourceID(req.inputID, field: "input_id")
        }
        try validateInputTargetStructure(
            req.input.target,
            parent: req.parent,
        )
        let validatedAction: ValidatedInputAction
        do {
            validatedAction = try automationCoordinator.validateInputAction(req.input.action)
        } catch let coordError as CoordinatorError {
            throw RPCErrorHelpers.validationError(
                message: coordError.localizedDescription,
                reason: "INVALID_INPUT",
                field: "input.action",
            )
        }
        try validateInputTargetActionCompatibility(
            target: req.input.target,
            action: validatedAction,
        )

        let inputId = req.inputID.isEmpty ? UUID().uuidString : req.inputID
        let inputParent = req.parent
        let name = "\(inputParent)/inputs/\(inputId)"
        _ = try ParsingHelpers.parseInputName(name)

        let terminalInput: Exactmac_V1_Input
        do {
            terminalInput = try await automationCoordinator.withOwnedMutationTask(
                cancellation: cancellation,
                onAdmissionClosed: { [stateStore] in
                    if await stateStore.containsInputIdentity(name: name) {
                        return RPCError(
                            code: .alreadyExists,
                            message: "Input already exists",
                        )
                    }
                    return RPCError(
                        code: .unavailable,
                        message: "Input admission is closed",
                    )
                },
                { [self] runner, ownerID in
                    let identityLease: AppStateStore.InputIdentityLease
                    switch await stateStore.reserveInputIdentity(name: name, ownerID: ownerID) {
                    case let .reserved(lease):
                        identityLease = lease
                    case .duplicate:
                        throw RPCError(code: .alreadyExists, message: "Input already exists")
                    case .admissionClosed:
                        throw RPCError(code: .unavailable, message: "Input admission is closed")
                    }

                    var published = false
                    var committedEvidence: (
                        postedEventCount: Int,
                        routedDeliveryObserved: Bool,
                    )?
                    var expectedRoute: ExactMac.InputDeliveryRoute?
                    var overlayReservation: InputOverlayReservation?
                    do {
                        try Task.checkCancellation()
                        let executionLease = try await self.resolveInputExecutionTargetLease(
                            req.input.target,
                            parent: inputParent,
                            validatedAction: validatedAction,
                            expectedApplicationGeneration: expectedApplicationGeneration,
                        )
                        expectedRoute = executionLease.deliveryRoute
                        try Task.checkCancellation()
                        try await self.revalidateInputExecutionTargetLease(
                            executionLease,
                            requireFocus: false,
                        )
                        try Task.checkCancellation()
                        let reservedOverlay = try await self.reserveInputOverlay(
                            for: executionLease,
                        )
                        overlayReservation = reservedOverlay
                        try Task.checkCancellation()

                        guard await self.stateStore.publishPendingInput(
                            lease: identityLease,
                            action: req.input.action,
                            target: req.input.target,
                        ) != nil else {
                            throw RPCError(
                                code: .internalError,
                                message: "Input identity could not be published",
                            )
                        }
                        published = true

                        let receipt = try await runner.run(
                            authoritySystem: self.system,
                        ) { context in
                            try await self.revalidateInputExecutionTargetLease(
                                executionLease,
                                requireFocus: false,
                            )
                            try Task.checkCancellation()
                            guard await self.stateStore.markInputExecuting(lease: identityLease) != nil else {
                                throw RPCError(
                                    code: .cancelled,
                                    message: "Input reservation is no longer pending",
                                )
                            }
                            if executionLease.applicationAuthority != nil,
                               executionLease.preparedAction.action.requiresAppActivation
                            {
                                try await self.activateInputExecutionTarget(
                                    executionLease,
                                    system: context.system,
                                )
                            }
                            try await self.revalidateInputExecutionTargetLease(
                                executionLease,
                                requireFocus: executionLease.preparedAction.action
                                    .requiresAppActivation,
                            )
                            let backendOperation = try self.inputBackendOperation(
                                for: executionLease,
                            )
                            let receipt = try await context.executeInput(
                                executionLease.preparedAction.action,
                                route: executionLease.deliveryRoute,
                                executionBoundary: self.inputExecutionBoundary(
                                    executionLease,
                                ),
                                accessPreflighted: true,
                                backendOperation: backendOperation,
                            )
                            do {
                                if let reservedOverlay {
                                    try await self.revalidateInputExecutionTargetLease(
                                        executionLease,
                                        requireFocus: executionLease.preparedAction.action
                                            .requiresAppActivation,
                                    )
                                    try await self.inputOverlayPresenter.present(reservedOverlay)
                                }
                                return receipt
                            } catch {
                                throw ExactMac.InputExecutionFailure(
                                    underlying: error,
                                    route: receipt.route,
                                    postedEventCount: receipt.postedEventCount,
                                    routedDeliveryObserved: receipt.routedDeliveryObserved,
                                    physicalEffectOccurred: receipt.postedEventCount > 0,
                                )
                            }
                        }
                        guard let postedEventCount = Int32(exactly: receipt.postedEventCount) else {
                            throw ExactMac.InputExecutionFailure(
                                underlying: RPCError(
                                    code: .internalError,
                                    message: "Input delivery event count exceeded the public range",
                                ),
                                route: receipt.route,
                                postedEventCount: max(0, receipt.postedEventCount),
                                routedDeliveryObserved: receipt.routedDeliveryObserved,
                                physicalEffectOccurred: receipt.postedEventCount > 0,
                            )
                        }
                        committedEvidence = (
                            postedEventCount: receipt.postedEventCount,
                            routedDeliveryObserved: receipt.routedDeliveryObserved,
                        )
                        let delivery = inputDeliveryResult(
                            commitment: .committedAndSettled,
                            postedEventCount: postedEventCount,
                            routedDeliveryObserved: receipt.routedDeliveryObserved,
                        )
                        switch await stateStore.finishInput(
                            lease: identityLease,
                            outcome: .completed(delivery),
                        ) {
                        case let .finished(completedInput):
                            return completedInput
                        case .leaseLost:
                            throw InputTerminalPersistenceError.leaseLost
                        case .missingPublishedState:
                            throw InputTerminalPersistenceError.missingPublishedState
                        case .alreadyTerminal:
                            throw InputTerminalPersistenceError.alreadyTerminal
                        }
                    } catch {
                        if let overlayReservation {
                            await inputOverlayPresenter.cancelAndJoin(overlayReservation)
                        }
                        guard published else {
                            _ = await stateStore.abandonInputIdentity(identityLease)
                            let mappedError = mapInputExecutionError(error)
                            if let exactGenerationError = exactApplicationGenerationError(
                                mappedError,
                                expectedApplicationGeneration: expectedApplicationGeneration,
                            ) {
                                throw exactGenerationError
                            }
                            throw mappedError
                        }
                        if error is InputTerminalPersistenceError {
                            throw RPCError(
                                code: .internalError,
                                message: "Input terminal persistence lost its exact transaction state",
                            )
                        }

                        let evidence = inputExecutionFailureEvidence(
                            error,
                            expectedRoute: expectedRoute,
                            committedEvidence: committedEvidence,
                        )
                        let exactGenerationError = exactApplicationGenerationError(
                            evidence.underlying,
                            expectedApplicationGeneration: expectedApplicationGeneration,
                        )
                        let hasPossibleCommitment = evidence.postedEventCount > 0
                            || evidence.routedDeliveryObserved
                            || evidence.physicalEffectOccurred
                        let delivery = inputDeliveryResult(
                            commitment: hasPossibleCommitment ? .possiblyCommitted : .noEffect,
                            postedEventCount: Int32(clamping: evidence.postedEventCount),
                            routedDeliveryObserved: evidence.routedDeliveryObserved,
                        )
                        let terminalState: Exactmac_V1_Input.State =
                            isInputCancellation(evidence.underlying) ? .cancelled : .failed
                        let failureMessage =
                            exactGenerationError?.message
                                ?? evidence.underlying.localizedDescription
                        let outcome: AppStateStore.InputTerminalOutcome = if terminalState == .cancelled {
                            .cancelled(error: failureMessage, delivery: delivery)
                        } else {
                            .failed(error: failureMessage, delivery: delivery)
                        }
                        let failedInput: Exactmac_V1_Input
                        switch await stateStore.finishInput(
                            lease: identityLease,
                            outcome: outcome,
                        ) {
                        case let .finished(input):
                            failedInput = input
                        case .leaseLost, .missingPublishedState, .alreadyTerminal:
                            throw RPCError(
                                code: .internalError,
                                message: "Input terminal persistence lost its exact transaction state",
                            )
                        }

                        if let exactGenerationError {
                            throw exactGenerationError
                        }
                        if isInputCancellation(evidence.underlying) {
                            throw RPCError(code: .cancelled, message: "Input execution was cancelled")
                        }
                        if let rpcError = evidence.underlying as? RPCError {
                            throw rpcError
                        }
                        return failedInput
                    }
                },
            )
        } catch is CancellationError {
            throw RPCError(code: .cancelled, message: "Input execution was cancelled")
        }
        return terminalInput
    }

    @MainActor
    private func inputBackendOperation(
        for lease: InputExecutionTargetLease,
    ) throws
        -> (@MainActor @Sendable (any ExactMac.InputEventBackend) async throws -> Void)?
    {
        let text: String
        let characterDelay: Double
        switch lease.preparedAction.action {
        case let .type(value):
            text = value
            characterDelay = 0
        case let .typeText(value, delay):
            text = value
            characterDelay = delay
        default:
            return nil
        }
        guard let pid = lease.pid,
              let pasteKeyCode = lease.preparedAction.textPasteKeyCode
        else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Physical text input requires an exact application target and paste key",
            )
        }
        let clipboardManager = clipboardManager
        let stateReader = SystemInputTextStateReader(system: system)
        // Paste-based text convergence requires an observable text-state baseline
        // (kAXValueAttribute or kAXSelectedTextRangeAttribute on the focused
        // element). Non-text focused UIs (e.g. Calculator buttons) expose
        // neither, so the baseline capture throws FailedPrecondition. Probe it
        // once before committing to the paste route: when no text baseline is
        // observable, return nil so the caller falls back to keystroke posting
        // (executeInputAction .type/.typeText -> writeText), which posts unicode
        // keyDown/keyUp and is the correct route for single-character input into
        // a non-text surface. "No observable baseline" covers FailedPrecondition
        // (deterministic non-text UI), Unavailable (transient AX could-not-complete),
        // and InternalError (an unreadable focused element / unmapped AX code); in all
        // of these the paste route cannot converge, so keystroke posting is the safe
        // fallback. A real accessibility-permission loss (PermissionDenied) is NOT
        // swallowed — it propagates so the caller reports the environment failure.
        do {
            _ = try InputTextConvergenceVerifier(
                pid: pid,
                reader: stateReader,
            ).capture()
        } catch let error as RPCError
            where error.code == .failedPrecondition
            || error.code == .unavailable
            || error.code == .internalError
        {
            return nil
        }
        return { backend in
            let convergence = InputTextPasteConvergenceCoordinator(
                verifier: InputTextConvergenceVerifier(
                    pid: pid,
                    reader: stateReader,
                ),
            )
            try await clipboardManager.withTemporaryText { replacePasteboardText in
                try await ExactMac.writeTextByPasting(
                    text,
                    characterDelay: characterDelay,
                    pasteKeyCode: pasteKeyCode,
                    preparePasteboardText: { grapheme in
                        try await convergence.prepare(
                            text: grapheme,
                            replacePasteboardText: replacePasteboardText,
                        )
                    },
                    awaitPasteboardConsumption: {
                        try await convergence.waitForConsumption()
                    },
                    backend: backend,
                )
            }
        }
    }

    private func reserveInputOverlay(
        for lease: InputExecutionTargetLease,
    ) async throws -> InputOverlayReservation? {
        guard lease.preparedAction.visualFeedback else {
            return nil
        }
        let presentation = try InputOverlayPlanning.presentation(
            for: lease.preparedAction.action,
            topology: lease.topology,
            requestedDuration: lease.preparedAction.animationDuration,
        )
        return try await inputOverlayPresenter.reserve(presentation)
    }

    private func validateInputTargetStructure(
        _ target: Exactmac_V1_InputTarget,
        parent: String,
    ) throws {
        guard target.unknownFields.data.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "input.target contains unknown fields")
        }
        switch target.destination {
        case let .application(name):
            guard parent == name else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "application target must equal parent",
                )
            }
            try validateInputApplicationName(
                name,
                legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            )
        case let .window(name):
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 4,
                  components[0] == "applications",
                  components[2] == "windows"
            else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "Invalid input.target.window resource name",
                )
            }
            let applicationName = components[0 ... 1].joined(separator: "/")
            guard parent == applicationName else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "window target owner must equal parent",
                )
            }
            try validateInputApplicationName(
                applicationName,
                legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            )
            try ParsingHelpers.validateResourceID(
                String(components[3]),
                field: "input.target.window",
            )
        case let .display(name):
            guard parent == "applications/-" else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "display target requires parent applications/-",
                )
            }
            _ = try ParsingHelpers.parseDisplayName(
                name,
                field: "input.target.display",
            )
        case let .desktop(selected):
            guard selected, parent == "applications/-" else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "desktop target must be true with parent applications/-",
                )
            }
        case nil:
            throw RPCError(code: .invalidArgument, message: "input.target is required")
        }
    }

    private func validateInputTargetActionCompatibility(
        target: Exactmac_V1_InputTarget,
        action: ValidatedInputAction,
    ) throws {
        if case .display = target.destination, action.requiresKeyboardFocus {
            throw RPCErrorHelpers.validationError(
                message: "display targets cannot own keyboard or text delivery",
                reason: "INVALID_INPUT_TARGET",
                field: "input.target.display",
            )
        }
    }

    @MainActor
    private func resolveInputExecutionTargetLease(
        _ target: Exactmac_V1_InputTarget,
        parent: String,
        validatedAction: ValidatedInputAction,
        expectedApplicationGeneration: AppStateStore.ApplicationProcessGenerationLease?,
    ) async throws -> InputExecutionTargetLease {
        let topology = try await displayTopologyProvider.snapshot().validated().displays
        let owner: InputExecutionTargetLease.Owner
        switch target.destination {
        case let .application(name):
            guard parent == name else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "application target must equal parent",
                )
            }
            owner = try await .application(resolveInputApplicationAuthority(
                name,
                expectedApplicationGeneration: expectedApplicationGeneration,
            ))
        case let .window(name):
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let applicationName = components[0 ... 1].joined(separator: "/")
            let resourceID = String(components[3])
            let application = try await resolveInputApplicationAuthority(
                applicationName,
                expectedApplicationGeneration: expectedApplicationGeneration,
            )
            guard let binding = await windowRegistry.resolveWindowBinding(
                resourceID: resourceID,
                applicationName: applicationName,
                pid: application.pid,
                processIdentity: application.processIdentity,
            ) else {
                throw RPCError(code: .notFound, message: "Input target window is stale")
            }
            guard parent == application.name else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "window target owner must equal parent",
                )
            }
            owner = try await .window(resolveExactInputWindowAuthority(
                application: application,
                binding: binding,
            ))
        case let .display(name):
            guard parent == "applications/-" else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "display target requires parent applications/-",
                )
            }
            let displayID = try ParsingHelpers.parseDisplayName(
                name,
                field: "input.target.display",
            ).displayID
            guard topology.contains(where: { $0.displayID == displayID }) else {
                throw RPCError(code: .notFound, message: "Input target display is not active")
            }
            owner = .display(displayID)
        case let .desktop(selected):
            guard selected, parent == "applications/-" else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "desktop target must be true with parent applications/-",
                )
            }
            owner = .desktop
        case nil:
            throw RPCError(code: .invalidArgument, message: "input.target is required")
        }

        for (index, point) in inputActionPoints(validatedAction.action).enumerated() {
            try validateInputPoint(
                point,
                index: index,
                owner: owner,
                topology: topology,
            )
        }

        let preparedAction: PreparedInputAction
        do {
            preparedAction = try automationCoordinator.admitInputAction(validatedAction)
        } catch let coordError as CoordinatorError {
            throw RPCErrorHelpers.validationError(
                message: coordError.localizedDescription,
                reason: "INVALID_INPUT",
                field: "input.action",
            )
        }
        return InputExecutionTargetLease(
            owner: owner,
            topology: topology,
            preparedAction: preparedAction,
        )
    }

    @MainActor
    private func resolveInputApplicationAuthority(
        _ name: String,
        expectedApplicationGeneration: AppStateStore.ApplicationProcessGenerationLease?,
    ) async throws -> InputExecutionTargetLease.ApplicationAuthority {
        if legacyPIDResourceNamesForTests {
            return try .legacyTestPID(
                name: name,
                pid: ParsingHelpers.parsePID(fromName: name),
            )
        }
        _ = try ParsingHelpers.parseOpaqueApplicationName(name)
        guard let lease = await stateStore.applicationProcessGenerationLease(name: name),
              system.isApplicationProcessRunning(lease.identity),
              expectedApplicationGeneration == nil || expectedApplicationGeneration == lease
        else {
            if expectedApplicationGeneration != nil {
                throw staleInputApplicationGenerationError()
            }
            throw RPCError(
                code: .notFound,
                message: "Input target application generation is unavailable",
            )
        }
        return .production(lease)
    }

    @MainActor
    private func resolveExactInputWindowAuthority(
        application: InputExecutionTargetLease.ApplicationAuthority,
        binding: WindowRegistry.WindowBinding,
    ) async throws -> InputExecutionTargetLease.WindowAuthority {
        try await requireInputPublishedApplicationAuthority(application)
        try await requireInputWindowBinding(
            application: application,
            frozen: binding,
        )
        let resolved = try resolveExactInputAXWindow(
            application: application,
            privateWindowID: binding.windowID,
        )
        return InputExecutionTargetLease.WindowAuthority(
            application: application,
            binding: binding,
            privateWindowID: binding.windowID,
            retainedWindow: SendableAXUIElement(resolved.window),
            role: resolved.role,
            liveBounds: resolved.bounds,
        )
    }

    @MainActor
    private func revalidateInputExecutionTargetLease(
        _ lease: InputExecutionTargetLease,
        requireFocus: Bool,
    ) async throws {
        let currentTopology = try await revalidateInputExecutionTargetActorAuthority(lease)
        try revalidateInputExecutionTargetSynchronousAuthority(
            lease,
            currentTopology: currentTopology,
            requireFocus: requireFocus,
        )
    }

    @MainActor
    private func revalidateInputExecutionTargetActorAuthority(
        _ lease: InputExecutionTargetLease,
    ) async throws -> [DisplayTopologyDisplay] {
        let currentTopology = try await displayTopologyProvider.snapshot().validated().displays
        guard currentTopology == lease.topology else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Display topology changed while input was queued",
            )
        }
        switch lease.owner {
        case let .application(application):
            try await requireInputPublishedApplicationAuthority(application)
        case let .window(window):
            try await requireInputPublishedApplicationAuthority(window.application)
            try await requireInputWindowBinding(
                application: window.application,
                frozen: window.binding,
            )
        case .display, .desktop:
            break
        }
        return currentTopology
    }

    @MainActor
    private func revalidateInputExecutionTargetSynchronousAuthority(
        _ lease: InputExecutionTargetLease,
        currentTopology: [DisplayTopologyDisplay],
        requireFocus: Bool,
    ) throws {
        try automationCoordinator.revalidateInputAction(lease.preparedAction)
        switch lease.owner {
        case let .application(application):
            try requireInputKernelAuthority(application, system: system)
            if requireFocus {
                guard try inputApplicationIsFrontmost(application) else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Input target application is not frontmost",
                    )
                }
            }
        case let .window(window):
            let resolved = try readExactInputWindowAuthority(window)
            if requireFocus {
                guard try inputWindowHasExactFocus(
                    applicationElement: resolved.application,
                    window: window,
                ) else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Input target window does not own exact focus",
                    )
                }
            }
        case let .display(displayID):
            guard currentTopology.contains(where: { $0.displayID == displayID }) else {
                throw RPCError(code: .notFound, message: "Input target display is no longer active")
            }
        case .desktop:
            break
        }
        if let application = lease.applicationAuthority {
            try requireInputKernelAuthority(application, system: system)
        }
    }

    private func inputActionPoints(_ action: ExactMac.InputAction) -> [CGPoint] {
        switch action {
        case let .click(point),
             let .doubleClick(point),
             let .rightClick(point),
             let .clickSequence(point, _, _, _),
             let .move(to: point),
             let .movePointer(to: point, _, _),
             let .hover(at: point, _):
            [point]
        case let .drag(from, to, _, _):
            [from, to]
        case let .dragPath(points, _, _, _):
            points
        case let .scroll(point?, _, _, _, _):
            [point]
        case .type, .typeText, .press, .pressHold, .pressKeyCode,
             .pressKeyCodeHold, .scroll(nil, _, _, _, _):
            []
        }
    }

    @MainActor
    private func activateInputExecutionTarget(
        _ lease: InputExecutionTargetLease,
        system: SystemOperations,
    ) async throws {
        guard let application = lease.applicationAuthority else {
            return
        }
        try await requireInputPublishedApplicationAuthority(application)
        try requireInputKernelAuthority(application, system: system)
        guard let applicationElement = system.createAXApplication(pid: application.pid),
              CFGetTypeID(applicationElement as CFTypeRef) == AXUIElementGetTypeID()
        else {
            throw RPCError(code: .notFound, message: "Input target application is unavailable")
        }
        try await revalidateInputExecutionTargetLease(
            lease,
            requireFocus: false,
        )
        let initiallyConverged = try inputExecutionTargetHasExactFocus(
            lease,
            applicationElement: applicationElement,
        )
        var convergedBeforeWait = initiallyConverged
        var deferredWindowMutationError: RPCError?

        if !initiallyConverged {
            try requireInputKernelAuthority(application, system: system)
            let frontmostResult = system.setAXAttribute(
                element: applicationElement,
                attribute: kAXFrontmostAttribute as String,
                value: true,
            )
            guard frontmostResult == AXError.success.rawValue else {
                throw rpcErrorForInputAXMutation(
                    errorCode: frontmostResult,
                    operation: "frontmost activation",
                )
            }
            try await revalidateInputExecutionTargetLease(
                lease,
                requireFocus: false,
            )
            convergedBeforeWait = try inputExecutionTargetHasExactFocus(
                lease,
                applicationElement: applicationElement,
            )

            if !convergedBeforeWait, case let .window(window) = lease.owner {
                _ = try await requireExactInputWindowAuthority(window)
                try requireInputKernelAuthority(application, system: system)
                let raiseResult = system.performAXAction(
                    element: window.retainedWindow.element as AnyObject,
                    action: kAXRaiseAction as String,
                )
                if raiseResult != AXError.success.rawValue {
                    deferredWindowMutationError = rpcErrorForInputAXMutation(
                        errorCode: raiseResult,
                        operation: "window raise",
                    )
                }

                _ = try await requireExactInputWindowAuthority(window)
                try requireInputKernelAuthority(application, system: system)
                let mainResult = system.setAXAttribute(
                    element: window.retainedWindow.element as AnyObject,
                    attribute: kAXMainAttribute as String,
                    value: true,
                )
                if mainResult != AXError.success.rawValue, deferredWindowMutationError == nil {
                    deferredWindowMutationError = rpcErrorForInputAXMutation(
                        errorCode: mainResult,
                        operation: "window main focus",
                    )
                }

                _ = try await requireExactInputWindowAuthority(window)
                try requireInputKernelAuthority(application, system: system)
                let focusedResult = system.setAXAttribute(
                    element: window.retainedWindow.element as AnyObject,
                    attribute: kAXFocusedAttribute as String,
                    value: true,
                )
                if focusedResult != AXError.success.rawValue, deferredWindowMutationError == nil {
                    deferredWindowMutationError = rpcErrorForInputAXMutation(
                        errorCode: focusedResult,
                        operation: "window keyboard focus",
                    )
                }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowMutationConvergencePolicy.timeout)
        var stableReads = convergedBeforeWait ? 1 : 0
        if stableReads >= windowMutationConvergencePolicy.stableReadCount {
            return
        }
        while true {
            try Task.checkCancellation()
            try await revalidateInputExecutionTargetLease(
                lease,
                requireFocus: false,
            )
            let converged = try inputExecutionTargetHasExactFocus(
                lease,
                applicationElement: applicationElement,
            )
            if converged {
                stableReads += 1
                if stableReads >= windowMutationConvergencePolicy.stableReadCount {
                    return
                }
            } else {
                stableReads = 0
            }
            guard clock.now < deadline else {
                if let deferredWindowMutationError {
                    throw deferredWindowMutationError
                }
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for exact input target focus",
                )
            }
            try await Task.sleep(for: windowMutationConvergencePolicy.pollInterval)
        }
    }

    private func inputExecutionBoundary(
        _ lease: InputExecutionTargetLease,
    ) -> ExactMac.InputExecutionBoundary {
        ExactMac.InputExecutionBoundary(
            validateEffect: { [self] effect in
                try await validateInputPhysicalEffectAuthority(
                    effect: effect,
                    lease: lease,
                )
            },
            validateProcessRoute: { [system] pid in
                try lease.validateProcessRoute(
                    pid: pid,
                    system: system,
                )
            },
        )
    }

    @MainActor
    private func validateInputPhysicalEffectAuthority(
        effect: ExactMac.InputPhysicalEffect,
        lease: InputExecutionTargetLease,
    ) async throws {
        try lease.validate(effect: effect)
        let currentTopology = try await revalidateInputExecutionTargetActorAuthority(lease)
        let requireFocus = lease.preparedAction.action.requiresAppActivation
        try revalidateInputExecutionTargetSynchronousAuthority(
            lease,
            currentTopology: currentTopology,
            requireFocus: requireFocus,
        )
        try validateInputHitTestAuthority(
            effect: effect,
            lease: lease,
        )
        try revalidateInputExecutionTargetSynchronousAuthority(
            lease,
            currentTopology: currentTopology,
            requireFocus: requireFocus,
        )
    }

    @MainActor
    private func requireInputPublishedApplicationAuthority(
        _ authority: InputExecutionTargetLease.ApplicationAuthority,
    ) async throws {
        switch authority {
        case let .production(frozen):
            guard await stateStore.applicationProcessGenerationLease(name: frozen.name) == frozen else {
                throw RPCError(
                    code: .notFound,
                    message: "Input target application generation was replaced",
                )
            }
        case let .legacyTestPID(name, pid):
            guard legacyPIDResourceNamesForTests,
                  (try? ParsingHelpers.parsePID(fromName: name)) == pid
            else {
                throw RPCError(
                    code: .notFound,
                    message: "Legacy test input target is unavailable",
                )
            }
        }
    }

    private func requireInputKernelAuthority(
        _ authority: InputExecutionTargetLease.ApplicationAuthority,
        system: SystemOperations,
    ) throws {
        if case let .production(frozen) = authority,
           !system.isApplicationProcessRunning(frozen.identity)
        {
            throw RPCError(
                code: .notFound,
                message: "Input target application generation was replaced",
            )
        }
    }

    @MainActor
    private func requireInputWindowBinding(
        application: InputExecutionTargetLease.ApplicationAuthority,
        frozen: WindowRegistry.WindowBinding,
    ) async throws {
        guard let current = await windowRegistry.resolveWindowBinding(
            resourceID: frozen.resourceID,
            applicationName: application.name,
            pid: application.pid,
            processIdentity: application.processIdentity,
        ), current.windowID == frozen.windowID,
        current.ownerPID == frozen.ownerPID,
        current.applicationName == frozen.applicationName,
        current.processIdentity == frozen.processIdentity
        else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Input target window binding was replaced",
            )
        }
    }

    @MainActor
    private func requireExactInputWindowAuthority(
        _ window: InputExecutionTargetLease.WindowAuthority,
    ) async throws -> (application: AnyObject, window: AXUIElement) {
        try await requireInputPublishedApplicationAuthority(window.application)
        try await requireInputWindowBinding(
            application: window.application,
            frozen: window.binding,
        )
        return try readExactInputWindowAuthority(window)
    }

    @MainActor
    private func readExactInputWindowAuthority(
        _ window: InputExecutionTargetLease.WindowAuthority,
    ) throws -> (application: AnyObject, window: AXUIElement) {
        let resolved = try resolveExactInputAXWindow(
            application: window.application,
            privateWindowID: window.privateWindowID,
        )
        guard CFEqual(resolved.window, window.retainedWindow.element),
              resolved.role == window.role,
              resolved.bounds == window.liveBounds
        else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Input target AX window identity or live geometry changed",
            )
        }
        return (resolved.application, resolved.window)
    }

    @MainActor
    private func resolveExactInputAXWindow(
        application: InputExecutionTargetLease.ApplicationAuthority,
        privateWindowID: CGWindowID,
    ) throws -> (
        application: AnyObject,
        window: AXUIElement,
        role: String,
        bounds: CGRect,
    ) {
        try requireInputKernelAuthority(application, system: system)
        guard let applicationElement = system.createAXApplication(pid: application.pid),
              CFGetTypeID(applicationElement as CFTypeRef) == AXUIElementGetTypeID()
        else {
            throw RPCError(code: .notFound, message: "Input target application is unavailable")
        }
        try requireInputKernelAuthority(application, system: system)
        let rawWindows = try readRequiredAXAttribute(
            element: applicationElement,
            attribute: kAXWindowsAttribute as String,
        )
        guard let windows = rawWindows as? [AXUIElement] else {
            throw RPCError(
                code: .unavailable,
                message: "Input target AX windows have an invalid value",
            )
        }
        var matches: [AXUIElement] = []
        for candidate in windows {
            let candidateIDRead = system.readAXWindowID(element: candidate as AnyObject)
            guard candidateIDRead.errorCode == AXError.success.rawValue else {
                throw rpcErrorForInputAXRead(
                    errorCode: candidateIDRead.errorCode,
                    operation: "input target AX window private identity",
                )
            }
            guard let candidateID = candidateIDRead.windowID else {
                throw RPCError(
                    code: .unavailable,
                    message: "Input target AX window private identity is unavailable",
                )
            }
            if candidateID == privateWindowID {
                matches.append(candidate)
            }
        }
        guard !matches.isEmpty else {
            throw RPCError(code: .notFound, message: "Exact input target AX window was not found")
        }
        guard matches.count == 1 else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Input target AX window private identity is ambiguous",
            )
        }
        let window = matches[0]
        guard let role = try readRequiredAXAttribute(
            element: window as AnyObject,
            attribute: kAXRoleAttribute as String,
        ) as? String, role == kAXWindowRole as String else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Input target AX element is not a window",
            )
        }
        let position = try readRequiredAXPoint(
            element: window as AnyObject,
            attribute: kAXPositionAttribute as String,
        )
        let size = try readRequiredAXSize(
            element: window as AnyObject,
            attribute: kAXSizeAttribute as String,
        )
        let bounds = CGRect(origin: position, size: size)
        guard position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              bounds.maxX.isFinite,
              bounds.maxY.isFinite
        else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Input target AX window has invalid live bounds",
            )
        }
        return (applicationElement, window, role, bounds)
    }

    @MainActor
    private func inputApplicationIsFrontmost(
        _ application: InputExecutionTargetLease.ApplicationAuthority,
    ) throws -> Bool {
        try requireInputKernelAuthority(application, system: system)
        guard let applicationElement = system.createAXApplication(pid: application.pid),
              CFGetTypeID(applicationElement as CFTypeRef) == AXUIElementGetTypeID()
        else {
            throw RPCError(code: .notFound, message: "Input target application is unavailable")
        }
        try requireInputKernelAuthority(application, system: system)
        return try readRequiredAXBool(
            element: applicationElement,
            attribute: kAXFrontmostAttribute as String,
        )
    }

    private func inputWindowHasExactFocus(
        applicationElement: AnyObject,
        window: InputExecutionTargetLease.WindowAuthority,
    ) throws -> Bool {
        let frontmost = try readRequiredAXBool(
            element: applicationElement,
            attribute: kAXFrontmostAttribute as String,
        )
        let focusedWindow = try readRequiredAXAttribute(
            element: applicationElement,
            attribute: kAXFocusedWindowAttribute as String,
        )
        let mainWindow = try readRequiredAXAttribute(
            element: applicationElement,
            attribute: kAXMainWindowAttribute as String,
        )
        guard CFGetTypeID(focusedWindow as CFTypeRef) == AXUIElementGetTypeID(),
              CFGetTypeID(mainWindow as CFTypeRef) == AXUIElementGetTypeID()
        else {
            throw RPCError(
                code: .unavailable,
                message: "Input target application focus identity is invalid",
            )
        }
        let retained = window.retainedWindow.element
        let focused = unsafeDowncast(focusedWindow as CFTypeRef, to: AXUIElement.self)
        let main = unsafeDowncast(mainWindow as CFTypeRef, to: AXUIElement.self)
        let focusedAttribute = try readRequiredAXBool(
            element: retained as AnyObject,
            attribute: kAXFocusedAttribute as String,
        )
        let mainAttribute = try readRequiredAXBool(
            element: retained as AnyObject,
            attribute: kAXMainAttribute as String,
        )
        return frontmost
            && CFEqual(focused, retained)
            && CFEqual(main, retained)
            && (focusedAttribute || mainAttribute)
    }

    @MainActor
    private func inputExecutionTargetHasExactFocus(
        _ lease: InputExecutionTargetLease,
        applicationElement: AnyObject,
    ) throws -> Bool {
        switch lease.owner {
        case let .application(application):
            try inputApplicationIsFrontmost(application)
        case let .window(window):
            try inputWindowHasExactFocus(
                applicationElement: applicationElement,
                window: window,
            )
        case .display, .desktop:
            true
        }
    }

    @MainActor
    private func validateInputHitTestAuthority(
        effect: ExactMac.InputPhysicalEffect,
        lease: InputExecutionTargetLease,
    ) throws {
        guard let point = effect.hitTestPoint else {
            return
        }
        let application: InputExecutionTargetLease.ApplicationAuthority
        let requiredWindow: InputExecutionTargetLease.WindowAuthority?
        switch lease.owner {
        case let .application(owner):
            application = owner
            requiredWindow = nil
        case let .window(window):
            application = window.application
            requiredWindow = window
        case .display, .desktop:
            return
        }
        try requireInputKernelAuthority(application, system: system)
        let hitRead = system.copyAXElementAtPosition(point)
        guard hitRead.errorCode == AXError.success.rawValue,
              let hitElement = hitRead.element,
              CFGetTypeID(hitElement as CFTypeRef) == AXUIElementGetTypeID()
        else {
            throw rpcErrorForInputAXRead(
                errorCode: hitRead.errorCode,
                operation: "system-wide hit testing",
            )
        }
        let hitPID = system.getAXElementPID(element: hitElement)
        guard hitPID.errorCode == AXError.success.rawValue else {
            throw rpcErrorForInputAXRead(
                errorCode: hitPID.errorCode,
                operation: "hit target process identity",
            )
        }
        guard let hitPIDValue = hitPID.pid else {
            throw RPCError(
                code: .unavailable,
                message: "Input hit target process identity is missing",
            )
        }
        guard hitPIDValue == application.pid else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Input hit target belongs to another application",
            )
        }
        if let requiredWindow {
            var current = unsafeDowncast(hitElement, to: AXUIElement.self)
            var visited = Set<SendableAXUIElement>()
            for depth in 0 ..< 64 {
                let wrapped = SendableAXUIElement(current)
                guard visited.insert(wrapped).inserted else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Input hit target ancestry contains a cycle",
                    )
                }
                if depth > 0 {
                    let currentPID = system.getAXElementPID(element: current as AnyObject)
                    guard currentPID.errorCode == AXError.success.rawValue else {
                        throw rpcErrorForInputAXRead(
                            errorCode: currentPID.errorCode,
                            operation: "hit target ancestry process identity",
                        )
                    }
                    guard let currentPIDValue = currentPID.pid else {
                        throw RPCError(
                            code: .unavailable,
                            message: "Input hit target ancestry process identity is missing",
                        )
                    }
                    guard currentPIDValue == application.pid else {
                        throw RPCError(
                            code: .failedPrecondition,
                            message: "Input hit target ancestry changed application owner",
                        )
                    }
                }
                if wrapped == requiredWindow.retainedWindow {
                    return
                }
                let parentRead = system.copyAXAttributeResult(
                    element: current as AnyObject,
                    attribute: kAXParentAttribute as String,
                )
                if parentRead.errorCode != AXError.success.rawValue {
                    if parentRead.errorCode == AXError.attributeUnsupported.rawValue
                        || parentRead.errorCode == AXError.noValue.rawValue
                    {
                        throw RPCError(
                            code: .failedPrecondition,
                            message: "Input hit target does not descend from the retained window",
                        )
                    }
                    throw rpcErrorForInputAXRead(
                        errorCode: parentRead.errorCode,
                        operation: "hit target ancestry",
                    )
                }
                guard let parent = parentRead.value,
                      CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID()
                else {
                    throw RPCError(
                        code: .unavailable,
                        message: "Input hit target ancestry has an invalid value",
                    )
                }
                current = unsafeDowncast(parent as CFTypeRef, to: AXUIElement.self)
            }
            throw RPCError(
                code: .failedPrecondition,
                message: "Input hit target ancestry exceeds the supported depth",
            )
        }
    }

    private func rpcErrorForInputAXRead(
        errorCode: Int32,
        operation: String,
    ) -> RPCError {
        let code: RPCError.Code = switch errorCode {
        case AXError.apiDisabled.rawValue:
            .permissionDenied
        case AXError.invalidUIElement.rawValue:
            .notFound
        default:
            .unavailable
        }
        return RPCError(code: code, message: "Accessibility \(operation) failed")
    }

    private func readRequiredAXAttribute(
        element: AnyObject,
        attribute: String,
    ) throws -> Any {
        let read = system.copyAXAttributeResult(
            element: element,
            attribute: attribute,
        )
        guard read.errorCode == AXError.success.rawValue else {
            throw rpcErrorForInputAXRead(
                errorCode: read.errorCode,
                operation: "attribute \(attribute) read",
            )
        }
        guard let value = read.value else {
            throw RPCError(
                code: .unavailable,
                message: "Accessibility attribute \(attribute) has an invalid value",
            )
        }
        return value
    }

    private func readRequiredAXPoint(
        element: AnyObject,
        attribute: String,
    ) throws -> CGPoint {
        let value = try readRequiredAXAttribute(
            element: element,
            attribute: attribute,
        )
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            throw RPCError(
                code: .unavailable,
                message: "Accessibility attribute \(attribute) has an invalid value",
            )
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            throw RPCError(
                code: .unavailable,
                message: "Accessibility attribute \(attribute) has an invalid value",
            )
        }
        return point
    }

    private func readRequiredAXSize(
        element: AnyObject,
        attribute: String,
    ) throws -> CGSize {
        let value = try readRequiredAXAttribute(
            element: element,
            attribute: attribute,
        )
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            throw RPCError(
                code: .unavailable,
                message: "Accessibility attribute \(attribute) has an invalid value",
            )
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw RPCError(
                code: .unavailable,
                message: "Accessibility attribute \(attribute) has an invalid value",
            )
        }
        return size
    }

    private func readRequiredAXBool(
        element: AnyObject,
        attribute: String,
    ) throws -> Bool {
        let value = try readRequiredAXAttribute(
            element: element,
            attribute: attribute,
        )
        guard let boolean = value as? Bool else {
            throw RPCError(
                code: .unavailable,
                message: "Accessibility attribute \(attribute) has an invalid value",
            )
        }
        return boolean
    }

    private func rpcErrorForInputAXMutation(
        errorCode: Int32,
        operation: String,
    ) -> RPCError {
        let code: RPCError.Code = switch errorCode {
        case AXError.apiDisabled.rawValue:
            .permissionDenied
        case AXError.invalidUIElement.rawValue:
            .notFound
        case AXError.actionUnsupported.rawValue, AXError.attributeUnsupported.rawValue:
            .failedPrecondition
        default:
            .unavailable
        }
        return RPCError(code: code, message: "Accessibility \(operation) failed")
    }

    private func inputExecutionFailureEvidence(
        _ error: any Error,
        expectedRoute: ExactMac.InputDeliveryRoute?,
        committedEvidence: (
            postedEventCount: Int,
            routedDeliveryObserved: Bool,
        )?,
    ) -> (
        underlying: any Error,
        postedEventCount: Int,
        routedDeliveryObserved: Bool,
        physicalEffectOccurred: Bool,
    ) {
        if let committedEvidence {
            return (
                error,
                max(1, committedEvidence.postedEventCount),
                committedEvidence.routedDeliveryObserved,
                true,
            )
        }
        if let failure = error as? ExactMac.InputExecutionFailure {
            let observedOnExpectedRoute = expectedRoute.map { $0 == failure.route } == true
                && failure.routedDeliveryObserved
            let count = max(
                observedOnExpectedRoute ? 1 : 0,
                max(0, failure.postedEventCount),
            )
            return (
                failure.underlying,
                count,
                observedOnExpectedRoute,
                failure.physicalEffectOccurred,
            )
        }
        return (error, 0, false, false)
    }

    private func mapInputExecutionError(_ error: any Error) -> any Error {
        if isInputCancellation(error) {
            return RPCError(code: .cancelled, message: "Input execution was cancelled")
        }
        if let coordError = error as? CoordinatorError {
            return RPCErrorHelpers.validationError(
                message: coordError.localizedDescription,
                reason: "INVALID_INPUT",
                field: "input.action",
            )
        }
        return error
    }

    private func exactApplicationGenerationError(
        _ error: any Error,
        expectedApplicationGeneration:
        AppStateStore.ApplicationProcessGenerationLease?,
    ) -> RPCError? {
        guard expectedApplicationGeneration != nil else { return nil }
        if error is ExactMac.InputProcessRouteRetired {
            return staleInputApplicationGenerationError()
        }
        if let rpcError = error as? RPCError, rpcError.code == .notFound {
            return staleInputApplicationGenerationError()
        }
        return nil
    }
}

// MARK: - Input delivery result helpers (file-private, shared across Input paths)

/// Builds an `InputDeliveryResult` proto from observed delivery evidence. Shared
/// by the `InputTransactionExecutor` LRO lifecycle and the element-path Input
/// resource publisher (C6) so both record delivery evidence consistently.
func inputDeliveryResult(
    commitment: Exactmac_V1_InputDeliveryResult.Commitment,
    postedEventCount: Int32 = 0,
    routedDeliveryObserved: Bool = false,
) -> Exactmac_V1_InputDeliveryResult {
    Exactmac_V1_InputDeliveryResult.with {
        $0.commitment = commitment
        $0.postedEventCount = postedEventCount
        $0.routedDeliveryObserved = routedDeliveryObserved
    }
}

/// Returns true for cancellation errors (Swift `CancellationError` or a gRPC
/// `.cancelled` code). Shared by the LRO and element-path input publishers.
func isInputCancellation(_ error: any Error) -> Bool {
    if error is CancellationError {
        return true
    }
    return (error as? RPCError)?.code == .cancelled
}

private func staleInputApplicationGenerationError() -> RPCError {
    RPCError(
        code: .notFound,
        message: "Application not found or process identity is stale",
    )
}

private func validateInputApplicationName(
    _ name: String,
    legacyPIDResourceNamesForTests: Bool,
) throws {
    if legacyPIDResourceNamesForTests {
        _ = try ParsingHelpers.parseApplicationName(name)
    } else {
        _ = try ParsingHelpers.parseOpaqueApplicationName(name)
    }
}

extension ExactMacService {
    func createInput(
        request: ServerRequest<Exactmac_V1_CreateInputRequest>,
        context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Input> {
        Self.logger.info("createInput called")
        let input = try await inputTransactionExecutor.execute(
            request.message,
            cancellation: context.cancellation,
        )
        return ServerResponse(message: input)
    }

    func getInput(request: ServerRequest<Exactmac_V1_GetInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Exactmac_V1_Input>
    {
        let req = request.message
        Self.logger.info("getInput called")
        let resource = try ParsingHelpers.parseInputName(req.name)
        if case let .application(name) = resource.owner {
            try validateInputApplicationName(
                name,
                legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            )
        }
        guard let input = await stateStore.getInput(name: req.name) else {
            throw RPCError(code: .notFound, message: "Input not found")
        }
        return ServerResponse(message: input)
    }

    func listInputs(request: ServerRequest<Exactmac_V1_ListInputsRequest>, context _: ServerContext)
        async throws -> ServerResponse<Exactmac_V1_ListInputsResponse>
    {
        let req = request.message
        Self.logger.info("listInputs called")
        guard !req.parent.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "parent is required")
        }
        if req.parent != "applications/-" {
            try validateInputApplicationName(
                req.parent,
                legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            )
        }
        let stateFilter = try parseInputStateFilter(req.filter)
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let skip = try RequestNumericValidation.skip(req.skip)
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListInputs",
            parameters: [
                ("parent", req.parent),
                ("filter_state", stateFilter.map { String($0.rawValue) } ?? ""),
            ],
        )
        let cursor = try ParsingHelpers.pageCursor(
            token: req.pageToken,
            skip: skip,
            queryBinding: queryBinding,
        )
        let allInputs = await stateStore.listInputs(parent: req.parent)
        let filteredInputs = if let stateFilter {
            allInputs.filter { $0.state == stateFilter }
        } else {
            allInputs
        }

        // Sort by name for deterministic ordering
        let sortedInputs = filteredInputs.sorted { $0.name < $1.name }

        let totalCount = sortedInputs.count
        let range = try ParsingHelpers.pageRange(
            cursor: cursor,
            pageSize: pageSize,
            totalCount: totalCount,
        )
        let pageInputs = Array(sortedInputs[range])
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: totalCount,
            queryBinding: queryBinding,
        )

        let response = Exactmac_V1_ListInputsResponse.with {
            $0.inputs = pageInputs
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    private func parseInputStateFilter(
        _ rawFilter: String,
    ) throws -> Exactmac_V1_Input.State? {
        switch rawFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "":
            return nil
        case "PENDING":
            return .pending
        case "EXECUTING":
            return .executing
        case "COMPLETED":
            return .completed
        case "FAILED":
            return .failed
        case "CANCELLED":
            return .cancelled
        default:
            throw RPCErrorHelpers.validationError(
                message: "filter must be PENDING, EXECUTING, COMPLETED, FAILED, or CANCELLED",
                reason: "INVALID_FILTER",
                field: "filter",
                value: rawFilter,
            )
        }
    }
}

private extension InputExecutionTargetLease {
    func validate(effect: ExactMac.InputPhysicalEffect) throws {
        let point: CGPoint? = switch effect {
        case let .mouseDown(point, _, _, _),
             let .mouseMove(point, _),
             let .mouseDrag(point, _, _),
             let .scroll(point, _, _, _),
             let .cursorWarp(point):
            point
        case .keyDown, .unicodeKeyDown, .cursorDisassociation:
            nil
        }
        if let point {
            try validate(point: point, index: 0)
        }
    }

    func validateProcessRoute(
        pid: pid_t,
        system: SystemOperations,
    ) throws {
        let expected: (pid: pid_t, identity: ApplicationProcessIdentity?)? =
            switch owner {
            case let .application(application):
                (application.pid, application.processIdentity)
            case let .window(window):
                (window.application.pid, window.application.processIdentity)
            case .display, .desktop:
                nil
            }
        guard let expected, expected.pid == pid else {
            throw ExactMac.InputProcessRouteRetired(pid: pid)
        }
        if let identity = expected.identity,
           !system.isApplicationProcessRunning(identity)
        {
            throw ExactMac.InputProcessRouteRetired(pid: pid)
        }
    }

    func validate(point: CGPoint, index: Int) throws {
        try validateInputPoint(
            point,
            index: index,
            owner: owner,
            topology: topology,
        )
    }
}

private func validateInputPoint(
    _ point: CGPoint,
    index: Int,
    owner: InputExecutionTargetLease.Owner,
    topology: [DisplayTopologyDisplay],
) throws {
    let displayOwners = topology.filter {
        $0.frame.containsHalfOpen(point)
    }
    guard displayOwners.count == 1 else {
        if displayOwners.count > 1 {
            throw RPCError(
                code: .failedPrecondition,
                message: "input action point[\(index)] belongs to multiple active displays",
            )
        }
        throw outsideInputTarget(index)
    }
    switch owner {
    case let .window(window):
        guard window.liveBounds.containsHalfOpen(point) else {
            throw outsideInputTarget(index)
        }
    case let .display(displayID):
        guard displayOwners[0].displayID == displayID else {
            throw outsideInputTarget(index)
        }
    case .application, .desktop:
        break
    }
}

private func outsideInputTarget(_ index: Int) -> RPCError {
    RPCError(
        code: .invalidArgument,
        message: "input action point[\(index)] is outside the exact target",
    )
}

private extension ExactMac.InputPhysicalEffect {
    var hitTestPoint: CGPoint? {
        switch self {
        case let .mouseDown(point, _, _, _),
             let .scroll(point, _, _, _):
            point
        case .keyDown, .unicodeKeyDown, .mouseMove, .mouseDrag,
             .cursorWarp, .cursorDisassociation:
            nil
        }
    }
}

private extension CGRect {
    func containsHalfOpen(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}
