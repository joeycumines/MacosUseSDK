import CoreGraphics
@testable import ExactMac
import XCTest

final class InputExecutionObservationTests: XCTestCase {
    private let source = InputEventSourceIdentity(
        unixProcessID: 101,
        userID: 202,
    )

    func testExactOrderedAcknowledgementsProduceRouteBoundReceipt() throws {
        let route = InputDeliveryRoute.process(44)
        let ledger = InputDeliveryLedger(route: route)
        let down = obligation(1)
        let up = obligation(2)

        try ledger.registerAttempt(
            InputDeliveryAttempt(
                token: 11,
                obligationID: down,
                eventType: .keyDown,
                source: source,
                route: route,
                postTimeNanoseconds: 1000,
            ),
        )
        try ledger.registerAttempt(
            InputDeliveryAttempt(
                token: 12,
                obligationID: up,
                eventType: .keyUp,
                source: source,
                route: route,
                postTimeNanoseconds: 2000,
            ),
        )

        ledger.recordObserved(
            ObservedInputDelivery(
                token: 999,
                eventType: .keyDown,
                source: source,
                route: route,
            ),
        )
        ledger.recordObserved(
            ObservedInputDelivery(
                token: 11,
                eventType: .keyDown,
                source: source,
                route: route,
            ),
        )
        ledger.recordObserved(
            ObservedInputDelivery(
                token: 12,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )

        let receipt = try ledger.complete()
        XCTAssertEqual(receipt.route, route)
        XCTAssertEqual(receipt.postedEventCount, 2)
        XCTAssertTrue(receipt.routedDeliveryObserved)
        XCTAssertEqual(ledger.snapshot.attemptCount, 2)
        XCTAssertEqual(ledger.snapshot.settledObligationCount, 2)
        XCTAssertEqual(ledger.snapshot.outstandingAcknowledgementCount, 0)
    }

    func testKnownTokenRejectsWrongTypeSourceRouteAndGeneration() throws {
        let route = InputDeliveryRoute.session

        let wrongType = try singleAttemptLedger(route: route, token: 21)
        wrongType.recordObserved(
            ObservedInputDelivery(
                token: 21,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )
        XCTAssertThrowsError(try wrongType.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .eventTypeMismatch(token: 21),
            )
        }

        let wrongSource = try singleAttemptLedger(route: route, token: 22)
        wrongSource.recordObserved(
            ObservedInputDelivery(
                token: 22,
                eventType: .keyDown,
                source: InputEventSourceIdentity(
                    unixProcessID: source.unixProcessID + 1,
                    userID: source.userID,
                ),
                route: route,
            ),
        )
        XCTAssertThrowsError(try wrongSource.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .sourceMismatch(token: 22),
            )
        }

        let wrongRoute = try singleAttemptLedger(route: route, token: 23)
        wrongRoute.recordObserved(
            ObservedInputDelivery(
                token: 23,
                eventType: .keyDown,
                source: source,
                route: .process(44),
            ),
        )
        XCTAssertThrowsError(try wrongRoute.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .routeMismatch(token: 23),
            )
        }

        let wrongGeneration = try singleAttemptLedger(
            route: route,
            token: 24,
        )
        wrongGeneration.recordObserved(
            ObservedInputDelivery(
                token: 24,
                eventType: .keyDown,
                source: source,
                route: route,
                generation: 2,
            ),
        )
        XCTAssertThrowsError(try wrongGeneration.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .generationMismatch(token: 24),
            )
        }
    }

    func testDuplicateOutOfOrderAndMissingAcknowledgementsFailClosed() throws {
        let route = InputDeliveryRoute.session

        let duplicate = try singleAttemptLedger(route: route, token: 31)
        let observation = ObservedInputDelivery(
            token: 31,
            eventType: .keyDown,
            source: source,
            route: route,
        )
        duplicate.recordObserved(observation)
        duplicate.recordObserved(observation)
        XCTAssertThrowsError(try duplicate.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .duplicateObservation(token: 31),
            )
        }

        let outOfOrder = InputDeliveryLedger(route: route)
        let first = obligation(4)
        let second = obligation(5)
        try outOfOrder.registerAttempt(
            attempt(
                token: 41,
                obligationID: first,
                eventType: .keyDown,
                route: route,
                postTime: 100,
            ),
        )
        try outOfOrder.registerAttempt(
            attempt(
                token: 42,
                obligationID: second,
                eventType: .keyUp,
                route: route,
                postTime: 200,
            ),
        )
        outOfOrder.recordObserved(
            ObservedInputDelivery(
                token: 42,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )
        XCTAssertThrowsError(try outOfOrder.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .outOfOrder(expected: first, observed: second),
            )
        }

        let missing = try singleAttemptLedger(route: route, token: 51)
        XCTAssertThrowsError(try missing.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .missingAcknowledgements(count: 1),
            )
        }
    }

    func testOutOfOrderSafetyReleaseSettlesWithoutHidingOriginalFailure() throws {
        let route = InputDeliveryRoute.session
        let down = obligation(10)
        let release = obligation(11)
        let ledger = InputDeliveryLedger(route: route)
        _ = ledger.armCleanupObligation(.keyRelease)
        try ledger.registerAttempt(
            attempt(
                token: 81,
                obligationID: down,
                eventType: .keyDown,
                route: route,
                postTime: 100,
            ),
        )
        try ledger.registerAttempt(
            InputDeliveryAttempt(
                token: 82,
                obligationID: release,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                source: source,
                route: route,
                postTimeNanoseconds: 200,
            ),
        )

        ledger.recordObserved(
            ObservedInputDelivery(
                token: 82,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )

        XCTAssertTrue(ledger.isObligationSettled(release))
        XCTAssertEqual(ledger.settledPostTime(for: release), 200)
        XCTAssertEqual(ledger.snapshot.observedAttemptCount, 1)
        XCTAssertEqual(ledger.snapshot.outstandingAcknowledgementCount, 1)
        XCTAssertEqual(ledger.snapshot.outstandingCleanupObligationCount, 1)
        XCTAssertEqual(
            ledger.snapshot.failure,
            .outOfOrder(expected: down, observed: release),
        )
        XCTAssertThrowsError(try ledger.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .outOfOrder(expected: down, observed: release),
            )
        }
    }

    func testCleanupObligationsAreExactAndDoNotInflateReceiptCounts() throws {
        let route = InputDeliveryRoute.session
        let ledger = try singleAttemptLedger(route: route, token: 91)
        let cleanup = ledger.armCleanupObligation(.keyRelease)
        ledger.recordObserved(
            ObservedInputDelivery(
                token: 91,
                eventType: .keyDown,
                source: source,
                route: route,
            ),
        )

        XCTAssertEqual(ledger.snapshot.attemptCount, 1)
        XCTAssertEqual(ledger.snapshot.outstandingCleanupObligationCount, 1)
        XCTAssertThrowsError(try ledger.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .outstandingCleanupObligations(count: 1),
            )
        }

        ledger.settleCleanupObligation(cleanup)
        let receipt = try ledger.complete()
        XCTAssertEqual(receipt.postedEventCount, 1)
        XCTAssertEqual(ledger.snapshot.outstandingCleanupObligationCount, 0)

        ledger.abandonCleanupObligation(cleanup)
        XCTAssertThrowsError(try ledger.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .cleanupObligationMismatch(cleanup.id),
            )
        }
    }

    func testSafetyReleaseRoleRejectsNonReleaseEventTypes() throws {
        let ledger = InputDeliveryLedger(route: .session)
        XCTAssertThrowsError(
            try ledger.registerAttempt(
                InputDeliveryAttempt(
                    token: 92,
                    obligationID: obligation(92),
                    obligationKind: .safetyRelease,
                    eventType: .keyDown,
                    source: source,
                    route: .session,
                    postTimeNanoseconds: 100,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .invalidSafetyReleaseEventType(.keyDown),
            )
        }
        XCTAssertEqual(ledger.snapshot.attemptCount, 0)
    }

    func testObserverRegistrationFailureRecordsNoPostInvocation() async throws {
        let observer = RejectingInputDeliveryObserver()
        let counter = LockedInvocationCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postInvocationRecorder: counter.record,
            postAccessChecker: { true },
        )

        do {
            try await pressKey(
                keyCode: KEY_RETURN,
                flags: .maskCommand,
                backend: backend,
            )
            XCTFail("Expected observer registration failure")
        } catch let error as InputDeliveryLedgerError {
            XCTAssertEqual(
                error,
                .observerFailure("injected registration failure"),
            )
        }

        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(observer.outstandingCleanupObligationCount, 0)
    }

    func testSettledCleanupValidatesProposedAttemptBeforeSkippingRecoveryAndPhysicalPost()
        async throws
    {
        let observer = LedgerBackedSettledCleanupInputDeliveryObserver()
        let counter = LockedInvocationCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postInvocationRecorder: counter.record,
        )
        let event = try backend.prepare(.keyUp(keyCode: KEY_RETURN, flags: []))
        try observer.settle(event, postTimeNanoseconds: 777)

        let postTime = try await backend.postForCleanup(event)

        XCTAssertEqual(postTime, 777)
        XCTAssertEqual(observer.settledValidationCount, 1)
        XCTAssertEqual(observer.cleanupRegistrationCount, 0)
        XCTAssertEqual(observer.recoveryCount, 0)
        XCTAssertEqual(counter.value, 0)
    }

    func testFreshRetryTokenRetainsStableObligationAndLateAcknowledgementSettles() throws {
        let route = InputDeliveryRoute.session
        let obligationID = obligation(6)
        let ledger = InputDeliveryLedger(route: route)
        try ledger.registerAttempt(
            attempt(
                token: 61,
                obligationID: obligationID,
                eventType: .keyUp,
                route: route,
                postTime: 1000,
            ),
        )
        try ledger.registerAttempt(
            attempt(
                token: 62,
                obligationID: obligationID,
                eventType: .keyUp,
                route: route,
                postTime: 2000,
            ),
        )

        ledger.recordObserved(
            ObservedInputDelivery(
                token: 61,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )

        XCTAssertEqual(ledger.snapshot.attemptCount, 2)
        XCTAssertEqual(ledger.snapshot.settledObligationCount, 1)
        XCTAssertTrue(ledger.isObligationSettled(obligationID))
        XCTAssertEqual(
            ledger.settledPostTime(for: obligationID),
            1000,
        )
        XCTAssertThrowsError(try ledger.complete()) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .missingAcknowledgements(count: 1),
            )
        }
    }

    func testAtomicCleanupAdmissionSkipsRetryWhenLateAcknowledgementWins() throws {
        let route = InputDeliveryRoute.session
        let obligationID = obligation(63)
        let ledger = InputDeliveryLedger(route: route)
        try ledger.registerAttempt(
            attempt(
                token: 63,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                postTime: 1000,
            ),
        )
        ledger.recordObserved(
            ObservedInputDelivery(
                token: 63,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )

        let admission = try ledger.admitCleanupAttemptIfUnsettled(
            attempt(
                token: 64,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                postTime: 2000,
            ),
        )

        XCTAssertEqual(
            admission,
            .alreadySettled(postTimeNanoseconds: 1000),
        )
        XCTAssertEqual(ledger.snapshot.attemptCount, 1)
    }

    func testAtomicCleanupAdmissionOwnsOneRetryBeforeOldAcknowledgementArrives() throws {
        let route = InputDeliveryRoute.session
        let obligationID = obligation(65)
        let ledger = InputDeliveryLedger(route: route)
        try ledger.registerAttempt(
            attempt(
                token: 65,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                postTime: 1000,
            ),
        )

        let admission = try ledger.admitCleanupAttemptIfUnsettled(
            attempt(
                token: 66,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                postTime: 2000,
            ),
        )
        ledger.recordObserved(
            ObservedInputDelivery(
                token: 65,
                eventType: .keyUp,
                source: source,
                route: route,
            ),
        )

        XCTAssertEqual(admission, .admitted)
        XCTAssertEqual(ledger.snapshot.attemptCount, 2)
        XCTAssertEqual(
            ledger.settledPostTime(for: obligationID),
            1000,
        )
    }

    func testAtomicCleanupAdmissionLateAcknowledgementWinsRealLockRace() async throws {
        let route = InputDeliveryRoute.session
        let obligationID = obligation(651)
        let observationBarrier = InputLedgerCriticalSectionBarrier()
        let ledger = InputDeliveryLedger(
            route: route,
            synchronizationHooks: InputDeliveryLedgerSynchronizationHooks(
                observationDidAcquireLock: observationBarrier.pause,
            ),
        )
        try ledger.registerAttempt(
            attempt(
                token: 651,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                postTime: 1000,
            ),
        )
        let observedSource = source
        let retryAttempt = attempt(
            token: 652,
            obligationID: obligationID,
            obligationKind: .safetyRelease,
            eventType: .keyUp,
            route: route,
            postTime: 2000,
        )

        let observation = Task.detached {
            ledger.recordObserved(
                ObservedInputDelivery(
                    token: 651,
                    eventType: .keyUp,
                    source: observedSource,
                    route: route,
                ),
            )
        }
        XCTAssertTrue(observationBarrier.waitUntilPaused())
        let admission = Task.detached {
            try ledger.admitCleanupAttemptIfUnsettled(retryAttempt)
        }

        observationBarrier.resume()
        _ = await observation.value
        let admissionResult = try await admission.value
        XCTAssertEqual(
            admissionResult,
            .alreadySettled(postTimeNanoseconds: 1000),
        )
        XCTAssertEqual(ledger.snapshot.attemptCount, 1)
    }

    func testAtomicCleanupAdmissionRetryWinsRealLockRace() async throws {
        let route = InputDeliveryRoute.session
        let obligationID = obligation(653)
        let admissionBarrier = InputLedgerCriticalSectionBarrier()
        let ledger = InputDeliveryLedger(
            route: route,
            synchronizationHooks: InputDeliveryLedgerSynchronizationHooks(
                cleanupAdmissionDidAcquireLock: admissionBarrier.pause,
            ),
        )
        try ledger.registerAttempt(
            attempt(
                token: 653,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                postTime: 1000,
            ),
        )
        let observedSource = source
        let retryAttempt = attempt(
            token: 654,
            obligationID: obligationID,
            obligationKind: .safetyRelease,
            eventType: .keyUp,
            route: route,
            postTime: 2000,
        )

        let admission = Task.detached {
            try ledger.admitCleanupAttemptIfUnsettled(retryAttempt)
        }
        XCTAssertTrue(admissionBarrier.waitUntilPaused())
        let observation = Task.detached {
            ledger.recordObserved(
                ObservedInputDelivery(
                    token: 653,
                    eventType: .keyUp,
                    source: observedSource,
                    route: route,
                ),
            )
        }

        admissionBarrier.resume()
        let admissionResult = try await admission.value
        XCTAssertEqual(admissionResult, .admitted)
        _ = await observation.value
        XCTAssertEqual(ledger.snapshot.attemptCount, 2)
        XCTAssertEqual(ledger.settledPostTime(for: obligationID), 1000)
    }

    func testSettledCleanupStillRejectsMalformedRetryEvidence() throws {
        let route = InputDeliveryRoute.session
        let obligationID = obligation(67)
        let generation: UInt64 = 9
        let ledger = InputDeliveryLedger(
            route: route,
            generation: generation,
        )
        try ledger.registerAttempt(
            attempt(
                token: 67,
                obligationID: obligationID,
                obligationKind: .safetyRelease,
                eventType: .keyUp,
                route: route,
                generation: generation,
                postTime: 1000,
            ),
        )
        ledger.recordObserved(
            ObservedInputDelivery(
                token: 67,
                eventType: .keyUp,
                source: source,
                route: route,
                generation: generation,
            ),
        )

        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 68,
                    obligationID: obligationID,
                    eventType: .keyUp,
                    route: route,
                    generation: generation,
                    postTime: 2000,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .cleanupObligationMismatch(obligationID),
            )
        }
        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 69,
                    obligationID: obligationID,
                    obligationKind: .safetyRelease,
                    eventType: .leftMouseUp,
                    route: route,
                    generation: generation,
                    postTime: 3000,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .eventTypeMismatch(token: 69),
            )
        }
        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 70,
                    obligationID: obligationID,
                    obligationKind: .safetyRelease,
                    eventType: .keyUp,
                    source: InputEventSourceIdentity(
                        unixProcessID: 303,
                        userID: 404,
                    ),
                    route: route,
                    generation: generation,
                    postTime: 3500,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .sourceMismatch(token: 70),
            )
        }
        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 71,
                    obligationID: obligationID,
                    obligationKind: .safetyRelease,
                    eventType: .keyUp,
                    route: .process(4242),
                    generation: generation,
                    postTime: 3600,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .routeMismatch(token: 71),
            )
        }
        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 72,
                    obligationID: obligationID,
                    obligationKind: .safetyRelease,
                    eventType: .keyUp,
                    route: route,
                    generation: generation + 1,
                    postTime: 3700,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .generationMismatch(token: 72),
            )
        }
        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 0,
                    obligationID: obligationID,
                    obligationKind: .safetyRelease,
                    eventType: .keyUp,
                    route: route,
                    generation: generation,
                    postTime: 3800,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .invalidToken,
            )
        }
        XCTAssertThrowsError(
            try ledger.admitCleanupAttemptIfUnsettled(
                attempt(
                    token: 67,
                    obligationID: obligationID,
                    obligationKind: .safetyRelease,
                    eventType: .keyUp,
                    route: route,
                    generation: generation,
                    postTime: 4000,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .duplicateAttemptToken(67),
            )
        }
        XCTAssertEqual(ledger.snapshot.attemptCount, 1)
    }

    func testAttemptTokensAreNonzeroAndUnique() throws {
        let route = InputDeliveryRoute.session
        let ledger = InputDeliveryLedger(route: route)
        XCTAssertThrowsError(
            try ledger.registerAttempt(
                attempt(
                    token: 0,
                    obligationID: obligation(7),
                    eventType: .keyDown,
                    route: route,
                    postTime: 100,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .invalidToken,
            )
        }

        try ledger.registerAttempt(
            attempt(
                token: 71,
                obligationID: obligation(8),
                eventType: .keyDown,
                route: route,
                postTime: 200,
            ),
        )
        XCTAssertThrowsError(
            try ledger.registerAttempt(
                attempt(
                    token: 71,
                    obligationID: obligation(9),
                    eventType: .keyUp,
                    route: route,
                    postTime: 300,
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputDeliveryLedgerError,
                .duplicateAttemptToken(71),
            )
        }
    }

    private func singleAttemptLedger(
        route: InputDeliveryRoute,
        token: UInt64,
    ) throws -> InputDeliveryLedger {
        let ledger = InputDeliveryLedger(route: route)
        try ledger.registerAttempt(
            attempt(
                token: token,
                obligationID: obligation(Int(token)),
                eventType: .keyDown,
                route: route,
                postTime: 100,
            ),
        )
        return ledger
    }

    private func attempt(
        token: UInt64,
        obligationID: UUID,
        obligationKind: InputDeliveryObligationKind = .ordinary,
        eventType: CGEventType,
        source attemptSource: InputEventSourceIdentity? = nil,
        route: InputDeliveryRoute,
        generation: UInt64 = 1,
        postTime: UInt64,
    ) -> InputDeliveryAttempt {
        InputDeliveryAttempt(
            token: token,
            obligationID: obligationID,
            obligationKind: obligationKind,
            eventType: eventType,
            source: attemptSource ?? source,
            route: route,
            generation: generation,
            postTimeNanoseconds: postTime,
        )
    }

    private func obligation(_ value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012llx",
                value,
            ),
        )!
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock {
            count += 1
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class RejectingInputDeliveryObserver: InputDeliveryObserving, @unchecked Sendable {
    let route = InputDeliveryRoute.session
    let generation: UInt64 = 1
    private let lock = NSLock()
    private var cleanupObligations: Set<UUID> = []

    func invokeAttempt(
        _: InputDeliveryAttempt,
        forCleanup: Bool,
        invocation _: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        throw InputDeliveryLedgerError.observerFailure(
            forCleanup
                ? "unexpected cleanup registration"
                : "injected registration failure",
        )
    }

    func validateSettledCleanupAttempt(
        _: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        nil
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        let obligation = InputCleanupObligation(id: UUID(), kind: kind)
        lock.withLock {
            cleanupObligations.insert(obligation.id)
        }
        return obligation
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        lock.withLock {
            cleanupObligations.remove(obligation.id)
        }
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        lock.withLock {
            cleanupObligations.remove(obligation.id)
        }
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock { cleanupObligations.count }
    }

    func waitForAttempt(_: UInt64) async throws {
        throw InputDeliveryLedgerError.observerFailure("unexpected attempt wait")
    }

    func waitForObligation(_: UUID) async throws {
        throw InputDeliveryLedgerError.observerFailure("unexpected obligation wait")
    }

    func isObligationSettled(_: UUID) -> Bool {
        false
    }

    func settledPostTime(for _: UUID) -> UInt64? {
        nil
    }

    func recoverForCleanup() async throws {}

    func complete() throws -> InputExecutionReceipt {
        throw InputDeliveryLedgerError.observerFailure("unexpected completion")
    }

    var hasObservedDelivery: Bool {
        false
    }

    func stopAndJoin() async {}
}

private final class LedgerBackedSettledCleanupInputDeliveryObserver:
    InputDeliveryObserving,
    @unchecked Sendable
{
    let route = InputDeliveryRoute.session
    let generation: UInt64 = 1
    private let ledger = InputDeliveryLedger(route: .session)
    private let lock = NSLock()
    private var recoveries = 0
    private var settledValidations = 0
    private var cleanupRegistrations = 0

    func settle(
        _ event: PreparedInputEvent,
        postTimeNanoseconds: UInt64,
    ) throws {
        guard let eventType = event.eventType,
              let sourceIdentity = event.sourceIdentity
        else {
            throw InputDeliveryLedgerError.observerFailure(
                "test event lacks routed identity",
            )
        }
        let token: UInt64 = 700
        try ledger.registerAttempt(
            InputDeliveryAttempt(
                token: token,
                obligationID: event.obligationID,
                obligationKind: event.obligationKind,
                eventType: eventType,
                source: sourceIdentity,
                route: route,
                generation: generation,
                postTimeNanoseconds: postTimeNanoseconds,
            ),
        )
        ledger.recordObserved(
            ObservedInputDelivery(
                token: token,
                eventType: eventType,
                source: sourceIdentity,
                route: route,
                generation: generation,
            ),
        )
    }

    func invokeAttempt(
        _ attempt: InputDeliveryAttempt,
        forCleanup: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        guard forCleanup else {
            throw InputDeliveryLedgerError.observerFailure(
                "unexpected normal registration",
            )
        }
        lock.withLock {
            cleanupRegistrations += 1
        }
        let admission = try ledger.admitCleanupAttemptIfUnsettled(attempt)
        if admission == .admitted {
            try invocation()
        }
        return admission
    }

    func validateSettledCleanupAttempt(
        _ attempt: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        lock.withLock {
            settledValidations += 1
        }
        return try ledger.validateSettledCleanupAttempt(attempt)
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        InputCleanupObligation(id: UUID(), kind: kind)
    }

    func settleCleanupObligation(_: InputCleanupObligation) {}

    func abandonCleanupObligation(_: InputCleanupObligation) {}

    var outstandingCleanupObligationCount: Int {
        0
    }

    func waitForAttempt(_: UInt64) async throws {
        throw InputDeliveryLedgerError.observerFailure("unexpected attempt wait")
    }

    func waitForObligation(_: UUID) async throws {
        throw InputDeliveryLedgerError.observerFailure("unexpected obligation wait")
    }

    func isObligationSettled(_: UUID) -> Bool {
        ledger.snapshot.settledObligationCount > 0
    }

    func settledPostTime(for obligationID: UUID) -> UInt64? {
        ledger.settledPostTime(for: obligationID)
    }

    func recoverForCleanup() async throws {
        lock.withLock {
            recoveries += 1
        }
    }

    func complete() throws -> InputExecutionReceipt {
        throw InputDeliveryLedgerError.observerFailure("unexpected completion")
    }

    var hasObservedDelivery: Bool {
        false
    }

    func stopAndJoin() async {}

    var recoveryCount: Int {
        lock.withLock { recoveries }
    }

    var settledValidationCount: Int {
        lock.withLock { settledValidations }
    }

    var cleanupRegistrationCount: Int {
        lock.withLock { cleanupRegistrations }
    }
}

private final class InputLedgerCriticalSectionBarrier: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        paused.signal()
        release.wait()
    }

    func waitUntilPaused() -> Bool {
        paused.wait(timeout: .now() + 2) == .success
    }

    func resume() {
        release.signal()
    }
}
