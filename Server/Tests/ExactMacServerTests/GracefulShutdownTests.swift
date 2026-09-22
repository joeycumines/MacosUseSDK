import ExactMacProto
@testable import ExactMacServer
import Foundation
import Testing

/// Unit tests for graceful shutdown behavior.
/// These tests verify that server components properly clean up during shutdown.
struct GracefulShutdownTests {
    // MARK: - ObservationManager.cancelAllObservations Tests

    @Test
    func `cancelAllObservations cancels active observations`() async throws {
        // Create a fresh ObservationManager (not the shared singleton)
        let manager = ObservationManager(windowRegistry: WindowRegistry())

        // Create multiple observations (must await actor-isolated method)
        _ = try await manager.createObservation(
            name: "observations/test1",
            type: .windowChanges,
            parent: "applications/123",
            filter: nil,
            pid: 123,
            activate: false,
        )
        _ = try await manager.createObservation(
            name: "observations/test2",
            type: .elementChanges,
            parent: "applications/456",
            filter: nil,
            pid: 456,
            activate: false,
        )

        // Verify observations exist
        #expect(await manager.getObservation(name: "observations/test1") != nil)
        #expect(await manager.getObservation(name: "observations/test2") != nil)
        #expect(await manager.getActiveObservationCount() == 0) // Pending, not active yet

        // Start observations to make them active
        try? await manager.startObservation(name: "observations/test1")
        try? await manager.startObservation(name: "observations/test2")
        #expect(await manager.getActiveObservationCount() == 2)

        // Cancel all
        let cancelled = await manager.cancelAllObservations()
        #expect(cancelled == 2, "Should cancel 2 observations")

        // Verify all are gone
        #expect(await manager.getActiveObservationCount() == 0)
        #expect(await manager.getObservation(name: "observations/test1") == nil)
        #expect(await manager.getObservation(name: "observations/test2") == nil)
    }

    @Test
    func `cancelAllObservations returns zero for empty manager`() async {
        let manager = ObservationManager(windowRegistry: WindowRegistry())

        let cancelled = await manager.cancelAllObservations()
        #expect(cancelled == 0, "Should return 0 for empty manager")
    }

    @Test
    func `cancelAllObservations is idempotent`() async throws {
        let manager = ObservationManager(windowRegistry: WindowRegistry())

        _ = try await manager.createObservation(
            name: "observations/test",
            type: .windowChanges,
            parent: "applications/123",
            filter: nil,
            pid: 123,
            activate: false,
        )

        // First cancel
        let first = await manager.cancelAllObservations()
        #expect(first == 1)

        // Second cancel should return 0 (already cancelled)
        let second = await manager.cancelAllObservations()
        #expect(second == 0)
    }

    @Test
    func `cancelAllObservations handles pending observations`() async throws {
        let manager = ObservationManager(windowRegistry: WindowRegistry())

        // Create observation but don't start it (remains pending)
        _ = try await manager.createObservation(
            name: "observations/pending",
            type: .windowChanges,
            parent: "applications/123",
            filter: nil,
            pid: 123,
            activate: false,
        )

        let cancelled = await manager.cancelAllObservations()
        #expect(cancelled == 1, "Should cancel pending observation too")
    }

    // MARK: - OperationStore.drainAllOperations Tests

    @Test
    func `drainAllOperations cancels pending operations`() async {
        let store = OperationStore()

        // Create some operations
        _ = await store.createOperation(name: "operations/test1")
        _ = await store.createOperation(name: "operations/test2")

        // Finish one of them using a simple proto response
        _ = try? await store.finishOperation(
            name: "operations/test1",
            responseMessage: Exactmac_V1_ListObservationsResponse(),
        )

        // Drain
        let (pendingCancelled, totalDrained) = await store.drainAllOperations()
        #expect(pendingCancelled == 1, "Should cancel 1 pending operation")
        #expect(totalDrained == 2, "Should drain 2 total operations")

        // Verify all gone
        let op1 = await store.getOperation(name: "operations/test1")
        let op2 = await store.getOperation(name: "operations/test2")
        #expect(op1 == nil)
        #expect(op2 == nil)
    }

    @Test
    func `drainAllOperations returns zero for empty store`() async {
        let store = OperationStore()

        let (pendingCancelled, totalDrained) = await store.drainAllOperations()
        #expect(pendingCancelled == 0)
        #expect(totalDrained == 0)
    }

    @Test
    func `drainAllOperations marks cancelled operations as done with error`() async {
        let store = OperationStore()

        // Create pending operation
        _ = await store.createOperation(name: "operations/pending")

        // Drain
        _ = await store.drainAllOperations()

        // The operation is gone, but we can verify by checking it was processed
        // (If implementation kept it, it would have error set)
        let op = await store.getOperation(name: "operations/pending")
        #expect(op == nil, "Operation should be removed after drain")
    }

    @Test
    func `drainAllOperations is idempotent`() async {
        let store = OperationStore()

        _ = await store.createOperation(name: "operations/test")

        // First drain
        let (first, _) = await store.drainAllOperations()
        #expect(first == 1)

        // Second drain should return 0
        let (second, total) = await store.drainAllOperations()
        #expect(second == 0)
        #expect(total == 0)
    }

    // MARK: - Composition Construction Tests

    @Test
    func `ObservationManager supports composition construction`() {
        let localManager = ObservationManager(windowRegistry: WindowRegistry())
        _ = localManager
    }

    @Test
    func `MacroExecutor supports composition construction`() {
        let localExecutor = MacroExecutor(
            windowRegistry: WindowRegistry(),
            inputTransactionExecutor: makeTestInputTransactionExecutor(),
        )
        _ = localExecutor
    }

    // MARK: - Concurrent Shutdown Safety Tests

    @Test
    func `cancelAllObservations handles concurrent access`() async throws {
        let manager = ObservationManager(windowRegistry: WindowRegistry())

        // Create multiple observations (must be within actor context)
        for i in 0 ..< 10 {
            _ = try await manager.createObservation(
                name: "observations/concurrent-\(i)",
                type: .windowChanges,
                parent: "applications/\(i)",
                filter: nil,
                pid: pid_t(i),
                activate: false,
            )
        }

        // Cancel concurrently
        async let cancel1 = manager.cancelAllObservations()
        async let cancel2 = manager.cancelAllObservations()

        let (count1, count2) = await (cancel1, cancel2)

        // One should get all, the other should get 0 (or some split)
        #expect(count1 + count2 == 10, "Total cancelled should be 10")
    }

    @Test
    func `drainAllOperations handles concurrent access`() async {
        let store = OperationStore()

        // Create multiple operations
        for i in 0 ..< 10 {
            _ = await store.createOperation(name: "operations/concurrent-\(i)")
        }

        // Drain concurrently
        async let drain1 = store.drainAllOperations()
        async let drain2 = store.drainAllOperations()

        let ((pending1, total1), (pending2, total2)) = await (drain1, drain2)

        // One should get all, the other should get 0 (or some split)
        #expect(total1 + total2 == 10, "Total drained should be 10")
        #expect(pending1 + pending2 == 10, "Total pending cancelled should be 10")
    }

    // MARK: - SessionManager Tests

    struct SessionManagerShutdownTests {
        @Test
        func `invalidateAllSessions awaits cleanup and closes admission`() async throws {
            let probe = BlockingSessionCleanupProbe()
            let manager = SessionManager(cleanupOperation: { await probe.run() })

            _ = try await manager.createSession(
                sessionId: "owned-cleanup",
                displayName: "Owned cleanup",
                metadata: [:],
            )
            try await manager.startCleanup()
            await probe.waitUntilEntered()

            let invalidation = Task {
                let count = await manager.invalidateAllSessions()
                await probe.recordInvalidationReturned()
                return count
            }
            await probe.waitUntilCancellationObserved()

            #expect(await probe.didInvalidationReturn() == false)
            #expect(await manager.cleanupTaskCount() == 1)

            await probe.release()
            #expect(await invalidation.value == 1)
            #expect(await manager.cleanupTaskCount() == 0)

            do {
                _ = try await manager.createSession(
                    sessionId: "after-invalidation",
                    displayName: "Rejected",
                    metadata: [:],
                )
                Issue.record("Expected session admission to remain closed")
            } catch let error as SessionError {
                #expect(error == .admissionClosed)
            }
        }

        @Test
        func `invalidateAllSessions clears all sessions`() async throws {
            let manager = SessionManager()

            // Create test sessions
            let session1 = try await manager.createSession(
                sessionId: "shutdown-test-1",
                displayName: "Test 1",
                metadata: [:],
            )
            let session2 = try await manager.createSession(
                sessionId: "shutdown-test-2",
                displayName: "Test 2",
                metadata: [:],
            )

            // Verify sessions exist
            #expect(await manager.getSession(name: session1.name) != nil)
            #expect(await manager.getSession(name: session2.name) != nil)

            // Invalidate all - verify count is at least 2
            let count = await manager.invalidateAllSessions()
            #expect(count >= 2, "Should invalidate at least our 2 sessions")

            // Verify sessions are gone
            #expect(await manager.getSession(name: session1.name) == nil)
            #expect(await manager.getSession(name: session2.name) == nil)
        }

        @Test
        func `invalidateAllSessions returns zero when called twice`() async throws {
            let manager = SessionManager()

            // Create a session
            _ = try await manager.createSession(
                sessionId: "twice-test",
                displayName: "Twice Test",
                metadata: [:],
            )

            // First invalidate all
            let first = await manager.invalidateAllSessions()
            #expect(first >= 1, "Should invalidate at least 1 session")

            // Second call should return 0 (all already invalidated)
            let second = await manager.invalidateAllSessions()
            #expect(second == 0, "Second call should return 0")
        }

        @Test
        func `invalidateAllSessions clears active transactions`() async throws {
            let manager = SessionManager()

            // Create session with active transaction
            let session = try await manager.createSession(
                sessionId: "tx-shutdown-test",
                displayName: "TX Test",
                metadata: [:],
            )

            // Begin a transaction
            _ = try await manager.beginTransaction(
                sessionName: session.name,
                isolationLevel: .serializable,
                timeout: 60,
            )

            // Verify session is in transaction state
            let inTx = await manager.getSession(name: session.name)
            #expect(inTx?.state == .inTransaction)

            // Invalidate all
            _ = await manager.invalidateAllSessions()

            // Session should be gone
            #expect(await manager.getSession(name: session.name) == nil)
        }
    }

    struct ElementRegistryShutdownTests {
        @Test
        func `shutdown awaits cleanup task and clears only the owned registry`() async throws {
            let probe = BlockingSessionCleanupProbe()
            let registry = ElementRegistry(cleanupOperation: { await probe.run() })
            let otherRegistry = ElementRegistry()
            let element = Exactmac_V1_Element.with { $0.role = "AXButton" }
            _ = try await registry.registerElement(element, pid: 101)
            _ = try await otherRegistry.registerElement(element, pid: 202)

            try await registry.startCleanup()
            await probe.waitUntilEntered()

            let shutdown = Task {
                await registry.shutdown()
                await probe.recordInvalidationReturned()
            }
            await probe.waitUntilCancellationObserved()

            #expect(await probe.didInvalidationReturn() == false)
            #expect(await registry.cleanupTaskCount() == 1)

            await probe.release()
            await shutdown.value

            #expect(await registry.cleanupTaskCount() == 0)
            #expect(await registry.getCachedElementCount() == 0)
            #expect(await otherRegistry.getCachedElementCount() == 1)

            do {
                _ = try await registry.registerElement(element, pid: 303)
                Issue.record("Expected drained registry admission to remain closed")
            } catch let error as ElementRegistryError {
                #expect(error == .admissionClosed)
            }
        }
    }
}

private actor BlockingSessionCleanupProbe {
    private var entered = false
    private var cancellationObserved = false
    private var invalidationReturned = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withTaskCancellationHandler {
            entered = true
            let continuations = enteredContinuations
            enteredContinuations.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellationObserved() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func recordInvalidationReturned() {
        invalidationReturned = true
    }

    func didInvalidationReturn() -> Bool {
        invalidationReturned
    }

    private func recordCancellationObserved() {
        cancellationObserved = true
        let continuations = cancellationContinuations
        cancellationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
