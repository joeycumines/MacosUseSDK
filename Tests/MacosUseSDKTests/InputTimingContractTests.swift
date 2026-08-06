import CoreGraphics
@testable import MacosUseSDK
import XCTest

final class InputTimingContractTests: XCTestCase {
    func testKeyHoldMeasuresDownToUpWithoutFixedInflation() async throws {
        let backend = VirtualInputClockBackend()
        try await pressKeyHold(
            keyCode: KEY_SPACE,
            duration: 0.5,
            backend: backend,
        )

        let posts = backend.snapshot().posts
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[1].time - posts[0].time, 500_000_000)
    }

    func testCharacterDelayMeasuresSuccessiveDownOnsets() async throws {
        let backend = VirtualInputClockBackend()
        try await writeText("ab", characterDelay: 0.25, backend: backend)

        let downs = backend.snapshot().posts.filter { post in
            if case .unicodeKeyDown = post.event {
                return true
            }
            return false
        }
        XCTAssertEqual(downs.count, 2)
        XCTAssertEqual(downs[1].time - downs[0].time, 250_000_000)
    }

    func testMoveDurationMeasuresFirstToLastScheduledMovement() async throws {
        let backend = VirtualInputClockBackend(cursorPosition: .zero)
        try await moveMouse(
            to: CGPoint(x: 100, y: 100),
            duration: 1,
            backend: backend,
        )

        let posts = backend.snapshot().posts
        XCTAssertGreaterThan(posts.count, 1)
        XCTAssertEqual(try XCTUnwrap(posts.last?.time) - posts.first!.time, 1_000_000_000)
    }

    func testMoveAbsoluteDeadlinesRecoverAfterSchedulerOversleep() async throws {
        let backend = VirtualInputClockBackend(
            cursorPosition: .zero,
            firstPauseOversleepNanoseconds: 20_000_000,
        )
        try await moveMouse(
            to: CGPoint(x: 100, y: 100),
            duration: 1,
            backend: backend,
        )

        let snapshot = backend.snapshot()
        XCTAssertGreaterThan(snapshot.posts.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.posts.last?.time) - snapshot.posts.first!.time,
            1_000_000_000,
        )
        XCTAssertEqual(snapshot.now, 1_000_000_000)
    }

    func testScrollDurationMeasuresFirstToLastScheduledEvent() async throws {
        let backend = VirtualInputClockBackend()
        try await scrollMouse(
            horizontal: 20,
            vertical: -20,
            duration: 1,
            backend: backend,
        )

        let posts = backend.snapshot().posts
        XCTAssertGreaterThan(posts.count, 1)
        XCTAssertEqual(try XCTUnwrap(posts.last?.time) - posts.first!.time, 1_000_000_000)
    }

    func testMagnitudeOneTimedScrollPostsItsOnlyEventAtTheAbsoluteDurationBoundary() async throws {
        for (horizontal, vertical) in [(1.0, 0.0), (0.0, -1.0)] {
            let backend = VirtualInputClockBackend()
            try await scrollMouse(
                horizontal: horizontal,
                vertical: vertical,
                duration: 1,
                backend: backend,
            )

            let posts = backend.snapshot().posts
            XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(posts[0].time, 1_000_000_000)
        }
    }

    func testKeyReleaseRetriesUntilThePreparedUpSettles() async throws {
        let backend = VirtualInputClockBackend(keyUpFailures: 2)
        do {
            try await pressKey(keyCode: KEY_ESCAPE, backend: backend)
            XCTFail("Expected the first key-up post failure to remain truthful")
        } catch is VirtualInputClockError {
            // Expected after cancellation-independent cleanup settles.
        }

        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.keyUpAttempts, 3)
        XCTAssertEqual(snapshot.outstandingCleanupObligationCount, 0)
        XCTAssertTrue(snapshot.posts.contains { post in
            if case .keyUp = post.event {
                return true
            }
            return false
        })
    }

    func testDragReassociationRetriesUntilSettled() async throws {
        let backend = VirtualInputClockBackend(reassociationFailures: 2)
        do {
            try await performDrag(
                path: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)],
                backend: backend,
            )
            XCTFail("Expected the first reassociation failure to remain truthful")
        } catch is VirtualInputClockError {
            // Expected after cancellation-independent cleanup settles.
        }

        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.reassociationAttempts, 3)
        XCTAssertEqual(snapshot.associations.last, true)
        XCTAssertEqual(snapshot.outstandingCleanupObligationCount, 0)
    }

    func testDragReassociationDoesNotAbandonHostCleanupForRetiredRouteError() async throws {
        let backend = VirtualInputClockBackend(
            reassociationRouteRetirements: 2,
        )
        do {
            try await performDrag(
                path: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)],
                backend: backend,
            )
            XCTFail("Expected the first reassociation failure to remain truthful")
        } catch let error as InputProcessRouteRetired {
            XCTAssertEqual(error, InputProcessRouteRetired(pid: 4242))
        }

        let snapshot = backend.snapshot()
        XCTAssertEqual(snapshot.reassociationAttempts, 3)
        XCTAssertEqual(snapshot.associations.last, true)
        XCTAssertEqual(snapshot.outstandingCleanupObligationCount, 0)
    }
}

private final class VirtualInputClockBackend:
    InputEventBackend,
    InputCleanupObligationTracking,
    @unchecked Sendable
{
    struct Post: Equatable {
        let event: InputEvent
        let time: UInt64
    }

    struct Snapshot {
        let posts: [Post]
        let associations: [Bool]
        let keyUpAttempts: Int
        let reassociationAttempts: Int
        let outstandingCleanupObligationCount: Int
        let now: UInt64
    }

    private struct State {
        var now: UInt64 = 0
        var posts: [Post] = []
        var associations: [Bool] = []
        var keyUpAttempts = 0
        var reassociationAttempts = 0
        var pauseCalls = 0
        var cleanupObligations: [UUID: InputCleanupObligation] = [:]
    }

    private let lock = NSLock()
    private let initialCursorPosition: CGPoint
    private let keyUpFailures: Int
    private let reassociationFailures: Int
    private let reassociationRouteRetirements: Int
    private let firstPauseOversleepNanoseconds: UInt64
    private var state = State()

    init(
        cursorPosition: CGPoint = .zero,
        keyUpFailures: Int = 0,
        reassociationFailures: Int = 0,
        reassociationRouteRetirements: Int = 0,
        firstPauseOversleepNanoseconds: UInt64 = 0,
    ) {
        initialCursorPosition = cursorPosition
        self.keyUpFailures = keyUpFailures
        self.reassociationFailures = reassociationFailures
        self.reassociationRouteRetirements = reassociationRouteRetirements
        self.firstPauseOversleepNanoseconds = firstPauseOversleepNanoseconds
    }

    func checkPostAccess() throws {}

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        try PreparedInputEvent(event: event) { [weak self] in
            guard let self else {
                throw VirtualInputClockError.backendReleased
            }
            try lock.withLock {
                if case .keyUp = event {
                    state.keyUpAttempts += 1
                    if state.keyUpAttempts <= keyUpFailures {
                        throw VirtualInputClockError.injectedFailure
                    }
                }
                state.posts.append(Post(event: event, time: state.now))
            }
        }
    }

    func pause(nanoseconds: UInt64) async throws {
        lock.withLock {
            state.pauseCalls += 1
            state.now += nanoseconds
                + (state.pauseCalls == 1 ? firstPauseOversleepNanoseconds : 0)
        }
    }

    func monotonicTimeNanoseconds() -> UInt64 {
        lock.withLock { state.now }
    }

    func cursorPosition() throws -> CGPoint {
        initialCursorPosition
    }

    func warpCursor(x _: Double, y _: Double) async throws {}

    func setCursorAssociated(_ associated: Bool) async throws {
        try lock.withLock {
            if associated {
                state.reassociationAttempts += 1
                if state.reassociationAttempts <= reassociationFailures {
                    throw VirtualInputClockError.injectedFailure
                }
                if state.reassociationAttempts <= reassociationRouteRetirements {
                    throw InputProcessRouteRetired(pid: 4242)
                }
            }
            state.associations.append(associated)
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
                posts: state.posts,
                associations: state.associations,
                keyUpAttempts: state.keyUpAttempts,
                reassociationAttempts: state.reassociationAttempts,
                outstandingCleanupObligationCount: state.cleanupObligations.count,
                now: state.now,
            )
        }
    }
}

private enum VirtualInputClockError: Error {
    case backendReleased
    case injectedFailure
}
