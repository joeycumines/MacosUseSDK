import ExactMacProto
import Foundation
import SwiftProtobuf

enum OperationStoreError: Error, Equatable {
    case admissionClosed
    case duplicateExecution(String)
}

enum OperationStoreWaitError: Error, Equatable {
    case operationDeleted
}

public typealias OperationWaitTimeoutSleeper = @Sendable (UInt64) async -> Void
public typealias OperationBeginDrainingObserver = @Sendable () async -> Void

public enum OperationPublicationOutcome: Equatable, Sendable {
    /// The producer result became the public terminal operation result.
    case published
    /// The public record was deleted while its producer remained owned and completed.
    case discarded
    /// Another terminal result won before this producer attempted publication.
    case alreadyTerminal
}

private final class OperationWaitRegistration: @unchecked Sendable {
    typealias WaitResult = Result<Google_Longrunning_Operation?, any Error>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Google_Longrunning_Operation?, any Error>?
    private var completedResult: WaitResult?
    private var completed = false

    func wait() async throws -> Google_Longrunning_Operation? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ result: WaitResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            resume(continuation, with: result)
        } else {
            completedResult = result
            lock.unlock()
        }
    }

    private func install(
        _ continuation: CheckedContinuation<Google_Longrunning_Operation?, any Error>,
    ) {
        lock.lock()
        if let completedResult {
            self.completedResult = nil
            lock.unlock()
            resume(continuation, with: completedResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Google_Longrunning_Operation?, any Error>,
        with result: WaitResult,
    ) {
        switch result {
        case let .success(operation):
            continuation.resume(returning: operation)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

/// Simple in-memory operation store for google.longrunning.Operation objects.
/// Not persisted — lives for process lifetime. Provides create/update/get helpers.
public actor OperationStore {
    private struct ExecutionDisposition {
        var cancellationRequested = false
        var resultDiscarded = false
        var shutdownRequested = false
    }

    private struct Waiter {
        let registration: OperationWaitRegistration
    }

    private var operations: [String: Google_Longrunning_Operation] = [:]
    private var executionTasks: [String: Task<Void, Never>] = [:]
    private var executionDispositions: [String: ExecutionDisposition] = [:]
    private var waiters: [String: [UUID: Waiter]] = [:]
    private var waitTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var waiterSettlementsInFlight = 0
    private var waiterSettlementContinuations: [CheckedContinuation<Void, Never>] = []
    private var acceptingExecutions = true
    private let waitTimeoutSleeper: OperationWaitTimeoutSleeper
    private let beginDrainingObserver: OperationBeginDrainingObserver
    private var beginDrainingTask: Task<Void, Never>?
    private var drainTask: Task<(pendingCancelled: Int, totalDrained: Int), Never>?

    public init(
        waitTimeoutSleeper: @escaping OperationWaitTimeoutSleeper = { timeoutNs in
            try? await Task.sleep(nanoseconds: timeoutNs)
        },
        beginDrainingObserver: @escaping OperationBeginDrainingObserver = {},
    ) {
        self.waitTimeoutSleeper = waitTimeoutSleeper
        self.beginDrainingObserver = beginDrainingObserver
    }

    /// Test-only seed for a producerless operation. Production creation uses
    /// the owned execution overload below.
    func createOperation(name: String, metadata: SwiftProtobuf.Google_Protobuf_Any? = nil)
        -> Google_Longrunning_Operation
    {
        precondition(acceptingExecutions, "Operation seed admission is closed")
        precondition(
            operations[name] == nil
                && executionTasks[name] == nil
                && executionDispositions[name] == nil,
            "Operation seed identity is already owned",
        )
        let op = makeOperationRecord(name: name, metadata: metadata)
        operations[name] = op
        return op
    }

    private func makeOperationRecord(
        name: String,
        metadata: SwiftProtobuf.Google_Protobuf_Any?,
    ) -> Google_Longrunning_Operation {
        Google_Longrunning_Operation.with {
            $0.name = name
            $0.done = false
            if let metadata {
                $0.metadata = metadata
            }
        }
    }

    /// Atomically creates an operation and records the task that produces its
    /// terminal result. Shutdown and CancelOperation use this ownership to
    /// cancel and join real work rather than merely rewriting protobuf state.
    public func createOperation(
        name: String,
        metadata: SwiftProtobuf.Google_Protobuf_Any? = nil,
        execution: @escaping @Sendable () async -> Void,
    ) throws -> Google_Longrunning_Operation {
        guard acceptingExecutions else {
            throw OperationStoreError.admissionClosed
        }
        guard operations[name] == nil,
              executionTasks[name] == nil,
              executionDispositions[name] == nil
        else {
            throw OperationStoreError.duplicateExecution(name)
        }

        let operation = makeOperationRecord(name: name, metadata: metadata)
        operations[name] = operation
        executionDispositions[name] = ExecutionDisposition()
        executionTasks[name] = Task { [weak self] in
            await execution()
            await self?.executionDidFinish(name: name)
        }
        return operation
    }

    /// Mark an operation done with a response message
    @discardableResult
    public func finishOperation(
        name: String,
        responseMessage: SwiftProtobuf.Message,
    ) async throws -> OperationPublicationOutcome {
        guard acceptingExecutions,
              executionDispositions[name]?.shutdownRequested != true
        else {
            return .alreadyTerminal
        }
        guard var op = operations[name] else {
            guard var disposition = executionDispositions[name], disposition.resultDiscarded else {
                return .alreadyTerminal
            }
            disposition.resultDiscarded = false
            executionDispositions[name] = disposition
            return .discarded
        }
        guard !op.done else {
            return .alreadyTerminal
        }

        let data = try responseMessage.serializedData()
        let protoTypeName = type(of: responseMessage).protoMessageName
        let any = SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/\(protoTypeName)"
            $0.value = data
        }
        op.done = true
        op.result = .response(any)
        operations[name] = op
        clearExecutionCancellationRequest(name: name)
        await resolveWaiters(name: name, with: .success(op))
        return .published
    }

    /// Replaces an existing nonterminal operation entry.
    ///
    /// Creation is intentionally exclusive to `createOperation`. A producer
    /// holding a stale snapshot after DeleteOperation must not recreate the
    /// deleted public record through a late publication.
    @discardableResult
    func putOperation(_ op: Google_Longrunning_Operation) async -> Bool {
        guard acceptingExecutions,
              let current = operations[op.name],
              !current.done
        else {
            return false
        }
        operations[op.name] = op
        if op.done {
            clearExecutionCancellationRequest(name: op.name)
            await resolveWaiters(name: op.name, with: .success(op))
        }
        return true
    }

    /// Atomically updates metadata only while the public operation exists and
    /// remains nonterminal.
    @discardableResult
    public func updateOperationMetadata(
        name: String,
        metadata: SwiftProtobuf.Google_Protobuf_Any,
    ) -> Bool {
        guard acceptingExecutions,
              var operation = operations[name],
              !operation.done
        else {
            return false
        }
        operation.metadata = metadata
        operations[name] = operation
        return true
    }

    public func failOperation(name: String, code: Int32, message: String) async {
        guard acceptingExecutions,
              executionDispositions[name]?.shutdownRequested != true
        else {
            return
        }
        guard var operation = operations[name], !operation.done else {
            return
        }
        operation.done = true
        operation.error = Google_Rpc_Status.with {
            $0.code = code
            $0.message = message
        }
        operations[name] = operation
        clearExecutionCancellationRequest(name: name)
        await resolveWaiters(name: name, with: .success(operation))
    }

    /// Get an operation by name
    public func getOperation(name: String) -> Google_Longrunning_Operation? {
        operations[name]
    }

    /// Lists the first page of operations with optional filtering.
    public func listOperations(
        namePrefix: String? = nil,
        showOnlyDone: Bool? = nil,
        pageSize: Int = 0,
    ) -> (operations: [Google_Longrunning_Operation], nextPageToken: String) {
        let effectivePageSize = pageSize > 0 ? pageSize : 100
        let queryBinding = operationListQueryBinding(
            namePrefix: namePrefix,
            showOnlyDone: showOnlyDone,
            pageSize: effectivePageSize,
        )
        let filtered = filteredOperations(
            namePrefix: namePrefix,
            showOnlyDone: showOnlyDone,
        )
        let endOffset = min(effectivePageSize, filtered.count)
        return (
            Array(filtered[0 ..< endOffset]),
            ParsingHelpers.nextPageToken(
                endOffset: endOffset,
                totalCount: filtered.count,
                queryBinding: queryBinding,
            ),
        )
    }

    /// Lists operations using the canonical opaque query-bound token policy.
    public func listOperations(
        namePrefix: String? = nil,
        showOnlyDone: Bool? = nil,
        pageSize: Int = 0,
        pageToken: String,
        queryBinding: String? = nil,
    ) throws -> (operations: [Google_Longrunning_Operation], nextPageToken: String) {
        let effectivePageSize = pageSize > 0 ? pageSize : 100
        let binding = queryBinding ?? operationListQueryBinding(
            namePrefix: namePrefix,
            showOnlyDone: showOnlyDone,
            pageSize: effectivePageSize,
        )
        let offset = try ParsingHelpers.pageOffset(
            token: pageToken,
            queryBinding: binding,
        )
        let filtered = filteredOperations(
            namePrefix: namePrefix,
            showOnlyDone: showOnlyDone,
        )
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: effectivePageSize,
            totalCount: filtered.count,
        )
        return (
            Array(filtered[range]),
            ParsingHelpers.nextPageToken(
                endOffset: range.upperBound,
                totalCount: filtered.count,
                queryBinding: binding,
            ),
        )
    }

    private func filteredOperations(
        namePrefix: String?,
        showOnlyDone: Bool?,
    ) -> [Google_Longrunning_Operation] {
        var filtered = operations.values.filter { op in
            if let prefix = namePrefix, !prefix.isEmpty {
                if !op.name.hasPrefix(prefix) {
                    return false
                }
            }
            if let wantDone = showOnlyDone {
                if op.done != wantDone {
                    return false
                }
            }
            return true
        }

        filtered.sort { $0.name < $1.name }
        return filtered
    }

    private func operationListQueryBinding(
        namePrefix: String?,
        showOnlyDone: Bool?,
        pageSize _: Int,
    ) -> String {
        ParsingHelpers.pageTokenQuery(
            method: "OperationStore.listOperations",
            parameters: [
                ("name_prefix", namePrefix ?? ""),
                ("done", showOnlyDone.map(String.init) ?? ""),
            ],
        )
    }

    /// Discards an operation result without cancelling its producer.
    ///
    /// Google Long Running Operations defines DeleteOperation as client
    /// disinterest in the result, not cancellation of the underlying work.
    /// The producer remains retained here until it exits so shutdown can still
    /// cancel and join every owned task.
    @discardableResult
    public func deleteOperation(name: String) async -> Bool {
        guard operations.removeValue(forKey: name) != nil else {
            return false
        }
        if var disposition = executionDispositions[name], !disposition.shutdownRequested {
            disposition.cancellationRequested = false
            disposition.resultDiscarded = true
            executionDispositions[name] = disposition
        }
        await resolveWaiters(
            name: name,
            with: .failure(OperationStoreWaitError.operationDeleted),
        )
        return true
    }

    /// Starts cancellation of the exact task producing a pending operation.
    ///
    /// CancelOperation is best effort and asynchronous by contract. An owned
    /// producer is signalled while the public operation remains pending; its
    /// own response or failure may still win. Cancellation becomes terminal
    /// only if that producer exits without publishing another result.
    @discardableResult
    public func cancelOperation(name: String) async -> Bool {
        guard var op = operations[name] else { return false }
        guard !op.done else { return true }
        if let executionTask = executionTasks[name], var disposition = executionDispositions[name] {
            disposition.cancellationRequested = true
            executionDispositions[name] = disposition
            executionTask.cancel()
            return true
        }
        guard acceptingExecutions else {
            return true
        }

        // A manually inserted operation has no producer that can settle after
        // observing cancellation, so cancellation settles it immediately.
        var status = Google_Rpc_Status()
        status.code = 1 // CANCELLED
        status.message = "Operation cancelled"
        op.error = status
        op.done = true
        operations[name] = op
        await resolveWaiters(name: name, with: .success(op))
        return true
    }

    /// Drains all operations during graceful shutdown.
    ///
    /// This method:
    /// 1. Cancels all pending (not done) operations
    /// 2. Clears all operations from the store
    ///
    /// - Returns: A tuple of (pendingCancelled, totalDrained) counts.
    @discardableResult
    public func drainAllOperations() async -> (pendingCancelled: Int, totalDrained: Int) {
        let task: Task<(pendingCancelled: Int, totalDrained: Int), Never>
        let isLeader: Bool
        if let drainTask {
            task = drainTask
            isLeader = false
        } else {
            task = Task { [weak self] in
                guard let self else {
                    return (pendingCancelled: 0, totalDrained: 0)
                }
                return await self.performDrainAllOperations()
            }
            drainTask = task
            isLeader = true
        }
        let counts = await task.value
        return isLeader ? counts : (pendingCancelled: 0, totalDrained: 0)
    }

    /// Atomically closes operation-producer admission and establishes shutdown
    /// ownership before any dependent owner begins cancellation.
    public func beginDraining() async {
        let task: Task<Void, Never>
        if let beginDrainingTask {
            task = beginDrainingTask
        } else {
            acceptingExecutions = false
            for name in Array(executionDispositions.keys) {
                guard var disposition = executionDispositions[name] else { continue }
                disposition.shutdownRequested = true
                disposition.resultDiscarded = false
                disposition.cancellationRequested = false
                executionDispositions[name] = disposition
            }
            let observer = beginDrainingObserver
            task = Task { await observer() }
            beginDrainingTask = task
        }
        await task.value
    }

    private func performDrainAllOperations()
        async -> (pendingCancelled: Int, totalDrained: Int)
    {
        await beginDraining()

        let tasks = Array(executionTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        executionTasks.removeAll(keepingCapacity: false)
        executionDispositions.removeAll(keepingCapacity: false)

        let publicOperations = Array(operations.values)
        operations.removeAll(keepingCapacity: false)
        var pendingCancelled = 0
        var waiterResults: [String: OperationWaitRegistration.WaitResult] = [:]
        for var operation in publicOperations {
            if !operation.done {
                operation.done = true
                operation.error = Google_Rpc_Status.with {
                    $0.code = 1
                    $0.message = "Operation cancelled during server shutdown"
                }
                pendingCancelled += 1
            }
            waiterResults[operation.name] = .success(operation)
        }

        await resolveWaiters(with: waiterResults)
        await waitForWaiterSettlements()
        return (
            pendingCancelled: pendingCancelled,
            totalDrained: publicOperations.count,
        )
    }

    func executionTaskCount() -> Int {
        executionTasks.count
    }

    /// Wait for an operation to become terminal without polling. Completion,
    /// cancellation, deletion, timeout, caller cancellation, and store drain
    /// each resume the exact registered waiter once.
    public func waitOperation(
        name: String,
        timeoutNs: UInt64?,
    ) async throws -> Google_Longrunning_Operation? {
        try Task.checkCancellation()
        guard let operation = operations[name] else { return nil }
        guard !operation.done, timeoutNs != 0 else { return operation }

        let id = UUID()
        let registration = OperationWaitRegistration()
        waiters[name, default: [:]][id] = Waiter(registration: registration)
        if let timeoutNs {
            let sleeper = waitTimeoutSleeper
            waitTimeoutTasks[id] = Task { [weak self] in
                await sleeper(timeoutNs)
                guard !Task.isCancelled else { return }
                await self?.timeoutWaiter(name: name, id: id)
            }
        }

        do {
            let operation = try await registration.wait()
            await removeWaiterAndJoinTimeout(name: name, id: id)
            return operation
        } catch {
            await removeWaiterAndJoinTimeout(name: name, id: id)
            throw error
        }
    }

    func waiterCount(name: String? = nil) -> Int {
        if let name {
            return waiters[name]?.count ?? 0
        }
        return waiters.values.reduce(0) { $0 + $1.count }
    }

    func waitTimeoutTaskCount() -> Int {
        waitTimeoutTasks.count
    }

    private func executionDidFinish(name: String) async {
        executionTasks.removeValue(forKey: name)
        let disposition = executionDispositions.removeValue(forKey: name)
        if disposition?.shutdownRequested == true {
            return
        }
        guard let operation = operations[name], !operation.done else {
            return
        }
        if disposition?.cancellationRequested == true {
            await failOperation(
                name: name,
                code: 1,
                message: "Operation cancelled",
            )
            return
        }
        await failOperation(
            name: name,
            code: 13,
            message: "Operation producer exited without publishing a terminal result",
        )
    }

    private func clearExecutionCancellationRequest(name: String) {
        guard var disposition = executionDispositions[name] else { return }
        disposition.cancellationRequested = false
        executionDispositions[name] = disposition
    }

    private func timeoutWaiter(name: String, id: UUID) {
        guard let waiter = waiters[name]?[id] else { return }
        waiter.registration.resolve(.success(operations[name]))
    }

    private func removeWaiterAndJoinTimeout(name: String, id: UUID) async {
        beginWaiterSettlement()
        if var operationWaiters = waiters[name] {
            operationWaiters.removeValue(forKey: id)
            if operationWaiters.isEmpty {
                waiters.removeValue(forKey: name)
            } else {
                waiters[name] = operationWaiters
            }
        }
        if let timeoutTask = waitTimeoutTasks[id] {
            timeoutTask.cancel()
            await timeoutTask.value
            waitTimeoutTasks.removeValue(forKey: id)
        }
        endWaiterSettlement()
    }

    private func resolveWaiters(
        name: String,
        with result: OperationWaitRegistration.WaitResult,
    ) async {
        guard let operationWaiters = waiters.removeValue(forKey: name) else { return }
        beginWaiterSettlement()
        let ids = Array(operationWaiters.keys)
        let timeoutTasks = ids.compactMap { waitTimeoutTasks[$0] }
        for timeoutTask in timeoutTasks {
            timeoutTask.cancel()
        }
        for timeoutTask in timeoutTasks {
            await timeoutTask.value
        }
        for id in ids {
            waitTimeoutTasks.removeValue(forKey: id)
        }
        for waiter in operationWaiters.values {
            waiter.registration.resolve(result)
        }
        endWaiterSettlement()
    }

    private func resolveWaiters(
        with results: [String: OperationWaitRegistration.WaitResult],
    ) async {
        var claimed: [(
            registration: OperationWaitRegistration,
            result: OperationWaitRegistration.WaitResult,
        )] = []
        var timeoutIDs: [UUID] = []
        for (name, result) in results {
            guard let operationWaiters = waiters.removeValue(forKey: name) else { continue }
            timeoutIDs.append(contentsOf: operationWaiters.keys)
            claimed.append(contentsOf: operationWaiters.values.map {
                (registration: $0.registration, result: result)
            })
        }
        guard !claimed.isEmpty else { return }

        // Claim every waiter and cancellation child before the first join.
        // Otherwise a timeout belonging to a later operation can win while
        // drain is suspended joining an earlier cancellation-resistant child.
        beginWaiterSettlement()
        let timeoutTasks = timeoutIDs.compactMap { waitTimeoutTasks[$0] }
        for timeoutTask in timeoutTasks {
            timeoutTask.cancel()
        }
        for timeoutTask in timeoutTasks {
            await timeoutTask.value
        }
        for id in timeoutIDs {
            waitTimeoutTasks.removeValue(forKey: id)
        }
        for item in claimed {
            item.registration.resolve(item.result)
        }
        endWaiterSettlement()
    }

    private func beginWaiterSettlement() {
        waiterSettlementsInFlight += 1
    }

    private func endWaiterSettlement() {
        precondition(waiterSettlementsInFlight > 0)
        waiterSettlementsInFlight -= 1
        guard waiterSettlementsInFlight == 0 else { return }
        let continuations = waiterSettlementContinuations
        waiterSettlementContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func waitForWaiterSettlements() async {
        while waiterSettlementsInFlight > 0 {
            await withCheckedContinuation { continuation in
                waiterSettlementContinuations.append(continuation)
            }
        }
    }
}
