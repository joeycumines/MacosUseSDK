import Foundation
import MacosUseSDK
import MacosUseSDKProtos
import OSLog
import SwiftProtobuf

private let logger = MacosUseSDK.sdkLogger(category: "SessionManager")

/// Thread-safe session and transaction manager for the MacosUseSDK gRPC server.
/// Manages session lifecycle, transaction state, operation history, and resource tracking.
actor SessionManager {
    /// Shared singleton instance
    static let shared = SessionManager()

    /// Active sessions keyed by session name
    private var sessions: [String: SessionState] = [:]

    /// Default session timeout in seconds
    private let defaultSessionTimeout: TimeInterval = 3600 // 1 hour

    /// Session state wrapper containing session proto and associated metadata
    private struct SessionState {
        var session: Macosusesdk_V1_Session
        var activeTransaction: TransactionState?
        var operations: [Macosusesdk_V1_OperationRecord]
        var applications: [String] // Application resource names
        var observations: [String] // Observation resource names
        var snapshots: [SessionSnapshotState] // State snapshots for rollback
    }

    /// Transaction state wrapper
    private struct TransactionState {
        var transaction: Macosusesdk_V1_Transaction
        var operationStartIndex: Int // Index in operations array where transaction started
    }

    /// Session snapshot for rollback
    private struct SessionSnapshotState {
        var revisionId: String
        var timestamp: Date
        var operationIndex: Int
    }

    private init() {
        // Start background cleanup task
        Task {
            await startCleanupTask()
        }
    }

    /// Create a new session
    func createSession(
        sessionId: String?,
        displayName: String,
        metadata: [String: String],
    ) async -> Macosusesdk_V1_Session {
        let id = sessionId ?? UUID().uuidString
        let name = "sessions/\(id)"

        let now = Date()
        let expireTime = now.addingTimeInterval(defaultSessionTimeout)

        let session = Macosusesdk_V1_Session.with {
            $0.name = name
            $0.displayName = displayName
            $0.state = .active
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            $0.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            $0.expireTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: expireTime)
            $0.metadata = metadata
        }

        let state = SessionState(
            session: session,
            activeTransaction: nil,
            operations: [],
            applications: [],
            observations: [],
            snapshots: [],
        )

        sessions[name] = state
        return session
    }

    /// Get a session by name
    func getSession(name: String) async -> Macosusesdk_V1_Session? {
        guard var state = sessions[name] else {
            return nil
        }

        // Update last access time
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        sessions[name] = state

        return state.session
    }

    /// List all sessions with pagination
    func listSessions(pageSize: Int, pageToken: String?) async -> (
        sessions: [Macosusesdk_V1_Session], nextPageToken: String?,
    ) {
        let allSessions = sessions.values.map(\.session).sorted { $0.name < $1.name }

        // Simple pagination: page token is the last session name
        let startIndex: Int = if let token = pageToken, !token.isEmpty {
            allSessions.firstIndex(where: { $0.name > token }) ?? allSessions.count
        } else {
            0
        }

        let effectivePageSize = pageSize > 0 ? pageSize : 50
        let endIndex = min(startIndex + effectivePageSize, allSessions.count)

        let pageSessions = Array(allSessions[startIndex ..< endIndex])
        let nextToken = endIndex < allSessions.count ? pageSessions.last?.name : nil

        return (pageSessions, nextToken)
    }

    /// Delete a session
    func deleteSession(name: String) async -> Bool {
        guard sessions[name] != nil else {
            return false
        }

        sessions.removeValue(forKey: name)
        return true
    }

    /// Begin a transaction for a session
    func beginTransaction(
        sessionName: String,
        isolationLevel: Macosusesdk_V1_BeginTransactionRequest.IsolationLevel,
        timeout _: TimeInterval,
    ) async throws -> (transactionId: String, session: Macosusesdk_V1_Session) {
        guard var state = sessions[sessionName] else {
            throw SessionError.sessionNotFound
        }

        // Check if session is already in a transaction
        if state.activeTransaction != nil {
            throw SessionError.transactionAlreadyActive
        }

        // Check session state
        if state.session.state != .active {
            throw SessionError.invalidSessionState
        }

        let transactionId = UUID().uuidString
        let now = Date()

        let transaction = Macosusesdk_V1_Transaction.with {
            $0.transactionID = transactionId
            $0.session = sessionName
            $0.state = .active
            $0.startTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            $0.operationsCount = 0
        }

        // Create snapshot for rollback (if SERIALIZABLE isolation)
        if isolationLevel == .serializable {
            let snapshotId = "snapshot-\(transactionId)"
            let snapshot = SessionSnapshotState(
                revisionId: snapshotId,
                timestamp: now,
                operationIndex: state.operations.count,
            )
            state.snapshots.append(snapshot)
        }

        state.activeTransaction = TransactionState(
            transaction: transaction,
            operationStartIndex: state.operations.count,
        )

        // Update session state
        state.session.state = .inTransaction
        state.session.transactionID = transactionId
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)

        sessions[sessionName] = state
        return (transactionId, state.session)
    }

    /// Commit a transaction
    func commitTransaction(sessionName: String, transactionId: String) async throws -> Macosusesdk_V1_Transaction {
        guard var state = sessions[sessionName] else {
            throw SessionError.sessionNotFound
        }

        guard let transactionState = state.activeTransaction else {
            throw SessionError.noActiveTransaction
        }

        if transactionState.transaction.transactionID != transactionId {
            throw SessionError.transactionMismatch
        }

        // Count operations in transaction
        let operationsCount =
            Int32(state.operations.count - transactionState.operationStartIndex)

        // Update session state
        state.activeTransaction = nil
        state.session.state = .active
        state.session.transactionID = ""
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())

        sessions[sessionName] = state

        // Update transaction state with updated_session
        var committedTransaction = transactionState.transaction
        committedTransaction.state = .committed
        committedTransaction.operationsCount = operationsCount
        committedTransaction.updatedSession = state.session

        return committedTransaction
    }

    /// Rollback a transaction to a specific revision
    func rollbackTransaction(
        sessionName: String,
        transactionId: String,
        revisionId: String,
    ) async throws -> Macosusesdk_V1_Transaction {
        guard var state = sessions[sessionName] else {
            throw SessionError.sessionNotFound
        }

        guard let transactionState = state.activeTransaction else {
            throw SessionError.noActiveTransaction
        }

        if transactionState.transaction.transactionID != transactionId {
            throw SessionError.transactionMismatch
        }

        // Find snapshot by revision ID
        guard
            let snapshot = state.snapshots.first(where: { $0.revisionId == revisionId })
        else {
            throw SessionError.revisionNotFound
        }

        // Rollback operations to snapshot point
        let rolledBackCount = state.operations.count - snapshot.operationIndex
        state.operations = Array(state.operations.prefix(snapshot.operationIndex))

        // Update session state
        state.activeTransaction = nil
        state.session.state = .active
        state.session.transactionID = ""
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())

        sessions[sessionName] = state

        // Update transaction state with updated_session
        var rolledBackTransaction = transactionState.transaction
        rolledBackTransaction.state = .rolledBack
        rolledBackTransaction.operationsCount = Int32(rolledBackCount)
        rolledBackTransaction.updatedSession = state.session

        return rolledBackTransaction
    }

    /// Record an operation in session history
    func recordOperation(
        sessionName: String,
        operationType: String,
        resource: String,
        success: Bool,
        error: String?,
    ) async {
        guard var state = sessions[sessionName] else {
            return
        }

        let operation = Macosusesdk_V1_OperationRecord.with {
            $0.operationTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.operationType = operationType
            $0.resource = resource
            $0.success = success
            if let error {
                $0.error = error
            }
            if let transaction = state.activeTransaction {
                $0.transactionID = transaction.transaction.transactionID
            }
        }

        state.operations.append(operation)
        sessions[sessionName] = state
    }

    /// Add an application to session context
    func addApplication(sessionName: String, applicationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        if !state.applications.contains(applicationName) {
            state.applications.append(applicationName)
            sessions[sessionName] = state
        }
    }

    /// Remove an application from session context
    func removeApplication(sessionName: String, applicationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        state.applications.removeAll { $0 == applicationName }
        sessions[sessionName] = state
    }

    /// Add an observation to session context
    func addObservation(sessionName: String, observationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        if !state.observations.contains(observationName) {
            state.observations.append(observationName)
            sessions[sessionName] = state
        }
    }

    /// Remove an observation from session context
    func removeObservation(sessionName: String, observationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        state.observations.removeAll { $0 == observationName }
        sessions[sessionName] = state
    }

    /// Get a snapshot of session state
    func getSessionSnapshot(sessionName: String) async -> Macosusesdk_V1_SessionSnapshot? {
        guard let state = sessions[sessionName] else {
            return nil
        }

        return Macosusesdk_V1_SessionSnapshot.with {
            $0.session = state.session
            $0.applications = state.applications
            $0.observations = state.observations
            $0.history = state.operations
        }
    }

    /// Background task to clean up expired sessions
    private func startCleanupTask() async {
        while true {
            // Sleep for 1 minute
            try? await Task.sleep(nanoseconds: 60_000_000_000)

            let now = Date()

            // Find expired sessions
            let expiredSessions = sessions.filter { _, state in
                let expireTime = state.session.expireTime.date
                return expireTime < now
            }

            // Remove expired sessions
            for (name, _) in expiredSessions {
                var state = sessions[name]!
                state.session.state = .expired
                sessions[name] = state

                // Remove after marking as expired
                sessions.removeValue(forKey: name)
                logger.info("Cleaned up expired session: \(name, privacy: .public)")
            }
        }
    }
}

enum SessionError: Error, CustomStringConvertible {
    case sessionNotFound
    case transactionAlreadyActive
    case noActiveTransaction
    case transactionMismatch
    case invalidSessionState
    case revisionNotFound

    var description: String {
        switch self {
        case .sessionNotFound:
            "Session not found"
        case .transactionAlreadyActive:
            "Transaction already active for this session"
        case .noActiveTransaction:
            "No active transaction for this session"
        case .transactionMismatch:
            "Transaction ID does not match active transaction"
        case .invalidSessionState:
            "Session is not in a valid state for this operation"
        case .revisionNotFound:
            "Revision ID not found"
        }
    }
}
