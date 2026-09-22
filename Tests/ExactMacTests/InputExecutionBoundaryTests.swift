import CoreGraphics
@testable import ExactMac
import Foundation
import XCTest

@MainActor
final class InputExecutionBoundaryTests: XCTestCase {
    private let firstPoint = CGPoint(x: 10, y: 20)
    private let secondPoint = CGPoint(x: 30, y: 40)
    private let thirdPoint = CGPoint(x: 50, y: 60)

    func testEveryInputActionProducesItsExactSemanticEffectSequence() async throws {
        for actionCase in actionCases() {
            let backend = BoundaryRecordingInputBackend(
                route: .session,
                cursorPosition: .zero,
            )

            try await executeInputAction(
                actionCase.action,
                backend: backend,
            )

            XCTAssertEqual(
                backend.effectAttempts,
                actionCase.expectedEffects,
                actionCase.label,
            )
            XCTAssertEqual(
                backend.postedEvents.count,
                actionCase.action.expectedPostedEventCount,
                actionCase.label,
            )
            XCTAssertEqual(
                backend.outstandingCleanupObligationCount,
                0,
                actionCase.label,
            )
        }
    }

    func testRejectingEachSemanticEffectStopsThatEffectAndAllLaterEffects() async throws {
        for actionCase in actionCases() {
            for rejectedIndex in actionCase.expectedEffects.indices {
                let probe = InputExecutionBoundaryProbe(
                    rejectedEffectIndex: rejectedIndex,
                )
                let backend = BoundaryRecordingInputBackend(
                    route: .session,
                    cursorPosition: .zero,
                    probe: probe,
                )

                do {
                    try await executeInputAction(
                        actionCase.action,
                        backend: backend,
                    )
                    XCTFail(
                        "Expected \(actionCase.label) effect[\(rejectedIndex)] rejection",
                    )
                } catch let error as InputExecutionBoundaryTestError {
                    XCTAssertEqual(error, .rejectedEffect(rejectedIndex))
                }

                XCTAssertEqual(
                    backend.effectAttempts,
                    Array(actionCase.expectedEffects.prefix(rejectedIndex + 1)),
                    "\(actionCase.label) effect[\(rejectedIndex)]",
                )
                XCTAssertEqual(
                    backend.outstandingCleanupObligationCount,
                    0,
                    "\(actionCase.label) effect[\(rejectedIndex)]",
                )
            }
        }
    }

    func testCleanupEffectsBypassRevokedSemanticAuthority() async throws {
        let probe = InputExecutionBoundaryProbe(
            revokeAfterSuccessfulEffectCount: 1,
        )
        let backend = BoundaryRecordingInputBackend(
            route: .process(4242),
            probe: probe,
        )

        try await executeInputAction(
            .pressKeyCode(keyCode: KEY_RETURN, flags: .maskCommand),
            backend: backend,
        )

        XCTAssertEqual(
            backend.effectAttempts,
            [.keyDown(keyCode: KEY_RETURN, flags: .maskCommand)],
        )
        XCTAssertEqual(
            backend.postedEvents,
            [
                .keyDown(keyCode: KEY_RETURN, flags: .maskCommand),
                .keyUp(keyCode: KEY_RETURN, flags: .maskCommand),
            ],
        )
        XCTAssertEqual(probe.processRouteValidationCount, 2)
        XCTAssertEqual(backend.outstandingCleanupObligationCount, 0)
    }

    func testDragCleanupReleasesAndReassociatesAfterSemanticAuthorityLoss() async throws {
        let probe = InputExecutionBoundaryProbe(
            rejectedEffectIndex: 3,
        )
        let backend = BoundaryRecordingInputBackend(
            route: .process(4242),
            probe: probe,
        )

        do {
            try await executeInputAction(
                .dragPath(
                    points: [firstPoint, secondPoint, thirdPoint],
                    button: .left,
                    duration: 0,
                    modifiers: .maskShift,
                ),
                backend: backend,
            )
            XCTFail("Expected second waypoint warp rejection")
        } catch let error as InputExecutionBoundaryTestError {
            XCTAssertEqual(error, .rejectedEffect(3))
        }

        XCTAssertEqual(
            backend.effectAttempts,
            [
                .cursorWarp(point: firstPoint),
                .cursorDisassociation,
                .mouseDown(
                    point: firstPoint,
                    button: .left,
                    modifiers: .maskShift,
                    clickCount: 1,
                ),
                .cursorWarp(point: secondPoint),
            ],
        )
        XCTAssertEqual(
            backend.postedEvents,
            [
                .mouseDown(
                    point: firstPoint,
                    button: .left,
                    modifiers: .maskShift,
                    clickCount: 1,
                ),
                .mouseUp(
                    point: firstPoint,
                    button: .left,
                    modifiers: .maskShift,
                    clickCount: 1,
                ),
            ],
        )
        XCTAssertEqual(backend.cursorAssociations, [false, true])
        XCTAssertEqual(backend.outstandingCleanupObligationCount, 0)
    }

    func testPermanentProcessRouteRetirementStopsReleaseWithoutRetrying() async throws {
        let probe = InputExecutionBoundaryProbe(
            retiredProcessRouteValidationIndex: 1,
        )
        let backend = BoundaryRecordingInputBackend(
            route: .process(4242),
            probe: probe,
        )

        do {
            try await executeInputAction(
                .pressKeyCode(keyCode: KEY_RETURN, flags: []),
                backend: backend,
            )
            XCTFail("Expected permanent process-route retirement")
        } catch let error as InputProcessRouteRetired {
            XCTAssertEqual(error, InputProcessRouteRetired(pid: 4242))
        }

        XCTAssertEqual(
            backend.postedEvents,
            [.keyDown(keyCode: KEY_RETURN, flags: [])],
        )
        XCTAssertEqual(probe.processRouteValidationCount, 3)
        XCTAssertEqual(backend.cleanupPostAttempts, 1)
        XCTAssertEqual(backend.outstandingCleanupObligationCount, 0)
    }

    func testOmittedScrollCapturesCursorOnceDuringOwnedExecution() async throws {
        let cursor = CGPoint(x: 77, y: 88)
        let backend = BoundaryRecordingInputBackend(
            route: .session,
            cursorPosition: cursor,
        )

        try await executeInputAction(
            .scroll(
                at: nil,
                horizontal: 3,
                vertical: 0,
                duration: 1,
                modifiers: .maskControl,
            ),
            backend: backend,
        )

        XCTAssertEqual(backend.cursorReadCount, 1)
        XCTAssertEqual(
            backend.effectAttempts,
            [
                .scroll(
                    point: cursor,
                    horizontal: 1,
                    vertical: 0,
                    modifiers: .maskControl,
                ),
                .scroll(
                    point: cursor,
                    horizontal: 1,
                    vertical: 0,
                    modifiers: .maskControl,
                ),
                .scroll(
                    point: cursor,
                    horizontal: 1,
                    vertical: 0,
                    modifiers: .maskControl,
                ),
            ],
        )
    }

    func testCoreGraphicsBackendKeepsEffectAndRouteGuardAdjacentToSink() async throws {
        let trace = InputExecutionTrace()
        let boundary = InputExecutionBoundary(
            validateEffect: { effect in
                trace.append(.effect(effect))
            },
            validateProcessRoute: { pid in
                trace.append(.processGuard(pid))
            },
        )
        let backend = try CoreGraphicsInputEventBackend(
            route: .process(4242),
            executionBoundary: boundary,
            postAccessChecker: { true },
        )
        let event = try PreparedInputEvent(
            event: .keyDown(keyCode: KEY_RETURN, flags: []),
        ) {
            trace.append(.eventSink)
        }

        _ = try await backend.post(event)

        XCTAssertEqual(
            trace.snapshot,
            [
                .effect(.keyDown(keyCode: KEY_RETURN, flags: [])),
                .processGuard(4242),
                .eventSink,
            ],
        )
    }

    func testCoreGraphicsBackendRecordsSuccessfulCursorSinksExactly() async throws {
        let trace = InputExecutionTrace()
        let boundary = InputExecutionBoundary(
            validateEffect: { trace.append(.effect($0)) },
            validateProcessRoute: { _ in },
        )
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            nonEventPhysicalEffectRecorder: {
                trace.append(.nonEventPhysicalSink)
            },
            executionBoundary: boundary,
            postAccessChecker: { true },
            cursorWarper: { _ in .success },
            cursorAssociationSetter: { _ in .success },
        )

        try await backend.warpCursor(x: 10, y: 20)
        try await backend.setCursorAssociated(false)
        try await backend.setCursorAssociated(true)

        XCTAssertEqual(
            trace.snapshot,
            [
                .effect(.cursorWarp(point: CGPoint(x: 10, y: 20))),
                .nonEventPhysicalSink,
                .effect(.cursorDisassociation),
                .nonEventPhysicalSink,
            ],
        )
    }

    func testCoreGraphicsBackendRejectsScrollWithoutFrozenPosition() throws {
        let backend = try CoreGraphicsInputEventBackend(
            postAccessChecker: { true },
        )

        XCTAssertThrowsError(
            try backend.prepare(.scroll(
                point: nil,
                horizontal: 1,
                vertical: -1,
                modifiers: [],
            )),
        ) { error in
            guard let sdkError = error as? ExactMacError else {
                return XCTFail("Expected inputInvalidArgument, got \(error)")
            }
            switch sdkError {
            case let .internalError(message):
                XCTAssertEqual(
                    message,
                    "Input Argument Error: prepared scroll events require an exact cursor position",
                )
            default:
                XCTFail("Expected inputInvalidArgument, got \(error)")
            }
        }
    }

    func testSessionRouteNeverConsultsProcessGenerationGuard() async throws {
        let probe = InputExecutionBoundaryProbe()
        let backend = BoundaryRecordingInputBackend(
            route: .session,
            probe: probe,
        )

        try await executeInputAction(
            .click(point: firstPoint),
            backend: backend,
        )

        XCTAssertEqual(probe.processRouteValidationCount, 0)
    }

    private func actionCases() -> [InputExecutionBoundaryActionCase] {
        // The timed move warps the cursor to each intermediate waypoint before
        // posting the matching move event (InputController warps per step), so
        // the expected effect sequence interleaves cursorWarp + mouseMove for
        // each of the 20 steps.
        let timedMoveEffects = (1 ... 20).flatMap { step -> [InputPhysicalEffect] in
            let fraction = Double(step) / 20
            let waypoint = CGPoint(
                x: secondPoint.x * fraction,
                y: secondPoint.y * fraction,
            )
            return [
                .cursorWarp(point: waypoint),
                .mouseMove(point: waypoint, modifiers: .maskAlternate),
            ]
        }
        return [
            .init(
                label: "click",
                action: .click(point: firstPoint),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                    .mouseDown(
                        point: firstPoint,
                        button: .left,
                        modifiers: [],
                        clickCount: 1,
                    ),
                ],
            ),
            .init(
                label: "double-click",
                action: .doubleClick(point: firstPoint),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                    .mouseDown(
                        point: firstPoint,
                        button: .left,
                        modifiers: [],
                        clickCount: 1,
                    ),
                    .mouseDown(
                        point: firstPoint,
                        button: .left,
                        modifiers: [],
                        clickCount: 2,
                    ),
                ],
            ),
            .init(
                label: "right-click",
                action: .rightClick(point: firstPoint),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                    .mouseDown(
                        point: firstPoint,
                        button: .right,
                        modifiers: [],
                        clickCount: 1,
                    ),
                ],
            ),
            .init(
                label: "click-sequence",
                action: .clickSequence(
                    point: firstPoint,
                    button: .center,
                    clickCount: 3,
                    modifiers: .maskControl,
                ),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                ] + (1 ... 3).map {
                    .mouseDown(
                        point: firstPoint,
                        button: .center,
                        modifiers: .maskControl,
                        clickCount: Int64($0),
                    )
                },
            ),
            .init(
                label: "type",
                action: .type(text: "ab"),
                expectedEffects: [.unicodeKeyDown, .unicodeKeyDown],
            ),
            .init(
                label: "type-text",
                action: .typeText(text: "ab", charDelay: 0),
                expectedEffects: [.unicodeKeyDown, .unicodeKeyDown],
            ),
            .init(
                label: "named-press",
                action: .press(keyName: "return", flags: .maskCommand),
                expectedEffects: [
                    .keyDown(keyCode: KEY_RETURN, flags: .maskCommand),
                ],
            ),
            .init(
                label: "named-hold",
                action: .pressHold(
                    keyName: "return",
                    flags: .maskShift,
                    duration: 0,
                ),
                expectedEffects: [
                    .keyDown(keyCode: KEY_RETURN, flags: .maskShift),
                ],
            ),
            .init(
                label: "resolved-press",
                action: .pressKeyCode(keyCode: 12, flags: .maskCommand),
                expectedEffects: [
                    .keyDown(keyCode: 12, flags: .maskCommand),
                ],
            ),
            .init(
                label: "resolved-hold",
                action: .pressKeyCodeHold(
                    keyCode: 13,
                    flags: .maskShift,
                    duration: 0,
                ),
                expectedEffects: [
                    .keyDown(keyCode: 13, flags: .maskShift),
                ],
            ),
            .init(
                label: "move",
                action: .move(to: firstPoint),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                    .mouseMove(point: firstPoint, modifiers: []),
                ],
            ),
            .init(
                label: "timed-move",
                action: .movePointer(
                    to: secondPoint,
                    duration: 1,
                    modifiers: .maskAlternate,
                ),
                expectedEffects: timedMoveEffects,
            ),
            .init(
                label: "drag",
                action: .drag(
                    from: firstPoint,
                    to: secondPoint,
                    button: .left,
                    duration: 0,
                ),
                expectedEffects: dragEffects(
                    points: [firstPoint, secondPoint],
                    button: .left,
                    modifiers: [],
                ),
            ),
            .init(
                label: "drag-path",
                action: .dragPath(
                    points: [firstPoint, secondPoint, thirdPoint],
                    button: .right,
                    duration: 0,
                    modifiers: .maskShift,
                ),
                expectedEffects: dragEffects(
                    points: [firstPoint, secondPoint, thirdPoint],
                    button: .right,
                    modifiers: .maskShift,
                ),
            ),
            .init(
                label: "scroll",
                action: .scroll(
                    at: firstPoint,
                    horizontal: 3,
                    vertical: 0,
                    duration: 1,
                    modifiers: .maskControl,
                ),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                ] + (0 ..< 3).map { _ in
                    .scroll(
                        point: firstPoint,
                        horizontal: 1,
                        vertical: 0,
                        modifiers: .maskControl,
                    )
                },
            ),
            .init(
                label: "hover",
                action: .hover(at: firstPoint, duration: 1),
                expectedEffects: [
                    .cursorWarp(point: firstPoint),
                    .mouseMove(point: firstPoint, modifiers: []),
                ],
            ),
        ]
    }

    private func dragEffects(
        points: [CGPoint],
        button: CGMouseButton,
        modifiers: CGEventFlags,
    ) -> [InputPhysicalEffect] {
        var effects: [InputPhysicalEffect] = [
            .cursorWarp(point: points[0]),
            .cursorDisassociation,
            .mouseDown(
                point: points[0],
                button: button,
                modifiers: modifiers,
                clickCount: 1,
            ),
        ]
        for point in points.dropFirst() {
            effects.append(.cursorWarp(point: point))
            effects.append(
                .mouseDrag(
                    point: point,
                    button: button,
                    modifiers: modifiers,
                ),
            )
        }
        return effects
    }
}

private struct InputExecutionBoundaryActionCase {
    let label: String
    let action: InputAction
    let expectedEffects: [InputPhysicalEffect]
}

private enum InputExecutionBoundaryTestError: Error, Equatable {
    case rejectedEffect(Int)
}

private final class InputExecutionBoundaryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let rejectedEffectIndex: Int?
    private let revokeAfterSuccessfulEffectCount: Int?
    private let retiredProcessRouteValidationIndex: Int?
    private var effects: [InputPhysicalEffect] = []
    private var processRouteValidations = 0
    private var revoked = false

    init(
        rejectedEffectIndex: Int? = nil,
        revokeAfterSuccessfulEffectCount: Int? = nil,
        retiredProcessRouteValidationIndex: Int? = nil,
    ) {
        self.rejectedEffectIndex = rejectedEffectIndex
        self.revokeAfterSuccessfulEffectCount = revokeAfterSuccessfulEffectCount
        self.retiredProcessRouteValidationIndex = retiredProcessRouteValidationIndex
    }

    lazy var boundary = InputExecutionBoundary(
        validateEffect: { [weak self] effect in
            guard let self else { return }
            try validate(effect)
        },
        validateProcessRoute: { [weak self] pid in
            guard let self else { return }
            try validateProcessRoute(pid)
        },
    )

    func validate(_ effect: InputPhysicalEffect) throws {
        let rejection: InputExecutionBoundaryTestError? = lock.withLock {
            let index = effects.count
            effects.append(effect)
            if revoked || rejectedEffectIndex == index {
                return .rejectedEffect(index)
            }
            if let revokeAfterSuccessfulEffectCount,
               effects.count == revokeAfterSuccessfulEffectCount
            {
                revoked = true
            }
            return nil
        }
        if let rejection {
            throw rejection
        }
    }

    func validateProcessRoute(_ pid: pid_t) throws {
        let retired = lock.withLock {
            let index = processRouteValidations
            processRouteValidations += 1
            return retiredProcessRouteValidationIndex.map { index >= $0 } == true
        }
        if retired {
            throw InputProcessRouteRetired(pid: pid)
        }
    }

    var effectAttempts: [InputPhysicalEffect] {
        lock.withLock { effects }
    }

    var processRouteValidationCount: Int {
        lock.withLock { processRouteValidations }
    }
}

private final class BoundaryRecordingInputBackend:
    InputEventBackend,
    InputCleanupObligationTracking,
    @unchecked Sendable
{
    private struct State {
        var postedEvents: [InputEvent] = []
        var cleanupPostAttempts = 0
        var cursorAssociations: [Bool] = []
        var cursorReadCount = 0
        var now: UInt64 = 1
        var cleanupObligations: Set<UUID> = []
    }

    private let lock = NSLock()
    private let route: InputDeliveryRoute
    private let initialCursorPosition: CGPoint
    private let probe: InputExecutionBoundaryProbe
    private var state = State()

    init(
        route: InputDeliveryRoute,
        cursorPosition: CGPoint = .zero,
        probe: InputExecutionBoundaryProbe = InputExecutionBoundaryProbe(),
    ) {
        self.route = route
        initialCursorPosition = cursorPosition
        self.probe = probe
    }

    func checkPostAccess() throws {}

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        try PreparedInputEvent(event: event) { [weak self] in
            self?.lock.withLock {
                self?.state.postedEvents.append(event)
            }
        }
    }

    func post(_ event: PreparedInputEvent) async throws -> UInt64 {
        try await validateAndPost(event)
    }

    func postForCleanup(_ event: PreparedInputEvent) async throws -> UInt64 {
        lock.withLock {
            state.cleanupPostAttempts += 1
        }
        return try await validateAndPost(event)
    }

    private func validateAndPost(
        _ event: PreparedInputEvent,
    ) async throws -> UInt64 {
        if let effect = event.physicalEffect {
            try await probe.boundary.validateEffect(effect)
        }
        if case let .process(pid) = route {
            try probe.boundary.validateProcessRoute(pid)
        }
        try event.post()
        return lock.withLock {
            let postTime = state.now
            state.now += 1
            return postTime
        }
    }

    func pauseForCleanupRetry(nanoseconds _: UInt64) async {}

    func monotonicTimeNanoseconds() -> UInt64 {
        lock.withLock { state.now }
    }

    func pause(nanoseconds: UInt64) async throws {
        lock.withLock {
            state.now += nanoseconds
        }
    }

    func cursorPosition() throws -> CGPoint {
        lock.withLock {
            state.cursorReadCount += 1
        }
        return initialCursorPosition
    }

    func warpCursor(x: Double, y: Double) async throws {
        try await probe.boundary.validateEffect(
            .cursorWarp(point: CGPoint(x: x, y: y)),
        )
    }

    func setCursorAssociated(_ associated: Bool) async throws {
        if !associated {
            try await probe.boundary.validateEffect(.cursorDisassociation)
        }
        lock.withLock {
            state.cursorAssociations.append(associated)
        }
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        let obligation = InputCleanupObligation(id: UUID(), kind: kind)
        lock.withLock {
            state.cleanupObligations.insert(obligation.id)
        }
        return obligation
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        lock.withLock {
            state.cleanupObligations.remove(obligation.id)
        }
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        lock.withLock {
            state.cleanupObligations.remove(obligation.id)
        }
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock { state.cleanupObligations.count }
    }

    var effectAttempts: [InputPhysicalEffect] {
        probe.effectAttempts
    }

    var postedEvents: [InputEvent] {
        lock.withLock { state.postedEvents }
    }

    var cleanupPostAttempts: Int {
        lock.withLock { state.cleanupPostAttempts }
    }

    var cursorAssociations: [Bool] {
        lock.withLock { state.cursorAssociations }
    }

    var cursorReadCount: Int {
        lock.withLock { state.cursorReadCount }
    }
}

private final class InputExecutionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [InputExecutionTraceEntry] = []

    func append(_ entry: InputExecutionTraceEntry) {
        lock.withLock {
            entries.append(entry)
        }
    }

    var snapshot: [InputExecutionTraceEntry] {
        lock.withLock { entries }
    }
}

private enum InputExecutionTraceEntry: Equatable {
    case effect(InputPhysicalEffect)
    case processGuard(pid_t)
    case eventSink
    case nonEventPhysicalSink
}
