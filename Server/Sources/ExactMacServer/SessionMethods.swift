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
    func createSession(
        request: ServerRequest<Exactmac_V1_CreateSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Session> {
        let req = request.message
        Self.logger.info("createSession called")

        guard req.hasSession else {
            throw RPCErrorHelpers.validationError(
                message: "session is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "session",
            )
        }
        guard req.session.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "session.name must be omitted when creating a session",
                reason: "INVALID_RESOURCE_NAME",
                field: "session.name",
                value: req.session.name,
            )
        }

        // Extract session parameters from request
        let sessionId: String? = if req.sessionID.isEmpty {
            nil
        } else {
            try ParsingHelpers.validateResourceID(req.sessionID, field: "session_id")
        }
        let displayName =
            req.session.displayName.isEmpty ? "Unnamed Session" : req.session.displayName
        let metadata = req.session.metadata

        // Create session in SessionManager
        let session = try await sessionManager.createSession(
            sessionId: sessionId,
            displayName: displayName,
            metadata: metadata,
        )

        return ServerResponse(message: session)
    }

    func getSession(
        request: ServerRequest<Exactmac_V1_GetSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Session> {
        let req = request.message
        Self.logger.info("getSession called")

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try ParsingHelpers.parseSessionName(req.name)

        // Get session from SessionManager
        guard let session = await sessionManager.getSession(name: req.name) else {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: session)
    }

    func listSessions(
        request: ServerRequest<Exactmac_V1_ListSessionsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListSessionsResponse> {
        let req = request.message
        Self.logger.info("listSessions called")

        // List sessions from SessionManager with pagination
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize, default: 50)
        let skip = try RequestNumericValidation.skip(req.skip)
        let pageToken = req.pageToken.isEmpty ? nil : req.pageToken

        let (sessions, nextToken) = try await sessionManager.listSessions(
            pageSize: pageSize,
            pageToken: pageToken,
            skip: skip,
        )

        let response = Exactmac_V1_ListSessionsResponse.with {
            $0.sessions = sessions
            $0.nextPageToken = nextToken ?? ""
        }
        return ServerResponse(message: response)
    }

    func deleteSession(
        request: ServerRequest<Exactmac_V1_DeleteSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        Self.logger.info("deleteSession called")

        guard !req.force else {
            throw RPCError(code: .unimplemented, message: "force deletion is not supported")
        }

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try ParsingHelpers.parseSessionName(req.name)

        // Delete session from SessionManager
        let deleted = await sessionManager.deleteSession(name: req.name)

        if !deleted {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func beginTransaction(
        request: ServerRequest<Exactmac_V1_BeginTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_BeginTransactionResponse> {
        let req = request.message
        Self.logger.info("beginTransaction called")

        let timeout = try RequestNumericValidation.optionalTimeout(req.timeout, default: 300)
        guard req.timeout == 0 else {
            throw RPCError(code: .unimplemented, message: "transaction timeout is not supported")
        }
        // Validate session name is not empty
        guard !req.session.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "session is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "session",
            )
        }
        _ = try ParsingHelpers.parseSessionName(req.session)

        do {
            // Begin transaction in SessionManager
            let isolationLevel =
                req.isolationLevel == .unspecified ? .serializable : req.isolationLevel

            let (transactionId, revisionId, session) = try await sessionManager.beginTransaction(
                sessionName: req.session,
                isolationLevel: isolationLevel,
                timeout: timeout,
            )

            let response = Exactmac_V1_BeginTransactionResponse.with {
                $0.transactionID = transactionId
                $0.revisionID = revisionId
                $0.session = session
            }
            return ServerResponse(message: response)
        } catch let error as SessionError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to begin transaction: \(error)")
        }
    }

    func commitTransaction(
        request: ServerRequest<Exactmac_V1_CommitTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Transaction> {
        let req = request.message
        Self.logger.info("commitTransaction called")

        // Validate required fields are not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try ParsingHelpers.parseSessionName(req.name)
        guard !req.transactionID.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "transaction_id is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "transaction_id",
            )
        }

        do {
            // Commit transaction in SessionManager
            let transaction = try await sessionManager
                .commitTransaction(
                    sessionName: req.name,
                    transactionId: req.transactionID,
                )

            return ServerResponse(message: transaction)
        } catch let error as SessionError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to commit transaction: \(error)")
        }
    }

    func rollbackTransaction(
        request: ServerRequest<Exactmac_V1_RollbackTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Transaction> {
        let req = request.message
        Self.logger.info("rollbackTransaction called")

        // Validate required fields are not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try ParsingHelpers.parseSessionName(req.name)
        guard !req.transactionID.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "transaction_id is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "transaction_id",
            )
        }

        do {
            // Rollback transaction in SessionManager
            let transaction = try await sessionManager
                .rollbackTransaction(
                    sessionName: req.name,
                    transactionId: req.transactionID,
                    revisionId: req.revisionID,
                )

            return ServerResponse(message: transaction)
        } catch let error as SessionError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to rollback transaction: \(error)")
        }
    }

    func getSessionSnapshot(
        request: ServerRequest<Exactmac_V1_GetSessionSnapshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_SessionSnapshot> {
        let req = request.message
        Self.logger.info("getSessionSnapshot called")

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try ParsingHelpers.parseSessionName(req.name)

        // Get session snapshot from SessionManager
        guard let snapshot = await sessionManager.getSessionSnapshot(sessionName: req.name)
        else {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: snapshot)
    }
}
