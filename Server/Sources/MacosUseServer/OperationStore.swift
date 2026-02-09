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

    /// List operations with optional filtering and pagination.
    /// - Parameters:
    ///   - namePrefix: If provided, only operations whose name starts with this prefix are returned.
    ///   - showOnlyDone: If provided, filters by done status (true = only done, false = only pending).
    ///   - pageSize: Maximum number of operations to return. 0 or negative uses default of 100.
    ///   - pageToken: Opaque token from a previous response. Empty string starts from the beginning.
    /// - Returns: A tuple of (operations, nextPageToken). nextPageToken is empty if there are no more results.
    public func listOperations(
        namePrefix: String? = nil,
        showOnlyDone: Bool? = nil,
        pageSize: Int = 0,
        pageToken: String = "",
    ) -> (operations: [Google_Longrunning_Operation], nextPageToken: String) {
        // Default page size
        let effectivePageSize = pageSize > 0 ? pageSize : 100

        // Apply filters
        var filtered = operations.values.filter { op in
            // Name prefix filter
            if let prefix = namePrefix, !prefix.isEmpty {
                if !op.name.hasPrefix(prefix) {
                    return false
                }
            }
            // Done status filter
            if let wantDone = showOnlyDone {
                if op.done != wantDone {
                    return false
                }
            }
            return true
        }

        // Sort by name for deterministic pagination
        filtered.sort { $0.name < $1.name }

        // Decode page token to get offset
        let offset: Int = if pageToken.isEmpty {
            0
        } else if let decoded = decodeOperationsPageToken(pageToken) {
            decoded
        } else {
            // Invalid page token - start from beginning
            0
        }

        // Apply pagination
        let startIndex = min(offset, filtered.count)
        let endIndex = min(startIndex + effectivePageSize, filtered.count)
        let page = Array(filtered[startIndex ..< endIndex])

        // Generate next page token if there are more results
        var nextToken = ""
        if endIndex < filtered.count {
            nextToken = encodeOperationsPageToken(offset: endIndex)
        }

        return (page, nextToken)
    }

    /// Encodes an offset into an opaque page token.
    private func encodeOperationsPageToken(offset: Int) -> String {
        // Use base64-encoded JSON for opacity
        let data = try? JSONEncoder().encode(["offset": offset])
        return data?.base64EncodedString() ?? ""
    }

    /// Decodes a page token to extract the offset.
    private func decodeOperationsPageToken(_ token: String) -> Int? {
        guard let data = Data(base64Encoded: token),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data),
              let offset = decoded["offset"],
              offset >= 0
        else {
            return nil
        }
        return offset
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
