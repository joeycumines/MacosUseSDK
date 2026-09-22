import CoreGraphics
@testable import ExactMac
import XCTest

final class InputEventSafetyTests: XCTestCase {
    func testCoreGraphicsPostingUsesEventAppropriateAuthenticatedSessionBoundary() {
        XCTAssertEqual(
            coreGraphicsInputEventSourceState,
            .combinedSessionState,
        )
        let pid: pid_t = 73201
        XCTAssertEqual(
            coreGraphicsInputPostDestination(
                event: .unicodeKeyDown(text: "λ"),
                route: .process(pid),
            ),
            .applicationSession,
        )
        XCTAssertEqual(
            coreGraphicsInputPostDestination(
                event: .unicodeKeyUp(text: "λ"),
                route: .process(pid),
            ),
            .applicationSession,
        )
        XCTAssertEqual(
            coreGraphicsInputPostDestination(
                event: .unicodeKeyDown(text: "λ"),
                route: .session,
            ),
            .applicationSession,
        )

        let sessionEvents: [InputEvent] = [
            .keyDown(keyCode: KEY_RETURN, flags: []),
            .keyUp(keyCode: KEY_RETURN, flags: []),
            .mouseDown(
                point: CGPoint(x: 10, y: 20),
                button: .left,
                modifiers: [],
                clickCount: 1,
            ),
            .mouseUp(
                point: CGPoint(x: 10, y: 20),
                button: .left,
                modifiers: [],
                clickCount: 1,
            ),
            .mouseMove(point: CGPoint(x: 10, y: 20), modifiers: []),
            .mouseDrag(point: CGPoint(x: 10, y: 20), button: .left, modifiers: []),
            .scroll(
                point: CGPoint(x: 10, y: 20),
                horizontal: 1,
                vertical: 2,
                modifiers: [],
            ),
        ]
        for event in sessionEvents {
            XCTAssertEqual(
                coreGraphicsInputPostDestination(event: event, route: .process(pid)),
                .hidSession,
                "\(event) must retain HID-session WindowServer semantics",
            )
        }
    }

    func testAlreadyCancelledTaskPostsNoInputEvent() async throws {
        let backend = RecordingInputEventBackend()
        let task = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await pressKey(keyCode: KEY_RETURN, backend: backend)
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(backend.snapshot().events.isEmpty)
    }

    func testCancelledKeyPressReleasesSuccessfulDown() async throws {
        let backend = RecordingInputEventBackend(blockingPause: true)
        let task = Task {
            try await pressKey(keyCode: KEY_RETURN, flags: .maskCommand, backend: backend)
        }
        try await waitForEventCount(backend, count: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            backend.snapshot().events,
            [
                .keyDown(keyCode: KEY_RETURN, flags: .maskCommand),
                .keyUp(keyCode: KEY_RETURN, flags: .maskCommand),
            ],
        )
        XCTAssertEqual(
            backend.snapshot().outstandingCleanupObligationCount,
            0,
        )
    }

    func testPairedMouseOperationsReleaseAfterEveryInjectedPauseFailure() async throws {
        let operations: [(String, (RecordingInputEventBackend) async throws -> Void)] = [
            ("left", { try await clickMouse(at: CGPoint(x: 10, y: 20), backend: $0) }),
            ("double", { try await doubleClickMouse(at: CGPoint(x: 10, y: 20), backend: $0) }),
            ("right", { try await rightClickMouse(at: CGPoint(x: 10, y: 20), backend: $0) }),
        ]

        for (name, operation) in operations {
            let backend = RecordingInputEventBackend(failingPause: 1)
            do {
                try await operation(backend)
                XCTFail("Expected injected \(name) pause failure")
            } catch is InjectedInputEventError {
                // Expected.
            }
            let events = backend.snapshot().events
            XCTAssertEqual(events.count, 2, name)
            XCTAssertTrue(events[0].isMouseDown, name)
            XCTAssertTrue(events[1].isMatchingMouseUp(for: events[0]), name)
        }
    }

    func testMatchingKeyUpIsRetriedOutsideCancellationAfterPostFailure() async throws {
        let backend = RecordingInputEventBackend(failingPosts: [2])
        do {
            try await pressKey(keyCode: KEY_ESCAPE, flags: .maskShift, backend: backend)
            XCTFail("Expected injected key-up failure")
        } catch is InjectedInputEventError {
            // Expected.
        }
        XCTAssertEqual(
            backend.snapshot().events,
            [
                .keyDown(keyCode: KEY_ESCAPE, flags: .maskShift),
                .keyUp(keyCode: KEY_ESCAPE, flags: .maskShift),
            ],
        )
    }

    func testCommittedKeyDownThatThrowsIsStillReleased() async throws {
        let backend = RecordingInputEventBackend(commitThenFailingPosts: [1])
        do {
            try await pressKey(keyCode: KEY_ESCAPE, flags: .maskShift, backend: backend)
            XCTFail("Expected injected key-down failure after commit")
        } catch is InjectedInputEventError {
            // Expected.
        }
        XCTAssertEqual(
            backend.snapshot().events,
            [
                .keyDown(keyCode: KEY_ESCAPE, flags: .maskShift),
                .keyUp(keyCode: KEY_ESCAPE, flags: .maskShift),
            ],
        )
    }

    func testKeyHoldFailureReleasesSuccessfulDown() async throws {
        let backend = RecordingInputEventBackend(failingPause: 1)
        do {
            try await pressKeyHold(
                keyCode: KEY_SPACE,
                flags: .maskAlternate,
                duration: 1,
                backend: backend,
            )
            XCTFail("Expected injected hold failure")
        } catch is InjectedInputEventError {
            // Expected.
        }
        XCTAssertEqual(
            backend.snapshot().events,
            [
                .keyDown(keyCode: KEY_SPACE, flags: .maskAlternate),
                .keyUp(keyCode: KEY_SPACE, flags: .maskAlternate),
            ],
        )
    }

    func testDragCancellationReleasesButtonAndReassociatesCursor() async throws {
        let backend = RecordingInputEventBackend(blockingPauseAfter: 2)
        let task = Task {
            try await performDrag(
                from: CGPoint(x: 10, y: 20),
                to: CGPoint(x: 110, y: 120),
                button: .left,
                duration: 1,
                backend: backend,
            )
        }
        try await waitForEventCount(backend, count: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected drag cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.cursorAssociations, [false, true])
        XCTAssertTrue(snapshot.events[0].isMouseDown)
        XCTAssertTrue(snapshot.events.last?.isMatchingMouseUp(for: snapshot.events[0]) == true)
        XCTAssertEqual(snapshot.outstandingCleanupObligationCount, 0)
    }

    func testDragReleasesAndReassociatesAfterEveryPauseFailure() async throws {
        for failingPause in 1 ... 3 {
            let backend = RecordingInputEventBackend(failingPause: failingPause)
            do {
                try await performDrag(
                    from: CGPoint(x: 10, y: 20),
                    to: CGPoint(x: 110, y: 120),
                    duration: 1,
                    backend: backend,
                )
                XCTFail("Expected injected drag pause failure \(failingPause)")
            } catch is InjectedInputEventError {
                // Expected.
            }
            assertDragCleanup(backend.snapshot(), label: "pause \(failingPause)")
        }
    }

    func testDragReleasesAndReassociatesAfterEveryPostFailure() async throws {
        for failingPost in 1 ... 3 {
            let backend = RecordingInputEventBackend(failingPosts: [failingPost])
            do {
                try await performDrag(
                    from: CGPoint(x: 10, y: 20),
                    to: CGPoint(x: 110, y: 120),
                    duration: 1,
                    backend: backend,
                )
                XCTFail("Expected injected drag post failure \(failingPost)")
            } catch is InjectedInputEventError {
                // Expected.
            }
            assertDragCleanup(backend.snapshot(), label: "post \(failingPost)")
        }
    }

    func testCommittedDragDownThatThrowsIsReleasedAndCursorIsReassociated() async throws {
        let backend = RecordingInputEventBackend(commitThenFailingPosts: [1])
        do {
            try await performDrag(
                from: CGPoint(x: 10, y: 20),
                to: CGPoint(x: 110, y: 120),
                duration: 1,
                backend: backend,
            )
            XCTFail("Expected injected drag-down failure after commit")
        } catch is InjectedInputEventError {
            // Expected.
        }
        assertDragCleanup(backend.snapshot(), label: "committed drag down")
    }

    func testCommittedCursorDetachThatThrowsIsReassociated() async throws {
        let backend = RecordingInputEventBackend(commitThenFailingCursorAssociations: [1])
        do {
            try await performDrag(
                from: CGPoint(x: 10, y: 20),
                to: CGPoint(x: 110, y: 120),
                duration: 1,
                backend: backend,
            )
            XCTFail("Expected injected cursor-detach failure after commit")
        } catch is InjectedInputEventError {
            // Expected.
        }
        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.events, [])
        XCTAssertEqual(snapshot.cursorAssociations, [false, true])
    }

    func testAtomicClickSequencePreservesButtonCountAndModifiers() async throws {
        for button in [CGMouseButton.left, .right, .center] {
            let backend = RecordingInputEventBackend()
            try await clickMouse(
                at: CGPoint(x: 10, y: 20),
                button: button,
                clickCount: 3,
                modifiers: [.maskCommand, .maskShift],
                backend: backend,
            )
            let snapshot = backend.snapshot()
            let events = snapshot.events
            XCTAssertEqual(snapshot.pointerOperations.first, .warp(CGPoint(x: 10, y: 20)))
            XCTAssertEqual(events.count, 6)
            for clickIndex in 1 ... 3 {
                XCTAssertEqual(events[(clickIndex - 1) * 2], .mouseDown(
                    point: CGPoint(x: 10, y: 20),
                    button: button,
                    modifiers: [.maskCommand, .maskShift],
                    clickCount: Int64(clickIndex),
                ))
                XCTAssertEqual(events[((clickIndex - 1) * 2) + 1], .mouseUp(
                    point: CGPoint(x: 10, y: 20),
                    button: button,
                    modifiers: [.maskCommand, .maskShift],
                    clickCount: Int64(clickIndex),
                ))
            }
        }
    }

    func testInstantMoveWarpsBeforePostingTheMatchingMovement() async throws {
        let point = CGPoint(x: 30, y: 40)
        let backend = RecordingInputEventBackend()
        try await moveMouse(to: point, modifiers: .maskShift, backend: backend)

        XCTAssertEqual(backend.snapshot().pointerOperations, [
            .warp(point),
            .post(.mouseMove(point: point, modifiers: .maskShift)),
        ])
    }

    func testUnicodeTextUsesPairedEventsAndCharacterDelay() async throws {
        let backend = RecordingInputEventBackend()
        try await writeText("A🙂", characterDelay: 0.25, backend: backend)
        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.events, [
            .unicodeKeyDown(text: "A"),
            .unicodeKeyUp(text: "A"),
            .unicodeKeyDown(text: "🙂"),
            .unicodeKeyUp(text: "🙂"),
        ])
        XCTAssertTrue(snapshot.pauses.contains(250_000_000))
    }

    func testPhysicalUnicodePasteAwaitsConsumptionBeforeRestagingNextGrapheme() async throws {
        let backend = RecordingInputEventBackend()
        let steps = TextPasteRecorder()
        try await writeTextByPasting(
            "A🙂",
            characterDelay: 0.25,
            pasteKeyCode: 9,
            preparePasteboardText: { text in
                await steps.stage(text)
            },
            awaitPasteboardConsumption: {
                try await steps.consumeCurrent()
            },
            backend: backend,
        )

        let recordedSteps = await steps.snapshot()
        XCTAssertEqual(recordedSteps, [
            .stage("A"),
            .consume("A"),
            .stage("🙂"),
            .consume("🙂"),
        ])
        XCTAssertEqual(backend.snapshot().events, [
            .keyDown(keyCode: 9, flags: .maskCommand),
            .keyUp(keyCode: 9, flags: .maskCommand),
            .keyDown(keyCode: 9, flags: .maskCommand),
            .keyUp(keyCode: 9, flags: .maskCommand),
        ])
        XCTAssertTrue(backend.snapshot().pauses.contains(250_000_000))
        XCTAssertEqual(backend.snapshot().outstandingCleanupObligationCount, 0)
    }

    func testCancelledUnicodeTextReleasesPostedDown() async throws {
        let backend = RecordingInputEventBackend(blockingPause: true)
        let task = Task {
            try await writeText("abc", backend: backend)
        }
        try await waitForEventCount(backend, count: 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(backend.snapshot().events, [
            .unicodeKeyDown(text: "a"),
            .unicodeKeyUp(text: "a"),
        ])
    }

    func testScrollPreservesTotalsPositionAndModifiers() async throws {
        let backend = RecordingInputEventBackend()
        try await scrollMouse(
            at: CGPoint(x: 30, y: 40),
            horizontal: 3,
            vertical: -7,
            duration: 0.2,
            modifiers: .maskShift,
            backend: backend,
        )
        var horizontal: Int32 = 0
        var vertical: Int32 = 0
        for event in backend.snapshot().events {
            guard case let .scroll(point, stepHorizontal, stepVertical, modifiers) = event else {
                XCTFail("Expected only scroll events")
                continue
            }
            XCTAssertEqual(point, CGPoint(x: 30, y: 40))
            XCTAssertEqual(modifiers, .maskShift)
            horizontal += stepHorizontal
            vertical += stepVertical
        }
        XCTAssertEqual(horizontal, 3)
        XCTAssertEqual(vertical, -7)
        XCTAssertEqual(
            backend.snapshot().pointerOperations.first,
            .warp(CGPoint(x: 30, y: 40)),
        )
    }

    func testTimedMoveUsesObservedCursorAndPreservesModifiers() async throws {
        let backend = RecordingInputEventBackend(cursorPosition: CGPoint(x: 10, y: 20))
        try await moveMouse(
            to: CGPoint(x: 30, y: 60),
            duration: 1,
            modifiers: .maskControl,
            backend: backend,
        )
        let events = backend.snapshot().events
        XCTAssertEqual(events.count, 20)
        XCTAssertEqual(events.last, .mouseMove(
            point: CGPoint(x: 30, y: 60),
            modifiers: .maskControl,
        ))
        let pointerOperations = backend.snapshot().pointerOperations
        XCTAssertEqual(pointerOperations.count, 40)
        for index in stride(from: 0, to: pointerOperations.count, by: 2) {
            guard case let .warp(point) = pointerOperations[index],
                  case let .post(.mouseMove(eventPoint, modifiers)) = pointerOperations[index + 1]
            else {
                XCTFail("Expected each timed movement warp to precede its matching event")
                return
            }
            XCTAssertEqual(point, eventPoint)
            XCTAssertEqual(modifiers, .maskControl)
        }
    }

    func testHoverMovesThenWaitsForRequiredDuration() async throws {
        let backend = RecordingInputEventBackend()
        try await hoverMouse(
            at: CGPoint(x: 70, y: 80),
            duration: 0.5,
            backend: backend,
        )
        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.events, [
            .mouseMove(point: CGPoint(x: 70, y: 80), modifiers: []),
        ])
        XCTAssertEqual(snapshot.pointerOperations, [
            .warp(CGPoint(x: 70, y: 80)),
            .post(.mouseMove(point: CGPoint(x: 70, y: 80), modifiers: [])),
        ])
        XCTAssertEqual(snapshot.pauses.last, 500_000_000)
    }

    func testDragPreservesOrderedWaypointAndModifiers() async throws {
        let middle = CGPoint(x: 30, y: 90)
        let backend = RecordingInputEventBackend()
        try await performDrag(
            path: [CGPoint(x: 10, y: 20), middle, CGPoint(x: 50, y: 60)],
            button: .right,
            duration: 1,
            modifiers: .maskCommand,
            backend: backend,
        )
        let events = backend.snapshot().events
        XCTAssertTrue(events.contains(.mouseDrag(
            point: middle,
            button: .right,
            modifiers: .maskCommand,
        )))
        guard let down = events.first(where: \.isMouseDown) else {
            XCTFail("Expected mouse down")
            return
        }
        XCTAssertTrue(events.last?.isMatchingMouseUp(for: down) == true)
    }

    private func assertDragCleanup(
        _ snapshot: RecordingInputEventBackend.Snapshot,
        label: String,
    ) {
        XCTAssertEqual(snapshot.cursorAssociations, [false, true], label)
        XCTAssertEqual(snapshot.outstandingCleanupObligationCount, 0, label)
        guard let downIndex = snapshot.events.firstIndex(where: \.isMouseDown) else {
            return
        }
        let down = snapshot.events[downIndex]
        XCTAssertTrue(snapshot.events.last?.isMatchingMouseUp(for: down) == true, label)
    }

    private func waitForEventCount(
        _ backend: RecordingInputEventBackend,
        count: Int,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while backend.snapshot().events.count < count {
            guard clock.now < deadline else {
                throw InjectedInputEventError.convergenceTimeout
            }
            await Task.yield()
        }
    }
}

private actor TextPasteRecorder {
    enum Step: Equatable {
        case stage(String)
        case consume(String)
    }

    private var current: String?
    private var steps: [Step] = []

    func stage(_ value: String) {
        current = value
        steps.append(.stage(value))
    }

    func consumeCurrent() throws {
        guard let current else {
            throw InjectedInputEventError.convergenceTimeout
        }
        steps.append(.consume(current))
        self.current = nil
    }

    func snapshot() -> [Step] {
        steps
    }
}

private enum RecordedInputOperation: Equatable {
    case warp(CGPoint)
    case post(InputEvent)
}

private final class RecordingInputEventBackend:
    InputEventBackend,
    InputCleanupObligationTracking,
    @unchecked Sendable
{
    struct Snapshot {
        let events: [InputEvent]
        let cursorAssociations: [Bool]
        let pauses: [UInt64]
        let pointerOperations: [RecordedInputOperation]
        let outstandingCleanupObligationCount: Int
    }

    private struct State {
        var events: [InputEvent] = []
        var cursorAssociations: [Bool] = []
        var pauses: [UInt64] = []
        var pointerOperations: [RecordedInputOperation] = []
        var now: UInt64 = 0
        var pauseCalls = 0
        var postCalls = 0
        var cleanupObligations: [UUID: InputCleanupObligation] = [:]
    }

    private let lock = NSLock()
    private let failingPause: Int?
    private let failingPosts: Set<Int>
    private let commitThenFailingPosts: Set<Int>
    private let commitThenFailingCursorAssociations: Set<Int>
    private let blockingPauseAfter: Int?
    private let initialCursorPosition: CGPoint
    private let pauseBarrier = CancellableInputPauseBarrier()
    private var state = State()

    init(
        failingPause: Int? = nil,
        failingPosts: Set<Int> = [],
        commitThenFailingPosts: Set<Int> = [],
        commitThenFailingCursorAssociations: Set<Int> = [],
        blockingPause: Bool = false,
        blockingPauseAfter: Int? = nil,
        cursorPosition: CGPoint = .zero,
    ) {
        self.failingPause = failingPause
        self.failingPosts = failingPosts
        self.commitThenFailingPosts = commitThenFailingPosts
        self.commitThenFailingCursorAssociations = commitThenFailingCursorAssociations
        self.blockingPauseAfter = blockingPause ? 1 : blockingPauseAfter
        initialCursorPosition = cursorPosition
    }

    func checkPostAccess() throws {}

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        try PreparedInputEvent(event: event) { [weak self] in
            guard let self else {
                throw InjectedInputEventError.backendReleased
            }
            try lock.withLock {
                state.postCalls += 1
                if failingPosts.contains(state.postCalls) {
                    throw InjectedInputEventError.postFailure(state.postCalls)
                }
                state.events.append(event)
                state.pointerOperations.append(.post(event))
                if commitThenFailingPosts.contains(state.postCalls) {
                    throw InjectedInputEventError.postFailure(state.postCalls)
                }
            }
        }
    }

    func pause(nanoseconds: UInt64) async throws {
        let call = lock.withLock {
            state.pauseCalls += 1
            state.pauses.append(nanoseconds)
            state.now += nanoseconds
            return state.pauseCalls
        }
        if call == failingPause {
            throw InjectedInputEventError.pauseFailure(call)
        }
        if call == blockingPauseAfter {
            try await pauseBarrier.wait()
        }
    }

    func monotonicTimeNanoseconds() -> UInt64 {
        lock.withLock { state.now }
    }

    func cursorPosition() throws -> CGPoint {
        initialCursorPosition
    }

    func warpCursor(x: Double, y: Double) async throws {
        lock.withLock {
            state.pointerOperations.append(.warp(CGPoint(x: x, y: y)))
        }
    }

    func setCursorAssociated(_ associated: Bool) async throws {
        try lock.withLock {
            state.cursorAssociations.append(associated)
            if commitThenFailingCursorAssociations.contains(state.cursorAssociations.count) {
                throw InjectedInputEventError.cursorAssociationFailure(
                    state.cursorAssociations.count,
                )
            }
        }
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        lock.withLock {
            let obligation = InputCleanupObligation(id: UUID(), kind: kind)
            state.cleanupObligations[obligation.id] = obligation
            return obligation
        }
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        lock.withLock {
            state.cleanupObligations.removeValue(forKey: obligation.id)
        }
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        lock.withLock {
            state.cleanupObligations.removeValue(forKey: obligation.id)
        }
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock { state.cleanupObligations.count }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                events: state.events,
                cursorAssociations: state.cursorAssociations,
                pauses: state.pauses,
                pointerOperations: state.pointerOperations,
                outstandingCleanupObligationCount: state.cleanupObligations.count,
            )
        }
    }
}

private final class CancellableInputPauseBarrier: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, any Error>)
        case finished(Result<Void, any Error>)
    }

    private let lock = NSLock()
    private var state: State = .idle

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    switch state {
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        return .failure(
                            InjectedInputEventError.convergenceTimeout,
                        )
                    case let .finished(result):
                        return result
                    }
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                switch state {
                case .idle:
                    state = .finished(.failure(CancellationError()))
                    return nil
                case let .waiting(continuation):
                    state = .finished(.failure(CancellationError()))
                    return continuation
                case .finished:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private enum InjectedInputEventError: Error {
    case backendReleased
    case convergenceTimeout
    case cursorAssociationFailure(Int)
    case pauseFailure(Int)
    case postFailure(Int)
}
