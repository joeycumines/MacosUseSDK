import Foundation
import GRPCCore
import MacosUseProto
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

        // Parse filter for done status
        // AIP-160 filter syntax: "done=true" or "done=false"
        var showOnlyDone: Bool?
        let filter = req.filter.trimmingCharacters(in: .whitespaces)
        if filter == "done=true" {
            showOnlyDone = true
        } else if filter == "done=false" {
            showOnlyDone = false
        }
        // Note: We ignore filter expressions we don't understand per AIP-160 best practice
        // (fail-open for forward compatibility)

        // Extract name prefix from 'name' field (per google.longrunning.ListOperationsRequest)
        let namePrefix = req.name.isEmpty ? nil : req.name

        let (operations, nextPageToken) = await operationStore.listOperations(
            namePrefix: namePrefix,
            showOnlyDone: showOnlyDone,
            pageSize: Int(req.pageSize),
            pageToken: req.pageToken,
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
        await operationStore.deleteOperation(name: req.name)
        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func cancelOperation(
        request: ServerRequest<Google_Longrunning_CancelOperationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        await operationStore.cancelOperation(name: req.name)
        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func waitOperation(
        request: ServerRequest<Google_Longrunning_WaitOperationRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        let timeoutNs: UInt64? =
            req.hasTimeout
                ? UInt64(req.timeout.seconds) * 1_000_000_000 + UInt64(req.timeout.nanos) : nil
        if let op = await operationStore.waitOperation(name: req.name, timeoutNs: timeoutNs) {
            return ServerResponse(message: op)
        }
        throw RPCError(code: .notFound, message: "operation not found")
    }
}
