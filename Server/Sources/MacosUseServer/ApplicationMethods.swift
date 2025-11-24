import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

extension MacosUseServiceProvider {
    func openApplication(
        request: ServerRequest<Macosusesdk_V1_OpenApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message

        // Create an operation and return immediately
        let opName = "operations/open/\(UUID().uuidString)"

        Self.logger.info("openApplication called for id:\(req.id, privacy: .public) operation:\(opName, privacy: .public)")

        // optional metadata could include the requested id
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.OpenApplicationMetadata"
            $0.value = try Macosusesdk_V1_OpenApplicationMetadata.with { $0.id = req.id }
                .serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Schedule actual open on background task (coordinator runs on @MainActor internally)
        Task { [operationStore, stateStore] in
            do {
                let app = try await AutomationCoordinator.shared.handleOpenApplication(
                    identifier: req.id)
                await stateStore.addTarget(app)

                let response = Macosusesdk_V1_OpenApplicationResponse.with {
                    $0.application = app
                }

                try await operationStore.finishOperation(name: opName, responseMessage: response)
            } catch {
                // mark operation as done with an error in the response's metadata
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = 13
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }

    func getApplication(
        request: ServerRequest<Macosusesdk_V1_GetApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Application> {
        let req = request.message
        Self.logger.info("getApplication called")
        let pid = try parsePID(fromName: req.name)
        guard let app = await stateStore.getTarget(pid: pid) else {
            throw RPCError(code: .notFound, message: "Application not found")
        }
        return ServerResponse(message: app)
    }

    func listApplications(
        request: ServerRequest<Macosusesdk_V1_ListApplicationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListApplicationsResponse> {
        let req = request.message
        Self.logger.info("listApplications called")
        let allApps = await stateStore.listTargets()

        // Sort by name for deterministic ordering
        let sortedApps = allApps.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedApps.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageApps = Array(sortedApps[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListApplicationsResponse.with {
            $0.applications = pageApps
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func deleteApplication(
        request: ServerRequest<Macosusesdk_V1_DeleteApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        Self.logger.info("deleteApplication called")
        let pid = try parsePID(fromName: req.name)
        _ = await stateStore.removeTarget(pid: pid)
        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }
}
