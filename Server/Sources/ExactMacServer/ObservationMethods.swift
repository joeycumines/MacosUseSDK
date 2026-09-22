import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

extension ExactMacService {
    func createObservation(
        request: ServerRequest<Exactmac_V1_CreateObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("createObservation called (LRO)")

        guard req.hasObservation else {
            throw RPCErrorHelpers.validationError(
                message: "observation is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "observation",
            )
        }
        guard req.observation.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "observation.name must be omitted when creating an observation",
                reason: "INVALID_RESOURCE_NAME",
                field: "observation.name",
                value: req.observation.name,
            )
        }
        let requestedObservationID: String? = if req.observationID.isEmpty {
            nil
        } else {
            try ParsingHelpers.validateResourceID(
                req.observationID,
                field: "observation_id",
            )
        }

        // Reject unspecified and application-changes observation types.
        switch req.observation.type {
        case .unspecified:
            throw RPCErrorHelpers.validationError(
                message: "observation.type is required and must not be unspecified",
                reason: "REQUIRED_FIELD_MISSING",
                field: "observation.type",
            )
        case .applicationChanges:
            throw RPCError(
                code: .unimplemented,
                message: "OBSERVATION_TYPE_APPLICATION_CHANGES is not yet implemented; deferred to FUNC-012",
            )
        case .UNRECOGNIZED:
            throw RPCErrorHelpers.validationError(
                message: "observation.type is unrecognized; update the client to a supported value",
                reason: "INVALID_ARGUMENT",
                field: "observation.type",
            )
        default:
            break
        }

        var filter: Exactmac_V1_ObservationFilter?
        if req.observation.hasFilter {
            var validatedFilter = req.observation.filter
            validatedFilter.pollInterval = try RequestNumericValidation.optionalPollInterval(
                validatedFilter.pollInterval,
                default: 1,
                field: "observation.filter.poll_interval",
            )
            filter = validatedFilter
        }
        let pid = try await resolveApplicationPID(fromName: req.parent)

        // Generate observation ID
        let observationId =
            requestedObservationID ?? UUID().uuidString
        let observationName = "\(req.parent)/observations/\(observationId)"

        // Create operation for LRO
        let opName = "operations/\(UUID().uuidString)"

        // Prepare metadata without publishing manager state. The owned operation
        // registers this exact resource only after operation admission succeeds.
        let observation = ObservationManager.makeObservation(
            name: observationName,
            type: req.observation.type,
            filter: filter,
            activate: req.observation.activate,
        )

        // Create metadata
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/exactmac.v1.Observation"
            $0.value = try observation.serializedData()
        }

        // Atomically create the LRO with ownership of its producer task.
        let op = try await operationStore.createOperation(
            name: opName,
            metadata: metadata,
            execution: { [operationStore, observationManager] in
                var ownsObservation = false
                do {
                    try Task.checkCancellation()
                    try await observationManager.registerObservation(
                        observation,
                        parent: req.parent,
                        pid: pid,
                        activate: req.observation.activate,
                    )
                    ownsObservation = true

                    // Start the observation
                    try await observationManager.startObservation(name: observationName)
                    try Task.checkCancellation()

                    // Get updated observation
                    guard
                        let startedObservation = await observationManager.getObservation(
                            name: observationName,
                        )
                    else {
                        throw RPCError(code: .internalError, message: "Failed to start observation")
                    }

                    // Mark operation as done with observation in response
                    let publication = try await operationStore.finishOperation(
                        name: opName,
                        responseMessage: startedObservation,
                    )
                    await Self.reconcileObservationPublication(
                        publication,
                        observationName: observationName,
                        observationManager: observationManager,
                    )
                    ownsObservation = false

                } catch is CancellationError {
                    if ownsObservation {
                        _ = await observationManager.cancelObservation(name: observationName)
                    }
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.cancelled.rawValue),
                        message: "Observation creation cancelled",
                    )
                } catch {
                    if ownsObservation {
                        _ = await observationManager.cancelObservation(name: observationName)
                    }
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.internalError.rawValue),
                        message: "\(error)",
                    )
                }
            },
        )

        return ServerResponse(message: op)
    }

    static func reconcileObservationPublication(
        _ publication: OperationPublicationOutcome,
        observationName: String,
        observationManager: ObservationManager,
    ) async {
        switch publication {
        case .published, .discarded:
            return
        case .alreadyTerminal:
            _ = await observationManager.cancelObservation(name: observationName)
        }
    }

    func getObservation(
        request: ServerRequest<Exactmac_V1_GetObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Observation> {
        let req = request.message
        Self.logger.info("getObservation called")

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try await resolveApplicationChildResource(req.name, collection: "observations")

        // Get observation from ObservationManager
        guard let observation = await observationManager.getObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func listObservations(
        request: ServerRequest<Exactmac_V1_ListObservationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListObservationsResponse> {
        let req = request.message
        Self.logger.info("listObservations called")
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListObservations",
            parameters: [
                ("parent", req.parent),
                ("page_size", String(pageSize)),
            ],
        )
        let offset = try ParsingHelpers.pageOffset(
            token: req.pageToken,
            queryBinding: queryBinding,
        )
        _ = try await resolveApplicationPID(fromName: req.parent)

        // List observations for parent
        let allObservations = await observationManager.listObservations(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedObservations = allObservations.sorted { $0.name < $1.name }

        let totalCount = sortedObservations.count
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: pageSize,
            totalCount: totalCount,
        )
        let pageObservations = Array(sortedObservations[range])
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: totalCount,
            queryBinding: queryBinding,
        )

        let response = Exactmac_V1_ListObservationsResponse.with {
            $0.observations = pageObservations
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func cancelObservation(
        request: ServerRequest<Exactmac_V1_CancelObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Observation> {
        let req = request.message
        Self.logger.info("cancelObservation called")

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try await resolveApplicationChildResource(req.name, collection: "observations")

        // Cancel observation in ObservationManager
        guard
            let observation = await observationManager.cancelObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func streamObservations(
        request: ServerRequest<Exactmac_V1_StreamObservationsRequest>,
        context _: ServerContext,
    ) async throws -> StreamingServerResponse<Exactmac_V1_StreamObservationsResponse> {
        let req = request.message
        Self.logger.info("streamObservations called (streaming)")

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try await resolveApplicationChildResource(req.name, collection: "observations")

        // Verify observation exists
        guard await observationManager.getObservation(name: req.name) != nil else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        // Create event stream
        guard let eventStream = await observationManager.createEventStream(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Failed to create event stream")
        }

        return StreamingServerResponse { [observationManager] writer async throws -> Metadata in
            let producer = try await observationManager.createEventStreamProducer(
                id: eventStream.id,
                name: req.name,
            ) {
                for await event in eventStream.stream {
                    try Task.checkCancellation()
                    let response = Exactmac_V1_StreamObservationsResponse.with {
                        $0.event = event
                    }
                    try await writer.write(response)
                }
            }

            do {
                try await withTaskCancellationHandler {
                    try await withRPCCancellationHandler {
                        try await producer.value
                    } onCancelRPC: {
                        producer.cancel()
                    }
                } onCancel: {
                    producer.cancel()
                }
                await observationManager.releaseEventStream(id: eventStream.id, name: req.name)
                return [:]
            } catch {
                producer.cancel()
                _ = await producer.result
                await observationManager.releaseEventStream(id: eventStream.id, name: req.name)
                if error is CancellationError {
                    throw RPCError(code: .cancelled, message: "observation stream cancelled")
                }
                throw error
            }
        }
    }
}
