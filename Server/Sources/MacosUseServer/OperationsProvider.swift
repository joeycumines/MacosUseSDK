import Foundation
import GRPC
import MacosUseSDKProtos
import SwiftProtobuf

/// Provider for google.longrunning.Operations that proxies to OperationStore.
final class OperationsProvider: Google_Longrunning_OperationsAsyncProvider {
    let operationStore: OperationStore

    init(operationStore: OperationStore) {
        self.operationStore = operationStore
    }

    // List operations - simple implementation ignoring filter/pagination
    func listOperations(
        request _: Google_Longrunning_ListOperationsRequest, context _: GRPCAsyncServerCallContext,
    ) async throws -> Google_Longrunning_ListOperationsResponse {
        let ops = await operationStore.listOperations()
        return Google_Longrunning_ListOperationsResponse.with { $0.operations = ops }
    }

    func getOperation(
        request: Google_Longrunning_GetOperationRequest, context _: GRPCAsyncServerCallContext,
    ) async throws -> Google_Longrunning_Operation {
        if let op = await operationStore.getOperation(name: request.name) {
            return op
        }
        throw GRPCStatus(code: .notFound, message: "operation not found")
    }

    func deleteOperation(
        request: Google_Longrunning_DeleteOperationRequest, context _: GRPCAsyncServerCallContext,
    ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
        await operationStore.deleteOperation(name: request.name)
        return SwiftProtobuf.Google_Protobuf_Empty()
    }

    func cancelOperation(
        request: Google_Longrunning_CancelOperationRequest, context _: GRPCAsyncServerCallContext,
    ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
        await operationStore.cancelOperation(name: request.name)
        return SwiftProtobuf.Google_Protobuf_Empty()
    }

    func waitOperation(
        request: Google_Longrunning_WaitOperationRequest, context _: GRPCAsyncServerCallContext,
    ) async throws -> Google_Longrunning_Operation {
        let timeoutNs: UInt64? =
            request.hasTimeout
                ? UInt64(request.timeout.seconds) * 1_000_000_000 + UInt64(request.timeout.nanos) : nil
        if let op = await operationStore.waitOperation(name: request.name, timeoutNs: timeoutNs) {
            return op
        }
        throw GRPCStatus(code: .notFound, message: "operation not found")
    }
}
