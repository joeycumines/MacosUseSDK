import CryptoKit
import Foundation
import MacosUseProto
import SwiftProtobuf

/// Thread-safe state container using copy-on-write semantics.
/// This is the immutable "view" of the server state that can be safely shared.
public struct ServerState: Sendable {
    /// Map of PID to Application proto message
    public var applications: [pid_t: Macosusesdk_V1_Application] = [:]
    /// Map of input name to Input proto message
    public var inputs: [String: Macosusesdk_V1_Input] = [:]
}

/// Thread-safe actor for managing the server's state.
/// All state mutations go through this actor, ensuring serial access.
public actor AppStateStore {
    struct ApplicationProcessGenerationLease: Equatable, Sendable {
        let name: String
        let pid: pid_t
        let identity: ApplicationProcessIdentity
    }

    struct InputIdentityLease: Equatable, Sendable {
        let name: String
        let ownerID: UUID
    }

    enum InputIdentityReservationResult: Sendable {
        case reserved(InputIdentityLease)
        case duplicate
        case admissionClosed
    }

    enum InputTerminalOutcome: Sendable {
        case completed(Macosusesdk_V1_InputDeliveryResult)
        case failed(error: String, delivery: Macosusesdk_V1_InputDeliveryResult)
        case cancelled(error: String, delivery: Macosusesdk_V1_InputDeliveryResult)
    }

    enum InputFinishResult: Sendable {
        case finished(Macosusesdk_V1_Input)
        case leaseLost
        case missingPublishedState
        case alreadyTerminal(Macosusesdk_V1_Input)
    }

    private var state = ServerState()
    private var applicationProcessIdentitiesByName: [String: ApplicationProcessIdentity] = [:]
    private var applicationNamesByPID: [pid_t: String] = [:]
    private var applicationPIDsByName: [String: pid_t] = [:]
    private var acceptingInputs = true
    private var inputStateHistories: [String: [Macosusesdk_V1_Input.State]] = [:]
    private var inputIdentityNames: Set<String> = []
    private var inputIdentityOwnerIDs: [String: UUID] = [:]

    public init() {}

    /// Adds or updates a target application in the state
    public func addTarget(
        _ target: Macosusesdk_V1_Application,
        processIdentity: ApplicationProcessIdentity? = nil,
    ) {
        if let previousName = applicationNamesByPID[target.pid], previousName != target.name {
            applicationProcessIdentitiesByName.removeValue(forKey: previousName)
            applicationPIDsByName.removeValue(forKey: previousName)
        }
        state.applications[target.pid] = target
        applicationNamesByPID[target.pid] = target.name
        applicationPIDsByName[target.name] = target.pid
        if let processIdentity {
            applicationProcessIdentitiesByName[target.name] = processIdentity
        } else {
            applicationProcessIdentitiesByName.removeValue(forKey: target.name)
        }
    }

    /// Atomically replaces the running-application view with one exact
    /// identity-bound snapshot.
    public func replaceTargets(
        _ targets: [(application: Macosusesdk_V1_Application, identity: ApplicationProcessIdentity)],
    ) {
        state.applications = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.application.pid, $0.application) },
        )
        applicationNamesByPID = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.application.pid, $0.application.name) },
        )
        applicationPIDsByName = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.application.name, $0.application.pid) },
        )
        applicationProcessIdentitiesByName = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.application.name, $0.identity) },
        )
    }

    /// Reconciles a fallible discovery snapshot without discarding an exact
    /// process instance that this store already owns and the kernel still
    /// proves live. The merge occurs inside the actor so an application added
    /// concurrently with discovery cannot be lost between snapshot and
    /// replacement. A discovered PID always wins, allowing PID reuse to replace
    /// the stale identity rather than retaining it.
    public func reconcileTargets(
        _ discoveredTargets: [(application: Macosusesdk_V1_Application, identity: ApplicationProcessIdentity)],
        retainingExistingWhere shouldRetain: @Sendable (ApplicationProcessIdentity) -> Bool,
    ) {
        var reconciledTargets = discoveredTargets
        let discoveredPIDs = Set(discoveredTargets.map(\.application.pid))

        for (name, identity) in applicationProcessIdentitiesByName {
            guard !discoveredPIDs.contains(identity.pid),
                  shouldRetain(identity),
                  let pid = applicationPIDsByName[name],
                  let application = state.applications[pid],
                  application.name == name
            else {
                continue
            }
            reconciledTargets.append((application, identity))
        }

        replaceTargets(reconciledTargets)
    }

    /// Removes a target application from the state
    /// - Returns: The removed target, if it existed
    public func removeTarget(pid: pid_t) -> Macosusesdk_V1_Application? {
        if let name = applicationNamesByPID.removeValue(forKey: pid) {
            applicationProcessIdentitiesByName.removeValue(forKey: name)
            applicationPIDsByName.removeValue(forKey: name)
        }
        return state.applications.removeValue(forKey: pid)
    }

    /// Removes an exact application resource. A stale name never removes a
    /// replacement process that reused the same PID.
    public func removeTarget(name: String) -> Macosusesdk_V1_Application? {
        guard let pid = applicationPIDsByName[name],
              state.applications[pid]?.name == name
        else {
            return nil
        }
        return removeTarget(pid: pid)
    }

    public func getApplicationProcessIdentity(pid: pid_t) -> ApplicationProcessIdentity? {
        guard let name = applicationNamesByPID[pid] else { return nil }
        return applicationProcessIdentitiesByName[name]
    }

    public func getApplicationProcessIdentity(name: String) -> ApplicationProcessIdentity? {
        applicationProcessIdentitiesByName[name]
    }

    /// Returns one coherent process-generation view in a single actor turn.
    /// Every index and the public opaque name must identify the same kernel
    /// process generation; a torn or path-derived row is never leased.
    func applicationProcessGenerationLease(
        name: String,
    ) -> ApplicationProcessGenerationLease? {
        guard let pid = applicationPIDsByName[name],
              applicationNamesByPID[pid] == name,
              let application = state.applications[pid],
              application.name == name,
              application.pid == Int32(pid),
              let identity = applicationProcessIdentitiesByName[name],
              identity.pid == pid,
              applicationResourceName(for: identity) == name
        else {
            return nil
        }
        return ApplicationProcessGenerationLease(
            name: name,
            pid: pid,
            identity: identity,
        )
    }

    /// Gets a specific target application by PID
    public func getTarget(pid: pid_t) -> Macosusesdk_V1_Application? {
        state.applications[pid]
    }

    /// Gets only the exact current process instance named by the caller.
    public func getTarget(name: String) -> Macosusesdk_V1_Application? {
        guard let pid = applicationPIDsByName[name],
              state.applications[pid]?.name == name
        else {
            return nil
        }
        return state.applications[pid]
    }

    public func resolvePID(applicationName: String) -> pid_t? {
        guard let target = getTarget(name: applicationName) else { return nil }
        return target.pid
    }

    /// Lists all tracked target applications
    public func listTargets() -> [Macosusesdk_V1_Application] {
        Array(state.applications.values)
    }

    /// Returns a snapshot of the current state
    public func currentState() -> ServerState {
        state
    }

    /// Returns whether either an invisible reservation or a permanent public
    /// Input already owns this exact name.
    func containsInputIdentity(name: String) -> Bool {
        inputIdentityNames.contains(name)
    }

    /// Atomically reserves one immutable Input name without publishing a
    /// resource, history row, or timestamp. Duplicate identity wins over
    /// closed admission so clients never learn mutable server lifecycle state
    /// for an already-owned idempotency key.
    func reserveInputIdentity(
        name: String,
        ownerID: UUID,
    ) -> InputIdentityReservationResult {
        guard !containsInputIdentity(name: name) else {
            return .duplicate
        }
        guard acceptingInputs else {
            return .admissionClosed
        }
        inputIdentityNames.insert(name)
        inputIdentityOwnerIDs[name] = ownerID
        return .reserved(InputIdentityLease(name: name, ownerID: ownerID))
    }

    /// Publishes PENDING only after the exact hidden owner completed all
    /// pre-publication validation and dynamic admission. Immutable output
    /// fields are constructed here so callers cannot race or rewrite them.
    func publishPendingInput(
        lease: InputIdentityLease,
        action: Macosusesdk_V1_InputAction,
        target: Macosusesdk_V1_InputTarget,
    ) -> Macosusesdk_V1_Input? {
        guard inputIdentityOwnerIDs[lease.name] == lease.ownerID,
              state.inputs[lease.name] == nil
        else {
            return nil
        }
        let input = Macosusesdk_V1_Input.with {
            $0.name = lease.name
            $0.action = action
            $0.target = target
            $0.state = .pending
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        }
        state.inputs[lease.name] = input
        inputStateHistories[lease.name] = [.pending]
        return input
    }

    /// Releases only the exact still-hidden owner. Published identities are
    /// permanent and may leave ownership only through terminal settlement.
    @discardableResult
    func abandonInputIdentity(_ lease: InputIdentityLease) -> Bool {
        guard inputIdentityOwnerIDs[lease.name] == lease.ownerID,
              state.inputs[lease.name] == nil
        else {
            return false
        }
        inputIdentityOwnerIDs.removeValue(forKey: lease.name)
        inputIdentityNames.remove(lease.name)
        return true
    }

    func activeInputIdentityCount() -> Int {
        inputIdentityOwnerIDs.count
    }

    /// Test-only state seeding for read/list contract fixtures.
    func seedInputForTesting(_ input: Macosusesdk_V1_Input) {
        precondition(state.inputs[input.name] == nil)
        precondition(input.state == .completed || input.state == .failed || input.state == .cancelled)
        inputIdentityNames.insert(input.name)
        state.inputs[input.name] = input
        inputStateHistories[input.name] = [input.state]
    }

    /// Performs the only legal nonterminal transition after gate admission.
    func markInputExecuting(
        lease: InputIdentityLease,
    ) -> Macosusesdk_V1_Input? {
        guard inputIdentityOwnerIDs[lease.name] == lease.ownerID,
              var input = state.inputs[lease.name],
              input.state == .pending
        else {
            return nil
        }
        input.state = .executing
        state.inputs[lease.name] = input
        inputStateHistories[lease.name, default: []].append(.executing)
        return input
    }

    /// Atomically persists exactly one terminal outcome and releases its exact
    /// execution owner in the same actor turn. Malformed internal outcomes are
    /// downgraded to a conservative FAILED record rather than stranding a
    /// PENDING/EXECUTING identity.
    func finishInput(
        lease: InputIdentityLease,
        outcome: InputTerminalOutcome,
    ) -> InputFinishResult {
        guard inputIdentityOwnerIDs[lease.name] == lease.ownerID else {
            return .leaseLost
        }
        guard var input = state.inputs[lease.name] else {
            inputIdentityOwnerIDs.removeValue(forKey: lease.name)
            return .missingPublishedState
        }
        guard input.state == .pending || input.state == .executing else {
            inputIdentityOwnerIDs.removeValue(forKey: lease.name)
            return .alreadyTerminal(input)
        }

        let terminal = normalizedInputTerminalRecord(
            currentState: input.state,
            outcome: outcome,
        )
        input.state = terminal.state
        input.error = terminal.error
        input.deliveryResult = terminal.delivery
        input.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        state.inputs[lease.name] = input
        inputStateHistories[lease.name, default: []].append(terminal.state)
        inputIdentityOwnerIDs.removeValue(forKey: lease.name)
        return .finished(input)
    }

    private func normalizedInputTerminalRecord(
        currentState: Macosusesdk_V1_Input.State,
        outcome: InputTerminalOutcome,
    ) -> (
        state: Macosusesdk_V1_Input.State,
        error: String,
        delivery: Macosusesdk_V1_InputDeliveryResult,
    ) {
        switch outcome {
        case let .completed(delivery):
            guard currentState == .executing,
                  delivery.commitment == .committedAndSettled,
                  delivery.postedEventCount > 0,
                  delivery.routedDeliveryObserved
            else {
                return (
                    .failed,
                    "Input completion outcome violated the terminal contract",
                    normalizedInputFailureDelivery(delivery),
                )
            }
            return (.completed, "", delivery)
        case let .failed(error, delivery):
            return (
                .failed,
                error.isEmpty ? "Input execution failed" : error,
                normalizedInputFailureDelivery(delivery),
            )
        case let .cancelled(error, delivery):
            return (
                .cancelled,
                error.isEmpty ? "Input execution was cancelled" : error,
                normalizedInputFailureDelivery(delivery),
            )
        }
    }

    private func normalizedInputFailureDelivery(
        _ delivery: Macosusesdk_V1_InputDeliveryResult,
    ) -> Macosusesdk_V1_InputDeliveryResult {
        let hasPossibleEffect = delivery.postedEventCount != 0
            || delivery.routedDeliveryObserved
            || delivery.commitment == .possiblyCommitted
            || delivery.commitment == .committedAndSettled
        return Macosusesdk_V1_InputDeliveryResult.with {
            $0.commitment = hasPossibleEffect ? .possiblyCommitted : .noEffect
            $0.postedEventCount = max(
                delivery.routedDeliveryObserved ? 1 : 0,
                max(0, delivery.postedEventCount),
            )
            $0.routedDeliveryObserved = hasPossibleEffect
                && delivery.routedDeliveryObserved
        }
    }

    /// Closes reservation admission. Exact coordinator-owned tasks remain
    /// responsible for cancellation, cleanup, and terminal persistence.
    func beginInputDraining() {
        acceptingInputs = false
    }

    func inputStateHistory(name: String) -> [Macosusesdk_V1_Input.State] {
        inputStateHistories[name, default: []]
    }

    func inputStateHistoryCount() -> Int {
        inputStateHistories.count
    }

    func ownsInputExecution(_ lease: InputIdentityLease) -> Bool {
        inputIdentityOwnerIDs[lease.name] == lease.ownerID
    }

    /// Gets an input by name
    public func getInput(name: String) -> Macosusesdk_V1_Input? {
        state.inputs[name]
    }

    /// Lists inputs for a parent
    public func listInputs(parent: String) -> [Macosusesdk_V1_Input] {
        state.inputs.values.filter { input in
            guard let resource = try? ParsingHelpers.parseInputName(input.name) else {
                return false
            }
            switch resource.owner {
            case .desktop:
                return parent == "applications/-"
            case let .application(name):
                return parent == name
            }
        }
    }
}

/// Creates the opaque public name for one exact kernel process instance.
/// NUL-delimited fields are unambiguous because macOS paths and bundle IDs
/// cannot contain NUL bytes.
func applicationResourceName(for identity: ApplicationProcessIdentity) -> String {
    let payload = [
        "kernel-start-v1",
        String(identity.pid),
        String(identity.startTimeSeconds),
        String(identity.startTimeMicroseconds),
    ].joined(separator: "\0")
    let digest = SHA256.hash(data: Data(payload.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return "applications/\(digest)"
}
