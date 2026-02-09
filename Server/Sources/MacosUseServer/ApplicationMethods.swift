import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

extension MacosUseService {
    func openApplication(
        request: ServerRequest<Macosusesdk_V1_OpenApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message

        // Validate id is not empty
        guard !req.id.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "id is required (bundle identifier or application name)",
                reason: "REQUIRED_FIELD_MISSING",
                field: "id",
            )
        }

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
                    identifier: req.id,
                )
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

        // Apply read_mask per AIP-157
        let filteredApp = ParsingHelpers.applyFieldMask(to: app, readMask: req.readMask)
        return ServerResponse(message: filteredApp)
    }

    func listApplications(
        request: ServerRequest<Macosusesdk_V1_ListApplicationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListApplicationsResponse> {
        let req = request.message
        Self.logger.info("listApplications called")
        var allApps = await stateStore.listTargets()

        // Apply filter if specified (AIP-160)
        if !req.filter.isEmpty {
            allApps = applyApplicationFilter(allApps, filter: req.filter)
        }

        // Parse order_by (AIP-132)
        let orderBy = req.orderBy.isEmpty ? "name" : req.orderBy.lowercased()
        let descending = orderBy.contains(" desc")
        let field = orderBy.replacingOccurrences(of: " desc", with: "").trimmingCharacters(in: .whitespaces)

        // Sort based on field
        let sortedApps: [Macosusesdk_V1_Application] = switch field {
        case "name":
            allApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "pid":
            allApps.sorted { $0.pid < $1.pid }
        case "display_name":
            allApps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        default:
            // Unknown field, use default name ordering
            allApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // Apply descending order if requested
        let orderedApps = descending ? sortedApps.reversed() : Array(sortedApps)

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = orderedApps.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageApps = Array(orderedApps[startIndex ..< endIndex])

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

    // MARK: - Filter Helpers

    /// Applies filter expression to application list per AIP-160.
    /// Supported filters: name="..." (filters by display_name)
    /// Multiple conditions can be combined with spaces (AND semantics).
    /// Note: Internal visibility for unit testing.
    func applyApplicationFilter(_ apps: [Macosusesdk_V1_Application], filter: String) -> [Macosusesdk_V1_Application] {
        var result = apps

        // Filter by name (supports name="...", filters by displayName)
        if let nameMatch = extractQuotedValueForApp(from: filter, key: "name") {
            result = result.filter { $0.displayName.localizedCaseInsensitiveContains(nameMatch) }
        }

        return result
    }

    /// Extracts a quoted value from a filter expression like key="value"
    /// Note: Internal visibility for unit testing.
    func extractQuotedValueForApp(from filter: String, key: String) -> String? {
        // Pattern: key="value" or key = "value"
        let pattern = "\(key)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(filter.startIndex ..< filter.endIndex, in: filter)
        guard let match = regex.firstMatch(in: filter, options: [], range: range) else {
            return nil
        }
        guard let valueRange = Range(match.range(at: 1), in: filter) else {
            return nil
        }
        return String(filter[valueRange])
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
