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
    func createObservation(
        request: ServerRequest<Macosusesdk_V1_CreateObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("createObservation called (LRO)")

        // Parse parent resource name to get PID
        let pid = try parsePID(fromName: req.parent)

        // Generate observation ID
        let observationId =
            req.observationID.isEmpty ? UUID().uuidString : req.observationID
        let observationName = "\(req.parent)/observations/\(observationId)"

        // Create operation for LRO
        let opName = "operations/observation/\(observationId)"

        // Create initial observation in ObservationManager
        let observation = await ObservationManager.shared.createObservation(
            name: observationName,
            type: req.observation.type,
            parent: req.parent,
            filter: req.observation.hasFilter ? req.observation.filter : nil,
            pid: pid,
        )

        // Create metadata
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.Observation"
            $0.value = try observation.serializedData()
        }

        // Create LRO
        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Start observation in background
        Task { [operationStore] in
            do {
                // Start the observation
                try await ObservationManager.shared.startObservation(name: observationName)

                // Get updated observation
                guard
                    let startedObservation = await ObservationManager.shared.getObservation(
                        name: observationName)
                else {
                    throw RPCError(code: .internalError, message: "Failed to start observation")
                }

                // Mark operation as done with observation in response
                try await operationStore.finishOperation(name: opName, responseMessage: startedObservation)

            } catch {
                // Mark operation as failed
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }

    func getObservation(
        request: ServerRequest<Macosusesdk_V1_GetObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Observation> {
        let req = request.message
        Self.logger.info("getObservation called")

        // Get observation from ObservationManager
        guard let observation = await ObservationManager.shared.getObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func listObservations(
        request: ServerRequest<Macosusesdk_V1_ListObservationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListObservationsResponse> {
        let req = request.message
        Self.logger.info("listObservations called")

        // List observations for parent
        let allObservations = await ObservationManager.shared.listObservations(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedObservations = allObservations.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedObservations.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageObservations = Array(sortedObservations[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListObservationsResponse.with {
            $0.observations = pageObservations
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func cancelObservation(
        request: ServerRequest<Macosusesdk_V1_CancelObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Observation> {
        let req = request.message
        Self.logger.info("cancelObservation called")

        // Cancel observation in ObservationManager
        guard
            let observation = await ObservationManager.shared.cancelObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func streamObservations(
        request: ServerRequest<Macosusesdk_V1_StreamObservationsRequest>,
        context _: ServerContext,
    ) async throws -> StreamingServerResponse<Macosusesdk_V1_StreamObservationsResponse> {
        let req = request.message
        Self.logger.info("streamObservations called (streaming)")

        // Verify observation exists
        guard await ObservationManager.shared.getObservation(name: req.name) != nil else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        // Create event stream
        guard let eventStream = await ObservationManager.shared.createEventStream(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Failed to create event stream")
        }

        return StreamingServerResponse { writer async in
            // Stream events to client
            // NOTE: The for-await-in loop will suspend and yield control, allowing the gRPC
            // executor to handle this task cooperatively with others.
            for await event in eventStream {
                // Check if client disconnected
                if Task.isCancelled {
                    Self.logger.info("client disconnected from observation stream")
                    break
                }

                // Send event to client
                let response = Macosusesdk_V1_StreamObservationsResponse.with {
                    $0.event = event
                }

                do {
                    try await writer.write(response)
                } catch {
                    break
                }
            }

            // Return trailing metadata after stream completes
            return [:]
        }
    }
}
