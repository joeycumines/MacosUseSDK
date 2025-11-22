import Foundation

/// Placeholder for TargetApplicationsService implementation
/// This will be replaced with actual gRPC provider once proto stubs are generated
public final class TargetApplicationsServiceProvider {
    private let stateStore: AppStateStore

    public init(stateStore: AppStateStore) {
        self.stateStore = stateStore
    }

    // TODO: Implement actual gRPC methods once proto stubs are generated
    // - getTargetApplication
    // - listTargetApplications
    // - deleteTargetApplication
    // - performAction
    // - watch (streaming)

    // Helper to parse PID from resource name
    func parsePID(fromName name: String) throws -> pid_t {
        guard name.starts(with: "targetApplications/") else {
            throw ServiceError.invalidResourceName(name)
        }
        guard let pid = pid_t(name.dropFirst("targetApplications/".count)) else {
            throw ServiceError.invalidPID(name)
        }
        return pid
    }
}

// MARK: - Errors

public enum ServiceError: Error, LocalizedError {
    case invalidResourceName(String)
    case invalidPID(String)
    case targetNotFound(pid_t)

    public var errorDescription: String? {
        switch self {
        case let .invalidResourceName(name):
            "Invalid resource name format: \(name)"
        case let .invalidPID(name):
            "Invalid PID in resource name: \(name)"
        case let .targetNotFound(pid):
            "Target application with PID \(pid) not found"
        }
    }
}
