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
    func createSession(
        request: ServerRequest<Macosusesdk_V1_CreateSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Session> {
        let req = request.message
        Self.logger.info("createSession called")

        // Extract session parameters from request
        let sessionId = req.sessionID.isEmpty ? nil : req.sessionID
        let displayName =
            req.session.displayName.isEmpty ? "Unnamed Session" : req.session.displayName
        let metadata = req.session.metadata

        // Create session in SessionManager
        let session = await SessionManager.shared.createSession(
            sessionId: sessionId,
            displayName: displayName,
            metadata: metadata,
        )

        return ServerResponse(message: session)
    }

    func getSession(
        request: ServerRequest<Macosusesdk_V1_GetSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Session> {
        let req = request.message
        Self.logger.info("getSession called")

        // Get session from SessionManager
        guard let session = await SessionManager.shared.getSession(name: req.name) else {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: session)
    }

    func listSessions(
        request: ServerRequest<Macosusesdk_V1_ListSessionsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListSessionsResponse> {
        let req = request.message
        Self.logger.info("listSessions called")

        // List sessions from SessionManager with pagination
        let pageSize = Int(req.pageSize)
        let pageToken = req.pageToken.isEmpty ? nil : req.pageToken

        let (sessions, nextToken) = await SessionManager.shared.listSessions(
            pageSize: pageSize,
            pageToken: pageToken,
        )

        let response = Macosusesdk_V1_ListSessionsResponse.with {
            $0.sessions = sessions
            $0.nextPageToken = nextToken ?? ""
        }
        return ServerResponse(message: response)
    }

    func deleteSession(
        request: ServerRequest<Macosusesdk_V1_DeleteSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        Self.logger.info("deleteSession called")

        // Delete session from SessionManager
        let deleted = await SessionManager.shared.deleteSession(name: req.name)

        if !deleted {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func beginTransaction(
        request: ServerRequest<Macosusesdk_V1_BeginTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_BeginTransactionResponse> {
        let req = request.message
        Self.logger.info("beginTransaction called")

        do {
            // Begin transaction in SessionManager
            let isolationLevel =
                req.isolationLevel == .unspecified ? .serializable : req.isolationLevel
            let timeout = req.timeout > 0 ? req.timeout : 300.0

            let (transactionId, session) = try await SessionManager.shared.beginTransaction(
                sessionName: req.session,
                isolationLevel: isolationLevel,
                timeout: timeout,
            )

            let response = Macosusesdk_V1_BeginTransactionResponse.with {
                $0.transactionID = transactionId
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
        request: ServerRequest<Macosusesdk_V1_CommitTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Transaction> {
        let req = request.message
        Self.logger.info("commitTransaction called")

        do {
            // Commit transaction in SessionManager
            let transaction = try await SessionManager.shared
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
        request: ServerRequest<Macosusesdk_V1_RollbackTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Transaction> {
        let req = request.message
        Self.logger.info("rollbackTransaction called")

        do {
            // Rollback transaction in SessionManager
            let transaction = try await SessionManager.shared
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
        request: ServerRequest<Macosusesdk_V1_GetSessionSnapshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_SessionSnapshot> {
        let req = request.message
        Self.logger.info("getSessionSnapshot called")

        // Get session snapshot from SessionManager
        guard let snapshot = await SessionManager.shared.getSessionSnapshot(sessionName: req.name)
        else {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: snapshot)
    }
}
