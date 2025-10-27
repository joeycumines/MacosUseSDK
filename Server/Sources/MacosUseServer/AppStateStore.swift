import Foundation

// MARK: - Server State

/// Thread-safe state container using copy-on-write semantics.
/// This is the immutable "view" of the server state that can be safely shared.
public struct ServerState: Sendable {
    /// Map of PID to TargetApplication proto message
    /// Note: The actual proto types will be used once generated
    public var targets: [pid_t: TargetApplicationInfo] = [:]
}

/// Temporary struct to represent target application info
/// Will be replaced with generated proto message
public struct TargetApplicationInfo: Sendable {
    public let name: String
    public let pid: pid_t
    public let appName: String
    
    public init(name: String, pid: pid_t, appName: String) {
        self.name = name
        self.pid = pid
        self.appName = appName
    }
}

// MARK: - State Store Actor

/// Thread-safe actor for managing the server's state.
/// All state mutations go through this actor, ensuring serial access.
public actor AppStateStore {
    private var state = ServerState()
    
    public init() {}
    
    /// Adds or updates a target application in the state
    public func addTarget(_ target: TargetApplicationInfo) {
        state.targets[target.pid] = target
    }
    
    /// Removes a target application from the state
    /// - Returns: The removed target, if it existed
    public func removeTarget(pid: pid_t) -> TargetApplicationInfo? {
        return state.targets.removeValue(forKey: pid)
    }
    
    /// Gets a specific target application by PID
    public func getTarget(pid: pid_t) -> TargetApplicationInfo? {
        return state.targets[pid]
    }
    
    /// Lists all tracked target applications
    public func listTargets() -> [TargetApplicationInfo] {
        return Array(state.targets.values)
    }
    
    /// Returns a snapshot of the current state
    public func currentState() -> ServerState {
        return state
    }
}
