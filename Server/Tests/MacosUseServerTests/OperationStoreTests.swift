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

        let ops = await store.listOperations()
        XCTAssertEqual(ops.count, 3)
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

        try await store.finishOperation(name: "operations/to-finish", responseMessage: response)

        let op = await store.getOperation(name: "operations/to-finish")
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

    func testFinishOperation_nonExistentOperation_throwsError() async {
        let store = OperationStore()
        var response = Google_Protobuf_StringValue()
        response.value = "response"

        do {
            try await store.finishOperation(name: "operations/nonexistent", responseMessage: response)
            XCTFail("Expected error to be thrown")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "OperationStore")
            XCTAssertEqual(nsError.code, 1)
        }
    }

    func testFinishOperation_alreadyDoneOperation_stillUpdates() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/double-finish")

        var response1 = Google_Protobuf_StringValue()
        response1.value = "first"
        try await store.finishOperation(name: "operations/double-finish", responseMessage: response1)

        var response2 = Google_Protobuf_StringValue()
        response2.value = "second"
        try await store.finishOperation(name: "operations/double-finish", responseMessage: response2)

        let op = await store.getOperation(name: "operations/double-finish")
        XCTAssertTrue(op?.done ?? false)
    }

    // MARK: - putOperation Tests

    func testPutOperation_newOperation_storesIt() async {
        let store = OperationStore()
        var op = Google_Longrunning_Operation()
        op.name = "operations/put-new"
        op.done = true

        await store.putOperation(op)

        let retrieved = await store.getOperation(name: "operations/put-new")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "operations/put-new")
        XCTAssertTrue(retrieved?.done ?? false)
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

    // MARK: - listOperations Tests

    func testListOperations_emptyStore_returnsEmptyArray() async {
        let store = OperationStore()

        let ops = await store.listOperations()

        XCTAssertTrue(ops.isEmpty)
    }

    func testListOperations_withOperations_returnsAll() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/list-1")
        _ = await store.createOperation(name: "operations/list-2")
        _ = await store.createOperation(name: "operations/list-3")

        let ops = await store.listOperations()

        XCTAssertEqual(ops.count, 3)
        let names = Set(ops.map(\.name))
        XCTAssertTrue(names.contains("operations/list-1"))
        XCTAssertTrue(names.contains("operations/list-2"))
        XCTAssertTrue(names.contains("operations/list-3"))
    }

    func testListOperations_afterDeletion_excludesDeleted() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/keep")
        _ = await store.createOperation(name: "operations/delete")
        await store.deleteOperation(name: "operations/delete")

        let ops = await store.listOperations()

        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.name, "operations/keep")
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

        let ops = await store.listOperations()
        XCTAssertTrue(ops.isEmpty)
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

    func testCancelOperation_alreadyDoneOperation_overwritesState() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/already-done")
        var response = Google_Protobuf_StringValue()
        response.value = "completed"
        try await store.finishOperation(name: "operations/already-done", responseMessage: response)

        await store.cancelOperation(name: "operations/already-done")

        let op = await store.getOperation(name: "operations/already-done")
        // Cancellation overwrites the previous state
        guard case let .error(status) = op?.result else {
            XCTFail("Expected error result after cancel")
            return
        }
        XCTAssertEqual(status.code, 1) // CANCELLED
    }

    // MARK: - waitOperation Tests

    func testWaitOperation_alreadyDone_returnsImmediately() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/already-done")
        await store.cancelOperation(name: "operations/already-done") // marks as done

        let startTime = Date()
        let op = await store.waitOperation(name: "operations/already-done", timeoutNs: nil)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertNotNil(op)
        XCTAssertTrue(op?.done ?? false)
        // Should be very fast (less than 50ms) since already done
        XCTAssertLessThan(elapsed, 0.05)
    }

    func testWaitOperation_nonExistentOperation_returnsNilEventually() async {
        let store = OperationStore()

        // With a short timeout, should return nil
        let op = await store.waitOperation(name: "operations/nonexistent", timeoutNs: 50_000_000) // 50ms

        XCTAssertNil(op)
    }

    func testWaitOperation_withTimeout_respectsTimeout() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/slow") // never completes

        let startTime = Date()
        _ = await store.waitOperation(name: "operations/slow", timeoutNs: 150_000_000) // 150ms
        let elapsed = Date().timeIntervalSince(startTime)

        // Should respect timeout (within reasonable margin for polling interval)
        XCTAssertGreaterThanOrEqual(elapsed, 0.1) // At least 100ms
        XCTAssertLessThan(elapsed, 0.5) // But not too long
    }

    func testWaitOperation_operationCompletesInFlight_returnsCompletedOp() async {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/in-flight")

        // Complete the operation after a small delay in a separate task
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await store.cancelOperation(name: "operations/in-flight")
        }

        let op = await store.waitOperation(name: "operations/in-flight", timeoutNs: 500_000_000) // 500ms

        XCTAssertNotNil(op)
        XCTAssertTrue(op?.done ?? false)
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

        let ops = await store.listOperations()
        XCTAssertEqual(ops.count, 100)
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
        let ops = await store.listOperations()
        XCTAssertEqual(ops.count, 10)
        for op in ops {
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

    func testCreateOperation_duplicateName_overwritesPrevious() async {
        let store = OperationStore()
        let first = await store.createOperation(name: "operations/duplicate")

        var meta = Google_Protobuf_Any()
        meta.typeURL = "type.googleapis.com/second"
        let second = await store.createOperation(name: "operations/duplicate", metadata: meta)

        // Should have the second operation's metadata
        let retrieved = await store.getOperation(name: "operations/duplicate")
        XCTAssertTrue(retrieved?.hasMetadata ?? false)
        XCTAssertEqual(retrieved?.metadata.typeURL, "type.googleapis.com/second")

        // Only one operation with this name
        let ops = await store.listOperations()
        XCTAssertEqual(ops.count(where: { $0.name == "operations/duplicate" }), 1)

        // Suppress warnings about unused values
        _ = first
        _ = second
    }
}
