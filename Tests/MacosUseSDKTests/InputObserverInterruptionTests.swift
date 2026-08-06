import CoreGraphics
@testable import MacosUseSDK
import XCTest

private let inputObserverTestMachPortCallback:
    CFMachPortCallBack = { _, _, _, _ in }

final class InputObserverInterruptionTests: XCTestCase {
    func testSignalBeforeWaiterInstallationCannotBeMissed() async throws {
        let signal = InputDeliveryChangeSignal()
        let revision = signal.revision

        signal.signalChange()

        let change = try await signal.waitForChange(after: revision)
        XCTAssertEqual(change, .changed)
        XCTAssertEqual(signal.activeWaiterCount, 0)
    }

    func testCancellationBeforeAndAfterWaiterInstallationRemovesExactlyOnce() async throws {
        let waiterInstalled = InputObserverOneShot()
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waiterInstalled.signal,
        )
        let revision = signal.revision
        let cancelledBeforeInstallation = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await signal.waitForChange(after: revision)
        }

        do {
            _ = try await cancelledBeforeInstallation.value
            XCTFail("Expected cancellation before waiter installation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(signal.activeWaiterCount, 0)

        let cancelledAfterInstallation = Task {
            try await signal.waitForChange(after: signal.revision)
        }
        try await waiterInstalled.wait(
            failureCleanup: .init(task: cancelledAfterInstallation),
        )
        XCTAssertEqual(signal.activeWaiterCount, 1)
        cancelledAfterInstallation.cancel()

        do {
            _ = try await cancelledAfterInstallation.value
            XCTFail("Expected cancellation after waiter installation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(signal.activeWaiterCount, 0)
    }

    func testReadinessTimeoutCancelsAndJoinsItsOwnedSubject() async throws {
        let subjectInstalled = InputObserverOneShot()
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: subjectInstalled.signal,
        )
        let subject = Task {
            try await signal.waitForChange(after: signal.revision)
        }
        try await subjectInstalled.wait(
            failureCleanup: .init(task: subject),
        )
        let neverSignalled = InputObserverOneShot(
            timeout: .milliseconds(10),
        )

        do {
            try await neverSignalled.wait(
                failureCleanup: .init(task: subject),
            )
            XCTFail("Expected bounded readiness timeout")
        } catch let error as InputObserverBarrierError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }

        switch await subject.result {
        case .success:
            XCTFail("Expected owned subject cancellation")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(subjectInstalled.activeWaiterCount, 0)
        XCTAssertEqual(neverSignalled.activeWaiterCount, 0)
        XCTAssertEqual(signal.activeWaiterCount, 0)
    }

    func testCloseWakesEveryWaiterAndRejectsNewRegistration() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let revision = signal.revision
        let first = Task {
            try await signal.waitForChange(after: revision)
        }
        let second = Task {
            try await signal.waitForChange(after: revision)
        }
        try await waitersInstalled.wait(
            failureCleanup: .combine(
                .init(task: first),
                .init(task: second),
            ),
        )
        XCTAssertEqual(signal.activeWaiterCount, 2)

        signal.close()

        let firstChange = try await first.value
        let secondChange = try await second.value
        let afterClose = try await signal.waitForChange(
            after: signal.revision,
        )
        XCTAssertEqual(firstChange, .closed)
        XCTAssertEqual(secondChange, .closed)
        XCTAssertEqual(afterClose, .closed)
        XCTAssertEqual(signal.activeWaiterCount, 0)
    }

    func testExactObservationWakesAcknowledgementAndJoinsDeadlineSleeper() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: waitersInstalled.arrive,
        )
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let coordinator = InputDeliveryWaitCoordinator(
            signal: signal,
            scheduler: scheduler.scheduler,
        )
        let settled = LockedInputObserverFlag()
        let wait = Task {
            try await coordinator.waitUntil(
                timeoutNanoseconds: 1000,
                isSettled: settled.value,
                validateHealth: {},
                timeoutError: {
                    InputObserverInterruptionError.timeout
                },
            )
        }
        try await waitersInstalled.wait(
            failureCleanup: .init(task: wait),
        )
        XCTAssertEqual(coordinator.activeWaiterCount, 1)
        XCTAssertEqual(scheduler.activeSleeperCount, 1)

        settled.set()
        coordinator.signalChange()
        try await wait.value

        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
        XCTAssertEqual(scheduler.nowNanoseconds, 0)
    }

    func testObserverFailureWakesLongActionTimingAndJoinsDeadlineSleeper() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: waitersInstalled.arrive,
        )
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let coordinator = InputDeliveryWaitCoordinator(
            signal: signal,
            scheduler: scheduler.scheduler,
        )
        let failed = LockedInputObserverFlag()
        let wait = Task {
            try await coordinator.waitWhileHealthy(
                nanoseconds: 3_600_000_000_000,
                validateHealth: {
                    if failed.value() {
                        throw InputObserverInterruptionError.healthFailure
                    }
                },
            )
        }
        try await waitersInstalled.wait(
            failureCleanup: .init(task: wait),
        )
        XCTAssertEqual(coordinator.activeWaiterCount, 1)
        XCTAssertEqual(scheduler.activeSleeperCount, 1)

        failed.set()
        coordinator.signalChange()

        do {
            try await wait.value
            XCTFail("Expected observer health failure")
        } catch let error as InputObserverInterruptionError {
            XCTAssertEqual(error, .healthFailure)
        }
        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
        XCTAssertEqual(scheduler.nowNanoseconds, 0)
    }

    func testDeadlineWinnerCancelsAndJoinsSignalWaiter() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: waitersInstalled.arrive,
        )
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let coordinator = InputDeliveryWaitCoordinator(
            signal: signal,
            scheduler: scheduler.scheduler,
        )
        let wait = Task {
            try await coordinator.waitUntil(
                timeoutNanoseconds: 100,
                isSettled: { false },
                validateHealth: {},
                timeoutError: {
                    InputObserverInterruptionError.timeout
                },
            )
        }
        try await waitersInstalled.wait(
            failureCleanup: .init(task: wait),
        )
        XCTAssertEqual(coordinator.activeWaiterCount, 1)
        XCTAssertEqual(scheduler.activeSleeperCount, 1)

        scheduler.advance(to: 100)

        do {
            try await wait.value
            XCTFail("Expected exact timeout")
        } catch let error as InputObserverInterruptionError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
    }

    func testCleanupBackoffWakesForLateObserverChange() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: waitersInstalled.arrive,
        )
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let coordinator = InputDeliveryWaitCoordinator(
            signal: signal,
            scheduler: scheduler.scheduler,
        )
        let wait = Task {
            await coordinator.waitForChangeOrDelay(
                nanoseconds: 100_000_000,
            )
        }
        try await waitersInstalled.wait(
            failureCleanup: .init(task: wait),
        )
        XCTAssertEqual(coordinator.activeWaiterCount, 1)
        XCTAssertEqual(scheduler.activeSleeperCount, 1)

        coordinator.signalChange()
        await wait.value

        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
        XCTAssertEqual(scheduler.nowNanoseconds, 0)
    }

    func testCleanupAttemptConsumesHistoryWithoutMissingLaterChange() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: waitersInstalled.arrive,
        )
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let coordinator = InputDeliveryWaitCoordinator(
            signal: signal,
            scheduler: scheduler.scheduler,
        )
        coordinator.signalChange()
        coordinator.markCleanupAttemptStarted()
        let wait = Task {
            await coordinator.waitForChangeOrDelay(
                nanoseconds: 100_000_000,
            )
        }
        try await waitersInstalled.wait(
            failureCleanup: .init(task: wait),
        )
        XCTAssertEqual(coordinator.activeWaiterCount, 1)
        XCTAssertEqual(scheduler.activeSleeperCount, 1)

        coordinator.signalChange()
        await wait.value

        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
        XCTAssertEqual(scheduler.nowNanoseconds, 0)
    }

    func testCoreGraphicsBackendDelegatesTimingAndCleanupBackoffToObserver() async throws {
        let observer = TimingInputDeliveryObserver()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postAccessChecker: { true },
        )

        do {
            try await backend.pause(nanoseconds: 123)
            XCTFail("Expected observer timing failure")
        } catch let error as InputObserverInterruptionError {
            XCTAssertEqual(error, .healthFailure)
        }
        await backend.pauseForCleanupRetry(nanoseconds: 456)

        XCTAssertEqual(observer.normalWaits, [123])
        XCTAssertEqual(observer.cleanupWaits, [456])
    }

    func testCoreGraphicsBackendRevalidatesObserverBeforePhysicalSink() async throws {
        let observer = TimingInputDeliveryObserver(
            postingValidationError: .healthFailure,
        )
        let counter = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postInvocationRecorder: counter.increment,
            postAccessChecker: { true },
        )

        do {
            try await pressKey(
                keyCode: KEY_RETURN,
                backend: backend,
            )
            XCTFail("Expected posting validation failure")
        } catch let error as InputObserverInterruptionError {
            XCTAssertEqual(error, .healthFailure)
        }
        XCTAssertEqual(observer.postingValidationCount, 1)
        XCTAssertEqual(observer.normalRegistrationCount, 0)
        XCTAssertEqual(counter.value, 0)
    }

    func testLateAcknowledgementWinsAtomicCleanupAdmissionWithoutRetryPost() async throws {
        let observer = CleanupAdmissionInputDeliveryObserver()
        let counter = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postAccessChecker: { true },
        )
        let release = preparedInputRelease(counter: counter)
        try observer.settle(
            release,
            postTimeNanoseconds: 777,
        )

        let postTime = try await backend.postForCleanup(
            release,
        )

        XCTAssertEqual(postTime, 777)
        XCTAssertEqual(observer.settledValidationCount, 1)
        XCTAssertEqual(observer.cleanupRegistrationCount, 0)
        XCTAssertFalse(observer.didWaitForObligation)
        XCTAssertEqual(counter.value, 0)
    }

    func testRetryAdmissionWinsAndOwnsExactlyOneCleanupPost() async throws {
        let observer = CleanupAdmissionInputDeliveryObserver()
        let counter = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postAccessChecker: { true },
        )
        let release = preparedInputRelease(counter: counter)

        let postTime = try await backend.postForCleanup(
            release,
        )

        XCTAssertGreaterThan(postTime, 0)
        XCTAssertEqual(
            observer.settledPostTime(for: release.obligationID),
            postTime,
        )
        XCTAssertEqual(observer.cleanupRegistrationCount, 1)
        XCTAssertTrue(observer.didWaitForObligation)
        XCTAssertEqual(counter.value, 1)
    }

    func testRealBackendAndObserverLinearizeCleanupAcknowledgementAndRetry()
        async throws
    {
        for route in [
            InputDeliveryRoute.process(4242),
            InputDeliveryRoute.session,
        ] {
            try await assertLateAcknowledgementWinsRealCleanup(route: route)
            try await assertRetryWinsRealCleanup(route: route)
        }
    }

    func testPreparedEventOwnershipPrecedesAdmissionAndAllowsSequentialRetry() async throws {
        let observer = TimingInputDeliveryObserver()
        let sink = BlockingPreparedInputSink()
        let backend = try CoreGraphicsInputEventBackend(
            route: .session,
            deliveryObserver: observer,
            postAccessChecker: { true },
        )
        let event = PreparedInputEvent(
            event: .keyDown(keyCode: KEY_RETURN, flags: []),
            eventType: .keyDown,
            sourceIdentity: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            obligationKind: .ordinary,
        ) { _, _, recordInvocation in
            recordInvocation()
            sink.invoke()
        }

        let first = Task.detached {
            try await backend.post(event)
        }
        try await sink.waitUntilFirstInvocation(
            failureCleanup: .combine(
                .init(action: sink.releaseFirstInvocation),
                .init(task: first),
            ),
        )

        do {
            _ = try await backend.post(event)
            XCTFail("Expected concurrent prepared-event use to be rejected")
        } catch let error as PreparedInputEventOwnershipError {
            XCTAssertEqual(error, .concurrentInvocation)
        }
        XCTAssertEqual(observer.normalRegistrationCount, 1)
        XCTAssertEqual(sink.invocationCount, 1)

        sink.releaseFirstInvocation()
        _ = try await first.value
        _ = try await backend.post(event)

        XCTAssertEqual(observer.normalRegistrationCount, 2)
        XCTAssertEqual(sink.invocationCount, 2)
    }

    func testProcessGuardIsLastFallibleStepBeforeAdmissionAndSink() async throws {
        let observer = ProcessRegistrationInputDeliveryObserver()
        let guardProbe = IndexedInputProcessGuard(retireAt: 2)
        let sink = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .process(4242),
            deliveryObserver: observer,
            executionBoundary: InputExecutionBoundary(
                validateEffect: { _ in },
                validateProcessRoute: guardProbe.validate,
            ),
            postAccessChecker: { true },
        )
        let event = PreparedInputEvent(
            event: .keyDown(keyCode: KEY_RETURN, flags: []),
            eventType: .keyDown,
            sourceIdentity: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            obligationKind: .ordinary,
        ) { _, _, recordInvocation in
            recordInvocation()
            sink.increment()
        }

        _ = try await backend.post(event)

        XCTAssertEqual(guardProbe.validationCount, 1)
        XCTAssertEqual(observer.registrationCount, 1)
        XCTAssertEqual(sink.value, 1)
    }

    func testProcessRetirementBeforeAdmissionLeavesNoAttemptOrSink() async throws {
        let observer = ProcessRegistrationInputDeliveryObserver()
        let guardProbe = IndexedInputProcessGuard(retireAt: 1)
        let sink = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .process(4242),
            deliveryObserver: observer,
            executionBoundary: InputExecutionBoundary(
                validateEffect: { _ in },
                validateProcessRoute: guardProbe.validate,
            ),
            postAccessChecker: { true },
        )
        let event = PreparedInputEvent(
            event: .keyDown(keyCode: KEY_RETURN, flags: []),
            eventType: .keyDown,
            sourceIdentity: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            obligationKind: .ordinary,
        ) { _, _, recordInvocation in
            recordInvocation()
            sink.increment()
        }

        do {
            _ = try await backend.post(event)
            XCTFail("Expected process route retirement")
        } catch let error as InputProcessRouteRetired {
            XCTAssertEqual(error, InputProcessRouteRetired(pid: 4242))
        }

        XCTAssertEqual(guardProbe.validationCount, 1)
        XCTAssertEqual(observer.registrationCount, 0)
        XCTAssertEqual(sink.value, 0)
    }

    func testRetiredProcessCannotSuppressSessionGlobalSafetyRelease() async throws {
        let observer = ProcessRegistrationInputDeliveryObserver()
        let guardProbe = RetiredInputProcessGuard()
        let sink = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .process(4242),
            deliveryObserver: observer,
            executionBoundary: InputExecutionBoundary(
                validateEffect: { _ in },
                validateProcessRoute: guardProbe.validate,
            ),
            postAccessChecker: { true },
        )
        let release = PreparedInputEvent(
            event: .keyUp(keyCode: KEY_RETURN, flags: []),
            eventType: .keyUp,
            sourceIdentity: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            obligationKind: .safetyRelease,
        ) { _, _, recordInvocation in
            recordInvocation()
            sink.increment()
        }

        let firstPostTime = try await backend.postForCleanup(release)
        let secondPostTime = try await backend.postForCleanup(release)

        XCTAssertGreaterThan(firstPostTime, 0)
        XCTAssertEqual(secondPostTime, firstPostTime)
        XCTAssertEqual(guardProbe.validationCount, 1)
        XCTAssertEqual(observer.registrationCount, 0)
        XCTAssertEqual(sink.value, 1)
        XCTAssertEqual(release.invocationEvidence, .invoked(count: 1))
    }

    func testRetirementAfterSafetyReleaseInvocationNeverDuplicatesRelease() async throws {
        let observer = RetiringAfterInvocationInputDeliveryObserver()
        let sink = LockedInputObserverCounter()
        let backend = try CoreGraphicsInputEventBackend(
            route: .process(4242),
            deliveryObserver: observer,
            executionBoundary: .unrestricted,
            postAccessChecker: { true },
        )
        let release = PreparedInputEvent(
            event: .mouseUp(
                point: CGPoint(x: 25, y: 50),
                button: .left,
                modifiers: [],
                clickCount: 1,
            ),
            eventType: .leftMouseUp,
            sourceIdentity: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            obligationKind: .safetyRelease,
        ) { _, _, recordInvocation in
            recordInvocation()
            sink.increment()
        }

        let firstPostTime = try await backend.postForCleanup(release)
        let secondPostTime = try await backend.postForCleanup(release)

        XCTAssertGreaterThan(firstPostTime, 0)
        XCTAssertEqual(secondPostTime, firstPostTime)
        XCTAssertEqual(observer.registrationCount, 1)
        XCTAssertEqual(sink.value, 1)
        XCTAssertEqual(release.invocationEvidence, .invoked(count: 1))
    }

    func testObserverRecoveryCoordinatorJoinsConcurrentRecovery() async throws {
        let participants = InputObserverCountdown(2)
        let probe = InputObserverRecoveryProbe()
        let coordinator = InputObserverRecoveryCoordinator(
            recoveryParticipantDidEnter: participants.arrive,
        )
        let first = Task {
            try await coordinator.recover {
                try await probe.recover()
            }
        }
        try await probe.waitUntilRecoveryStarted(
            failureCleanup: .combine(
                .init(action: probe.releaseRecovery),
                .init(task: first),
            ),
        )
        let second = Task {
            try await coordinator.recover {
                try await probe.recover()
            }
        }
        try await participants.wait(
            failureCleanup: .combine(
                .init(action: probe.releaseRecovery),
                .init(task: first),
                .init(task: second),
            ),
        )

        XCTAssertEqual(probe.recoveryStartCount, 1)
        probe.releaseRecovery()
        try await first.value
        try await second.value

        XCTAssertEqual(probe.recoveryStartCount, 1)
        XCTAssertEqual(probe.recoveryFinishCount, 1)
    }

    func testObserverRecoveryFailureIsSharedThenRetriesSameFrozenRoute() async throws {
        for route in [
            InputDeliveryRoute.process(4242),
            InputDeliveryRoute.session,
        ] {
            let participants = InputObserverCountdown(2)
            let probe = RoutedInputObserverRecoveryProbe(
                route: route,
                failuresRemaining: 1,
            )
            let coordinator = InputObserverRecoveryCoordinator(
                recoveryParticipantDidEnter: participants.arrive,
            )
            let first = Task {
                try await coordinator.recover {
                    try await probe.recover()
                }
            }
            try await probe.waitUntilRecoveryStarted(
                failureCleanup: .combine(
                    .init(action: probe.releaseRecovery),
                    .init(task: first),
                ),
            )
            let second = Task {
                try await coordinator.recover {
                    try await probe.recover()
                }
            }
            try await participants.wait(
                failureCleanup: .combine(
                    .init(action: probe.releaseRecovery),
                    .init(task: first),
                    .init(task: second),
                ),
            )
            probe.releaseRecovery()

            for task in [first, second] {
                do {
                    try await task.value
                    XCTFail("Expected shared reinstall failure for \(route)")
                } catch let error as InputObserverRecoveryProbeError {
                    XCTAssertEqual(error, .reinstallFailed(route))
                }
            }

            try await coordinator.recover {
                try await probe.recover()
            }
            XCTAssertEqual(probe.attemptedRoutes, [route, route])
            XCTAssertEqual(probe.successCount, 1)
        }
    }

    func testObserverStopJoinsRecoveryAndBecomesTerminal() async throws {
        let stopBegan = InputObserverOneShot()
        let probe = InputObserverRecoveryProbe()
        let coordinator = InputObserverRecoveryCoordinator(
            stopDidBegin: stopBegan.signal,
        )
        let recovery = Task {
            try await coordinator.recover {
                try await probe.recover()
            }
        }
        try await probe.waitUntilRecoveryStarted(
            failureCleanup: .combine(
                .init(action: probe.releaseRecovery),
                .init(task: recovery),
            ),
        )
        let firstStop = Task {
            await coordinator.stop {
                await probe.stop()
            }
        }
        try await stopBegan.wait(
            failureCleanup: .combine(
                .init(action: probe.releaseRecovery),
                .init(task: recovery),
                .init(task: firstStop),
            ),
        )

        do {
            try await coordinator.recover {
                try await probe.recover()
            }
            XCTFail("Expected recovery admission to close during stop")
        } catch let error as InputDeliveryLedgerError {
            guard case .observerFailure = error else {
                return XCTFail("Expected observerFailure, got \(error)")
            }
        }

        let secondStop = Task {
            await coordinator.stop {
                await probe.stop()
            }
        }
        probe.releaseRecovery()
        try await recovery.value
        await firstStop.value
        await secondStop.value
        await coordinator.stop {
            await probe.stop()
        }

        XCTAssertEqual(
            probe.events,
            [.recoveryStarted, .recoveryFinished, .stopped],
        )
    }

    func testTapCallbackContextLeaseReleasesExactlyOnceAcrossConcurrentCallers()
        async throws
    {
        let releases = LockedInputObserverCounter()
        var context: InputTapContextLifetimeProbe? = InputTapContextLifetimeProbe(
            onDeinit: releases.increment,
        )
        let lease = try InputTapCallbackContextLease(retaining: XCTUnwrap(context))
        context = nil

        XCTAssertEqual(releases.value, 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    lease.release()
                }
            }
        }

        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(releases.value, 1)
        lease.release()
        XCTAssertEqual(releases.value, 1)
    }

    func testTapCallbackContextLeaseDeinitReleasesUnclaimedContext() throws {
        let releases = LockedInputObserverCounter()
        var context: InputTapContextLifetimeProbe? = InputTapContextLifetimeProbe(
            onDeinit: releases.increment,
        )
        var lease: InputTapCallbackContextLease? = try InputTapCallbackContextLease(
            retaining: XCTUnwrap(context),
        )
        context = nil

        XCTAssertEqual(releases.value, 0)
        lease = nil

        XCTAssertNil(lease)
        XCTAssertEqual(releases.value, 1)
    }

    func testTapCallbackContextDeactivationQuiescesInFlightAndQueuedCallbacksBeforeRelease()
        async throws
    {
        let handler = BlockingPreparedInputSink()
        let installationID = UUID()
        let context = InputTapEventCallbackContext(
            installationID: installationID,
            eventHandler: { _, _, receivedInstallationID in
                XCTAssertEqual(receivedInstallationID, installationID)
                handler.invoke()
            },
        )
        let lease = InputTapCallbackContextLease(retaining: context)
        let callbackCompleted = InputObserverOneShot()
        let callback = Task.detached {
            defer { callbackCompleted.signal() }
            context.record(
                type: .keyDown,
                event: CGEvent(source: nil)!,
            )
        }
        try await handler.waitUntilFirstInvocation(
            failureCleanup: .combine(
                .init(action: handler.releaseFirstInvocation),
                .init(task: callback),
            ),
        )

        let deactivationStarted = InputObserverOneShot()
        let deactivationCompleted = InputObserverOneShot()
        let deactivation = Task.detached {
            deactivationStarted.signal()
            context.deactivate()
            deactivationCompleted.signal()
        }
        try await deactivationStarted.wait(
            failureCleanup: .combine(
                .init(action: handler.releaseFirstInvocation),
                .init(task: callback),
                .init(task: deactivation),
            ),
        )
        handler.releaseFirstInvocation()
        try await callbackCompleted.wait(
            failureCleanup: .combine(
                .init(task: callback),
                .init(task: deactivation),
            ),
        )
        try await deactivationCompleted.wait(
            failureCleanup: .combine(
                .init(task: callback),
                .init(task: deactivation),
            ),
        )
        _ = await callback.value
        _ = await deactivation.value

        try context.record(
            type: CGEventType.keyDown,
            event: XCTUnwrap(CGEvent(source: nil)),
        )
        XCTAssertEqual(handler.invocationCount, 1)
        XCTAssertFalse(lease.isReleased)
        lease.release()
        XCTAssertTrue(lease.isReleased)
    }

    func testTapInvalidationRegistryDeliversCurrentInstallationExactlyOnce() throws {
        let registry = InputTapInvalidationRegistry()
        let events = LockedInputTapInvalidationEvents()
        let port = InputTapPortLifetime(
            identity: InputTapPortIdentity(rawValue: 0xA1),
            retaining: NSObject(),
        )
        let installationID = UUID()
        try registry.register(
            port: port,
            installationID: installationID,
            handler: events.record,
        )

        XCTAssertEqual(registry.activeRegistrationCount, 1)
        XCTAssertTrue(
            registry.recordInvalidation(
                port: port,
            ),
        )
        XCTAssertFalse(
            registry.recordInvalidation(
                port: port,
            ),
        )

        XCTAssertEqual(
            events.values,
            [
                InputTapInvalidation(
                    port: port.identity,
                    installationID: installationID,
                ),
            ],
        )
        XCTAssertEqual(registry.activeRegistrationCount, 0)
    }

    func testCoreGraphicsInvalidationIgnoresNilAndUnrelatedContext() throws {
        var context = CFMachPortContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
        )
        let port = try XCTUnwrap(
            CFMachPortCreate(
                kCFAllocatorDefault,
                inputObserverTestMachPortCallback,
                &context,
                nil,
            ),
        )
        defer { CFMachPortInvalidate(port) }

        let registry = InputTapInvalidationRegistry()
        let lifetime = InputTapPortLifetime(port: port)
        let events = LockedInputTapInvalidationEvents()
        try registry.register(
            port: lifetime,
            installationID: UUID(),
            handler: events.record,
        )
        XCTAssertTrue(
            recordCoreGraphicsInputTapInvalidation(
                port: port,
                info: nil,
                registry: registry,
            ),
        )

        try registry.register(
            port: lifetime,
            installationID: UUID(),
            handler: events.record,
        )
        var unrelatedContext = 0
        XCTAssertTrue(
            withUnsafeMutablePointer(to: &unrelatedContext) { pointer in
                recordCoreGraphicsInputTapInvalidation(
                    port: port,
                    info: UnsafeMutableRawPointer(pointer),
                    registry: registry,
                )
            },
        )
        XCTAssertEqual(events.values.count, 2)
        XCTAssertEqual(registry.activeRegistrationCount, 0)
    }

    func testTapInvalidationRegistryRejectsStaleUnregisterAndIgnoresIntentionalDetach()
        throws
    {
        let registry = InputTapInvalidationRegistry()
        let events = LockedInputTapInvalidationEvents()
        let reusedPort = InputTapPortIdentity(rawValue: 0xA2)
        let oldPort = InputTapPortLifetime(
            identity: reusedPort,
            retaining: NSObject(),
        )
        let currentPort = InputTapPortLifetime(
            identity: reusedPort,
            retaining: NSObject(),
        )
        let oldInstallationID = UUID()
        let currentInstallationID = UUID()
        try registry.register(
            port: oldPort,
            installationID: oldInstallationID,
            handler: events.record,
        )

        XCTAssertFalse(
            registry.unregister(
                port: currentPort,
                installationID: oldInstallationID,
            ),
            "a distinct lifetime at the same raw address must not detach the owner",
        )
        XCTAssertTrue(
            registry.unregister(
                port: oldPort,
                installationID: oldInstallationID,
            ),
        )

        try registry.register(
            port: currentPort,
            installationID: currentInstallationID,
            handler: events.record,
        )
        XCTAssertFalse(
            registry.recordInvalidation(
                port: oldPort,
            ),
            "a stale callback must not evict the replacement at a reused port identity",
        )
        XCTAssertEqual(registry.activeRegistrationCount, 1)
        XCTAssertTrue(
            registry.recordInvalidation(
                port: currentPort,
            ),
        )
        XCTAssertEqual(
            events.values,
            [
                InputTapInvalidation(
                    port: reusedPort,
                    installationID: currentInstallationID,
                ),
            ],
        )
        XCTAssertEqual(registry.activeRegistrationCount, 0)
    }

    func testTapInvalidationRegistryRejectsDuplicatePortOwnership() throws {
        let registry = InputTapInvalidationRegistry()
        let identity = InputTapPortIdentity(rawValue: 0xA4)
        let port = InputTapPortLifetime(
            identity: identity,
            retaining: NSObject(),
        )
        let firstInstallationID = UUID()
        try registry.register(
            port: port,
            installationID: firstInstallationID,
            handler: { _ in },
        )

        XCTAssertThrowsError(
            try registry.register(
                port: InputTapPortLifetime(
                    identity: identity,
                    retaining: NSObject(),
                ),
                installationID: UUID(),
                handler: { _ in },
            ),
        ) { error in
            XCTAssertEqual(
                error as? InputTapInvalidationRegistryError,
                .portAlreadyRegistered(identity),
            )
        }
        XCTAssertEqual(registry.activeRegistrationCount, 1)
    }

    func testAlreadyInvalidatedTapFailsAdmissionAndReleasesEveryOwner()
        async throws
    {
        let registry = InputTapInvalidationRegistry()
        let releasedContexts = LockedInputObserverCounter()
        let factory = FakeInputTapInstallationFactory(
            registry: registry,
            releasedContexts: releasedContexts,
        )
        factory.invalidateNextBeforeAdmission()

        do {
            _ = try await CoreGraphicsInputRouteObserver.start(
                route: .session,
                eventMask: CGEventMask(1) << CGEventType.keyDown.rawValue,
                executionBoundary: .unrestricted,
                tapInstallationFactory: factory,
            )
            XCTFail("Expected an already-invalid tap to fail admission")
        } catch let error as FakeInputTapLifecycleError {
            XCTAssertEqual(error, .unhealthy(.session))
        }

        XCTAssertEqual(registry.activeRegistrationCount, 0)
        XCTAssertEqual(factory.activeOwnerCount, 0)
        XCTAssertEqual(releasedContexts.value, 1)
    }

    func testCoreGraphicsObserverLinearizesPostingBeforeConcurrentCurrentInvalidation()
        async throws
    {
        for route in [
            InputDeliveryRoute.process(4242),
            InputDeliveryRoute.session,
        ] {
            try await assertPostingWinsConcurrentInvalidation(route: route)
        }
    }

    func testCoreGraphicsObserverRejectsPostingWhenConcurrentInvalidationWins()
        async throws
    {
        for route in [
            InputDeliveryRoute.process(4242),
            InputDeliveryRoute.session,
        ] {
            try await assertInvalidationWinsConcurrentPosting(route: route)
        }
    }

    func testStoppedFinalizationRejectsCallbackAcceptedAfterProvisionalReceipt()
        async throws
    {
        let registry = InputTapInvalidationRegistry()
        let releasedContexts = LockedInputObserverCounter()
        let factory = FakeInputTapInstallationFactory(
            registry: registry,
            releasedContexts: releasedContexts,
        )
        let observer = try await CoreGraphicsInputRouteObserver.start(
            route: .session,
            eventMask: CGEventMask(1) << CGEventType.keyDown.rawValue,
            executionBoundary: .unrestricted,
            tapInstallationFactory: factory,
        )
        let installation = try XCTUnwrap(factory.installations.first)
        let event = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: KEY_RETURN,
                keyDown: true,
            ),
        )
        let attempt = InputDeliveryAttempt(
            token: 808,
            obligationID: UUID(),
            obligationKind: .ordinary,
            eventType: .keyDown,
            source: InputEventSourceIdentity(
                unixProcessID: event.getIntegerValueField(
                    .eventSourceUnixProcessID,
                ),
                userID: event.getIntegerValueField(.eventSourceUserID),
                sourceStateID: event.getIntegerValueField(
                    .eventSourceStateID,
                ),
            ),
            route: .session,
            generation: observer.generation,
            postTimeNanoseconds: 909,
        )
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Int64(bitPattern: attempt.token),
        )
        XCTAssertEqual(
            try observer.invokeAttempt(
                attempt,
                forCleanup: false,
                invocation: {},
            ),
            .admitted,
        )
        installation.emit(type: .keyDown, event: event)
        let provisional = try observer.complete()

        installation.emit(type: .keyDown, event: event)
        await observer.stopAndJoin()

        XCTAssertThrowsError(
            try observer.validateStoppedCompletion(
                provisionalReceipt: provisional,
            ),
        )
        XCTAssertEqual(observer.activeWaiterCount, 0)
        XCTAssertEqual(registry.activeRegistrationCount, 0)
        XCTAssertEqual(releasedContexts.value, 1)
    }

    func testCurrentTapInvalidationWakesLongActionAndJoinsWaiters() async throws {
        let waitersInstalled = InputObserverCountdown(2)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: waitersInstalled.arrive,
        )
        let signal = InputDeliveryChangeSignal(
            waiterDidInstall: waitersInstalled.arrive,
        )
        let coordinator = InputDeliveryWaitCoordinator(
            signal: signal,
            scheduler: scheduler.scheduler,
        )
        let registry = InputTapInvalidationRegistry()
        let failed = LockedInputObserverFlag()
        let port = InputTapPortLifetime(
            identity: InputTapPortIdentity(rawValue: 0xA5),
            retaining: NSObject(),
        )
        let installationID = UUID()
        try registry.register(
            port: port,
            installationID: installationID,
        ) { _ in
            failed.set()
            coordinator.signalChange()
        }
        let action = Task {
            try await coordinator.waitWhileHealthy(
                nanoseconds: 3_600_000_000_000,
            ) {
                if failed.value() {
                    throw InputObserverInterruptionError.healthFailure
                }
            }
        }
        try await waitersInstalled.wait(
            failureCleanup: .combine(
                .init(action: coordinator.close),
                .init(task: action),
            ),
        )

        XCTAssertTrue(
            registry.recordInvalidation(
                port: port,
            ),
        )
        do {
            try await action.value
            XCTFail("Expected invalidation health failure")
        } catch let error as InputObserverInterruptionError {
            XCTAssertEqual(error, .healthFailure)
        }
        XCTAssertEqual(registry.activeRegistrationCount, 0)
        XCTAssertEqual(coordinator.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
        XCTAssertEqual(scheduler.nowNanoseconds, 0)
    }

    func testLongKeyHoldObserverFailureStartsCleanupBeforeNominalDeadline() async throws {
        let actionReady = InputObserverCountdown(3)
        let scheduler = ManualInputDeliveryWaitScheduler(
            sleeperDidInstall: actionReady.arrive,
        )
        let backend = InterruptibleInputEventBackend(
            scheduler: scheduler,
            waiterDidInstall: actionReady.arrive,
            eventDidPost: actionReady.arrive,
        )
        let action = Task {
            try await pressKeyHold(
                keyCode: KEY_SPACE,
                flags: .maskCommand,
                duration: 3600,
                backend: backend,
            )
        }
        try await actionReady.wait(
            failureCleanup: .combine(
                .init(action: backend.failObserver),
                .init(task: action),
            ),
        )
        XCTAssertEqual(
            backend.events,
            [.keyDown(keyCode: KEY_SPACE, flags: .maskCommand)],
        )
        XCTAssertEqual(backend.activeWaiterCount, 1)

        backend.failObserver()

        do {
            try await action.value
            XCTFail("Expected observer failure")
        } catch let error as InputObserverInterruptionError {
            XCTAssertEqual(error, .healthFailure)
        }
        XCTAssertEqual(
            backend.events,
            [
                .keyDown(keyCode: KEY_SPACE, flags: .maskCommand),
                .keyUp(keyCode: KEY_SPACE, flags: .maskCommand),
            ],
        )
        XCTAssertEqual(backend.outstandingCleanupObligationCount, 0)
        XCTAssertEqual(backend.activeWaiterCount, 0)
        XCTAssertEqual(scheduler.activeSleeperCount, 0)
        XCTAssertEqual(scheduler.nowNanoseconds, 0)
    }

    func testCoreGraphicsObserverOwnsCompleteInjectedTapLifecycleForBothRoutes()
        async throws
    {
        for route in [
            InputDeliveryRoute.process(4242),
            InputDeliveryRoute.session,
        ] {
            let waitersInstalled = InputObserverCountdown(2)
            let waitSignal = InputDeliveryChangeSignal(
                waiterDidInstall: waitersInstalled.arrive,
            )
            let waitScheduler = ManualInputDeliveryWaitScheduler(
                sleeperDidInstall: waitersInstalled.arrive,
            )
            let recoveryParticipants = InputObserverCountdown(2)
            let stopBegan = InputObserverOneShot()
            let recoveryCoordinator = InputObserverRecoveryCoordinator(
                recoveryParticipantDidEnter: recoveryParticipants.arrive,
                stopDidBegin: stopBegan.signal,
            )
            let registry = InputTapInvalidationRegistry()
            let releasedContexts = LockedInputObserverCounter()
            let factory = FakeInputTapInstallationFactory(
                registry: registry,
                releasedContexts: releasedContexts,
            )
            let observer = try await CoreGraphicsInputRouteObserver.start(
                route: route,
                eventMask: CGEventMask(1) << CGEventType.keyDown.rawValue,
                executionBoundary: .unrestricted,
                tapInstallationFactory: factory,
                waitCoordinator: InputDeliveryWaitCoordinator(
                    signal: waitSignal,
                    scheduler: waitScheduler.scheduler,
                ),
                recoveryCoordinator: recoveryCoordinator,
            )
            let first = try XCTUnwrap(factory.installations.first)
            XCTAssertEqual(first.route, route)
            XCTAssertEqual(registry.activeRegistrationCount, 1)
            XCTAssertEqual(factory.activeOwnerCount, 1)

            let longActionCompleted = InputObserverOneShot()
            let longAction = Task {
                defer { longActionCompleted.signal() }
                try await observer.waitWhileHealthy(
                    nanoseconds: 3_600_000_000_000,
                )
            }
            try await waitersInstalled.wait(
                failureCleanup: .combine(
                    .init(action: {
                        _ = first.triggerInvalidation()
                    }),
                    .init(task: longAction),
                ),
            )
            XCTAssertTrue(first.triggerInvalidation())
            try await longActionCompleted.wait(
                failureCleanup: .init(task: longAction),
            )
            do {
                try await longAction.value
                XCTFail("Expected current invalidation to interrupt \(route)")
            } catch let error as InputDeliveryLedgerError {
                guard case .observerFailure = error else {
                    return XCTFail("Expected observerFailure, got \(error)")
                }
            }
            XCTAssertEqual(observer.activeWaiterCount, 0)
            XCTAssertEqual(waitScheduler.activeSleeperCount, 0)

            let failedFinish = FakeInputTapFinishGate(shouldFail: true)
            factory.useFinishGateForNextInstallation(failedFinish)
            let firstRecoveryCompleted = InputObserverOneShot()
            let firstRecovery = Task {
                defer { firstRecoveryCompleted.signal() }
                try await observer.recoverForCleanup()
            }
            try await failedFinish.waitUntilStarted(
                failureCleanup: .combine(
                    .init(action: failedFinish.release),
                    .init(task: firstRecovery),
                ),
            )
            let secondRecoveryCompleted = InputObserverOneShot()
            let secondRecovery = Task {
                defer { secondRecoveryCompleted.signal() }
                try await observer.recoverForCleanup()
            }
            try await recoveryParticipants.wait(
                failureCleanup: .combine(
                    .init(action: failedFinish.release),
                    .init(task: firstRecovery),
                    .init(task: secondRecovery),
                ),
            )
            failedFinish.release()

            for completion in [firstRecoveryCompleted, secondRecoveryCompleted] {
                try await completion.wait(
                    failureCleanup: .combine(
                        .init(task: firstRecovery),
                        .init(task: secondRecovery),
                    ),
                )
            }
            for recovery in [firstRecovery, secondRecovery] {
                do {
                    try await recovery.value
                    XCTFail("Expected shared reinstall failure for \(route)")
                } catch let error as FakeInputTapLifecycleError {
                    XCTAssertEqual(error, .finishAdmissionFailed(route))
                }
            }
            XCTAssertEqual(factory.installations.count, 2)
            XCTAssertEqual(factory.activeOwnerCount, 0)
            XCTAssertEqual(registry.activeRegistrationCount, 0)
            XCTAssertEqual(releasedContexts.value, 2)

            let retryCompleted = InputObserverOneShot()
            let retry = Task {
                defer { retryCompleted.signal() }
                try await observer.recoverForCleanup()
            }
            try await retryCompleted.wait(
                failureCleanup: .init(task: retry),
            )
            try await retry.value
            let recovered = try XCTUnwrap(factory.installations.last)
            XCTAssertEqual(factory.installations.count, 3)
            XCTAssertEqual(factory.activeOwnerCount, 1)
            XCTAssertEqual(registry.activeRegistrationCount, 1)

            XCTAssertFalse(first.triggerInvalidation())
            try first.emit(
                type: .tapDisabledByTimeout,
                event: XCTUnwrap(CGEvent(source: nil)),
            )
            let staleRecoveryCompleted = InputObserverOneShot()
            let staleRecovery = Task {
                defer { staleRecoveryCompleted.signal() }
                try await observer.recoverForCleanup()
            }
            try await staleRecoveryCompleted.wait(
                failureCleanup: .init(task: staleRecovery),
            )
            try await staleRecovery.value
            XCTAssertEqual(
                factory.installations.count,
                3,
                "stale callback must not poison the replacement for \(route)",
            )

            recovered.invalidateInventory()
            let successfulFinish = FakeInputTapFinishGate(shouldFail: false)
            factory.useFinishGateForNextInstallation(successfulFinish)
            let finalRecoveryCompleted = InputObserverOneShot()
            let finalRecovery = Task {
                defer { finalRecoveryCompleted.signal() }
                try await observer.recoverForCleanup()
            }
            try await successfulFinish.waitUntilStarted(
                failureCleanup: .combine(
                    .init(action: successfulFinish.release),
                    .init(task: finalRecovery),
                ),
            )
            let stopCompleted = InputObserverOneShot()
            let stop = Task {
                defer { stopCompleted.signal() }
                await observer.stopAndJoin()
            }
            try await stopBegan.wait(
                failureCleanup: .combine(
                    .init(action: successfulFinish.release),
                    .init(task: finalRecovery),
                    .init(task: stop),
                ),
            )
            successfulFinish.release()
            try await finalRecoveryCompleted.wait(
                failureCleanup: .combine(
                    .init(task: finalRecovery),
                    .init(task: stop),
                ),
            )
            try await stopCompleted.wait(
                failureCleanup: .combine(
                    .init(task: finalRecovery),
                    .init(task: stop),
                ),
            )
            try await finalRecovery.value
            await stop.value

            XCTAssertEqual(factory.installations.count, 4)
            XCTAssertEqual(factory.activeOwnerCount, 0)
            XCTAssertEqual(registry.activeRegistrationCount, 0)
            XCTAssertEqual(releasedContexts.value, 4)
            XCTAssertEqual(observer.activeWaiterCount, 0)
            XCTAssertEqual(waitScheduler.activeSleeperCount, 0)
            XCTAssertFalse(
                factory.installations.last?.triggerInvalidation() ?? true,
            )

            do {
                try await observer.recoverForCleanup()
                XCTFail("Expected recovery admission to stay closed after stop")
            } catch let error as InputDeliveryLedgerError {
                guard case .observerFailure = error else {
                    return XCTFail("Expected observerFailure, got \(error)")
                }
            }
            XCTAssertEqual(factory.installations.count, 4)
        }
    }

    private func assertLateAcknowledgementWinsRealCleanup(
        route: InputDeliveryRoute,
    ) async throws {
        let registry = InputTapInvalidationRegistry()
        let releasedContexts = LockedInputObserverCounter()
        let factory = FakeInputTapInstallationFactory(
            registry: registry,
            releasedContexts: releasedContexts,
        )
        let observer = try await CoreGraphicsInputRouteObserver.start(
            route: route,
            eventMask: CGEventMask(1) << CGEventType.keyUp.rawValue,
            executionBoundary: .unrestricted,
            tapInstallationFactory: factory,
        )
        let initial = try XCTUnwrap(factory.installations.first)
        let observedEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: KEY_RETURN,
                keyDown: false,
            ),
        )
        let source = InputEventSourceIdentity(
            unixProcessID: observedEvent.getIntegerValueField(
                .eventSourceUnixProcessID,
            ),
            userID: observedEvent.getIntegerValueField(.eventSourceUserID),
            sourceStateID: observedEvent.getIntegerValueField(
                .eventSourceStateID,
            ),
        )
        let sink = LockedInputObserverCounter()
        let release = PreparedInputEvent(
            event: .keyUp(keyCode: KEY_RETURN, flags: []),
            eventType: .keyUp,
            sourceIdentity: source,
            obligationKind: .safetyRelease,
        ) { _, _, recordInvocation in
            recordInvocation()
            sink.increment()
        }
        let backend = try CoreGraphicsInputEventBackend(
            route: route,
            deliveryObserver: observer,
            executionBoundary: .unrestricted,
            postAccessChecker: { true },
        )

        initial.invalidateInventory()
        let finishGate = FakeInputTapFinishGate(shouldFail: false)
        factory.useFinishGateForNextInstallation(finishGate)
        let completed = InputObserverOneShot()
        let cleanup = Task {
            defer { completed.signal() }
            return try await backend.postForCleanup(release)
        }
        try await finishGate.waitUntilStarted(
            failureCleanup: .combine(
                .init(action: finishGate.release),
                .init(task: cleanup),
            ),
        )

        let replacement = try XCTUnwrap(factory.installations.last)
        let lateAttempt = InputDeliveryAttempt(
            token: 701,
            obligationID: release.obligationID,
            obligationKind: .safetyRelease,
            eventType: .keyUp,
            source: source,
            route: route,
            generation: observer.generation,
            postTimeNanoseconds: 777,
        )
        XCTAssertEqual(
            try observer.invokeAttempt(
                lateAttempt,
                forCleanup: true,
                invocation: {},
            ),
            .admitted,
        )
        observedEvent.setIntegerValueField(
            .eventSourceUserData,
            value: Int64(bitPattern: lateAttempt.token),
        )
        replacement.emit(type: .keyUp, event: observedEvent)
        finishGate.release()

        try await completed.wait(
            failureCleanup: .init(task: cleanup),
        )
        let cleanupPostTime = try await cleanup.value
        XCTAssertEqual(cleanupPostTime, 777)
        XCTAssertEqual(sink.value, 0)
        XCTAssertEqual(release.invocationEvidence, .notInvoked)
        await observer.stopAndJoin()
        XCTAssertEqual(registry.activeRegistrationCount, 0)
        XCTAssertEqual(factory.activeOwnerCount, 0)
        XCTAssertEqual(releasedContexts.value, 2)
    }

    private func assertRetryWinsRealCleanup(
        route: InputDeliveryRoute,
    ) async throws {
        let registry = InputTapInvalidationRegistry()
        let releasedContexts = LockedInputObserverCounter()
        let factory = FakeInputTapInstallationFactory(
            registry: registry,
            releasedContexts: releasedContexts,
        )
        let observer = try await CoreGraphicsInputRouteObserver.start(
            route: route,
            eventMask: CGEventMask(1) << CGEventType.keyUp.rawValue,
            executionBoundary: .unrestricted,
            tapInstallationFactory: factory,
        )
        let installation = try XCTUnwrap(factory.installations.first)
        let observedEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: KEY_RETURN,
                keyDown: false,
            ),
        )
        let source = InputEventSourceIdentity(
            unixProcessID: observedEvent.getIntegerValueField(
                .eventSourceUnixProcessID,
            ),
            userID: observedEvent.getIntegerValueField(.eventSourceUserID),
            sourceStateID: observedEvent.getIntegerValueField(
                .eventSourceStateID,
            ),
        )
        let sink = LockedInputObserverCounter()
        let release = PreparedInputEvent(
            event: .keyUp(keyCode: KEY_RETURN, flags: []),
            eventType: .keyUp,
            sourceIdentity: source,
            obligationKind: .safetyRelease,
        ) { token, _, recordInvocation in
            recordInvocation()
            sink.increment()
            observedEvent.setIntegerValueField(
                .eventSourceUserData,
                value: Int64(bitPattern: token),
            )
            installation.emit(type: .keyUp, event: observedEvent)
        }
        let backend = try CoreGraphicsInputEventBackend(
            route: route,
            deliveryObserver: observer,
            executionBoundary: .unrestricted,
            postAccessChecker: { true },
        )

        let postTime = try await backend.postForCleanup(release)

        XCTAssertGreaterThan(postTime, 0)
        XCTAssertEqual(
            observer.settledPostTime(for: release.obligationID),
            postTime,
        )
        XCTAssertEqual(sink.value, 1)
        XCTAssertEqual(release.invocationEvidence, .invoked(count: 1))
        await observer.stopAndJoin()
        XCTAssertEqual(registry.activeRegistrationCount, 0)
        XCTAssertEqual(factory.activeOwnerCount, 0)
        XCTAssertEqual(releasedContexts.value, 1)
    }

    private func assertPostingWinsConcurrentInvalidation(
        route: InputDeliveryRoute,
    ) async throws {
        let postingEntered = DispatchSemaphore(value: 0)
        let postingRelease = DispatchSemaphore(value: 0)
        let invalidationWillAcquire = DispatchSemaphore(value: 0)
        let order = LockedInputObserverOperations()
        let criticalSection = InputTapPostingCriticalSection(
            hooks: InputTapPostingCriticalSectionHooks(
                willAcquire: { operation in
                    if operation == .terminalFailure {
                        invalidationWillAcquire.signal()
                    }
                },
                didAcquire: { operation in
                    if operation == .terminalFailure {
                        order.record(.invalidation)
                    }
                },
            ),
        )
        let registry = InputTapInvalidationRegistry()
        let factory = FakeInputTapInstallationFactory(
            registry: registry,
            releasedContexts: LockedInputObserverCounter(),
        )
        let observer = try await CoreGraphicsInputRouteObserver.start(
            route: route,
            eventMask: CGEventMask(1) << CGEventType.keyDown.rawValue,
            executionBoundary: .unrestricted,
            tapInstallationFactory: factory,
            postingCriticalSection: criticalSection,
        )
        let installation = try XCTUnwrap(factory.installations.first)
        let attempt = InputDeliveryAttempt(
            token: 1,
            obligationID: UUID(),
            obligationKind: .ordinary,
            eventType: .keyDown,
            source: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            route: route,
            generation: observer.generation,
            postTimeNanoseconds: 303,
        )

        let postCompleted = DispatchSemaphore(value: 0)
        let post = Task.detached {
            defer { postCompleted.signal() }
            return try observer.invokeAttempt(
                attempt,
                forCleanup: false,
            ) {
                postingEntered.signal()
                postingRelease.wait()
                order.record(.sink)
            }
        }
        guard await boundedInputObserverSemaphoreWait(postingEntered) == .success else {
            postingRelease.signal()
            post.cancel()
            _ = try? await post.value
            await observer.stopAndJoin()
            return XCTFail("posting critical section did not start for \(route)")
        }

        let invalidationCompleted = DispatchSemaphore(value: 0)
        let invalidation = Task.detached {
            defer { invalidationCompleted.signal() }
            return installation.triggerInvalidation()
        }
        guard await boundedInputObserverSemaphoreWait(invalidationWillAcquire) == .success else {
            postingRelease.signal()
            post.cancel()
            invalidation.cancel()
            _ = try? await post.value
            _ = await invalidation.value
            await observer.stopAndJoin()
            return XCTFail(
                "current invalidation never reached the posting gate for \(route)",
            )
        }

        postingRelease.signal()
        let postFinished = await boundedInputObserverSemaphoreWait(postCompleted)
        let invalidationFinished = await boundedInputObserverSemaphoreWait(
            invalidationCompleted,
        )
        guard postFinished == .success,
              invalidationFinished == .success
        else {
            postingRelease.signal()
            post.cancel()
            invalidation.cancel()
            _ = try? await post.value
            _ = await invalidation.value
            await observer.stopAndJoin()
            return XCTFail(
                "posting or invalidation did not settle for \(route)",
            )
        }

        let admission = try await post.value
        let invalidated = await invalidation.value
        XCTAssertEqual(admission, .admitted)
        XCTAssertTrue(invalidated)
        XCTAssertEqual(order.values, [.sink, .invalidation])
        await observer.stopAndJoin()
        XCTAssertEqual(criticalSection.activeOwnerCount, 0)
        XCTAssertEqual(registry.activeRegistrationCount, 0)
    }

    private func assertInvalidationWinsConcurrentPosting(
        route: InputDeliveryRoute,
    ) async throws {
        let invalidationDidAcquire = DispatchSemaphore(value: 0)
        let invalidationRelease = DispatchSemaphore(value: 0)
        let postingWillAcquire = DispatchSemaphore(value: 0)
        let order = LockedInputObserverOperations()
        let criticalSection = InputTapPostingCriticalSection(
            hooks: InputTapPostingCriticalSectionHooks(
                willAcquire: { operation in
                    if operation == .eventSink {
                        postingWillAcquire.signal()
                    }
                },
                didAcquire: { operation in
                    guard operation == .terminalFailure else {
                        return
                    }
                    order.record(.invalidation)
                    invalidationDidAcquire.signal()
                    invalidationRelease.wait()
                },
            ),
        )
        let registry = InputTapInvalidationRegistry()
        let factory = FakeInputTapInstallationFactory(
            registry: registry,
            releasedContexts: LockedInputObserverCounter(),
        )
        let observer = try await CoreGraphicsInputRouteObserver.start(
            route: route,
            eventMask: CGEventMask(1) << CGEventType.keyDown.rawValue,
            executionBoundary: .unrestricted,
            tapInstallationFactory: factory,
            postingCriticalSection: criticalSection,
        )
        let installation = try XCTUnwrap(factory.installations.first)
        let attempt = InputDeliveryAttempt(
            token: 2,
            obligationID: UUID(),
            obligationKind: .ordinary,
            eventType: .keyDown,
            source: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            route: route,
            generation: observer.generation,
            postTimeNanoseconds: 404,
        )

        let invalidationCompleted = DispatchSemaphore(value: 0)
        let invalidation = Task.detached {
            defer { invalidationCompleted.signal() }
            return installation.triggerInvalidation()
        }
        guard await boundedInputObserverSemaphoreWait(invalidationDidAcquire) == .success else {
            invalidationRelease.signal()
            invalidation.cancel()
            _ = await invalidation.value
            await observer.stopAndJoin()
            return XCTFail(
                "current invalidation did not acquire the terminal gate for \(route)",
            )
        }

        let postCompleted = DispatchSemaphore(value: 0)
        let post = Task.detached {
            defer { postCompleted.signal() }
            return try observer.invokeAttempt(
                attempt,
                forCleanup: false,
            ) {
                order.record(.sink)
            }
        }
        guard await boundedInputObserverSemaphoreWait(postingWillAcquire) == .success else {
            invalidationRelease.signal()
            post.cancel()
            invalidation.cancel()
            _ = try? await post.value
            _ = await invalidation.value
            await observer.stopAndJoin()
            return XCTFail(
                "posting did not reach the terminal gate for \(route)",
            )
        }

        invalidationRelease.signal()
        let invalidationFinished = await boundedInputObserverSemaphoreWait(
            invalidationCompleted,
        )
        let postFinished = await boundedInputObserverSemaphoreWait(postCompleted)
        guard invalidationFinished == .success,
              postFinished == .success
        else {
            invalidationRelease.signal()
            post.cancel()
            invalidation.cancel()
            _ = try? await post.value
            _ = await invalidation.value
            await observer.stopAndJoin()
            return XCTFail(
                "invalidation or rejected posting did not settle for \(route)",
            )
        }

        let invalidated = await invalidation.value
        XCTAssertTrue(invalidated)
        do {
            _ = try await post.value
            XCTFail("Expected current invalidation to reject posting for \(route)")
        } catch let error as InputDeliveryLedgerError {
            guard case .observerFailure = error else {
                return XCTFail("Expected observerFailure for \(route), got \(error)")
            }
        }
        XCTAssertEqual(order.values, [.invalidation])
        await observer.stopAndJoin()
        XCTAssertEqual(criticalSection.activeOwnerCount, 0)
        XCTAssertEqual(registry.activeRegistrationCount, 0)
    }

    private func preparedInputRelease(
        counter: LockedInputObserverCounter,
    ) -> PreparedInputEvent {
        PreparedInputEvent(
            event: .keyUp(keyCode: KEY_RETURN, flags: []),
            eventType: .keyUp,
            sourceIdentity: InputEventSourceIdentity(
                unixProcessID: 101,
                userID: 202,
            ),
            obligationKind: .safetyRelease,
        ) { _, _, recordInvocation in
            recordInvocation()
            counter.increment()
        }
    }
}

private enum InputObserverRecoveryProbeError: Error, Equatable {
    case reinstallFailed(InputDeliveryRoute)
}

private final class RoutedInputObserverRecoveryProbe: @unchecked Sendable {
    private let route: InputDeliveryRoute
    private let started = InputObserverOneShot()
    private let released = InputObserverOneShot()
    private let lock = NSLock()
    private var failuresRemaining: Int
    private var routes: [InputDeliveryRoute] = []
    private var successes = 0

    init(
        route: InputDeliveryRoute,
        failuresRemaining: Int,
    ) {
        self.route = route
        self.failuresRemaining = failuresRemaining
    }

    func recover() async throws {
        let shouldFail = lock.withLock {
            routes.append(route)
            guard failuresRemaining > 0 else {
                return false
            }
            failuresRemaining -= 1
            return true
        }
        started.signal()
        try await released.wait()
        if shouldFail {
            throw InputObserverRecoveryProbeError.reinstallFailed(route)
        }
        lock.withLock {
            successes += 1
        }
    }

    func waitUntilRecoveryStarted(
        failureCleanup: InputObserverBarrierFailureCleanup = .none,
    ) async throws {
        try await started.wait(failureCleanup: failureCleanup)
    }

    func releaseRecovery() {
        released.signal()
    }

    var attemptedRoutes: [InputDeliveryRoute] {
        lock.withLock { routes }
    }

    var successCount: Int {
        lock.withLock { successes }
    }
}

private final class InputObserverRecoveryProbe: @unchecked Sendable {
    enum Event: Equatable {
        case recoveryStarted
        case recoveryFinished
        case stopped
    }

    private let started = InputObserverOneShot()
    private let released = InputObserverOneShot()
    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    func recover() async throws {
        lock.withLock {
            recordedEvents.append(.recoveryStarted)
        }
        started.signal()
        try await released.wait()
        lock.withLock {
            recordedEvents.append(.recoveryFinished)
        }
    }

    func stop() async {
        lock.withLock {
            recordedEvents.append(.stopped)
        }
    }

    func waitUntilRecoveryStarted(
        failureCleanup: InputObserverBarrierFailureCleanup = .none,
    ) async throws {
        try await started.wait(failureCleanup: failureCleanup)
    }

    func releaseRecovery() {
        released.signal()
    }

    var recoveryStartCount: Int {
        lock.withLock {
            recordedEvents.count { $0 == .recoveryStarted }
        }
    }

    var recoveryFinishCount: Int {
        lock.withLock {
            recordedEvents.count { $0 == .recoveryFinished }
        }
    }

    var events: [Event] {
        lock.withLock { recordedEvents }
    }
}

private struct InputObserverBarrierFailureCleanup: Sendable {
    let cancel: @Sendable () -> Void
    let join: @Sendable () async -> Void

    init(
        task: Task<some Any, some Error>,
    ) {
        cancel = task.cancel
        join = {
            _ = await task.result
        }
    }

    init(
        action: @escaping @Sendable () -> Void,
    ) {
        cancel = action
        join = {}
    }

    private init(
        cancel: @escaping @Sendable () -> Void,
        join: @escaping @Sendable () async -> Void,
    ) {
        self.cancel = cancel
        self.join = join
    }

    static let none = InputObserverBarrierFailureCleanup(
        cancel: {},
        join: {},
    )

    static func combine(
        _ cleanups: InputObserverBarrierFailureCleanup...,
    ) -> InputObserverBarrierFailureCleanup {
        InputObserverBarrierFailureCleanup(
            cancel: {
                for cleanup in cleanups {
                    cleanup.cancel()
                }
            },
            join: {
                for cleanup in cleanups {
                    await cleanup.join()
                }
            },
        )
    }

    func run() async {
        cancel()
        await join()
    }
}

private enum InputObserverBarrierError: Error {
    case timedOut
    case lostWaiters
}

private enum InputObserverBarrierOutcome: @unchecked Sendable {
    case waiter(Result<Void, any Error>)
    case timeout
    case cancelled
    case lostWaiters
}

private func waitForInputObserverBarrier(
    timeout: Duration,
    waiter: @escaping @Sendable () async throws -> Void,
) async throws {
    let outcome = await withTaskGroup(
        of: InputObserverBarrierOutcome.self,
        returning: InputObserverBarrierOutcome.self,
    ) { group in
        group.addTask {
            do {
                try await waiter()
                return .waiter(.success(()))
            } catch {
                return .waiter(.failure(error))
            }
        }
        group.addTask {
            do {
                try await ContinuousClock().sleep(for: timeout)
                return .timeout
            } catch {
                return .cancelled
            }
        }
        var first: InputObserverBarrierOutcome?
        while let outcome = await group.next() {
            if case .cancelled = outcome {
                continue
            }
            first = outcome
            break
        }
        guard let first else {
            return .lostWaiters
        }
        group.cancelAll()
        while await group.next() != nil {}
        return first
    }
    switch outcome {
    case let .waiter(result):
        try result.get()
    case .timeout:
        throw InputObserverBarrierError.timedOut
    case .cancelled:
        throw CancellationError()
    case .lostWaiters:
        throw InputObserverBarrierError.lostWaiters
    }
}

private func boundedInputObserverSemaphoreWait(
    _ semaphore: DispatchSemaphore,
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + 2),
            )
        }
    }
}

private final class InputObserverOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: Duration
    private var signalled = false
    private var waiters: [
        UUID: CheckedContinuation<Void, any Error>
    ] = [:]

    init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    func signal() {
        let continuations = lock.withLock {
            guard !signalled else {
                return [CheckedContinuation<Void, any Error>]()
            }
            signalled = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: ())
        }
    }

    func wait(
        failureCleanup: InputObserverBarrierFailureCleanup = .none,
    ) async throws {
        do {
            try await waitForInputObserverBarrier(timeout: timeout) {
                try await self.waitWithoutTimeout()
            }
        } catch {
            await failureCleanup.run()
            throw error
        }
    }

    var activeWaiterCount: Int {
        lock.withLock { waiters.count }
    }

    private func waitWithoutTimeout() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if Task<Never, Never>.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard !signalled else {
                        return .success(())
                    }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                waiters.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class InputObserverCountdown: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: Duration
    private var remaining: Int
    private var waiters: [
        UUID: CheckedContinuation<Void, any Error>
    ] = [:]

    init(
        _ count: Int,
        timeout: Duration = .seconds(2),
    ) {
        precondition(count >= 0)
        remaining = count
        self.timeout = timeout
    }

    func arrive() {
        let continuations = lock.withLock {
            if remaining > 0 {
                remaining -= 1
            }
            guard remaining == 0 else {
                return [CheckedContinuation<Void, any Error>]()
            }
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: ())
        }
    }

    func wait(
        failureCleanup: InputObserverBarrierFailureCleanup = .none,
    ) async throws {
        do {
            try await waitForInputObserverBarrier(timeout: timeout) {
                try await self.waitWithoutTimeout()
            }
        } catch {
            await failureCleanup.run()
            throw error
        }
    }

    var activeWaiterCount: Int {
        lock.withLock { waiters.count }
    }

    private func waitWithoutTimeout() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if Task<Never, Never>.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard remaining != 0 else {
                        return .success(())
                    }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                waiters.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class IndexedInputProcessGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let retiredIndex: Int
    private var count = 0

    init(retireAt index: Int) {
        retiredIndex = index
    }

    func validate(_ pid: pid_t) throws {
        let index = lock.withLock {
            count += 1
            return count
        }
        if index == retiredIndex {
            throw InputProcessRouteRetired(pid: pid)
        }
    }

    var validationCount: Int {
        lock.withLock { count }
    }
}

private final class RetiredInputProcessGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func validate(_ pid: pid_t) throws {
        lock.withLock {
            count += 1
        }
        throw InputProcessRouteRetired(pid: pid)
    }

    var validationCount: Int {
        lock.withLock { count }
    }
}

private final class ProcessRegistrationInputDeliveryObserver:
    InputDeliveryObserving,
    @unchecked Sendable
{
    let route = InputDeliveryRoute.process(4242)
    let generation: UInt64 = 1
    private let lock = NSLock()
    private var registrations = 0

    func invokeAttempt(
        _: InputDeliveryAttempt,
        forCleanup _: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        lock.withLock {
            registrations += 1
        }
        try invocation()
        return .admitted
    }

    func validateSettledCleanupAttempt(
        _: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        nil
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

    func waitForAttempt(_: UInt64) async throws {}
    func waitForObligation(_: UUID) async throws {}
    func isObligationSettled(_: UUID) -> Bool {
        false
    }

    func settledPostTime(for _: UUID) -> UInt64? {
        nil
    }

    func recoverForCleanup() async throws {}

    func complete() throws -> InputExecutionReceipt {
        InputExecutionReceipt(
            route: route,
            postedEventCount: registrationCount,
            routedDeliveryObserved: true,
        )
    }

    var hasObservedDelivery: Bool {
        true
    }

    func stopAndJoin() async {}

    var registrationCount: Int {
        lock.withLock { registrations }
    }
}

private final class RetiringAfterInvocationInputDeliveryObserver:
    InputDeliveryObserving,
    @unchecked Sendable
{
    let route = InputDeliveryRoute.process(4242)
    let generation: UInt64 = 1
    private let lock = NSLock()
    private var registrations = 0

    func invokeAttempt(
        _: InputDeliveryAttempt,
        forCleanup _: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        lock.withLock {
            registrations += 1
        }
        try invocation()
        throw InputProcessRouteRetired(pid: 4242)
    }

    func validateSettledCleanupAttempt(
        _: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        nil
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

    func waitForAttempt(_: UInt64) async throws {}
    func waitForObligation(_: UUID) async throws {}
    func isObligationSettled(_: UUID) -> Bool {
        false
    }

    func settledPostTime(for _: UUID) -> UInt64? {
        nil
    }

    func recoverForCleanup() async throws {}

    func complete() throws -> InputExecutionReceipt {
        InputExecutionReceipt(
            route: route,
            postedEventCount: registrationCount,
            routedDeliveryObserved: false,
        )
    }

    var hasObservedDelivery: Bool {
        false
    }

    func stopAndJoin() async {}

    var registrationCount: Int {
        lock.withLock { registrations }
    }
}

private final class BlockingPreparedInputSink: @unchecked Sendable {
    private let firstInvocationRelease = DispatchSemaphore(value: 0)
    private let firstInvocationEntered = InputObserverOneShot()
    private let lock = NSLock()
    private var count = 0

    func invoke() {
        let invocation = lock.withLock {
            count += 1
            return count
        }
        guard invocation == 1 else {
            return
        }
        firstInvocationEntered.signal()
        firstInvocationRelease.wait()
    }

    func waitUntilFirstInvocation(
        failureCleanup: InputObserverBarrierFailureCleanup = .none,
    ) async throws {
        try await firstInvocationEntered.wait(
            failureCleanup: failureCleanup,
        )
    }

    func releaseFirstInvocation() {
        firstInvocationRelease.signal()
    }

    var invocationCount: Int {
        lock.withLock { count }
    }
}

private final class ManualInputDeliveryWaitScheduler: @unchecked Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private let sleeperDidInstall: (@Sendable () -> Void)?
    private var now: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]

    init(sleeperDidInstall: (@Sendable () -> Void)? = nil) {
        self.sleeperDidInstall = sleeperDidInstall
    }

    var scheduler: InputDeliveryWaitScheduler {
        InputDeliveryWaitScheduler(
            nowNanoseconds: { [weak self] in
                self?.nowNanoseconds ?? 0
            },
            sleepUntil: { [weak self] deadline in
                guard let self else {
                    throw InputObserverInterruptionError.schedulerReleased
                }
                try await sleep(until: deadline)
            },
        )
    }

    var nowNanoseconds: UInt64 {
        lock.withLock { now }
    }

    var activeSleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func advance(to newValue: UInt64) {
        let continuations: [CheckedContinuation<Void, any Error>] = lock.withLock {
            precondition(newValue >= now)
            now = newValue
            let ready = sleepers.filter { $0.value.deadline <= now }
            for id in ready.keys {
                sleepers.removeValue(forKey: id)
            }
            return ready.values.map(\.continuation)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func sleep(until deadline: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var didInstall = false
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if Task<Never, Never>.isCancelled {
                        return .failure(CancellationError())
                    }
                    if now >= deadline {
                        return .success(())
                    }
                    sleepers[id] = Sleeper(
                        deadline: deadline,
                        continuation: continuation,
                    )
                    didInstall = true
                    return nil
                }
                if didInstall {
                    sleeperDidInstall?()
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                sleepers.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class LockedInputObserverFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.withLock {
            isSet = true
        }
    }

    func value() -> Bool {
        lock.withLock { isSet }
    }
}

private final class LockedInputObserverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock {
            count += 1
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private enum InputObserverOperation: Equatable {
    case sink
    case invalidation
}

private final class LockedInputObserverOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [InputObserverOperation] = []

    func record(_ operation: InputObserverOperation) {
        lock.withLock {
            recorded.append(operation)
        }
    }

    var values: [InputObserverOperation] {
        lock.withLock { recorded }
    }
}

private final class InputTapContextLifetimeProbe: @unchecked Sendable {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private final class LockedInputTapInvalidationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [InputTapInvalidation] = []

    func record(_ event: InputTapInvalidation) {
        lock.withLock {
            recorded.append(event)
        }
    }

    var values: [InputTapInvalidation] {
        lock.withLock { recorded }
    }
}

private enum FakeInputTapLifecycleError: Error, Equatable {
    case unhealthy(InputDeliveryRoute)
    case inventoryMismatch(InputDeliveryRoute)
    case finishAdmissionFailed(InputDeliveryRoute)
}

private final class FakeInputTapFinishGate: @unchecked Sendable {
    let shouldFail: Bool

    private let started = InputObserverOneShot()
    private let released = InputObserverOneShot()

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func run(route: InputDeliveryRoute) async throws {
        started.signal()
        try await released.wait()
        if shouldFail {
            throw FakeInputTapLifecycleError.finishAdmissionFailed(route)
        }
    }

    func waitUntilStarted(
        failureCleanup: InputObserverBarrierFailureCleanup = .none,
    ) async throws {
        try await started.wait(failureCleanup: failureCleanup)
    }

    func release() {
        released.signal()
    }
}

private final class FakeInputTapInstallationFactory:
    InputTapInstallationPreparing,
    @unchecked Sendable
{
    private let registry: InputTapInvalidationRegistry
    private let releasedContexts: LockedInputObserverCounter
    private let lock = NSLock()
    private var nextPort: UInt = 0xB0
    private var nextFinishGate: FakeInputTapFinishGate?
    private var nextStartsInvalidated = false
    private var preparedInstallations: [FakeInputTapInstallation] = []

    init(
        registry: InputTapInvalidationRegistry,
        releasedContexts: LockedInputObserverCounter,
    ) {
        self.registry = registry
        self.releasedContexts = releasedContexts
    }

    @MainActor
    func prepare(
        route: InputDeliveryRoute,
        eventMask _: CGEventMask,
        validateProcessRoute: @escaping @Sendable () throws -> Void,
        eventHandler: @escaping InputTapEventHandler,
    ) throws -> any InputTapInstallationOwning {
        try validateProcessRoute()
        let state = lock.withLock {
            let port = InputTapPortLifetime(
                identity: InputTapPortIdentity(rawValue: nextPort),
                retaining: NSObject(),
            )
            nextPort += 1
            let gate = nextFinishGate
            let startsInvalidated = nextStartsInvalidated
            nextFinishGate = nil
            nextStartsInvalidated = false
            return (port, gate, startsInvalidated)
        }
        let installation = FakeInputTapInstallation(
            route: route,
            portLifetime: state.0,
            registry: registry,
            finishGate: state.1,
            startsInvalidated: state.2,
            eventHandler: eventHandler,
            releasedContexts: releasedContexts,
        )
        lock.withLock {
            preparedInstallations.append(installation)
        }
        return installation
    }

    func useFinishGateForNextInstallation(
        _ finishGate: FakeInputTapFinishGate,
    ) {
        lock.withLock {
            precondition(nextFinishGate == nil)
            nextFinishGate = finishGate
        }
    }

    func invalidateNextBeforeAdmission() {
        lock.withLock {
            precondition(!nextStartsInvalidated)
            nextStartsInvalidated = true
        }
    }

    var installations: [FakeInputTapInstallation] {
        lock.withLock { preparedInstallations }
    }

    var activeOwnerCount: Int {
        installations.count { !$0.isReleased }
    }
}

private final class FakeInputTapInstallation:
    InputTapInstallationOwning,
    @unchecked Sendable
{
    let route: InputDeliveryRoute
    let installationID = UUID()
    let portLifetime: InputTapPortLifetime
    var portIdentity: InputTapPortIdentity {
        portLifetime.identity
    }

    private struct State {
        var healthy = true
        var inventoryValid = true
        var detached = false
    }

    private let registry: InputTapInvalidationRegistry
    private let finishGate: FakeInputTapFinishGate?
    private let callbackContext: InputTapEventCallbackContext
    private let callbackContextLease: InputTapCallbackContextLease
    private let releasedContexts: LockedInputObserverCounter
    private let lock = NSLock()
    private var state: State

    init(
        route: InputDeliveryRoute,
        portLifetime: InputTapPortLifetime,
        registry: InputTapInvalidationRegistry,
        finishGate: FakeInputTapFinishGate?,
        startsInvalidated: Bool,
        eventHandler: @escaping InputTapEventHandler,
        releasedContexts: LockedInputObserverCounter,
    ) {
        self.route = route
        self.portLifetime = portLifetime
        self.registry = registry
        self.finishGate = finishGate
        self.releasedContexts = releasedContexts
        state = State(healthy: !startsInvalidated)
        let context = InputTapEventCallbackContext(
            installationID: installationID,
            eventHandler: eventHandler,
        )
        callbackContext = context
        callbackContextLease = InputTapCallbackContextLease(
            retaining: context,
        )
    }

    func requireHealthy() throws {
        let isHealthy = lock.withLock {
            state.healthy && !state.detached
        }
        guard isHealthy else {
            throw FakeInputTapLifecycleError.unhealthy(route)
        }
    }

    @MainActor
    func finishAdmission(
        invalidationHandler: @escaping @Sendable (
            InputTapInvalidation,
        ) -> Void,
    ) async throws {
        try registry.register(
            port: portLifetime,
            installationID: installationID,
            handler: invalidationHandler,
        )
        if !lock.withLock({ state.healthy }) {
            registry.recordInvalidation(port: portLifetime)
        }
        if let finishGate {
            try await finishGate.run(route: route)
        }
        try requireHealthy()
        try validateInventory()
    }

    @MainActor
    func validateInventory() throws {
        let isValid = lock.withLock {
            state.inventoryValid && !state.detached
        }
        guard isValid else {
            throw FakeInputTapLifecycleError.inventoryMismatch(route)
        }
    }

    @MainActor
    func detach() {
        let shouldDetach = lock.withLock {
            guard !state.detached else {
                return false
            }
            state.detached = true
            return true
        }
        guard shouldDetach else {
            return
        }
        callbackContext.deactivate()
        registry.unregister(
            port: portLifetime,
            installationID: installationID,
        )
    }

    @MainActor
    func awaitCallbackQuiescenceAndRelease() async {
        guard !callbackContextLease.isReleased else {
            return
        }
        callbackContextLease.release()
        releasedContexts.increment()
    }

    @discardableResult
    func triggerInvalidation() -> Bool {
        lock.withLock {
            state.healthy = false
        }
        return registry.recordInvalidation(
            port: portLifetime,
        )
    }

    func emit(type: CGEventType, event: CGEvent) {
        callbackContext.record(type: type, event: event)
    }

    func invalidateInventory() {
        lock.withLock {
            state.inventoryValid = false
        }
    }

    var isReleased: Bool {
        callbackContextLease.isReleased
    }
}

private final class TimingInputDeliveryObserver:
    InputDeliveryObserving,
    @unchecked Sendable
{
    let route = InputDeliveryRoute.session
    let generation: UInt64 = 1
    private let lock = NSLock()
    private let postingValidationError: InputObserverInterruptionError?
    private var normal: [UInt64] = []
    private var cleanup: [UInt64] = []
    private var validations = 0
    private var normalRegistrations = 0

    init(
        postingValidationError: InputObserverInterruptionError? = nil,
    ) {
        self.postingValidationError = postingValidationError
    }

    func validateForPosting() async throws {
        lock.withLock {
            validations += 1
        }
        if let postingValidationError {
            throw postingValidationError
        }
    }

    func waitWhileHealthy(nanoseconds: UInt64) async throws {
        lock.withLock {
            normal.append(nanoseconds)
        }
        throw InputObserverInterruptionError.healthFailure
    }

    func waitForChangeOrDelay(nanoseconds: UInt64) async {
        lock.withLock {
            cleanup.append(nanoseconds)
        }
    }

    var normalWaits: [UInt64] {
        lock.withLock { normal }
    }

    var cleanupWaits: [UInt64] {
        lock.withLock { cleanup }
    }

    var postingValidationCount: Int {
        lock.withLock { validations }
    }

    var normalRegistrationCount: Int {
        lock.withLock { normalRegistrations }
    }

    func invokeAttempt(
        _: InputDeliveryAttempt,
        forCleanup: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        lock.withLock {
            if !forCleanup {
                normalRegistrations += 1
            }
        }
        try invocation()
        return .admitted
    }

    func validateSettledCleanupAttempt(
        _: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        nil
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

    func waitForAttempt(_: UInt64) async throws {}
    func waitForObligation(_: UUID) async throws {}
    func isObligationSettled(_: UUID) -> Bool {
        false
    }

    func settledPostTime(for _: UUID) -> UInt64? {
        nil
    }

    func recoverForCleanup() async throws {}

    func complete() throws -> InputExecutionReceipt {
        InputExecutionReceipt(
            route: route,
            postedEventCount: 1,
            routedDeliveryObserved: true,
        )
    }

    var hasObservedDelivery: Bool {
        true
    }

    func stopAndJoin() async {}
}

private final class CleanupAdmissionInputDeliveryObserver:
    InputDeliveryObserving,
    @unchecked Sendable
{
    let route = InputDeliveryRoute.session
    let generation: UInt64 = 1
    private let ledger = InputDeliveryLedger(
        route: .session,
        generation: 1,
    )
    private let lock = NSLock()
    private var latestCleanupAttempt: InputDeliveryAttempt?
    private var cleanupRegistrations = 0
    private var settledValidations = 0
    private var waitedForObligation = false

    func settle(
        _ event: PreparedInputEvent,
        postTimeNanoseconds: UInt64,
    ) throws {
        guard let eventType = event.eventType,
              let source = event.sourceIdentity
        else {
            throw InputDeliveryLedgerError.observerFailure(
                "test cleanup event lacks delivery identity",
            )
        }
        let attempt = InputDeliveryAttempt(
            token: 700,
            obligationID: event.obligationID,
            obligationKind: event.obligationKind,
            eventType: eventType,
            source: source,
            route: route,
            generation: generation,
            postTimeNanoseconds: postTimeNanoseconds,
        )
        try ledger.registerAttempt(attempt)
        ledger.recordObserved(
            ObservedInputDelivery(
                token: attempt.token,
                eventType: attempt.eventType,
                source: attempt.source,
                route: attempt.route,
                generation: attempt.generation,
            ),
        )
    }

    func invokeAttempt(
        _ attempt: InputDeliveryAttempt,
        forCleanup: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        if !forCleanup {
            try ledger.registerAttempt(attempt)
            try invocation()
            return .admitted
        }
        lock.withLock {
            cleanupRegistrations += 1
        }
        let admission = try ledger.admitCleanupAttemptIfUnsettled(attempt)
        if admission == .admitted {
            lock.withLock {
                latestCleanupAttempt = attempt
            }
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
        ledger.armCleanupObligation(kind)
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        ledger.settleCleanupObligation(obligation)
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        ledger.abandonCleanupObligation(obligation)
    }

    var outstandingCleanupObligationCount: Int {
        ledger.outstandingCleanupObligationCount
    }

    func waitForAttempt(_ token: UInt64) async throws {
        guard ledger.isAttemptObserved(token) else {
            throw InputDeliveryLedgerError.observerFailure(
                "test attempt was not observed",
            )
        }
    }

    func waitForObligation(_ obligationID: UUID) async throws {
        let attempt = try lock.withLock {
            waitedForObligation = true
            guard let latestCleanupAttempt,
                  latestCleanupAttempt.obligationID == obligationID
            else {
                throw InputDeliveryLedgerError.observerFailure(
                    "test cleanup attempt was not admitted",
                )
            }
            return latestCleanupAttempt
        }
        ledger.recordObserved(
            ObservedInputDelivery(
                token: attempt.token,
                eventType: attempt.eventType,
                source: attempt.source,
                route: attempt.route,
                generation: attempt.generation,
            ),
        )
    }

    func isObligationSettled(_ obligationID: UUID) -> Bool {
        ledger.isObligationSettled(obligationID)
    }

    func settledPostTime(for obligationID: UUID) -> UInt64? {
        ledger.settledPostTime(for: obligationID)
    }

    func recoverForCleanup() async throws {}

    func complete() throws -> InputExecutionReceipt {
        try ledger.complete()
    }

    var hasObservedDelivery: Bool {
        ledger.snapshot.hasObservedDelivery
    }

    func stopAndJoin() async {}

    var cleanupRegistrationCount: Int {
        lock.withLock { cleanupRegistrations }
    }

    var settledValidationCount: Int {
        lock.withLock { settledValidations }
    }

    var didWaitForObligation: Bool {
        lock.withLock { waitedForObligation }
    }
}

private final class InterruptibleInputEventBackend:
    InputEventBackend,
    InputCleanupObligationTracking,
    @unchecked Sendable
{
    private struct State {
        var events: [InputEvent] = []
        var failed = false
        var cleanupObligations: Set<UUID> = []
    }

    private let lock = NSLock()
    private let coordinator: InputDeliveryWaitCoordinator
    private let eventDidPost: (@Sendable () -> Void)?
    private var state = State()

    init(
        scheduler: ManualInputDeliveryWaitScheduler,
        waiterDidInstall: (@Sendable () -> Void)? = nil,
        eventDidPost: (@Sendable () -> Void)? = nil,
    ) {
        self.eventDidPost = eventDidPost
        coordinator = InputDeliveryWaitCoordinator(
            signal: InputDeliveryChangeSignal(
                waiterDidInstall: waiterDidInstall,
            ),
            scheduler: scheduler.scheduler,
        )
    }

    func checkPostAccess() throws {}

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        try PreparedInputEvent(event: event) { [weak self] in
            guard let self else {
                throw InputObserverInterruptionError.backendReleased
            }
            lock.withLock {
                state.events.append(event)
            }
            self.eventDidPost?()
        }
    }

    func pause(nanoseconds: UInt64) async throws {
        try await coordinator.waitWhileHealthy(
            nanoseconds: nanoseconds,
            validateHealth: { [weak self] in
                guard let self else {
                    throw InputObserverInterruptionError.backendReleased
                }
                if lock.withLock({ state.failed }) {
                    throw InputObserverInterruptionError.healthFailure
                }
            },
        )
    }

    func monotonicTimeNanoseconds() -> UInt64 {
        0
    }

    func cursorPosition() throws -> CGPoint {
        .zero
    }

    func warpCursor(x _: Double, y _: Double) async throws {}
    func setCursorAssociated(_: Bool) async throws {}

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        lock.withLock {
            let obligation = InputCleanupObligation(id: UUID(), kind: kind)
            state.cleanupObligations.insert(obligation.id)
            return obligation
        }
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        _ = lock.withLock {
            state.cleanupObligations.remove(obligation.id)
        }
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        _ = lock.withLock {
            state.cleanupObligations.remove(obligation.id)
        }
    }

    var events: [InputEvent] {
        lock.withLock { state.events }
    }

    var activeWaiterCount: Int {
        coordinator.activeWaiterCount
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock { state.cleanupObligations.count }
    }

    func failObserver() {
        lock.withLock {
            state.failed = true
        }
        coordinator.signalChange()
    }
}

private enum InputObserverInterruptionError: Error, Equatable {
    case backendReleased
    case convergence
    case healthFailure
    case schedulerReleased
    case timeout
}
