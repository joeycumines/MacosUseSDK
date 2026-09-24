import ExactMacProto
import Foundation
import GRPCCore
import SwiftProtobuf

/// Provider for google.longrunning.Operations that proxies to OperationStore.
final class OperationsProvider: Google_Longrunning_Operations.ServiceProtocol {
    let operationStore: OperationStore

    init(operationStore: OperationStore) {
        self.operationStore = operationStore
    }

    /// List operations with optional filter and pagination.
    /// Supports filtering by done status via 'filter' field (e.g., "done=true", "done=false").
    /// Supports name prefix filtering via 'name' field.
    func listOperations(
        request: ServerRequest<Google_Longrunning_ListOperationsRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_ListOperationsResponse> {
        let req = request.message

        guard !req.returnPartialSuccess else {
            throw RPCError(
                code: .unimplemented,
                message: "return_partial_success is not supported",
            )
        }
        guard req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name must be empty for the global operations collection",
                reason: "INVALID_RESOURCE_NAME",
                field: "name",
                value: req.name,
            )
        }
        let showOnlyDone = try Self.parseDoneFilter(req.filter)
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListOperations",
            parameters: [
                ("name", ""),
                ("done", showOnlyDone.map(String.init) ?? ""),
                ("return_partial_success", "false"),
            ],
        )
        let (operations, nextPageToken) = try await operationStore.listOperations(
            namePrefix: nil,
            showOnlyDone: showOnlyDone,
            pageSize: pageSize,
            pageToken: req.pageToken,
            queryBinding: queryBinding,
        )

        var response = Google_Longrunning_ListOperationsResponse()
        response.operations = operations
        response.nextPageToken = nextPageToken
        return ServerResponse(message: response)
    }

    func getOperation(
        request: ServerRequest<Google_Longrunning_GetOperationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        _ = try ParsingHelpers.parseOperationName(req.name)
        if let op = await operationStore.getOperation(name: req.name) {
            return ServerResponse(message: op)
        }
        throw RPCError(code: .notFound, message: "operation not found")
    }

    func deleteOperation(
        request: ServerRequest<Google_Longrunning_DeleteOperationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        _ = try ParsingHelpers.parseOperationName(req.name)
        guard await operationStore.deleteOperation(name: req.name) else {
            throw RPCError(code: .notFound, message: "operation not found")
        }
        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func cancelOperation(
        request: ServerRequest<Google_Longrunning_CancelOperationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        _ = try ParsingHelpers.parseOperationName(req.name)
        guard await operationStore.cancelOperation(name: req.name) else {
            throw RPCError(code: .notFound, message: "operation not found")
        }
        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func waitOperation(
        request: ServerRequest<Google_Longrunning_WaitOperationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        _ = try ParsingHelpers.parseOperationName(req.name)
        let timeoutNs: UInt64? =
            req.hasTimeout
                ? try Self.validatedTimeoutNanoseconds(req.timeout) : nil
        let waitTask = Task {
            try await operationStore.waitOperation(name: req.name, timeoutNs: timeoutNs)
        }
        let operation: Google_Longrunning_Operation?
        do {
            operation = try await withTaskCancellationHandler {
                try await withRPCCancellationHandler {
                    try await waitTask.value
                } onCancelRPC: {
                    waitTask.cancel()
                }
            } onCancel: {
                waitTask.cancel()
            }
        } catch is CancellationError {
            throw RPCError(code: .cancelled, message: "operation wait cancelled")
        } catch OperationStoreWaitError.operationDeleted {
            throw RPCError(code: .notFound, message: "operation not found")
        }

        if let op = operation {
            return ServerResponse(message: op)
        }
        throw RPCError(code: .notFound, message: "operation not found")
    }

    static func validatedTimeoutNanoseconds(
        _ timeout: Google_Protobuf_Duration,
    ) throws -> UInt64 {
        try RequestNumericValidation.protobufTimeoutNanoseconds(
            timeout,
            allowZero: true,
        )
    }

    static func parseDoneFilter(_ rawFilter: String) throws -> Bool? {
        let filter = rawFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else {
            return nil
        }
        let expression = filter as NSString
        let regex = try NSRegularExpression(
            pattern: #"(?i)^done\s*=\s*(true|false)$"#,
        )
        let fullRange = NSRange(location: 0, length: expression.length)
        guard let match = regex.firstMatch(in: filter, range: fullRange),
              match.range == fullRange
        else {
            throw RPCErrorHelpers.validationError(
                message: "filter must be empty, done=true, or done=false",
                reason: "INVALID_FILTER",
                field: "filter",
                value: rawFilter,
            )
        }
        switch expression.substring(with: match.range(at: 1)).lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            preconditionFailure("Operations filter regex admitted an unknown boolean")
        }
    }
}
