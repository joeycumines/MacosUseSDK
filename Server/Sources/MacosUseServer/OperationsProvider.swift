import Foundation
import GRPCCore
import MacosUseSDKProtos
import SwiftProtobuf

/// Provider for google.longrunning.Operations that proxies to OperationStore.
final class OperationsProvider: Google_Longrunning_Operations.ServiceProtocol {
    let operationStore: OperationStore

    init(operationStore: OperationStore) {
        self.operationStore = operationStore
    }

    // List operations - simple implementation ignoring filter/pagination
    func listOperations(
        request: ServerRequest<Google_Longrunning_ListOperationsRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_ListOperationsResponse> {
        _ = request.message
        var response = Google_Longrunning_ListOperationsResponse()
        let operations = await operationStore.listOperations()

        response.operations = operations
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
