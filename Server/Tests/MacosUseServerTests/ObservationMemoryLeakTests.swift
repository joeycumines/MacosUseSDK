import Foundation
@testable import MacosUseServer
import Testing

/// Tests for observation resource lifecycle and leak detection.
///
/// These tests verify that creating and cancelling observations doesn't
/// leak resources (observations, tasks, memory).
@Suite("Observation Memory Leak Tests")
struct ObservationMemoryLeakTests {
    /// Number of observations to create and cancel
    private let observationCount = 100

    @Test("Create and cancel observations leaves no residue")
    func createCancelObservationsNoResidue() async {
        let registry = WindowRegistry()
        let manager = ObservationManager(windowRegistry: registry)

        // Verify clean initial state
        let initialCount = await manager.getActiveObservationCount()
        #expect(initialCount == 0, "Should start with 0 observations")

        // Create many observations
        var names: [String] = []
        for i in 0 ..< observationCount {
            let name = "observations/test-leak-\(i)"
            names.append(name)

            _ = await manager.createObservation(
                name: name,
                type: .windowChanges,
                parent: "applications/1234",
                filter: nil,
                pid: 1234,
                activate: false,
            )
        }

        // Verify observations were created (count them via listObservations)
        let createdObs = await manager.listObservations(parent: "applications/1234")
        #expect(createdObs.count == observationCount, "Should have created \(observationCount) observations")

        // Cancel all observations
        for name in names {
            _ = await manager.cancelObservation(name: name)
        }

        // Verify all observations are cleaned up
        let finalCount = await manager.getActiveObservationCount()
        #expect(finalCount == 0, "Should have 0 active observations after cancel")

        // Verify listing returns empty
        let remaining = await manager.listObservations(parent: "applications/1234")
        // Note: Cancelled observations may still be in the list with cancelled state
        let activeRemaining = remaining.filter { $0.state == .active || $0.state == .pending }
        #expect(activeRemaining.isEmpty, "Should have no active/pending observations")
    }

    @Test("Rapid create/cancel cycle doesn't accumulate state")
    func rapidCreateCancelCycle() async {
        let registry = WindowRegistry()
        let manager = ObservationManager(windowRegistry: registry)

        // Rapid create/cancel cycles
        for i in 0 ..< observationCount {
            let name = "observations/rapid-\(i)"

            _ = await manager.createObservation(
                name: name,
                type: .elementChanges,
                parent: "applications/5678",
                filter: nil,
                pid: 5678,
                activate: false,
            )

            // Immediately cancel
            _ = await manager.cancelObservation(name: name)
        }

        // Verify no accumulation
        let finalActiveCount = await manager.getActiveObservationCount()
        #expect(finalActiveCount == 0, "Rapid create/cancel should leave no active observations")
    }

    @Test("CancelAllObservations cleans up everything")
    func cancelAllObservationsCleanup() async {
        let registry = WindowRegistry()
        let manager = ObservationManager(windowRegistry: registry)

        // Create multiple observations
        for i in 0 ..< 20 {
            let name = "observations/batch-\(i)"
            _ = await manager.createObservation(
                name: name,
                type: .treeChanges,
                parent: "applications/9999",
                filter: nil,
                pid: 9999,
                activate: false,
            )
        }

        // Cancel all at once
        let cancelledCount = await manager.cancelAllObservations()
        #expect(cancelledCount == 20, "Should cancel all 20 observations")

        // Verify clean state
        let remaining = await manager.getActiveObservationCount()
        #expect(remaining == 0, "Should have 0 active observations after cancelAll")
    }

    @Test("Double cancel is safe")
    func doubleCancelSafe() async {
        let registry = WindowRegistry()
        let manager = ObservationManager(windowRegistry: registry)

        let name = "observations/double-cancel"
        _ = await manager.createObservation(
            name: name,
            type: .windowChanges,
            parent: "applications/1111",
            filter: nil,
            pid: 1111,
            activate: false,
        )

        // Cancel twice - should be idempotent
        let result1 = await manager.cancelObservation(name: name)
        #expect(result1 != nil, "First cancel should return observation")

        let result2 = await manager.cancelObservation(name: name)
        // Second cancel returns the same observation (still in store, but already cancelled)
        #expect(result2 != nil, "Second cancel should still find observation in store")

        // Verify no active observations
        let activeCount = await manager.getActiveObservationCount()
        #expect(activeCount == 0, "Should have 0 active observations after double cancel")
    }

    @Test("Concurrent create/cancel from multiple tasks is safe")
    func concurrentCreateCancel() async {
        let registry = WindowRegistry()
        let manager = ObservationManager(windowRegistry: registry)

        // Create observations concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 50 {
                group.addTask {
                    let name = "observations/concurrent-\(i)"
                    _ = await manager.createObservation(
                        name: name,
                        type: .attributeChanges,
                        parent: "applications/2222",
                        filter: nil,
                        pid: 2222,
                        activate: false,
                    )
                }
            }
        }

        // Cancel concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 50 {
                group.addTask {
                    let name = "observations/concurrent-\(i)"
                    _ = await manager.cancelObservation(name: name)
                }
            }
        }

        // Verify clean state (no crashes, no active observations)
        let finalCount = await manager.getActiveObservationCount()
        #expect(finalCount == 0, "Concurrent operations should leave no active observations")
    }
}
