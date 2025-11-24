import Foundation
import MacosUseProto
import SwiftProtobuf

/// Simple in-memory operation store for google.longrunning.Operation objects.
/// Not persisted — lives for process lifetime. Provides create/update/get helpers.
public actor OperationStore {
    private var operations: [String: Google_Longrunning_Operation] = [:]

    public init() {}

    /// Create a new operation with the given name and optional metadata.
    public func createOperation(name: String, metadata: SwiftProtobuf.Google_Protobuf_Any? = nil)
        -> Google_Longrunning_Operation
    {
        var op = Google_Longrunning_Operation()
        op.name = name
        op.done = false
        if let m = metadata {
            op.metadata = m
        }
        operations[name] = op
        return op
    }

    /// Mark an operation done with a response message
    public func finishOperation(name: String, responseMessage: SwiftProtobuf.Message) throws {
        guard var op = operations[name] else {
            throw NSError(
                domain: "OperationStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "operation not found"],
            )
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
    }

    /// Replace an operation entry (thread-safe)
    public func putOperation(_ op: Google_Longrunning_Operation) {
        operations[op.name] = op
    }

    /// Get an operation by name
    public func getOperation(name: String) -> Google_Longrunning_Operation? {
        operations[name]
    }

    /// List operations (simple implementation: ignore filter and pagination)
    public func listOperations() -> [Google_Longrunning_Operation] {
        Array(operations.values)
    }

    /// Delete an operation by name
    public func deleteOperation(name: String) {
        operations.removeValue(forKey: name)
    }

    /// Cancel an operation (mark as cancelled). Best-effort.
    public func cancelOperation(name: String) {
        guard var op = operations[name] else { return }
        var status = Google_Rpc_Status()
        status.code = 1 // CANCELLED
        status.message = "Operation cancelled"
        op.error = status
        op.done = true
        operations[name] = op
    }

    /// Wait for an operation to complete until optional timeout in nanoseconds.
    /// If timeoutNs is nil, waits until done (but will still poll with sleeps).
    public func waitOperation(name: String, timeoutNs: UInt64?) async -> Google_Longrunning_Operation? {
        let deadline = timeoutNs.map { DispatchTime.now().uptimeNanoseconds + $0 }
        while true {
            if let op = operations[name], op.done {
                return op
            }
            if let d = deadline, DispatchTime.now().uptimeNanoseconds >= d {
                // timeout expired, return current op state if present
                return operations[name]
            }
            // sleep a bit
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
}
