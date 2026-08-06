import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

final class OperationStoreTests: XCTestCase {
    // MARK: - createOperation Tests

    func testCreateOperation_basicCreate_returnsOperationWithCorrectName() async {
        let store = OperationStore()
        let op = await store.createOperation(name: "operations/test-123")

        XCTAssertEqual(op.name, "operations/test-123")
    }

    func testCreateOperation_basicCreate_returnsOperationNotDone() async {
        let store = OperationStore()
        let op = await store.createOperation(name: "operations/test-123")

        XCTAssertFalse(op.done)
    }

    func testCreateOperation_withoutMetadata_hasNoMetadata() async {
        let store = OperationStore()
        let op = await store.createOperation(name: "operations/test-123")

        XCTAssertFalse(op.hasMetadata)
    }

    func testCreateOperation_withMetadata_preservesMetadata() async {
        let store = OperationStore()
        var metadata = Google_Protobuf_Any()
        metadata.typeURL = "type.googleapis.com/test.Metadata"
        metadata.value = Data([0x01, 0x02, 0x03])

        let op = await store.createOperation(name: "operations/meta-test", metadata: metadata)

        XCTAssertTrue(op.hasMetadata)
        XCTAssertEqual(op.metadata.typeURL, "type.googleapis.com/test.Metadata")
        XCTAssertEqual(op.metadata.value, Data([0x01, 0x02, 0x03]))
    }

    func testCreateOperation_storesOperationForLaterRetrieval() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/stored-op")

        let retrieved = await store.getOperation(name: "operations/stored-op")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "operations/stored-op")
    }

    func testCreateOperation_multipleOperations_eachStoredSeparately() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/op-1")
        _ = await store.createOperation(name: "operations/op-2")
        _ = await store.createOperation(name: "operations/op-3")

        let result = await store.listOperations()
        XCTAssertEqual(result.operations.count, 3)
    }

    // MARK: - getOperation Tests

    func testGetOperation_existingOperation_returnsOperation() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/existing")

        let op = await store.getOperation(name: "operations/existing")

        XCTAssertNotNil(op)
        XCTAssertEqual(op?.name, "operations/existing")
    }

    func testGetOperation_nonExistentOperation_returnsNil() async {
        let store = OperationStore()

        let op = await store.getOperation(name: "operations/does-not-exist")

        XCTAssertNil(op)
    }

    func testGetOperation_afterDeletion_returnsNil() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-delete")
        await store.deleteOperation(name: "operations/to-delete")

        let op = await store.getOperation(name: "operations/to-delete")

        XCTAssertNil(op)
    }

    // MARK: - finishOperation Tests

    func testFinishOperation_validOperation_marksDone() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-finish")

        // Use a simple StringValue as response message
        var response = Google_Protobuf_StringValue()
        response.value = "completed successfully"

        let outcome = try await store.finishOperation(
            name: "operations/to-finish",
            responseMessage: response,
        )

        let op = await store.getOperation(name: "operations/to-finish")
        XCTAssertEqual(outcome, .published)
        XCTAssertTrue(op?.done ?? false)
    }

    func testFinishOperation_validOperation_setsResponseResult() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-finish")

        var response = Google_Protobuf_StringValue()
        response.value = "result data"

        try await store.finishOperation(name: "operations/to-finish", responseMessage: response)

        let op = await store.getOperation(name: "operations/to-finish")
        guard case let .response(any) = op?.result else {
            XCTFail("Expected response result")
            return
        }
        XCTAssertTrue(any.typeURL.contains("StringValue"))
    }

    func testFinishOperation_deletedOperation_discardsLatePublicationWithoutThrowing() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/deleted-before-publication"
        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()
        let deleted = await store.deleteOperation(name: name)
        XCTAssertTrue(deleted)

        var response = Google_Protobuf_StringValue()
        response.value = "response"

        let outcome = try await store.finishOperation(
            name: name,
            responseMessage: response,
        )

        XCTAssertEqual(outcome, .discarded)
        let resurrected = await store.getOperation(name: name)
        XCTAssertNil(resurrected)
        await probe.release()
        try await waitForExecutionTaskCount(0, store: store)
    }

    func testFinishOperation_arbitraryMissingOperationFailsClosed() async throws {
        let store = OperationStore()
        let outcome = try await store.finishOperation(
            name: "operations/never-created",
            responseMessage: Google_Protobuf_StringValue.with { $0.value = "response" },
        )

        XCTAssertEqual(outcome, .alreadyTerminal)
    }

    func testFinishOperation_alreadyDoneOperation_doesNotOverwriteTerminalResult() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/double-finish")

        var response1 = Google_Protobuf_StringValue()
        response1.value = "first"
        let firstOutcome = try await store.finishOperation(
            name: "operations/double-finish",
            responseMessage: response1,
        )

        var response2 = Google_Protobuf_StringValue()
        response2.value = "second"
        let secondOutcome = try await store.finishOperation(
            name: "operations/double-finish",
            responseMessage: response2,
        )

        let op = await store.getOperation(name: "operations/double-finish")
        XCTAssertEqual(firstOutcome, .published)
        XCTAssertEqual(secondOutcome, .alreadyTerminal)
        XCTAssertTrue(op?.done ?? false)
        guard case let .response(any) = op?.result else {
            return XCTFail("Expected the first terminal response")
        }
        let retainedResponse = try Google_Protobuf_StringValue(serializedBytes: any.value)
        XCTAssertEqual(retainedResponse.value, "first")
    }

    // MARK: - putOperation Tests

    func testPutOperation_missingOperation_doesNotInsertIt() async {
        let store = OperationStore()
        var op = Google_Longrunning_Operation()
        op.name = "operations/put-new"
        op.done = true

        let replaced = await store.putOperation(op)

        let retrieved = await store.getOperation(name: "operations/put-new")
        XCTAssertFalse(replaced)
        XCTAssertNil(retrieved)
    }

    func testPutOperation_existingOperation_replacesIt() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-replace")

        var replacement = Google_Longrunning_Operation()
        replacement.name = "operations/to-replace"
        replacement.done = true
        await store.putOperation(replacement)

        let retrieved = await store.getOperation(name: "operations/to-replace")
        XCTAssertTrue(retrieved?.done ?? false)
    }

    func testPutOperation_withMetadata_preservesMetadata() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/with-meta")
        var op = Google_Longrunning_Operation()
        op.name = "operations/with-meta"
        var meta = Google_Protobuf_Any()
        meta.typeURL = "type.googleapis.com/custom.Type"
        meta.value = Data([0xDE, 0xAD, 0xBE, 0xEF])
        op.metadata = meta

        await store.putOperation(op)

        let retrieved = await store.getOperation(name: "operations/with-meta")
        XCTAssertEqual(retrieved?.metadata.value, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testPutOperation_staleSnapshotAfterDeletion_doesNotResurrect() async {
        let store = OperationStore()
        let name = "operations/deleted-before-stale-publication"
        _ = await store.createOperation(name: name)
        guard var staleSnapshot = await store.getOperation(name: name) else {
            XCTFail("Expected the operation snapshot to exist before deletion")
            return
        }

        await store.deleteOperation(name: name)
        staleSnapshot.metadata = Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/test.StaleMetadata"
        }
        await store.putOperation(staleSnapshot)

        let resurrected = await store.getOperation(name: name)
        XCTAssertNil(resurrected, "Late producer publication must not recreate a deleted public operation")
    }

    // MARK: - listOperations Tests

    func testListOperations_emptyStore_returnsEmptyArray() async {
        let store = OperationStore()

        let result = await store.listOperations()

        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertTrue(result.nextPageToken.isEmpty)
    }

    func testListOperations_withOperations_returnsAll() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/list-1")
        _ = await store.createOperation(name: "operations/list-2")
        _ = await store.createOperation(name: "operations/list-3")

        let result = await store.listOperations()

        XCTAssertEqual(result.operations.count, 3)
        let names = Set(result.operations.map(\.name))
        XCTAssertTrue(names.contains("operations/list-1"))
        XCTAssertTrue(names.contains("operations/list-2"))
        XCTAssertTrue(names.contains("operations/list-3"))
    }

    func testListOperations_afterDeletion_excludesDeleted() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/keep")
        _ = await store.createOperation(name: "operations/delete")
        await store.deleteOperation(name: "operations/delete")

        let result = await store.listOperations()

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/keep")
    }

    // MARK: - deleteOperation Tests

    func testDeleteOperation_existingOperation_removesIt() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-delete")

        await store.deleteOperation(name: "operations/to-delete")

        let op = await store.getOperation(name: "operations/to-delete")
        XCTAssertNil(op)
    }

    func testDeleteOperation_nonExistentOperation_noError() async {
        let store = OperationStore()

        // Should not throw or crash
        await store.deleteOperation(name: "operations/nonexistent")

        let result = await store.listOperations()
        XCTAssertTrue(result.operations.isEmpty)
    }

    func testDeleteOperation_multipleTimes_noError() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/delete-twice")

        await store.deleteOperation(name: "operations/delete-twice")
        await store.deleteOperation(name: "operations/delete-twice")

        let op = await store.getOperation(name: "operations/delete-twice")
        XCTAssertNil(op)
    }

    // MARK: - cancelOperation Tests

    func testCancelOperation_existingOperation_marksDone() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-cancel")

        await store.cancelOperation(name: "operations/to-cancel")

        let op = await store.getOperation(name: "operations/to-cancel")
        XCTAssertTrue(op?.done ?? false)
    }

    func testCancelOperation_existingOperation_setsErrorWithCancelledCode() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/to-cancel")

        await store.cancelOperation(name: "operations/to-cancel")

        let op = await store.getOperation(name: "operations/to-cancel")
        guard case let .error(status) = op?.result else {
            XCTFail("Expected error result")
            return
        }
        XCTAssertEqual(status.code, 1) // CANCELLED
        XCTAssertEqual(status.message, "Operation cancelled")
    }

    func testCancelOperation_nonExistentOperation_noEffect() async {
        let store = OperationStore()

        // Should not throw or crash
        await store.cancelOperation(name: "operations/nonexistent")

        let op = await store.getOperation(name: "operations/nonexistent")
        XCTAssertNil(op)
    }

    func testCancelOperation_alreadyDoneOperation_preservesTerminalState() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/already-done")
        var response = Google_Protobuf_StringValue()
        response.value = "completed"
        try await store.finishOperation(name: "operations/already-done", responseMessage: response)

        await store.cancelOperation(name: "operations/already-done")

        let op = await store.getOperation(name: "operations/already-done")
        guard case let .response(responseAny) = op?.result else {
            XCTFail("Expected completed response to remain terminal")
            return
        }
        XCTAssertTrue(responseAny.typeURL.contains("StringValue"))
    }

    // MARK: - waitOperation Tests

    func testWaitOperation_alreadyDone_returnsImmediately() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/already-done")
        await store.cancelOperation(name: "operations/already-done") // marks as done

        let startTime = Date()
        let op = try await store.waitOperation(name: "operations/already-done", timeoutNs: nil)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertNotNil(op)
        XCTAssertTrue(op?.done ?? false)
        // Should be very fast (less than 50ms) since already done
        XCTAssertLessThan(elapsed, 0.05)
    }

    func testWaitOperation_nonExistentOperation_returnsNilImmediately() async throws {
        let store = OperationStore()

        let op = try await store.waitOperation(name: "operations/nonexistent", timeoutNs: nil)

        XCTAssertNil(op)
    }

    func testWaitOperation_withTimeout_respectsTimeout() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/slow") // never completes

        let startTime = Date()
        _ = try await store.waitOperation(name: "operations/slow", timeoutNs: 150_000_000) // 150ms
        let elapsed = Date().timeIntervalSince(startTime)

        // Should respect timeout (within reasonable margin for polling interval)
        XCTAssertGreaterThanOrEqual(elapsed, 0.1) // At least 100ms
        XCTAssertLessThan(elapsed, 0.5) // But not too long
    }

    func testWaitOperation_operationCompletesInFlight_returnsCompletedOp() async throws {
        let store = OperationStore()
        let name = "operations/in-flight"
        _ = await store.createOperation(name: name)

        let waiter = Task {
            try await store.waitOperation(name: name, timeoutNs: 500_000_000)
        }
        try await waitForWaiterCount(1, name: name, store: store)
        await store.cancelOperation(name: name)

        let op = try await waiter.value

        XCTAssertNotNil(op)
        XCTAssertTrue(op?.done ?? false)
    }

    func testWaitOperation_noTimeoutCancellationRemovesWaiter() async throws {
        let store = OperationStore()
        let name = "operations/cancel-waiter"
        _ = await store.createOperation(name: name)

        let waiter = Task {
            try await store.waitOperation(name: name, timeoutNs: nil)
        }
        try await waitForWaiterCount(1, name: name, store: store)

        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let waiterCount = await store.waiterCount(name: name)
        XCTAssertEqual(waiterCount, 0)
    }

    func testWaitOperation_deleteWakesNoTimeoutWaiter() async throws {
        let store = OperationStore()
        let name = "operations/delete-waiter"
        _ = await store.createOperation(name: name)

        let waiter = Task {
            try await store.waitOperation(name: name, timeoutNs: nil)
        }
        try await waitForWaiterCount(1, name: name, store: store)

        await store.deleteOperation(name: name)
        do {
            _ = try await waiter.value
            XCTFail("Expected deleted operation to terminate its waiter")
        } catch let error as OperationStoreWaitError {
            XCTAssertEqual(error, .operationDeleted)
        }
        let waiterCount = await store.waiterCount(name: name)
        XCTAssertEqual(waiterCount, 0)
    }

    func testWaitOperation_drainWakesNoTimeoutWaiterWithCancellation() async throws {
        let store = OperationStore()
        let name = "operations/drain-waiter"
        _ = await store.createOperation(name: name)

        let waiter = Task {
            try await store.waitOperation(name: name, timeoutNs: nil)
        }
        try await waitForWaiterCount(1, name: name, store: store)

        _ = await store.drainAllOperations()
        let operation = try await waiter.value
        XCTAssertEqual(operation?.name, name)
        XCTAssertTrue(operation?.done ?? false)
        XCTAssertEqual(operation?.error.code, 1)
        let waiterCount = await store.waiterCount(name: name)
        XCTAssertEqual(waiterCount, 0)
    }

    func testWaitOperation_completionWakesWithoutPolling() async throws {
        let store = OperationStore()
        let name = "operations/completion-waiter"
        _ = await store.createOperation(name: name)

        let waiter = Task {
            try await store.waitOperation(name: name, timeoutNs: nil)
        }
        try await waitForWaiterCount(1, name: name, store: store)

        var response = Google_Protobuf_StringValue()
        response.value = "complete"
        try await store.finishOperation(name: name, responseMessage: response)

        let operation = try await waiter.value
        XCTAssertTrue(operation?.done ?? false)
        let waiterCount = await store.waiterCount(name: name)
        XCTAssertEqual(waiterCount, 0)
    }

    func testWaitOperationCompletionJoinsItsFiniteTimeoutTask() async throws {
        let sleeper = BlockingWaitTimeoutSleeper()
        let store = OperationStore(waitTimeoutSleeper: { _ in await sleeper.run() })
        let name = "operations/completion-joins-timeout"
        _ = await store.createOperation(name: name)
        let waiterReturned = AsyncReturnProbe()
        let waiter = Task {
            do {
                let result = try await store.waitOperation(
                    name: name,
                    timeoutNs: 60_000_000_000,
                )
                await waiterReturned.record()
                return result
            } catch {
                await waiterReturned.record()
                throw error
            }
        }
        try await sleeper.waitUntilEntered()

        let returned = AsyncReturnProbe()
        let completion = Task {
            var response = Google_Protobuf_StringValue()
            response.value = "complete"
            let outcome = try await store.finishOperation(name: name, responseMessage: response)
            await returned.record()
            return outcome
        }
        try await sleeper.waitUntilCancellationObserved()
        let completionReturnedWhileTimeoutOwned = await returned.didReturn()
        let waiterReturnedWhileTimeoutOwned = await waiterReturned.didReturn()
        let ownedTimeoutsBeforeRelease = await store.waitTimeoutTaskCount()
        XCTAssertFalse(completionReturnedWhileTimeoutOwned)
        XCTAssertFalse(waiterReturnedWhileTimeoutOwned)
        XCTAssertEqual(ownedTimeoutsBeforeRelease, 1)

        sleeper.release()
        let completionOutcome = try await completion.value
        let terminal = try await waiter.value
        let ownedTimeoutsAfterRelease = await store.waitTimeoutTaskCount()
        XCTAssertEqual(completionOutcome, .published)
        XCTAssertTrue(terminal?.done ?? false)
        XCTAssertEqual(ownedTimeoutsAfterRelease, 0)
    }

    func testWaitOperationDeletionJoinsItsFiniteTimeoutTask() async throws {
        let sleeper = BlockingWaitTimeoutSleeper()
        let store = OperationStore(waitTimeoutSleeper: { _ in await sleeper.run() })
        let name = "operations/deletion-joins-timeout"
        _ = await store.createOperation(name: name)
        let waiterReturned = AsyncReturnProbe()
        let waiter = Task {
            do {
                let result = try await store.waitOperation(
                    name: name,
                    timeoutNs: 60_000_000_000,
                )
                await waiterReturned.record()
                return result
            } catch {
                await waiterReturned.record()
                throw error
            }
        }
        try await sleeper.waitUntilEntered()

        let returned = AsyncReturnProbe()
        let deletion = Task {
            let deleted = await store.deleteOperation(name: name)
            await returned.record()
            return deleted
        }
        try await sleeper.waitUntilCancellationObserved()
        let deletionReturnedWhileTimeoutOwned = await returned.didReturn()
        let waiterReturnedWhileTimeoutOwned = await waiterReturned.didReturn()
        let ownedTimeoutsBeforeRelease = await store.waitTimeoutTaskCount()
        XCTAssertFalse(deletionReturnedWhileTimeoutOwned)
        XCTAssertFalse(waiterReturnedWhileTimeoutOwned)
        XCTAssertEqual(ownedTimeoutsBeforeRelease, 1)

        sleeper.release()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        do {
            _ = try await waiter.value
            XCTFail("Expected deleted waiter to fail")
        } catch let error as OperationStoreWaitError {
            XCTAssertEqual(error, .operationDeleted)
        }
        let ownedTimeoutsAfterRelease = await store.waitTimeoutTaskCount()
        XCTAssertEqual(ownedTimeoutsAfterRelease, 0)
    }

    func testWaitOperationCallerCancellationJoinsItsFiniteTimeoutTask() async throws {
        let sleeper = BlockingWaitTimeoutSleeper()
        let store = OperationStore(waitTimeoutSleeper: { _ in await sleeper.run() })
        let name = "operations/caller-cancellation-joins-timeout"
        _ = await store.createOperation(name: name)
        let returned = AsyncReturnProbe()
        let waiter = Task {
            do {
                let result = try await store.waitOperation(
                    name: name,
                    timeoutNs: 60_000_000_000,
                )
                await returned.record()
                return result
            } catch {
                await returned.record()
                throw error
            }
        }
        try await sleeper.waitUntilEntered()

        waiter.cancel()
        try await sleeper.waitUntilCancellationObserved()
        let waiterReturnedWhileTimeoutOwned = await returned.didReturn()
        let ownedTimeoutsBeforeRelease = await store.waitTimeoutTaskCount()
        XCTAssertFalse(waiterReturnedWhileTimeoutOwned)
        XCTAssertEqual(ownedTimeoutsBeforeRelease, 1)

        sleeper.release()
        do {
            _ = try await waiter.value
            XCTFail("Expected caller cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForCondition { await returned.didReturn() }
        let ownedTimeoutsAfterRelease = await store.waitTimeoutTaskCount()
        XCTAssertEqual(ownedTimeoutsAfterRelease, 0)
    }

    func testWaitOperationDrainJoinsItsFiniteTimeoutTask() async throws {
        let sleeper = BlockingWaitTimeoutSleeper()
        let store = OperationStore(waitTimeoutSleeper: { _ in await sleeper.run() })
        let name = "operations/drain-joins-timeout"
        _ = await store.createOperation(name: name)
        let waiterReturned = AsyncReturnProbe()
        let waiter = Task {
            do {
                let result = try await store.waitOperation(
                    name: name,
                    timeoutNs: 60_000_000_000,
                )
                await waiterReturned.record()
                return result
            } catch {
                await waiterReturned.record()
                throw error
            }
        }
        try await sleeper.waitUntilEntered()

        let returned = AsyncReturnProbe()
        let drain = Task {
            let counts = await store.drainAllOperations()
            await returned.record()
            return counts
        }
        try await sleeper.waitUntilCancellationObserved()
        let drainReturnedWhileTimeoutOwned = await returned.didReturn()
        let waiterReturnedWhileTimeoutOwned = await waiterReturned.didReturn()
        let ownedTimeoutsBeforeRelease = await store.waitTimeoutTaskCount()
        XCTAssertFalse(drainReturnedWhileTimeoutOwned)
        XCTAssertFalse(waiterReturnedWhileTimeoutOwned)
        XCTAssertEqual(ownedTimeoutsBeforeRelease, 1)

        sleeper.release()
        let counts = await drain.value
        let terminal = try await waiter.value
        let ownedTimeoutsAfterRelease = await store.waitTimeoutTaskCount()
        XCTAssertEqual(counts.pendingCancelled, 1)
        XCTAssertTrue(terminal?.done ?? false)
        XCTAssertEqual(ownedTimeoutsAfterRelease, 0)
    }

    func testDrainClaimsEveryTimedWaiterBeforeItsFirstJoin() async throws {
        let sleeper = SelectiveBlockingWaitTimeoutSleeper()
        let store = OperationStore(
            waitTimeoutSleeper: { timeoutNs in
                await sleeper.run(token: timeoutNs)
            },
        )
        let names = (0 ..< 4).map { "operations/drain-claims-all-waiters-\($0)" }
        for name in names {
            _ = await store.createOperation(name: name)
        }
        let waiters = names.enumerated().map { index, name in
            Task {
                try await store.waitOperation(
                    name: name,
                    timeoutNs: UInt64(index + 1),
                )
            }
        }
        try await sleeper.waitUntilEntered(count: names.count)
        defer { sleeper.releaseAll() }

        let drain = Task {
            await store.drainAllOperations()
        }
        try await sleeper.waitUntilCancellationObserved(count: names.count)

        // Drain must synchronously detach every waiter and cancel every timeout
        // child before awaiting even one cancellation-resistant child.
        XCTAssertEqual(sleeper.releaseUncancelled(), 0)

        sleeper.releaseAll()
        let counts = await drain.value
        XCTAssertEqual(counts.pendingCancelled, names.count)
        XCTAssertEqual(counts.totalDrained, names.count)
        for (index, waiter) in waiters.enumerated() {
            let terminal = try await waiter.value
            XCTAssertEqual(terminal?.name, names[index])
            XCTAssertTrue(terminal?.done ?? false)
            XCTAssertEqual(terminal?.error.code, 1)
        }
        let waiterCount = await store.waiterCount()
        let timeoutTaskCount = await store.waitTimeoutTaskCount()
        XCTAssertEqual(waiterCount, 0)
        XCTAssertEqual(timeoutTaskCount, 0)
    }

    // MARK: - Actor Isolation Tests

    func testConcurrentAccess_multipleCreates_allSucceed() async {
        let store = OperationStore()

        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 100 {
                group.addTask {
                    _ = await store.createOperation(name: "operations/concurrent-\(i)")
                }
            }
        }

        let result = await store.listOperations()
        XCTAssertEqual(result.operations.count, 100)
    }

    func testConcurrentAccess_mixedOperations_noDataCorruption() async {
        let store = OperationStore()

        // Pre-create some operations
        for i in 0 ..< 10 {
            _ = await store.createOperation(name: "operations/mixed-\(i)")
        }

        await withTaskGroup(of: Void.self) { group in
            // Readers
            for _ in 0 ..< 50 {
                group.addTask {
                    _ = await store.listOperations()
                }
            }
            // Writers (cancellers)
            for i in 0 ..< 10 {
                group.addTask {
                    await store.cancelOperation(name: "operations/mixed-\(i)")
                }
            }
            // Getters
            for i in 0 ..< 10 {
                group.addTask {
                    _ = await store.getOperation(name: "operations/mixed-\(i)")
                }
            }
        }

        // All operations should still exist and be cancelled
        let result = await store.listOperations()
        XCTAssertEqual(result.operations.count, 10)
        for op in result.operations {
            XCTAssertTrue(op.done)
        }
    }

    // MARK: - Edge Cases

    func testCreateOperation_emptyName_allowed() async {
        let store = OperationStore()
        let op = await store.createOperation(name: "")

        XCTAssertEqual(op.name, "")
        let retrieved = await store.getOperation(name: "")
        XCTAssertNotNil(retrieved)
    }

    func testCreateOperation_specialCharactersInName_preserved() async {
        let store = OperationStore()
        let specialName = "operations/test-123!@#$%^&*()_+-=[]{}|;':\",./<>?"
        let op = await store.createOperation(name: specialName)

        XCTAssertEqual(op.name, specialName)
        let retrieved = await store.getOperation(name: specialName)
        XCTAssertNotNil(retrieved)
    }

    func testCreateOperation_unicodeName_preserved() async {
        let store = OperationStore()
        let unicodeName = "operations/日本語-テスト-🚀"
        let op = await store.createOperation(name: unicodeName)

        XCTAssertEqual(op.name, unicodeName)
        let retrieved = await store.getOperation(name: unicodeName)
        XCTAssertNotNil(retrieved)
    }

    func testCreateOperation_veryLongName_handled() async {
        let store = OperationStore()
        let longName = "operations/" + String(repeating: "a", count: 10000)
        let op = await store.createOperation(name: longName)

        XCTAssertEqual(op.name, longName)
        let retrieved = await store.getOperation(name: longName)
        XCTAssertNotNil(retrieved)
    }

    func testCreateOperation_duplicateNameIsRejected() async throws {
        let store = OperationStore()
        _ = try await store.createOperation(name: "operations/duplicate", execution: {})

        do {
            _ = try await store.createOperation(name: "operations/duplicate", execution: {})
            XCTFail("Expected duplicate operation identity rejection")
        } catch let error as OperationStoreError {
            XCTAssertEqual(error, .duplicateExecution("operations/duplicate"))
        }
    }

    // MARK: - Pagination Tests

    func testListOperations_pagination_respectsPageSize() async {
        let store = OperationStore()
        for i in 0 ..< 10 {
            _ = await store.createOperation(name: "operations/page-\(i)")
        }

        let result = await store.listOperations(pageSize: 3)

        XCTAssertEqual(result.operations.count, 3)
        XCTAssertFalse(result.nextPageToken.isEmpty, "Should have next page token")
    }

    func testListOperations_pagination_returnsNextPage() async throws {
        let store = OperationStore()
        for i in 0 ..< 10 {
            _ = await store.createOperation(name: "operations/page-\(String(format: "%02d", i))")
        }

        // Get first page
        let firstPage = await store.listOperations(pageSize: 3)
        XCTAssertEqual(firstPage.operations.count, 3)

        // Get second page using token
        let secondPage = try await store.listOperations(pageSize: 3, pageToken: firstPage.nextPageToken)
        XCTAssertEqual(secondPage.operations.count, 3)

        // Names should be different
        let firstNames = Set(firstPage.operations.map(\.name))
        let secondNames = Set(secondPage.operations.map(\.name))
        XCTAssertTrue(firstNames.isDisjoint(with: secondNames), "Pages should not overlap")
    }

    func testListOperations_pagination_lastPageHasEmptyToken() async throws {
        let store = OperationStore()
        for i in 0 ..< 5 {
            _ = await store.createOperation(name: "operations/last-\(i)")
        }

        // First page
        let firstPage = await store.listOperations(pageSize: 3)
        XCTAssertFalse(firstPage.nextPageToken.isEmpty)

        // Second page (last page)
        let lastPage = try await store.listOperations(pageSize: 3, pageToken: firstPage.nextPageToken)
        XCTAssertEqual(lastPage.operations.count, 2)
        XCTAssertTrue(lastPage.nextPageToken.isEmpty, "Last page should have empty next token")
    }

    func testListOperations_pagination_exactBoundary() async {
        let store = OperationStore()
        for i in 0 ..< 6 {
            _ = await store.createOperation(name: "operations/exact-\(i)")
        }

        // Page size exactly matches total
        let firstPage = await store.listOperations(pageSize: 6)
        XCTAssertEqual(firstPage.operations.count, 6)
        XCTAssertTrue(firstPage.nextPageToken.isEmpty, "Should have empty token when exactly at boundary")
    }

    func testListOperations_pagination_defaultPageSize() async {
        let store = OperationStore()
        // Create more than 100 items
        for i in 0 ..< 150 {
            _ = await store.createOperation(name: "operations/default-\(String(format: "%03d", i))")
        }

        // pageSize=0 should default to 100
        let result = await store.listOperations(pageSize: 0)

        XCTAssertEqual(result.operations.count, 100)
        XCTAssertFalse(result.nextPageToken.isEmpty)
    }

    func testListOperations_pagination_invalidTokenIsRejected() async {
        let store = OperationStore()
        for i in 0 ..< 5 {
            _ = await store.createOperation(name: "operations/invalid-\(i)")
        }

        do {
            _ = try await store.listOperations(pageSize: 3, pageToken: "invalid-garbage-token")
            XCTFail("Expected invalid token rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        } catch {
            XCTFail("Expected RPCError, got \(error)")
        }
    }

    func testListOperations_pagination_negativeOffsetToken_isRejected() async throws {
        let store = OperationStore()
        for i in 0 ..< 5 {
            _ = await store.createOperation(name: "operations/neg-\(i)")
        }

        // Craft a token with negative offset
        let maliciousPayload = try JSONEncoder().encode(["offset": -5])
        let maliciousToken = maliciousPayload.base64EncodedString()

        do {
            _ = try await store.listOperations(pageSize: 3, pageToken: maliciousToken)
            XCTFail("Expected negative offset token rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testListOperations_pagination_deterministicOrder() async {
        let store = OperationStore()
        // Create in random order
        _ = await store.createOperation(name: "operations/z-last")
        _ = await store.createOperation(name: "operations/a-first")
        _ = await store.createOperation(name: "operations/m-middle")

        let result = await store.listOperations()

        // Should be sorted by name
        XCTAssertEqual(result.operations[0].name, "operations/a-first")
        XCTAssertEqual(result.operations[1].name, "operations/m-middle")
        XCTAssertEqual(result.operations[2].name, "operations/z-last")
    }

    // MARK: - Filter Tests

    func testListOperations_filterByDoneTrue_onlyReturnsDone() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/pending")
        _ = await store.createOperation(name: "operations/done")
        await store.cancelOperation(name: "operations/done") // marks done

        let result = await store.listOperations(showOnlyDone: true)

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/done")
        XCTAssertTrue(result.operations.first?.done ?? false)
    }

    func testListOperations_filterByDoneFalse_onlyReturnsPending() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/pending")
        _ = await store.createOperation(name: "operations/done")
        await store.cancelOperation(name: "operations/done")

        let result = await store.listOperations(showOnlyDone: false)

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/pending")
        XCTAssertFalse(result.operations.first?.done ?? true)
    }

    func testListOperations_filterByNamePrefix_matchingOperations() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/macro/execute-1")
        _ = await store.createOperation(name: "operations/macro/execute-2")
        _ = await store.createOperation(name: "operations/script/run-1")

        let result = await store.listOperations(namePrefix: "operations/macro/")

        XCTAssertEqual(result.operations.count, 2)
        XCTAssertTrue(result.operations.allSatisfy { $0.name.hasPrefix("operations/macro/") })
    }

    func testListOperations_filterByNamePrefix_noMatches() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/macro/execute")

        let result = await store.listOperations(namePrefix: "operations/nonexistent/")

        XCTAssertTrue(result.operations.isEmpty)
    }

    func testListOperations_combinedFilters_prefixAndDone() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/macro/pending")
        _ = await store.createOperation(name: "operations/macro/done")
        await store.cancelOperation(name: "operations/macro/done")
        _ = await store.createOperation(name: "operations/script/done")
        await store.cancelOperation(name: "operations/script/done")

        let result = await store.listOperations(namePrefix: "operations/macro/", showOnlyDone: true)

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/macro/done")
    }

    func testListOperations_combinedFiltersAndPagination() async throws {
        let store = OperationStore()
        // Create 10 done macro operations
        for i in 0 ..< 10 {
            _ = await store.createOperation(name: "operations/macro/done-\(String(format: "%02d", i))")
            await store.cancelOperation(name: "operations/macro/done-\(String(format: "%02d", i))")
        }
        // Create 5 pending macro operations
        for i in 0 ..< 5 {
            _ = await store.createOperation(name: "operations/macro/pending-\(i)")
        }
        // Create 5 done script operations
        for i in 0 ..< 5 {
            _ = await store.createOperation(name: "operations/script/done-\(i)")
            await store.cancelOperation(name: "operations/script/done-\(i)")
        }

        // Filter by macro prefix AND done=true, paginated
        let firstPage = await store.listOperations(
            namePrefix: "operations/macro/",
            showOnlyDone: true,
            pageSize: 3,
        )

        XCTAssertEqual(firstPage.operations.count, 3)
        XCTAssertTrue(firstPage.operations.allSatisfy { $0.name.hasPrefix("operations/macro/") })
        XCTAssertTrue(firstPage.operations.allSatisfy(\.done))
        XCTAssertFalse(firstPage.nextPageToken.isEmpty)

        // Get remaining pages
        var allFiltered: [Google_Longrunning_Operation] = firstPage.operations
        var token = firstPage.nextPageToken
        while !token.isEmpty {
            let nextPage = try await store.listOperations(
                namePrefix: "operations/macro/",
                showOnlyDone: true,
                pageSize: 3,
                pageToken: token,
            )
            allFiltered.append(contentsOf: nextPage.operations)
            token = nextPage.nextPageToken
        }

        XCTAssertEqual(allFiltered.count, 10, "Should have all 10 done macro operations")
    }

    func testCancelOperationAllowsUncooperativeProducerSuccessToWin() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/owned-cancellation"

        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
            var response = Google_Protobuf_StringValue()
            response.value = "late success"
            _ = try? await store.finishOperation(name: name, responseMessage: response)
        })
        await probe.waitUntilEntered()

        let cancellation = Task {
            await store.cancelOperation(name: name)
            await probe.recordCancelReturned()
        }
        await probe.waitUntilCancellationObserved()

        let cancelReturnedBeforeRelease = await waitForCancelReturn(probe)
        let executingBeforeRelease = await store.executionTaskCount()
        let pendingBeforeRelease = await store.getOperation(name: name)
        XCTAssertTrue(cancelReturnedBeforeRelease)
        XCTAssertEqual(executingBeforeRelease, 1)
        XCTAssertFalse(pendingBeforeRelease?.done ?? true)
        XCTAssertNil(pendingBeforeRelease?.result)

        await probe.release()
        await cancellation.value
        try await waitForExecutionTaskCount(0, store: store)

        let operation = await store.getOperation(name: name)
        XCTAssertTrue(operation?.done ?? false)
        guard case let .response(any) = operation?.result else {
            return XCTFail("Expected late producer success to remain authoritative")
        }
        let response = try Google_Protobuf_StringValue(serializedBytes: any.value)
        XCTAssertEqual(response.value, "late success")
        let executingAfterCancel = await store.executionTaskCount()
        XCTAssertEqual(executingAfterCancel, 0)
    }

    func testCancelOperationPublishesCancellationOnlyAfterProducerSettles() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/cooperative-cancellation"

        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()

        let cancelled = await store.cancelOperation(name: name)
        XCTAssertTrue(cancelled)
        await probe.waitUntilCancellationObserved()

        let pending = await store.getOperation(name: name)
        XCTAssertFalse(pending?.done ?? true)
        XCTAssertNil(pending?.result)
        let executionTaskCount = await store.executionTaskCount()
        XCTAssertEqual(executionTaskCount, 1)

        await probe.release()
        try await waitForExecutionTaskCount(0, store: store)

        let settled = await store.getOperation(name: name)
        XCTAssertTrue(settled?.done ?? false)
        XCTAssertEqual(settled?.error.code, Int32(RPCError.Code.cancelled.rawValue))
        XCTAssertEqual(settled?.error.message, "Operation cancelled")
    }

    func testDrainAwaitsOwnedExecutionAndClosesProducerAdmission() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/owned-drain"

        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()

        let drain = Task {
            let counts = await store.drainAllOperations()
            await probe.recordCancelReturned()
            return counts
        }
        await probe.waitUntilCancellationObserved()

        let drainReturnedBeforeRelease = await probe.didCancelReturn()
        XCTAssertFalse(drainReturnedBeforeRelease)

        await probe.release()
        let counts = await drain.value
        XCTAssertEqual(counts.pendingCancelled, 1)
        XCTAssertEqual(counts.totalDrained, 1)
        let operationAfterDrain = await store.getOperation(name: name)
        let executingAfterDrain = await store.executionTaskCount()
        XCTAssertNil(operationAfterDrain)
        XCTAssertEqual(executingAfterDrain, 0)

        do {
            _ = try await store.createOperation(
                name: "operations/after-drain",
                execution: {},
            )
            XCTFail("Expected producer admission to remain closed after drain")
        } catch let error as OperationStoreError {
            XCTAssertEqual(error, .admissionClosed)
        }
    }

    func testDrainSettlesWaiterOnlyAfterOwnedProducerCleanupJoins() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/cleanup-aware-drain"

        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()
        let waiter = Task {
            try await store.waitOperation(name: name, timeoutNs: nil)
        }
        try await waitForWaiterCount(1, name: name, store: store)

        let drain = Task {
            await store.drainAllOperations()
        }
        await probe.waitUntilCancellationObserved()

        let operationWhileCleanupIsOwned = await store.getOperation(name: name)
        let waiterCountWhileOwned = await store.waiterCount(name: name)
        let executionCountWhileOwned = await store.executionTaskCount()
        XCTAssertFalse(operationWhileCleanupIsOwned?.done ?? true)
        XCTAssertEqual(waiterCountWhileOwned, 1)
        XCTAssertEqual(executionCountWhileOwned, 1)

        await probe.release()
        let terminal = try await waiter.value
        let counts = await drain.value
        XCTAssertEqual(terminal?.error.code, Int32(RPCError.Code.cancelled.rawValue))
        XCTAssertTrue(terminal?.done ?? false)
        XCTAssertEqual(counts.pendingCancelled, 1)
        XCTAssertEqual(counts.totalDrained, 1)
        let finalExecutionCount = await store.executionTaskCount()
        let finalWaiterCount = await store.waiterCount()
        let finalOperation = await store.getOperation(name: name)
        XCTAssertEqual(finalExecutionCount, 0)
        XCTAssertEqual(finalWaiterCount, 0)
        XCTAssertNil(finalOperation)
    }

    func testDeleteDuringDrainDoesNotInflatePublicDrainCounts() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/delete-during-drain"
        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()

        let drain = Task { await store.drainAllOperations() }
        await probe.waitUntilCancellationObserved()
        let deleted = await store.deleteOperation(name: name)
        XCTAssertTrue(deleted)
        await probe.release()

        let counts = await drain.value
        XCTAssertEqual(counts.pendingCancelled, 0)
        XCTAssertEqual(counts.totalDrained, 0)
        let executionTaskCount = await store.executionTaskCount()
        XCTAssertEqual(executionTaskCount, 0)
    }

    func testPredeletedProducerIsJoinedButExcludedFromPublicDrainCounts() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/predeleted-drain"
        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()
        let deleted = await store.deleteOperation(name: name)
        XCTAssertTrue(deleted)

        let returned = AsyncReturnProbe()
        let drain = Task {
            let counts = await store.drainAllOperations()
            await returned.record()
            return counts
        }
        await probe.waitUntilCancellationObserved()
        let drainReturnedBeforeRelease = await returned.didReturn()
        XCTAssertFalse(drainReturnedBeforeRelease)
        await probe.release()

        let counts = await drain.value
        XCTAssertEqual(counts.pendingCancelled, 0)
        XCTAssertEqual(counts.totalDrained, 0)
        let executionTaskCount = await store.executionTaskCount()
        XCTAssertEqual(executionTaskCount, 0)
    }

    func testConcurrentDrainsShareOnePublicTransition() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let name = "operations/concurrent-drain"
        _ = try await store.createOperation(name: name, execution: {
            await probe.run()
        })
        await probe.waitUntilEntered()

        let first = Task { await store.drainAllOperations() }
        let second = Task { await store.drainAllOperations() }
        await probe.waitUntilCancellationObserved()
        await probe.release()

        let firstCounts = await first.value
        let secondCounts = await second.value
        XCTAssertEqual(firstCounts.pendingCancelled + secondCounts.pendingCancelled, 1)
        XCTAssertEqual(firstCounts.totalDrained + secondCounts.totalDrained, 1)
        XCTAssertTrue(
            (firstCounts.pendingCancelled == 0 && firstCounts.totalDrained == 0)
                || (secondCounts.pendingCancelled == 0 && secondCounts.totalDrained == 0),
        )
    }

    func testTerminalPutCannotPublishAcrossTheShutdownFence() async throws {
        let store = OperationStore()
        let probe = BlockingOwnedOperationProbe()
        let ownedName = "operations/owned-drain-fence"
        let seededName = "operations/seeded-drain-fence"
        _ = try await store.createOperation(name: ownedName, execution: {
            await probe.run()
        })
        _ = await store.createOperation(name: seededName)
        await probe.waitUntilEntered()
        let waiter = Task {
            try await store.waitOperation(name: seededName, timeoutNs: nil)
        }
        try await waitForWaiterCount(1, name: seededName, store: store)

        let drain = Task { await store.drainAllOperations() }
        await probe.waitUntilCancellationObserved()
        let pending = await store.getOperation(name: seededName)
        var stale = try XCTUnwrap(pending)
        stale.done = true
        stale.error = Google_Rpc_Status.with {
            $0.code = Int32(RPCError.Code.internalError.rawValue)
            $0.message = "stale publication"
        }
        let replaced = await store.putOperation(stale)
        let waiterCount = await store.waiterCount(name: seededName)
        XCTAssertFalse(replaced)
        XCTAssertEqual(waiterCount, 1)

        await probe.release()
        _ = await drain.value
        let terminal = try await waiter.value
        XCTAssertEqual(terminal?.error.code, Int32(RPCError.Code.cancelled.rawValue))
    }

    func testEveryOwnerlessPublicationPathHonorsTheShutdownFence() async throws {
        let store = OperationStore()
        let finishName = "operations/fenced-finish"
        let failName = "operations/fenced-fail"
        let metadataName = "operations/fenced-metadata"
        let cancelName = "operations/fenced-cancel"
        for name in [finishName, failName, metadataName, cancelName] {
            _ = await store.createOperation(name: name)
        }
        await store.beginDraining()

        var response = Google_Protobuf_StringValue()
        response.value = "must not publish"
        let finishOutcome = try await store.finishOperation(
            name: finishName,
            responseMessage: response,
        )
        await store.failOperation(
            name: failName,
            code: Int32(RPCError.Code.internalError.rawValue),
            message: "must not publish",
        )
        var metadata = Google_Protobuf_Any()
        metadata.typeURL = "type.googleapis.com/fenced.Metadata"
        let metadataUpdated = await store.updateOperationMetadata(
            name: metadataName,
            metadata: metadata,
        )
        _ = await store.cancelOperation(name: cancelName)

        XCTAssertEqual(finishOutcome, .alreadyTerminal)
        XCTAssertFalse(metadataUpdated)
        for name in [finishName, failName, metadataName, cancelName] {
            let operation = await store.getOperation(name: name)
            XCTAssertFalse(operation?.done ?? true)
            XCTAssertFalse(operation?.hasMetadata ?? true)
        }
    }

    func testBeginDrainingClosesProducerAdmissionBeforeDependentShutdown() async throws {
        let store = OperationStore()
        await store.beginDraining()

        do {
            _ = try await store.createOperation(
                name: "operations/after-front-door-close",
                execution: {},
            )
            XCTFail("Expected producer admission to close synchronously")
        } catch let error as OperationStoreError {
            XCTAssertEqual(error, .admissionClosed)
        }
    }

    func testOwnedExecutionWithoutTerminalResultFailsInsteadOfLeavingPendingOperation() async throws {
        let store = OperationStore()
        let name = "operations/missing-terminal-result"

        _ = try await store.createOperation(name: name, execution: {})
        try await waitForExecutionTaskCount(0, store: store)

        let operation = await store.getOperation(name: name)
        XCTAssertTrue(operation?.done ?? false)
        XCTAssertEqual(operation?.error.code, Int32(RPCError.Code.internalError.rawValue))
        XCTAssertEqual(
            operation?.error.message,
            "Operation producer exited without publishing a terminal result",
        )
    }

    private func waitForWaiterCount(
        _ expectedCount: Int,
        name: String,
        store: OperationStore,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while await store.waiterCount(name: name) != expectedCount {
            guard clock.now < deadline else {
                throw WaiterRegistrationTimeout()
            }
            await Task.yield()
        }
    }

    private func waitForCancelReturn(_ probe: BlockingOwnedOperationProbe) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while await !probe.didCancelReturn() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    private func waitForExecutionTaskCount(
        _ expectedCount: Int,
        store: OperationStore,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while await store.executionTaskCount() != expectedCount {
            guard clock.now < deadline else {
                throw WaiterRegistrationTimeout()
            }
            await Task.yield()
        }
    }

    private func waitForCondition(
        _ condition: @escaping @Sendable () async -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !condition() {
            guard clock.now < deadline else {
                throw WaiterRegistrationTimeout()
            }
            await Task.yield()
        }
    }
}

private struct WaiterRegistrationTimeout: Error {}

private actor AsyncReturnProbe {
    private var returned = false

    func record() {
        returned = true
    }

    func didReturn() -> Bool {
        returned
    }
}

private final class BlockingWaitTimeoutSleeper: @unchecked Sendable {
    private struct State {
        var entered = false
        var cancellationObserved = false
        var released = false
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func run() async {
        await withTaskCancellationHandler {
            lock.withLock { state.entered = true }
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if state.released {
                        return true
                    }
                    state.releaseWaiters.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.lock.withLock {
                self.state.cancellationObserved = true
            }
        }
    }

    func waitUntilEntered() async throws {
        try await waitForFlag { $0.entered }
    }

    func waitUntilCancellationObserved() async throws {
        try await waitForFlag { $0.cancellationObserved }
    }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !state.released else { return [] }
            state.released = true
            defer { state.releaseWaiters.removeAll(keepingCapacity: false) }
            return state.releaseWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForFlag(
        _ predicate: @escaping @Sendable (State) -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while lock.withLock({ !predicate(state) }) {
            guard clock.now < deadline else {
                throw WaiterRegistrationTimeout()
            }
            await Task.yield()
        }
    }
}

private final class SelectiveBlockingWaitTimeoutSleeper: @unchecked Sendable {
    private struct State {
        var entered: Set<UInt64> = []
        var cancellationObserved: Set<UInt64> = []
        var released: Set<UInt64> = []
        var releaseWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    func run(token: UInt64) async {
        await withTaskCancellationHandler {
            lock.withLock { state.entered.insert(token) }
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if state.released.contains(token) {
                        return true
                    }
                    state.releaseWaiters[token] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.lock.withLock {
                _ = self.state.cancellationObserved.insert(token)
            }
        }
    }

    func waitUntilEntered(count: Int) async throws {
        try await waitForState { $0.entered.count == count }
    }

    func waitUntilCancellationObserved(count: Int) async throws {
        try await waitForState { $0.cancellationObserved.count == count }
    }

    @discardableResult
    func releaseUncancelled() -> Int {
        let tokens = lock.withLock {
            state.entered.subtracting(state.cancellationObserved)
        }
        release(tokens)
        return tokens.count
    }

    func releaseAll() {
        let tokens = lock.withLock { state.entered }
        release(tokens)
    }

    private func release(_ tokens: Set<UInt64>) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            state.released.formUnion(tokens)
            return tokens.compactMap { state.releaseWaiters.removeValue(forKey: $0) }
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func waitForState(
        _ predicate: @escaping @Sendable (State) -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !lock.withLock({ predicate(state) }) {
            guard clock.now < deadline else {
                throw WaiterRegistrationTimeout()
            }
            await Task.yield()
        }
    }
}

private actor BlockingOwnedOperationProbe {
    private var entered = false
    private var cancellationObserved = false
    private var cancelReturned = false
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

    func recordCancelReturned() {
        cancelReturned = true
    }

    func didCancelReturn() -> Bool {
        cancelReturned
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
