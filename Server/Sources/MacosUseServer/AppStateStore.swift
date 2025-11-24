import Foundation
import MacosUseProto

/// Thread-safe state container using copy-on-write semantics.
/// This is the immutable "view" of the server state that can be safely shared.
public struct ServerState: Sendable {
    /// Map of PID to Application proto message
    public var applications: [pid_t: Macosusesdk_V1_Application] = [:]
    /// Map of input name to Input proto message
    public var inputs: [String: Macosusesdk_V1_Input] = [:]
}

/// Temporary struct to represent target application info
/// Will be replaced with generated proto message
public typealias TargetApplicationInfo = Macosusesdk_V1_Application

/// Thread-safe actor for managing the server's state.
/// All state mutations go through this actor, ensuring serial access.
public actor AppStateStore {
    private var state = ServerState()

    public init() {}

    /// Adds or updates a target application in the state
    public func addTarget(_ target: Macosusesdk_V1_Application) {
        state.applications[target.pid] = target
    }

    /// Removes a target application from the state
    /// - Returns: The removed target, if it existed
    public func removeTarget(pid: pid_t) -> Macosusesdk_V1_Application? {
        state.applications.removeValue(forKey: pid)
    }

    /// Gets a specific target application by PID
    public func getTarget(pid: pid_t) -> Macosusesdk_V1_Application? {
        state.applications[pid]
    }

    /// Lists all tracked target applications
    public func listTargets() -> [Macosusesdk_V1_Application] {
        Array(state.applications.values)
    }

    /// Returns a snapshot of the current state
    public func currentState() -> ServerState {
        state
    }

    /// Adds an input to the state
    public func addInput(_ input: Macosusesdk_V1_Input) {
        state.inputs[input.name] = input
    }

    /// Gets an input by name
    public func getInput(name: String) -> Macosusesdk_V1_Input? {
        state.inputs[name]
    }

    /// Lists inputs for a parent
    public func listInputs(parent: String) -> [Macosusesdk_V1_Input] {
        if parent.isEmpty {
            // Desktop inputs
            state.inputs.values.filter { $0.name.hasPrefix("desktopInputs/") }
        } else {
            // Application inputs
            state.inputs.values.filter { $0.name.hasPrefix("\(parent)/inputs/") }
        }
    }
}
