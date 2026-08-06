import CoreGraphics
import MacosUseProto
import MacosUseSDK
@testable import MacosUseServer
import XCTest

final class PhysicalDesktopMutationGateTests: XCTestCase {
    func testWaiterCancelBeforeInstallResumesOnceWithoutEnqueue() async {
        let waiter = PhysicalDesktopMutationWaiter()
        waiter.cancel()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                XCTAssertFalse(waiter.install(continuation))
            }
            XCTFail("Expected cancellation before continuation installation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(waiter.promote())
    }

    func testWaiterInstallThenCancelResumesOnce() async {
        let waiter = PhysicalDesktopMutationWaiter()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                XCTAssertTrue(waiter.install(continuation))
                waiter.cancel()
            }
            XCTFail("Expected installed waiter cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(waiter.promote())
    }

    func testWaiterPromoteThenCancelRetainsSinglePromotion() async throws {
        let waiter = PhysicalDesktopMutationWaiter()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            XCTAssertTrue(waiter.install(continuation))
            XCTAssertTrue(waiter.promote())
            waiter.cancel()
        }
        XCTAssertFalse(waiter.promote())
    }

    func testWaiterCancelThenPromoteRetainsSingleCancellation() async {
        let waiter = PhysicalDesktopMutationWaiter()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                XCTAssertTrue(waiter.install(continuation))
                waiter.cancel()
                XCTAssertFalse(waiter.promote())
            }
            XCTFail("Expected cancellation to win promotion")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCoordinatorSerializesAcrossAwaitAndBoundsQueue() async throws {
        let gate = PhysicalDesktopMutationGate(capacity: 1)
        let recorder = BlockingInputExecutionRecorder()
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )

        let first = Task { @MainActor in
            try await executeMove(coordinator, x: 1)
        }
        try await waitForInputEntered(recorder, count: 1)

        let second = Task { @MainActor in
            try await executeMove(coordinator, x: 2)
        }
        try await waitForMutationPending(gate, count: 1)
        let queuedSnapshot = await recorder.snapshot()
        XCTAssertEqual(queuedSnapshot.entered, [1])
        XCTAssertEqual(queuedSnapshot.maximumActive, 1)

        do {
            try await executeMove(coordinator, x: 3)
            XCTFail("Expected bounded mutation queue rejection")
        } catch let error as PhysicalDesktopMutationError {
            XCTAssertEqual(error, .queueFull)
        }

        await recorder.release(label: 1)
        try await waitForInputEntered(recorder, count: 2)
        let secondSnapshot = await recorder.snapshot()
        XCTAssertEqual(secondSnapshot.entered, [1, 2])
        XCTAssertEqual(secondSnapshot.maximumActive, 1)
        await recorder.release(label: 2)

        try await first.value
        try await second.value
        let finalPending = await gate.pendingCount()
        XCTAssertEqual(finalPending, 0)
    }

    @MainActor
    func testCoordinatorRemovesCancelledQueuedMutationBeforeExecution() async throws {
        let gate = PhysicalDesktopMutationGate(capacity: 1)
        let recorder = BlockingInputExecutionRecorder()
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )

        let first = Task { @MainActor in
            try await executeMove(coordinator, x: 1)
        }
        try await waitForInputEntered(recorder, count: 1)

        let cancelled = Task { @MainActor in
            try await executeMove(coordinator, x: 2)
        }
        try await waitForMutationPending(gate, count: 1)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected queued mutation cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForMutationPending(gate, count: 0)
        let cancelledSnapshot = await recorder.snapshot()
        XCTAssertEqual(cancelledSnapshot.entered, [1])

        await recorder.release(label: 1)
        try await first.value
    }

    @MainActor
    func testDrainRejectsNewAdmissionAndAwaitsPreviouslyAdmittedWork() async throws {
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let recorder = BlockingMutationLifecycleRecorder()

        let first = Task {
            try await gate.withExclusiveOperation {
                await recorder.execute(label: 1)
            }
        }
        try await waitForMutationLifecycleEntered(recorder, count: 1)

        let second = Task {
            try await gate.withExclusiveOperation {
                await recorder.execute(label: 2)
            }
        }
        try await waitForMutationPending(gate, count: 1)

        await gate.beginDraining()
        let drainingState = await gate.lifecycleState()
        XCTAssertEqual(drainingState, .draining)

        do {
            try await gate.withExclusiveOperation {}
            XCTFail("Expected post-drain admission rejection")
        } catch let error as PhysicalDesktopMutationError {
            XCTAssertEqual(error, .admissionClosed)
        }

        let drain = Task {
            await gate.waitUntilDrained()
        }

        await recorder.release(label: 1)
        try await waitForMutationLifecycleEntered(recorder, count: 2)
        let promotedState = await gate.lifecycleState()
        XCTAssertEqual(promotedState, .draining)

        await recorder.release(label: 2)
        try await first.value
        try await second.value
        await drain.value

        let drainedState = await gate.lifecycleState()
        XCTAssertEqual(drainedState, .drained)
        let finalPending = await gate.pendingCount()
        XCTAssertEqual(finalPending, 0)
    }

    @MainActor
    func testCancellationAfterPromotionReleasesOwnershipToNextFIFOOperation() async throws {
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let holder = BlockingMutationLifecycleRecorder()
        let entries = MutationPromotionRecorder()
        let cancellationBarrier = CancellableMutationBarrier()

        let first = Task {
            try await gate.withExclusiveOperation {
                await holder.execute(label: 1)
            }
        }
        try await waitForMutationLifecycleEntered(holder, count: 1)

        let promotedThenCancelled = Task {
            try await gate.withExclusiveOperation {
                await entries.record(2)
                try await cancellationBarrier.wait()
            }
        }
        let final = Task {
            try await gate.withExclusiveOperation {
                await entries.record(3)
            }
        }
        try await waitForMutationPending(gate, count: 2)

        await holder.release(label: 1)
        try await first.value
        await entries.waitUntilRecorded(2)
        promotedThenCancelled.cancel()
        do {
            try await promotedThenCancelled.value
            XCTFail("Expected promoted mutation cancellation")
        } catch is CancellationError {
            // The promoted owner must release through withExclusiveOperation.
        }

        try await final.value
        let recordedEntries = await entries.snapshot()
        let pendingCount = await gate.pendingCount()
        XCTAssertEqual(recordedEntries, [2, 3])
        XCTAssertEqual(pendingCount, 0)
    }

    @MainActor
    private func executeMove(
        _ coordinator: AutomationCoordinator,
        x: Double,
    ) async throws {
        _ = try await coordinator.handlePhysicalMutation { context in
            try await context.executeInput(
                .movePointer(
                    to: CGPoint(x: x, y: 100),
                    duration: 0,
                    modifiers: [],
                ),
                route: .session,
            )
        }
    }

    @MainActor
    private func waitForMutationPending(
        _ gate: PhysicalDesktopMutationGate,
        count: Int,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await gate.pendingCount() != count {
            guard clock.now < deadline else {
                XCTFail("Mutation queue did not converge to \(count)")
                return
            }
            await Task.yield()
        }
    }
}

private final class CancellableMutationBarrier: @unchecked Sendable {
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
                            InputMutationTestError.duplicateBarrierWaiter,
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

    func resume() {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            switch state {
            case .idle:
                state = .finished(.success(()))
                return nil
            case let .waiting(continuation):
                state = .finished(.success(()))
                return continuation
            case .finished:
                return nil
            }
        }
        continuation?.resume()
    }
}

actor MutationPromotionRecorder {
    private var entries: [Int] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ value: Int) {
        entries.append(value)
        let continuations = waiters.removeValue(forKey: value) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilRecorded(_ value: Int) async {
        guard !entries.contains(value) else { return }
        await withCheckedContinuation { continuation in
            waiters[value, default: []].append(continuation)
        }
    }

    func snapshot() -> [Int] {
        entries
    }
}

actor BlockingMutationLifecycleRecorder {
    private var entered: [Int] = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    func execute(label: Int) async {
        entered.append(label)
        await withCheckedContinuation { continuation in
            releases[label] = continuation
        }
    }

    func release(label: Int) {
        releases.removeValue(forKey: label)?.resume()
    }

    func enteredCount() -> Int {
        entered.count
    }
}

func waitForMutationLifecycleEntered(
    _ recorder: BlockingMutationLifecycleRecorder,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await recorder.enteredCount() < count {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("mutation lifecycle entries", count)
        }
        await Task.yield()
    }
}

actor BlockingInputExecutionRecorder {
    struct Snapshot: Sendable {
        let entered: [Int]
        let maximumActive: Int
    }

    private var active = 0
    private var maximumActive = 0
    private var entered: [Int] = []
    private var releases: [Int: CancellableMutationBarrier] = [:]

    func execute(_ action: MacosUseSDK.InputAction) async throws {
        guard case let .movePointer(point, _, _) = action else {
            XCTFail("Expected injected move action")
            return
        }
        let label = Int(point.x)
        active += 1
        defer { active -= 1 }
        maximumActive = max(maximumActive, active)
        entered.append(label)
        let release = CancellableMutationBarrier()
        releases[label] = release
        defer { releases.removeValue(forKey: label) }
        try await release.wait()
        try Task.checkCancellation()
    }

    func release(label: Int) {
        releases.removeValue(forKey: label)?.resume()
    }

    func snapshot() -> Snapshot {
        Snapshot(entered: entered, maximumActive: maximumActive)
    }
}

func waitForInputEntered(
    _ recorder: BlockingInputExecutionRecorder,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await recorder.snapshot().entered.count < count {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("input executions", count)
        }
        await Task.yield()
    }
}

enum InputMutationTestError: Error {
    case convergenceTimeout(String, Int)
    case duplicateBarrierWaiter
}
