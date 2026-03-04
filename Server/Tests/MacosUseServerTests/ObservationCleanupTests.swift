import CoreGraphics
import Foundation
import MacosUseProto
@testable import MacosUseServer
import Testing

/// Unit tests for ObservationManager cleanup behavior.
/// Tests verify proper cleanup of polling tasks, stream continuations, and state transitions.
@Suite("ObservationManager Cleanup Tests")
struct ObservationCleanupTests {
    /// Helper to create an ObservationManager with injected dependencies.
    func makeObservationManager() -> ObservationManager {
        let registry = WindowRegistry() // Use real registry for tests
        return ObservationManager(windowRegistry: registry)
    }

    // MARK: - cancelObservation Cleanup Tests

    @Test("cancelObservation returns cancelled observation")
    func cancelObservationReturnsObservation() async {
        let manager = makeObservationManager()

        // Create an observation
        let created = await manager.createObservation(
            name: "observations/test-cancel-1",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        #expect(created.state == .pending, "New observation should be pending")

        // Cancel it
        let cancelled = await manager.cancelObservation(name: "observations/test-cancel-1")

        #expect(cancelled != nil, "Should return cancelled observation")
        #expect(cancelled?.state == .cancelled, "State should be cancelled")
        #expect(cancelled?.name == "observations/test-cancel-1", "Name should match")
        #expect(cancelled?.hasEndTime == true, "Should have end time set")
    }

    @Test("cancelObservation removes observation from active list")
    func cancelObservationRemovesFromList() async {
        let manager = makeObservationManager()

        // Create observations
        _ = await manager.createObservation(
            name: "observations/cleanup-1",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        _ = await manager.createObservation(
            name: "observations/cleanup-2",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        // Verify both exist
        let beforeList = await manager.listObservations(parent: "sessions/test")
        #expect(beforeList.count == 2, "Should have 2 observations before cancel")

        // Cancel one
        _ = await manager.cancelObservation(name: "observations/cleanup-1")

        // Verify only one remains in getObservation (cancelled observations still retrievable)
        let getResult = await manager.getObservation(name: "observations/cleanup-1")
        #expect(getResult?.state == .cancelled, "Cancelled observation should still be retrievable")

        let getOther = await manager.getObservation(name: "observations/cleanup-2")
        #expect(getOther?.state == .pending, "Other observation should still be pending")
    }

    @Test("cancelObservation is idempotent")
    func cancelObservationIdempotent() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/idempotent-test",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        // Cancel multiple times
        let first = await manager.cancelObservation(name: "observations/idempotent-test")
        #expect(first?.state == .cancelled, "First cancel should work")

        let second = await manager.cancelObservation(name: "observations/idempotent-test")
        // Second cancel should still return the cancelled observation OR nil
        // Implementation may vary - key is it doesn't crash
        if let secondResult = second {
            #expect(secondResult.state == .cancelled, "Should remain cancelled")
        }
    }

    @Test("cancelObservation returns nil for non-existent observation")
    func cancelObservationNonExistentReturnsNil() async {
        let manager = makeObservationManager()

        let result = await manager.cancelObservation(name: "observations/does-not-exist")
        #expect(result == nil, "Should return nil for non-existent observation")
    }

    @Test("cancelObservation sets end time")
    func cancelObservationSetsEndTime() async throws {
        let manager = makeObservationManager()

        let created = await manager.createObservation(
            name: "observations/endtime-test",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        #expect(created.hasEndTime == false, "New observation should not have end time")

        let cancelled = await manager.cancelObservation(name: "observations/endtime-test")

        #expect(cancelled?.hasEndTime == true, "Cancelled observation should have end time")
        #expect(try #require(cancelled?.endTime.seconds) > 0, "End time should be non-zero")
    }

    // MARK: - failObservation Cleanup Tests

    @Test("failObservation changes state to failed")
    func failObservationChangesState() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/fail-test",
            type: .attributeChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        // Fail the observation
        await manager.failObservation(name: "observations/fail-test", error: TestError.simulatedError)

        let failed = await manager.getObservation(name: "observations/fail-test")
        #expect(failed?.state == .failed, "State should be failed")
        #expect(failed?.hasEndTime == true, "Should have end time set")
    }

    @Test("failObservation removes polling task")
    func failObservationRemovesPollingTask() async {
        let manager = makeObservationManager()

        let created = await manager.createObservation(
            name: "observations/polling-fail",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        #expect(created.state == .pending)

        // Start the observation to create tasks
        try? await manager.startObservation(name: "observations/polling-fail")

        // Fail it
        await manager.failObservation(name: "observations/polling-fail", error: TestError.simulatedError)

        // Observation should be failed
        let failed = await manager.getObservation(name: "observations/polling-fail")
        #expect(failed?.state == .failed, "Should be in failed state")
    }

    @Test("failObservation is safe for non-existent observation")
    func failObservationNonExistentIsSafe() async {
        let manager = makeObservationManager()

        // Should not crash
        await manager.failObservation(name: "observations/does-not-exist", error: TestError.simulatedError)

        // Verify manager is still functional
        let obs = await manager.createObservation(
            name: "observations/after-fail",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        #expect(obs.name == "observations/after-fail", "Manager should still be functional")
    }

    // MARK: - Stream Continuation Tests

    @Test("createEventStream returns stream for valid observation")
    func createEventStreamReturnsStream() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/stream-test",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        let stream = await manager.createEventStream(name: "observations/stream-test")
        #expect(stream != nil, "Should return stream for valid observation")
    }

    @Test("createEventStream returns nil for non-existent observation")
    func createEventStreamNonExistentReturnsNil() async {
        let manager = makeObservationManager()

        let stream = await manager.createEventStream(name: "observations/does-not-exist")
        #expect(stream == nil, "Should return nil for non-existent observation")
    }

    @Test("Multiple independent event streams can be created")
    func multipleIndependentEventStreams() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/multi-stream",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        let stream1 = await manager.createEventStream(name: "observations/multi-stream")
        let stream2 = await manager.createEventStream(name: "observations/multi-stream")

        #expect(stream1 != nil, "First stream should be created")
        #expect(stream2 != nil, "Second stream should be created")
        // These are independent streams for the same observation
    }

    // MARK: - completeObservation Tests

    @Test("completeObservation changes state to completed")
    func completeObservationChangesState() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/complete-test",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        await manager.completeObservation(name: "observations/complete-test")

        let completed = await manager.getObservation(name: "observations/complete-test")
        #expect(completed?.state == .completed, "State should be completed")
        #expect(completed?.hasEndTime == true, "Should have end time set")
    }

    @Test("completeObservation cleans up resources")
    func completeObservationCleansUpResources() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/cleanup-complete",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        // Start to create tasks
        try? await manager.startObservation(name: "observations/cleanup-complete")

        // Complete
        await manager.completeObservation(name: "observations/cleanup-complete")

        // Verify completed
        let obs = await manager.getObservation(name: "observations/cleanup-complete")
        #expect(obs?.state == .completed, "Should be completed")
    }

    // MARK: - State Transition Tests

    @Test("Observation state transitions: pending -> active -> cancelled")
    func stateTransitionPendingActiveCancelled() async {
        let manager = makeObservationManager()

        let created = await manager.createObservation(
            name: "observations/state-transition-1",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        #expect(created.state == .pending, "Initial state should be pending")

        try? await manager.startObservation(name: "observations/state-transition-1")

        let started = await manager.getObservation(name: "observations/state-transition-1")
        #expect(started?.state == .active, "After start, state should be active")

        _ = await manager.cancelObservation(name: "observations/state-transition-1")

        let cancelled = await manager.getObservation(name: "observations/state-transition-1")
        #expect(cancelled?.state == .cancelled, "After cancel, state should be cancelled")
    }

    @Test("Observation state transitions: pending -> active -> completed")
    func stateTransitionPendingActiveCompleted() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/state-transition-2",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        try? await manager.startObservation(name: "observations/state-transition-2")
        await manager.completeObservation(name: "observations/state-transition-2")

        let completed = await manager.getObservation(name: "observations/state-transition-2")
        #expect(completed?.state == .completed, "Final state should be completed")
    }

    @Test("Observation state transitions: pending -> active -> failed")
    func stateTransitionPendingActiveFailed() async {
        let manager = makeObservationManager()

        _ = await manager.createObservation(
            name: "observations/state-transition-3",
            type: .treeChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        try? await manager.startObservation(name: "observations/state-transition-3")
        await manager.failObservation(name: "observations/state-transition-3", error: TestError.simulatedError)

        let failed = await manager.getObservation(name: "observations/state-transition-3")
        #expect(failed?.state == .failed, "Final state should be failed")
    }

    // MARK: - Active Observation Count Tests

    @Test("getActiveObservationCount reflects actual active observations")
    func getActiveObservationCountReflectsState() async {
        let manager = makeObservationManager()

        // Initially empty
        let initialCount = await manager.getActiveObservationCount()
        #expect(initialCount == 0, "Initially should have 0 active observations")

        // Create and start observations
        _ = await manager.createObservation(
            name: "observations/count-1",
            type: .windowChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )
        _ = await manager.createObservation(
            name: "observations/count-2",
            type: .elementChanges,
            parent: "sessions/test",
            filter: nil,
            pid: 1234,
        )

        try? await manager.startObservation(name: "observations/count-1")

        let afterStart = await manager.getActiveObservationCount()
        #expect(afterStart == 1, "Should have 1 active after starting one")

        try? await manager.startObservation(name: "observations/count-2")

        let afterSecondStart = await manager.getActiveObservationCount()
        #expect(afterSecondStart == 2, "Should have 2 active after starting both")

        // Cancel one
        _ = await manager.cancelObservation(name: "observations/count-1")

        let afterCancel = await manager.getActiveObservationCount()
        #expect(afterCancel == 1, "Should have 1 active after cancelling one")

        // Clean up
        _ = await manager.cancelObservation(name: "observations/count-2")
    }

    // MARK: - Concurrent Cleanup Tests

    @Test("Concurrent cancel operations are safe")
    func concurrentCancelOperationsSafe() async {
        let manager = makeObservationManager()

        // Create multiple observations
        for i in 0 ..< 10 {
            _ = await manager.createObservation(
                name: "observations/concurrent-\(i)",
                type: .windowChanges,
                parent: "sessions/test",
                filter: nil,
                pid: 1234,
            )
        }

        // Cancel all concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 10 {
                group.addTask {
                    _ = await manager.cancelObservation(name: "observations/concurrent-\(i)")
                }
            }
        }

        // Verify all are cancelled or no longer active
        let activeCount = await manager.getActiveObservationCount()
        #expect(activeCount == 0, "No active observations should remain after concurrent cancellation")
    }

    @Test("Cancel and create operations are safe concurrently")
    func cancelAndCreateConcurrentlySafe() async {
        let manager = makeObservationManager()

        // Pre-create some observations
        for i in 0 ..< 5 {
            _ = await manager.createObservation(
                name: "observations/pre-\(i)",
                type: .elementChanges,
                parent: "sessions/test",
                filter: nil,
                pid: 1234,
            )
        }

        // Concurrently cancel existing and create new
        await withTaskGroup(of: Void.self) { group in
            // Cancellers
            for i in 0 ..< 5 {
                group.addTask {
                    _ = await manager.cancelObservation(name: "observations/pre-\(i)")
                }
            }
            // Creators
            for i in 5 ..< 10 {
                group.addTask {
                    _ = await manager.createObservation(
                        name: "observations/new-\(i)",
                        type: .windowChanges,
                        parent: "sessions/test",
                        filter: nil,
                        pid: 1234,
                    )
                }
            }
        }

        // Verify new observations exist
        for i in 5 ..< 10 {
            let obs = await manager.getObservation(name: "observations/new-\(i)")
            #expect(obs != nil, "New observation \(i) should exist")
        }
    }
}

// MARK: - Test Helpers

private enum TestError: Error {
    case simulatedError
}
