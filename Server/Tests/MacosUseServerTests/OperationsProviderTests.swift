import GRPCCore
import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Unit tests for OperationsProvider filter parsing.
/// These tests specifically verify filter string parsing which is handled at the provider layer.
/// Core pagination and filtering logic is tested in OperationStoreTests.
final class OperationsProviderTests: XCTestCase {
    // MARK: - Filter String Parsing Tests

    func testFilterParsing_doneTrue_parsesCorrectly() {
        XCTAssertEqual(try OperationsProvider.parseDoneFilter("done=true"), true)
    }

    func testFilterParsing_doneFalse_parsesCorrectly() {
        XCTAssertEqual(try OperationsProvider.parseDoneFilter("done=false"), false)
    }

    func testFilterParsing_caseInsensitive_doneTrue() {
        for filterValue in ["done=TRUE", "DONE=true", "Done=True", "DONE=TRUE", "done=True"] {
            XCTAssertEqual(try OperationsProvider.parseDoneFilter(filterValue), true, "'\(filterValue)' should parse to true")
        }
    }

    func testFilterParsing_caseInsensitive_doneFalse() {
        for filterValue in ["done=FALSE", "DONE=false", "Done=False", "DONE=FALSE", "done=False"] {
            XCTAssertEqual(try OperationsProvider.parseDoneFilter(filterValue), false, "'\(filterValue)' should parse to false")
        }
    }

    func testFilterParsing_internalSpaces_normalized() {
        // These should all normalize to "done=true"
        for filterValue in ["done = true", "done =true", "done= true", "  done = true  "] {
            XCTAssertEqual(try OperationsProvider.parseDoneFilter(filterValue), true, "'\(filterValue)' should parse to true")
        }
    }

    func testFilterParsing_newlines_trimmed() {
        XCTAssertEqual(try OperationsProvider.parseDoneFilter("done=true\n"), true)
        XCTAssertEqual(try OperationsProvider.parseDoneFilter("\ndone=false\n"), false)
    }

    func testFilterParsing_unrecognized_rejects() throws {
        XCTAssertNil(try OperationsProvider.parseDoneFilter(""))
        for filter in [
            "status=running",
            "done=maybe",
            "complete=true",
            "d o n e = t r u e",
            "do ne=true",
            "done=tr ue",
        ] {
            XCTAssertThrowsError(try OperationsProvider.parseDoneFilter(filter)) { error in
                XCTAssertEqual((error as? RPCError)?.code, .invalidArgument)
            }
        }
    }

    // MARK: - Integration Test with OperationStore

    func testListOperations_filterDoneTrue_integratedCorrectly() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/done-1")
        _ = await store.createOperation(name: "operations/pending-1")
        var response = Google_Protobuf_StringValue()
        response.value = "completed"
        try await store.finishOperation(name: "operations/done-1", responseMessage: response)

        // Parse filter string the way OperationsProvider does
        let showOnlyDone = try OperationsProvider.parseDoneFilter("DONE=TRUE")

        let result = try await store.listOperations(
            namePrefix: nil,
            showOnlyDone: showOnlyDone,
            pageSize: 100,
            pageToken: "",
        )

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/done-1")
    }

    func testListOperations_filterDoneFalse_integratedCorrectly() async throws {
        let store = OperationStore()
        _ = await store.createOperation(name: "operations/done-1")
        _ = await store.createOperation(name: "operations/pending-1")
        var response = Google_Protobuf_StringValue()
        response.value = "completed"
        try await store.finishOperation(name: "operations/done-1", responseMessage: response)

        // Parse filter string the way OperationsProvider does (with spaces)
        let showOnlyDone = try OperationsProvider.parseDoneFilter("done = false")

        let result = try await store.listOperations(
            namePrefix: nil,
            showOnlyDone: showOnlyDone,
            pageSize: 100,
            pageToken: "",
        )

        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.name, "operations/pending-1")
    }

    // MARK: - Provider Initialization Test

    func testProviderInitialization() {
        let store = OperationStore()
        let provider = OperationsProvider(operationStore: store)
        XCTAssertNotNil(provider)
    }

    func testWaitTimeoutConversion_acceptsCanonicalFiniteDuration() throws {
        let timeout = Google_Protobuf_Duration.with {
            $0.seconds = 1
            $0.nanos = 2
        }

        XCTAssertEqual(
            try OperationsProvider.validatedTimeoutNanoseconds(timeout),
            1_000_000_002,
        )
    }

    func testWaitTimeoutConversion_rejectsNegativeNoncanonicalAndOverflowDurations() {
        assertInvalidWaitTimeout(seconds: -1, nanos: 0)
        assertInvalidWaitTimeout(seconds: 0, nanos: -1)
        assertInvalidWaitTimeout(seconds: 0, nanos: 1_000_000_000)
        assertInvalidWaitTimeout(seconds: Int64.max, nanos: 0)
    }

    func testWaitOperation_rpcCancellationTerminatesNoTimeoutWaiter() async throws {
        let store = OperationStore()
        let provider = OperationsProvider(operationStore: store)
        let name = "operations/provider-cancel"
        _ = await store.createOperation(name: name)
        let request = ServerRequest(
            metadata: Metadata(),
            message: Google_Longrunning_WaitOperationRequest.with { $0.name = name },
        )

        try await withServerContextRPCCancellationHandle { cancellation in
            let context = ServerContext(
                descriptor: Google_Longrunning_Operations.Method.WaitOperation.descriptor,
                remotePeer: "in-process:tests",
                localPeer: "in-process:server",
                cancellation: cancellation,
            )
            let response = Task {
                try await provider.waitOperation(request: request, context: context)
            }
            try await waitForWaiterCount(1, name: name, store: store)

            cancellation.cancel()
            do {
                _ = try await response.value
                XCTFail("Expected RPC cancellation")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .cancelled)
            }
            let waiterCount = await store.waiterCount(name: name)
            XCTAssertEqual(waiterCount, 0)
        }
    }

    func testDeleteOperationDiscardsResultWithoutCancellingOwnedExecution() async throws {
        let store = OperationStore()
        let provider = OperationsProvider(operationStore: store)
        let probe = OwnedOperationProducerProbe()
        let name = "operations/delete-without-cancel"
        _ = try await store.createOperation(
            name: name,
            execution: { await probe.run() },
        )
        await probe.waitUntilEntered()
        let request = ServerRequest(
            metadata: Metadata(),
            message: Google_Longrunning_DeleteOperationRequest.with { $0.name = name },
        )

        try await withServerContextRPCCancellationHandle { cancellation in
            let context = ServerContext(
                descriptor: Google_Longrunning_Operations.Method.DeleteOperation.descriptor,
                remotePeer: "in-process:tests",
                localPeer: "in-process:server",
                cancellation: cancellation,
            )
            let deletion = Task {
                let response = try await provider.deleteOperation(request: request, context: context)
                await probe.recordMethodReturned()
                return response
            }

            let firstEvent = await probe.waitForFirstEvent()
            XCTAssertEqual(firstEvent, .methodReturned)
            let cancellationObserved = await probe.wasCancellationObserved()
            XCTAssertFalse(cancellationObserved)
            let deletedOperation = await store.getOperation(name: name)
            let producerCountBeforeRelease = await store.executionTaskCount()
            XCTAssertNil(deletedOperation)
            XCTAssertEqual(producerCountBeforeRelease, 1)

            await probe.release()
            _ = try await deletion.value
            try await waitForExecutionTaskCount(0, store: store)
        }
    }

    func testCancelOperationStartsCancellationWithoutJoiningOwnedExecution() async throws {
        let store = OperationStore()
        let provider = OperationsProvider(operationStore: store)
        let probe = OwnedOperationProducerProbe()
        let name = "operations/asynchronous-cancel"
        _ = try await store.createOperation(
            name: name,
            execution: { await probe.run() },
        )
        await probe.waitUntilEntered()
        let request = ServerRequest(
            metadata: Metadata(),
            message: Google_Longrunning_CancelOperationRequest.with { $0.name = name },
        )

        try await withServerContextRPCCancellationHandle { cancellation in
            let context = ServerContext(
                descriptor: Google_Longrunning_Operations.Method.CancelOperation.descriptor,
                remotePeer: "in-process:tests",
                localPeer: "in-process:server",
                cancellation: cancellation,
            )
            let cancellationRequest = Task {
                let response = try await provider.cancelOperation(request: request, context: context)
                await probe.recordMethodReturned()
                return response
            }

            _ = await probe.waitForFirstEvent()
            let methodReturned = await waitForMethodReturn(probe)
            let producerCancelled = await waitForProducerCancellation(probe)
            XCTAssertTrue(methodReturned)
            XCTAssertTrue(producerCancelled)
            let operation = await store.getOperation(name: name)
            let producerCountBeforeRelease = await store.executionTaskCount()
            XCTAssertFalse(operation?.done ?? true)
            XCTAssertNil(operation?.result)
            XCTAssertEqual(producerCountBeforeRelease, 1)

            await probe.release()
            _ = try await cancellationRequest.value
            try await waitForExecutionTaskCount(0, store: store)
            let settled = await store.getOperation(name: name)
            XCTAssertTrue(settled?.done ?? false)
            XCTAssertEqual(settled?.error.code, Int32(RPCError.Code.cancelled.rawValue))
        }
    }

    private func assertInvalidWaitTimeout(seconds: Int64, nanos: Int32) {
        let timeout = Google_Protobuf_Duration.with {
            $0.seconds = seconds
            $0.nanos = nanos
        }
        XCTAssertThrowsError(try OperationsProvider.validatedTimeoutNanoseconds(timeout)) { error in
            guard let rpcError = error as? RPCError else {
                return XCTFail("Expected RPCError, got \(error)")
            }
            XCTAssertEqual(rpcError.code, .invalidArgument)
        }
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
                throw OperationsProviderWaiterTimeout()
            }
            await Task.yield()
        }
    }

    private func waitForExecutionTaskCount(
        _ expectedCount: Int,
        store: OperationStore,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while await store.executionTaskCount() != expectedCount {
            guard clock.now < deadline else {
                throw OperationsProviderWaiterTimeout()
            }
            await Task.yield()
        }
    }

    private func waitForMethodReturn(_ probe: OwnedOperationProducerProbe) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while await !probe.didMethodReturn() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    private func waitForProducerCancellation(_ probe: OwnedOperationProducerProbe) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while await !probe.wasCancellationObserved() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

private struct OperationsProviderWaiterTimeout: Error {}

private enum OperationMethodFirstEvent: Equatable {
    case methodReturned
    case producerCancelled
}

private actor OwnedOperationProducerProbe {
    private var entered = false
    private var methodReturned = false
    private var cancellationObserved = false
    private var firstEvent: OperationMethodFirstEvent?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstEventContinuations: [CheckedContinuation<OperationMethodFirstEvent, Never>] = []

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
            Task { await self.recordProducerCancelled() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func recordMethodReturned() {
        methodReturned = true
        recordFirstEvent(.methodReturned)
    }

    func waitForFirstEvent() async -> OperationMethodFirstEvent {
        if let firstEvent {
            return firstEvent
        }
        return await withCheckedContinuation { continuation in
            firstEventContinuations.append(continuation)
        }
    }

    func wasCancellationObserved() -> Bool {
        cancellationObserved
    }

    func didMethodReturn() -> Bool {
        methodReturned
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func recordProducerCancelled() {
        cancellationObserved = true
        recordFirstEvent(.producerCancelled)
    }

    private func recordFirstEvent(_ event: OperationMethodFirstEvent) {
        guard firstEvent == nil else { return }
        firstEvent = event
        let continuations = firstEventContinuations
        firstEventContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: event)
        }
    }
}
