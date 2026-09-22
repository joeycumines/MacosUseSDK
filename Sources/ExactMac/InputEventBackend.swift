import CoreGraphics
import Foundation

/// A fully specified input event prepared by the SDK before any global event
/// is posted. This surface is public so embedders can supply a non-posting
/// backend for permission checks, deterministic verification, or alternate
/// event delivery while retaining the SDK's pairing and cleanup guarantees.
public enum InputEvent: Equatable, Sendable {
    case keyDown(keyCode: CGKeyCode, flags: CGEventFlags)
    case keyUp(keyCode: CGKeyCode, flags: CGEventFlags)
    case unicodeKeyDown(text: String)
    case unicodeKeyUp(text: String)
    case mouseDown(
        point: CGPoint,
        button: CGMouseButton,
        modifiers: CGEventFlags,
        clickCount: Int64,
    )
    case mouseUp(
        point: CGPoint,
        button: CGMouseButton,
        modifiers: CGEventFlags,
        clickCount: Int64,
    )
    case mouseMove(point: CGPoint, modifiers: CGEventFlags)
    case mouseDrag(point: CGPoint, button: CGMouseButton, modifiers: CGEventFlags)
    case scroll(
        point: CGPoint?,
        horizontal: Int32,
        vertical: Int32,
        modifiers: CGEventFlags,
    )

    var isMouseDown: Bool {
        if case .mouseDown = self {
            return true
        }
        return false
    }

    func isMatchingMouseUp(for down: InputEvent) -> Bool {
        guard
            case let .mouseDown(_, downButton, downModifiers, downClickCount) = down,
            case let .mouseUp(_, upButton, upModifiers, upClickCount) = self
        else {
            return false
        }
        return downButton == upButton
            && downModifiers == upModifiers
            && downClickCount == upClickCount
    }

    var deliveryObligationKind: InputDeliveryObligationKind {
        switch self {
        case .keyUp, .unicodeKeyUp, .mouseUp:
            .safetyRelease
        case .keyDown, .unicodeKeyDown, .mouseDown, .mouseMove, .mouseDrag, .scroll:
            .ordinary
        }
    }
}

enum CoreGraphicsInputPostDestination: Equatable, Sendable {
    case hidSession
    case applicationSession
}

let coreGraphicsInputEventSourceState = CGEventSourceStateID.combinedSessionState

func coreGraphicsInputPostDestination(
    event: InputEvent,
    route _: InputDeliveryRoute,
) -> CoreGraphicsInputPostDestination {
    switch event {
    case .unicodeKeyDown, .unicodeKeyUp:
        .applicationSession
    case .keyDown, .keyUp, .mouseDown, .mouseUp, .mouseMove, .mouseDrag, .scroll:
        .hidSession
    }
}

enum InputPostInvocationEvidence: Equatable, Sendable {
    case unknown
    case notInvoked
    case invoked(count: Int)
}

enum PreparedInputEventOwnershipError: Error, Equatable {
    case concurrentInvocation
}

private final class InputPostInvocationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var evidence: InputPostInvocationEvidence
    private var activeInvocationID: UUID?
    private var firstInvocationTimeNanoseconds: UInt64?

    init(_ evidence: InputPostInvocationEvidence) {
        self.evidence = evidence
    }

    func recordInvocation(timestampNanoseconds: UInt64? = nil) {
        lock.withLock {
            switch evidence {
            case .unknown, .notInvoked:
                evidence = .invoked(count: 1)
            case let .invoked(count):
                evidence = .invoked(
                    count: count == Int.max ? Int.max : count + 1,
                )
            }
            if firstInvocationTimeNanoseconds == nil {
                firstInvocationTimeNanoseconds = timestampNanoseconds
            }
        }
    }

    func recordInvocationTimeIfInvoked(_ timestampNanoseconds: UInt64) {
        lock.withLock {
            guard firstInvocationTimeNanoseconds == nil,
                  case .invoked = evidence
            else {
                return
            }
            firstInvocationTimeNanoseconds = timestampNanoseconds
        }
    }

    func acquireInvocation() throws -> InputPostInvocationLease {
        let invocationID = UUID()
        try lock.withLock {
            guard activeInvocationID == nil else {
                throw PreparedInputEventOwnershipError.concurrentInvocation
            }
            activeInvocationID = invocationID
        }
        return InputPostInvocationLease(
            invocationID: invocationID,
            witness: self,
        )
    }

    fileprivate func releaseInvocation(_ invocationID: UUID) {
        lock.withLock {
            guard activeInvocationID == invocationID else {
                return
            }
            activeInvocationID = nil
        }
    }

    var snapshot: InputPostInvocationEvidence {
        lock.withLock { evidence }
    }

    var firstInvocationTime: UInt64? {
        lock.withLock { firstInvocationTimeNanoseconds }
    }
}

private final class InputPostInvocationLease: @unchecked Sendable {
    private let lock = NSLock()
    private let invocationID: UUID
    private weak var witness: InputPostInvocationWitness?
    private var released = false

    fileprivate init(
        invocationID: UUID,
        witness: InputPostInvocationWitness,
    ) {
        self.invocationID = invocationID
        self.witness = witness
    }

    func release() {
        let owner = lock.withLock {
            guard !released else {
                return nil as InputPostInvocationWitness?
            }
            released = true
            let witness = self.witness
            self.witness = nil
            return witness
        }
        owner?.releaseInvocation(invocationID)
    }

    deinit {
        release()
    }
}

public final class PreparedInputEvent: @unchecked Sendable {
    private let postOperation: () throws -> Void
    private let metadataPostOperation: ((UInt64, UInt64) throws -> Void)?
    private let invocationWitness: InputPostInvocationWitness
    let eventType: CGEventType?
    let sourceIdentity: InputEventSourceIdentity?
    let obligationID: UUID
    let obligationKind: InputDeliveryObligationKind
    let physicalEffect: InputPhysicalEffect?

    public init(
        event: InputEvent,
        postOperation: @escaping () throws -> Void,
    ) throws {
        if case .scroll(nil, _, _, _) = event {
            throw ExactMacError.inputInvalidArgument(
                "prepared scroll events require an exact cursor position",
            )
        }
        let invocationWitness = InputPostInvocationWitness(.unknown)
        self.invocationWitness = invocationWitness
        self.postOperation = {
            try postOperation()
            invocationWitness.recordInvocation()
        }
        metadataPostOperation = nil
        eventType = nil
        sourceIdentity = nil
        obligationID = UUID()
        obligationKind = event.deliveryObligationKind
        physicalEffect = event.physicalEffect
    }

    init(
        event: InputEvent,
        eventType: CGEventType,
        sourceIdentity: InputEventSourceIdentity,
        obligationKind: InputDeliveryObligationKind,
        postOperation: @escaping (
            UInt64,
            UInt64,
            @escaping @Sendable () -> Void,
        ) throws -> Void,
    ) {
        let invocationWitness = InputPostInvocationWitness(.notInvoked)
        self.invocationWitness = invocationWitness
        self.eventType = eventType
        self.sourceIdentity = sourceIdentity
        obligationID = UUID()
        self.obligationKind = obligationKind
        physicalEffect = event.physicalEffect
        let metadataOperation: (UInt64, UInt64) throws -> Void = {
            token,
            timestampNanoseconds in
            try postOperation(
                token,
                timestampNanoseconds,
                {
                    invocationWitness.recordInvocation(
                        timestampNanoseconds: timestampNanoseconds,
                    )
                },
            )
        }
        metadataPostOperation = metadataOperation
        self.postOperation = {
            var generator = SystemRandomNumberGenerator()
            var token = UInt64.random(in: UInt64.min ... UInt64.max, using: &generator)
            while token == 0 {
                token = UInt64.random(in: UInt64.min ... UInt64.max, using: &generator)
            }
            try metadataOperation(
                token,
                DispatchTime.now().uptimeNanoseconds,
            )
        }
    }

    var invocationEvidence: InputPostInvocationEvidence {
        invocationWitness.snapshot
    }

    fileprivate var firstInvocationTimeNanoseconds: UInt64? {
        invocationWitness.firstInvocationTime
    }

    public func post() throws {
        let invocation = try acquireInvocation()
        defer { invocation.release() }
        try invoke()
    }

    fileprivate func acquireInvocation() throws -> InputPostInvocationLease {
        try invocationWitness.acquireInvocation()
    }

    fileprivate func invoke() throws {
        try postOperation()
    }

    fileprivate func invoke(token: UInt64, timestampNanoseconds: UInt64) throws {
        guard let metadataPostOperation else {
            do {
                try postOperation()
            } catch {
                invocationWitness.recordInvocationTimeIfInvoked(
                    timestampNanoseconds,
                )
                throw error
            }
            invocationWitness.recordInvocationTimeIfInvoked(
                timestampNanoseconds,
            )
            return
        }
        try metadataPostOperation(token, timestampNanoseconds)
    }
}

public protocol InputEventBackend: Sendable {
    /// Verifies that the process may post global input without presenting a
    /// system permission prompt. This must complete before event preparation,
    /// cursor reads, cursor warps, or cursor-association changes.
    func checkPostAccess() throws
    /// Prepares an event without posting it. If this returns successfully, the
    /// production implementation can post later without another allocation.
    func prepare(_ event: InputEvent) throws -> PreparedInputEvent
    /// Invokes one prepared event and returns the monotonic timestamp assigned
    /// immediately before the posting call. Production observation backends
    /// override this to await exact routed acknowledgement.
    func post(_ event: PreparedInputEvent) async throws -> UInt64
    /// Posts a release event after normal delivery has failed. Production
    /// backends may recreate only the same frozen route observer here.
    func postForCleanup(_ event: PreparedInputEvent) async throws -> UInt64
    /// Waits between cleanup retries without inheriting caller cancellation.
    func pauseForCleanupRetry(nanoseconds: UInt64) async
    /// Returns a monotonic time base shared with `pause`.
    func monotonicTimeNanoseconds() -> UInt64
    func pause(nanoseconds: UInt64) async throws
    func cursorPosition() throws -> CGPoint
    func warpCursor(x: Double, y: Double) async throws
    func setCursorAssociated(_ associated: Bool) async throws
}

public extension InputEventBackend {
    func post(_ event: PreparedInputEvent) async throws -> UInt64 {
        let postTime = monotonicTimeNanoseconds()
        try event.post()
        return postTime
    }

    func postForCleanup(_ event: PreparedInputEvent) async throws -> UInt64 {
        try await post(event)
    }

    func pauseForCleanupRetry(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

final class CoreGraphicsInputEventBackend:
    InputEventBackend,
    InputCleanupObligationTracking,
    @unchecked Sendable
{
    private let source: CGEventSource
    private let route: InputDeliveryRoute
    private let deliveryObserver: (any InputDeliveryObserving)?
    private let cleanupObligationTracker: any InputCleanupObligationTracking
    private let postInvocationRecorder: (@Sendable () -> Void)?
    private let nonEventPhysicalEffectRecorder: (@Sendable () -> Void)?
    private let postAccessChecker: @Sendable () -> Bool
    private let cursorWarper: @Sendable (CGPoint) -> CGError
    private let cursorAssociationSetter: @Sendable (Bool) -> CGError
    private let executionBoundary: InputExecutionBoundary

    init(
        route: InputDeliveryRoute = .session,
        deliveryObserver: (any InputDeliveryObserving)? = nil,
        postInvocationRecorder: (@Sendable () -> Void)? = nil,
        nonEventPhysicalEffectRecorder: (@Sendable () -> Void)? = nil,
        executionBoundary: InputExecutionBoundary = .unrestricted,
        postAccessChecker: @escaping @Sendable () -> Bool = {
            CGPreflightPostEventAccess()
        },
        cursorWarper: @escaping @Sendable (CGPoint) -> CGError = {
            CGWarpMouseCursorPosition($0)
        },
        cursorAssociationSetter: @escaping @Sendable (Bool) -> CGError = {
            CGAssociateMouseAndMouseCursorPosition(boolean_t($0 ? 1 : 0))
        },
    ) throws {
        guard let source = CGEventSource(stateID: coreGraphicsInputEventSourceState) else {
            throw ExactMacError.inputSimulationFailed("failed to create event source")
        }
        self.source = source
        self.route = route
        self.deliveryObserver = deliveryObserver
        cleanupObligationTracker = deliveryObserver
            ?? InputDeliveryLedger(route: route)
        self.postInvocationRecorder = postInvocationRecorder
        self.nonEventPhysicalEffectRecorder = nonEventPhysicalEffectRecorder
        self.executionBoundary = executionBoundary
        self.postAccessChecker = postAccessChecker
        self.cursorWarper = cursorWarper
        self.cursorAssociationSetter = cursorAssociationSetter
    }

    func checkPostAccess() throws {
        guard postAccessChecker() else {
            throw ExactMacError.accessibilityDenied
        }
    }

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        if case .scroll(nil, _, _, _) = event {
            throw ExactMacError.inputInvalidArgument(
                "prepared scroll events require an exact cursor position",
            )
        }
        let cgEvent: CGEvent?
        switch event {
        case let .keyDown(keyCode, flags):
            cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true,
            )
            cgEvent?.flags = flags
        case let .keyUp(keyCode, flags):
            cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false,
            )
            cgEvent?.flags = flags
        case let .unicodeKeyDown(text):
            cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true,
            )
            try setUnicodeText(text, on: cgEvent)
        case let .unicodeKeyUp(text):
            cgEvent = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false,
            )
            try setUnicodeText(text, on: cgEvent)
        case let .mouseDown(point, button, modifiers, clickCount):
            cgEvent = try CGEvent(
                mouseEventSource: source,
                mouseType: mouseEventType(button: button, down: true),
                mouseCursorPosition: point,
                mouseButton: button,
            )
            cgEvent?.flags = modifiers
            cgEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        case let .mouseUp(point, button, modifiers, clickCount):
            cgEvent = try CGEvent(
                mouseEventSource: source,
                mouseType: mouseEventType(button: button, down: false),
                mouseCursorPosition: point,
                mouseButton: button,
            )
            cgEvent?.flags = modifiers
            cgEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        case let .mouseMove(point, modifiers):
            cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left,
            )
            cgEvent?.flags = modifiers
        case let .mouseDrag(point, button, modifiers):
            cgEvent = try CGEvent(
                mouseEventSource: source,
                mouseType: mouseDragEventType(button: button),
                mouseCursorPosition: point,
                mouseButton: button,
            )
            cgEvent?.flags = modifiers
        case let .scroll(point, horizontal, vertical, modifiers):
            cgEvent = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0,
            )
            if let point {
                cgEvent?.location = point
            }
            cgEvent?.flags = modifiers
        }

        guard let cgEvent else {
            throw ExactMacError.inputSimulationFailed("failed to prepare input event")
        }
        let sourceIdentity = InputEventSourceIdentity(
            unixProcessID: Int64(getpid()),
            userID: Int64(geteuid()),
            sourceStateID: Int64(coreGraphicsInputEventSourceState.rawValue),
        )
        let postDestination = coreGraphicsInputPostDestination(
            event: event,
            route: route,
        )
        return PreparedInputEvent(
            event: event,
            eventType: cgEvent.type,
            sourceIdentity: sourceIdentity,
            obligationKind: event.deliveryObligationKind,
        ) { [postDestination, postInvocationRecorder] token, timestampNanoseconds, recordInvocation in
            cgEvent.setIntegerValueField(
                .eventSourceUserData,
                value: Int64(bitPattern: token),
            )
            cgEvent.timestamp = CGEventTimestamp(timestampNanoseconds)
            recordInvocation()
            postInvocationRecorder?()
            switch postDestination {
            case .hidSession:
                // Virtual-key and pointer events enter at the HID-session
                // boundary so WindowServer performs its normal annotation,
                // routing, and pointer-state updates.
                cgEvent.post(tap: .cghidEventTap)
            case .applicationSession:
                // Physical input is dispatched by the authenticated
                // application session so WindowServer can route the supplied
                // Unicode payload to the frontmost application. Exact
                // process/window authority is established before the post and
                // observed at the process tap.
                cgEvent.post(tap: .cgSessionEventTap)
            }
        }
    }

    func post(_ event: PreparedInputEvent) async throws -> UInt64 {
        try await post(event, forCleanup: false)
    }

    func postForCleanup(_ event: PreparedInputEvent) async throws -> UInt64 {
        try await post(event, forCleanup: true)
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        cleanupObligationTracker.armCleanupObligation(kind)
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        cleanupObligationTracker.settleCleanupObligation(obligation)
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        cleanupObligationTracker.abandonCleanupObligation(obligation)
    }

    var outstandingCleanupObligationCount: Int {
        cleanupObligationTracker.outstandingCleanupObligationCount
    }

    private func post(
        _ event: PreparedInputEvent,
        forCleanup: Bool,
    ) async throws -> UInt64 {
        let invocation = try event.acquireInvocation()
        defer { invocation.release() }
        if forCleanup,
           let firstInvocationTime = event.firstInvocationTimeNanoseconds
        {
            return firstInvocationTime
        }
        do {
            return try await postOnOwnedRoute(
                event,
                forCleanup: forCleanup,
            )
        } catch let error as InputProcessRouteRetired {
            guard forCleanup else {
                throw error
            }
            return try invokeSessionGlobalCleanup(event)
        }
    }

    private func postOnOwnedRoute(
        _ event: PreparedInputEvent,
        forCleanup: Bool,
    ) async throws -> UInt64 {
        if forCleanup, let deliveryObserver {
            try validateProcessRoute()
            guard let eventType = event.eventType,
                  let sourceIdentity = event.sourceIdentity
            else {
                throw ExactMacError.inputSimulationFailed(
                    "prepared Core Graphics event is missing delivery identity",
                )
            }
            settledValidationLoop: while true {
                let attempt = InputDeliveryAttempt(
                    token: Self.randomNonzeroToken(),
                    obligationID: event.obligationID,
                    obligationKind: event.obligationKind,
                    eventType: eventType,
                    source: sourceIdentity,
                    route: route,
                    generation: deliveryObserver.generation,
                    postTimeNanoseconds: monotonicTimeNanoseconds(),
                )
                do {
                    if case let .alreadySettled(postTimeNanoseconds)? =
                        try deliveryObserver.validateSettledCleanupAttempt(attempt)
                    {
                        return postTimeNanoseconds
                    }
                    break settledValidationLoop
                } catch let error as InputDeliveryLedgerError {
                    if case .duplicateAttemptToken = error {
                        continue
                    }
                    throw error
                }
            }
            try await deliveryObserver.recoverForCleanup()
        }
        if !forCleanup {
            try Task.checkCancellation()
            if let deliveryObserver {
                try await deliveryObserver.validateForPosting()
            }
            if let effect = event.physicalEffect {
                try await executionBoundary.validateEffect(effect)
            }
            try Task.checkCancellation()
        }
        guard let deliveryObserver else {
            let postTime = monotonicTimeNanoseconds()
            try validateProcessRoute()
            try event.invoke(
                token: Self.randomNonzeroToken(),
                timestampNanoseconds: postTime,
            )
            return postTime
        }
        guard let eventType = event.eventType,
              let sourceIdentity = event.sourceIdentity
        else {
            throw ExactMacError.inputSimulationFailed(
                "prepared Core Graphics event is missing delivery identity",
            )
        }

        var attempt: InputDeliveryAttempt
        registrationLoop: while true {
            let postTime = monotonicTimeNanoseconds()
            attempt = InputDeliveryAttempt(
                token: Self.randomNonzeroToken(),
                obligationID: event.obligationID,
                obligationKind: event.obligationKind,
                eventType: eventType,
                source: sourceIdentity,
                route: route,
                generation: deliveryObserver.generation,
                postTimeNanoseconds: postTime,
            )
            do {
                try validateProcessRoute()
                switch try deliveryObserver.invokeAttempt(
                    attempt,
                    forCleanup: forCleanup,
                    invocation: {
                        try event.invoke(
                            token: attempt.token,
                            timestampNanoseconds: attempt
                                .postTimeNanoseconds,
                        )
                    },
                ) {
                case .admitted:
                    break registrationLoop
                case let .alreadySettled(postTimeNanoseconds):
                    return postTimeNanoseconds
                }
            } catch let error as InputDeliveryLedgerError {
                if case .duplicateAttemptToken = error {
                    continue
                }
                throw error
            }
        }

        if forCleanup {
            try await deliveryObserver.waitForObligation(
                event.obligationID,
            )
        } else {
            try await deliveryObserver.waitForAttempt(attempt.token)
        }
        return deliveryObserver.settledPostTime(for: event.obligationID)
            ?? attempt.postTimeNanoseconds
    }

    private func invokeSessionGlobalCleanup(
        _ event: PreparedInputEvent,
    ) throws -> UInt64 {
        guard event.obligationKind == .safetyRelease else {
            throw InputDeliveryLedgerError.cleanupObligationMismatch(
                event.obligationID,
            )
        }
        if let firstInvocationTime = event.firstInvocationTimeNanoseconds {
            return firstInvocationTime
        }

        let postTime = monotonicTimeNanoseconds()
        do {
            try event.invoke(
                token: Self.randomNonzeroToken(),
                timestampNanoseconds: postTime,
            )
        } catch {
            if let firstInvocationTime = event.firstInvocationTimeNanoseconds {
                return firstInvocationTime
            }
            throw error
        }
        return event.firstInvocationTimeNanoseconds ?? postTime
    }

    func pauseForCleanupRetry(nanoseconds: UInt64) async {
        guard let deliveryObserver else {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return
        }
        await deliveryObserver.waitForChangeOrDelay(
            nanoseconds: nanoseconds,
        )
    }

    func pause(nanoseconds: UInt64) async throws {
        guard let deliveryObserver else {
            try await Task.sleep(nanoseconds: nanoseconds)
            return
        }
        try await deliveryObserver.waitWhileHealthy(
            nanoseconds: nanoseconds,
        )
    }

    func monotonicTimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func cursorPosition() throws -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            throw ExactMacError.inputSimulationFailed("failed to read cursor position")
        }
        return event.location
    }

    func warpCursor(x: Double, y: Double) async throws {
        try await executionBoundary.validateEffect(
            .cursorWarp(point: CGPoint(x: x, y: y)),
        )
        try Task.checkCancellation()
        let result = cursorWarper(CGPoint(x: x, y: y))
        guard result == .success else {
            throw ExactMacError.inputSimulationFailed(
                "failed to warp cursor: CGError=\(result.rawValue)",
            )
        }
        nonEventPhysicalEffectRecorder?()
    }

    func setCursorAssociated(_ associated: Bool) async throws {
        if !associated {
            try await executionBoundary.validateEffect(
                .cursorDisassociation,
            )
            try Task.checkCancellation()
        }
        let result = cursorAssociationSetter(associated)
        guard result == .success else {
            throw ExactMacError.inputSimulationFailed(
                "failed to set cursor association: CGError=\(result.rawValue)",
            )
        }
        if !associated {
            nonEventPhysicalEffectRecorder?()
        }
    }

    private func validateProcessRoute() throws {
        guard case let .process(pid) = route else {
            return
        }
        try executionBoundary.validateProcessRoute(pid)
    }

    private func mouseEventType(button: CGMouseButton, down: Bool) throws -> CGEventType {
        switch (button, down) {
        case (.left, true):
            .leftMouseDown
        case (.left, false):
            .leftMouseUp
        case (.right, true):
            .rightMouseDown
        case (.right, false):
            .rightMouseUp
        case (.center, true):
            .otherMouseDown
        case (.center, false):
            .otherMouseUp
        default:
            throw ExactMacError.inputInvalidArgument(
                "unsupported mouse button \(button.rawValue)",
            )
        }
    }

    private func setUnicodeText(_ text: String, on event: CGEvent?) throws {
        guard let event else {
            throw ExactMacError.inputSimulationFailed("failed to prepare Unicode keyboard event")
        }
        let codeUnits = Array(text.utf16)
        codeUnits.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress,
            )
        }
    }

    private func mouseDragEventType(button: CGMouseButton) throws -> CGEventType {
        switch button {
        case .left:
            .leftMouseDragged
        case .right:
            .rightMouseDragged
        case .center:
            .otherMouseDragged
        default:
            throw ExactMacError.inputInvalidArgument(
                "unsupported mouse button \(button.rawValue)",
            )
        }
    }

    private static func randomNonzeroToken() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        var token = UInt64.random(in: UInt64.min ... UInt64.max, using: &generator)
        while token == 0 {
            token = UInt64.random(in: UInt64.min ... UInt64.max, using: &generator)
        }
        return token
    }
}
