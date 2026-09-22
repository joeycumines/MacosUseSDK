import ApplicationServices
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

private let logger = ExactMac.sdkLogger(category: "ObservationManager")

struct ObservationEventStreamLease: Sendable {
    let id: UUID
    let stream: AsyncStream<Exactmac_V1_ObservationEvent>
}

/// Manages active observations and coordinates streaming of observation events.
///
actor ObservationManager {
    private let windowRegistry: WindowRegistry
    private let system: SystemOperations
    private let monitorOperation: (@Sendable (String) async -> Void)?
    nonisolated let automationCoordinator: AutomationCoordinator
    private var observations: [String: ObservationState] = [:]
    private var eventStreams: [String: [UUID: AsyncStream<Exactmac_V1_ObservationEvent>.Continuation]] = [:]
    private var streamProducerTasks: [UUID: Task<Void, any Error>] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var acceptingObservations = true

    init(
        windowRegistry: WindowRegistry,
        system: SystemOperations = ProductionSystemOperations.shared,
        automationCoordinator: AutomationCoordinator? = nil,
        monitorOperation: (@Sendable (String) async -> Void)? = nil,
    ) {
        self.windowRegistry = windowRegistry
        self.system = system
        self.monitorOperation = monitorOperation
        self.automationCoordinator = automationCoordinator ?? AutomationCoordinator(
            activationSystem: system,
        )
    }

    func createObservation(
        name: String,
        type: Exactmac_V1_ObservationType,
        parent: String,
        filter: Exactmac_V1_ObservationFilter?,
        pid: pid_t,
        activate: Bool = false,
    ) throws -> Exactmac_V1_Observation {
        let observation = Self.makeObservation(
            name: name,
            type: type,
            filter: filter,
            activate: activate,
        )
        return try registerObservation(
            observation,
            parent: parent,
            pid: pid,
            activate: activate,
        )
    }

    nonisolated static func makeObservation(
        name: String,
        type: Exactmac_V1_ObservationType,
        filter: Exactmac_V1_ObservationFilter?,
        activate: Bool,
    ) -> Exactmac_V1_Observation {
        Exactmac_V1_Observation.with {
            $0.name = name
            $0.type = type
            $0.state = .pending
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.activate = activate
            if let filter {
                $0.filter = filter
            }
        }
    }

    @discardableResult
    func registerObservation(
        _ observation: Exactmac_V1_Observation,
        parent: String,
        pid: pid_t,
        activate: Bool,
    ) throws -> Exactmac_V1_Observation {
        guard acceptingObservations else {
            throw ObservationError.admissionClosed
        }
        guard observations[observation.name] == nil else {
            throw ObservationError.alreadyExists
        }
        guard observation.state == .pending,
              !observation.name.isEmpty,
              observation.hasCreateTime
        else {
            throw ObservationError.invalidState
        }
        if observation.hasFilter {
            _ = try RequestNumericValidation.optionalPollInterval(
                observation.filter.pollInterval,
                default: 1,
                field: "observation.filter.poll_interval",
            )
        }

        let state = ObservationState(observation: observation, parent: parent, pid: pid, activate: activate)
        observations[observation.name] = state
        eventStreams[observation.name] = [:]
        return observation
    }

    func startObservation(name: String) async throws {
        guard acceptingObservations else { throw ObservationError.admissionClosed }
        try Task.checkCancellation()
        guard var state = observations[name] else { throw ObservationError.notFound }
        switch state.observation.state {
        case .pending:
            break
        case .active:
            throw ObservationError.alreadyStarted
        case .completed, .cancelled, .failed, .unspecified, .UNRECOGNIZED:
            throw ObservationError.invalidState
        }
        guard tasks[name] == nil else { throw ObservationError.alreadyStarted }

        state.observation.state = .active
        state.observation.startTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state

        let initialState = state
        let monitorOperation = self.monitorOperation
        let task = Task { [weak self] in
            guard let self else { return }
            if let monitorOperation {
                await monitorOperation(name)
            } else {
                await monitorObservation(name: name, initialState: initialState)
            }
            await monitorDidExit(name: name)
        }
        tasks[name] = task
    }

    func getObservation(name: String) -> Exactmac_V1_Observation? {
        observations[name]?.observation
    }

    func listObservations(parent: String) -> [Exactmac_V1_Observation] {
        observations.values.filter { $0.parent == parent }.map(\.observation)
    }

    func getActiveObservationCount() -> Int {
        observations.values.count { $0.observation.state == .active }
    }

    func monitorTaskCount() -> Int {
        tasks.count
    }

    func streamContinuationCount(name: String) -> Int {
        eventStreams[name]?.count ?? 0
    }

    func streamProducerCount() -> Int {
        streamProducerTasks.count
    }

    func cancelObservation(name: String) async -> Exactmac_V1_Observation? {
        guard var state = observations[name] else { return nil }
        let task = tasks[name]
        let streamIDs = eventStreams[name].map { Array($0.keys) } ?? []
        let streamTasks = streamIDs.compactMap { streamProducerTasks[$0] }
        task?.cancel()
        for streamTask in streamTasks {
            streamTask.cancel()
        }
        if state.observation.state == .pending || state.observation.state == .active {
            state.observation.state = .cancelled
            state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            observations[name] = state
        }
        finishEventStreams(name: name)
        await task?.value
        for streamTask in streamTasks {
            _ = try? await streamTask.value
        }
        tasks.removeValue(forKey: name)
        for id in streamIDs {
            streamProducerTasks.removeValue(forKey: id)
        }
        return observations[name]?.observation
    }

    /// Cancels all active observations during graceful shutdown.
    ///
    /// This method:
    /// 1. Cancels all polling tasks
    /// 2. Finishes all event stream continuations
    /// 3. Marks all observations as cancelled
    /// 4. Clears all internal state
    ///
    /// - Returns: The number of observations that were cancelled.
    @discardableResult
    func cancelAllObservations() async -> Int {
        acceptingObservations = false
        let observationNames = Array(observations.keys)
        let monitorTasks = Array(tasks.values)
        let streamTasks = Array(streamProducerTasks.values)

        for task in monitorTasks {
            task.cancel()
        }
        for task in streamTasks {
            task.cancel()
        }

        for name in observationNames {
            if var state = observations[name] {
                if state.observation.state == .pending || state.observation.state == .active {
                    state.observation.state = .cancelled
                    state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
                    observations[name] = state
                }
            }
            finishEventStreams(name: name)
        }

        observations.removeAll()
        for task in monitorTasks {
            await task.value
        }
        for task in streamTasks {
            _ = try? await task.value
        }
        tasks.removeAll()
        streamProducerTasks.removeAll()

        logger.info("Cancelled \(observationNames.count, privacy: .public) observation(s) during shutdown")
        return observationNames.count
    }

    func completeObservation(name: String) async {
        await terminateObservation(name: name, terminalState: .completed)
    }

    func failObservation(name: String, error _: Error) async {
        await terminateObservation(name: name, terminalState: .failed)
    }

    private func terminateObservation(
        name: String,
        terminalState: Exactmac_V1_Observation.State,
    ) async {
        guard var state = observations[name] else { return }
        let task = tasks[name]
        task?.cancel()
        if state.observation.state == .pending || state.observation.state == .active {
            state.observation.state = terminalState
            state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            observations[name] = state
        }
        finishEventStreams(name: name)
        await task?.value
        tasks.removeValue(forKey: name)
    }

    func createEventStream(name: String) -> ObservationEventStreamLease? {
        guard let state = observations[name],
              state.observation.state == .pending || state.observation.state == .active,
              eventStreams[name] != nil
        else {
            return nil
        }

        let continuationID = UUID()
        let (stream, continuation) = AsyncStream<Exactmac_V1_ObservationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(100),
        )
        eventStreams[name]?[continuationID] = continuation
        return ObservationEventStreamLease(id: continuationID, stream: stream)
    }

    func createEventStreamProducer(
        id: UUID,
        name: String,
        operation: @escaping @Sendable () async throws -> Void,
    ) throws -> Task<Void, any Error> {
        guard acceptingObservations, eventStreams[name]?[id] != nil else {
            throw RPCError(code: .unavailable, message: "Observation stream admission is closed")
        }
        let task = Task { try await operation() }
        streamProducerTasks[id] = task
        return task
    }

    func releaseEventStream(id: UUID, name: String) {
        streamProducerTasks.removeValue(forKey: id)
        eventStreams[name]?.removeValue(forKey: id)?.finish()
    }

    private func publishEvent(name: String, event: Exactmac_V1_ObservationEvent) {
        guard let continuations = eventStreams[name] else { return }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func finishEventStreams(name: String) {
        if let continuations = eventStreams.removeValue(forKey: name) {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
    }

    private func monitorDidExit(name: String) {
        tasks.removeValue(forKey: name)
        guard var state = observations[name], state.observation.state == .active else { return }
        state.observation.state = .completed
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state
        finishEventStreams(name: name)
    }

    private func monitorDidFail(name: String) {
        tasks.removeValue(forKey: name)
        guard var state = observations[name], state.observation.state == .active else { return }
        state.observation.state = .failed
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state
        finishEventStreams(name: name)
    }

    private nonisolated func monitorObservation(name: String, initialState: ObservationState) async {
        let type = initialState.observation.type
        let filter = initialState.observation.filter
        let pid = initialState.pid
        let shouldActivate = initialState.activate
        let pollInterval = (filter.pollInterval > 0) ? filter.pollInterval : 1.0

        var previousElements: [Exactmac_V1_Element] = []
        var previousWindows: [AXWindowSnapshot] = []
        var sequence: Int64 = 0

        while !Task.isCancelled {
            await Task.yield()
            do {
                switch type {
                case .elementChanges, .treeChanges:
                    let traverseResult = try await automationCoordinator.handleTraverse(
                        pid: pid,
                        visibleOnly: filter.visibleOnly,
                        shouldActivate: shouldActivate,
                        applicationName: initialState.parent,
                    )
                    let currentElements = traverseResult.elements
                    let changes = detectElementChanges(previous: previousElements, current: currentElements)
                    for change in changes {
                        let event = createObservationEvent(name: name, change: change, sequence: sequence)
                        sequence += 1
                        await publishEvent(name: name, event: event)
                    }
                    previousElements = currentElements

                case .windowChanges:
                    logger.debug("[monitorObservation] Starting window poll cycle, previousWindows.count=\(previousWindows.count, privacy: .public)")
                    let currentWindows = try await fetchAXWindows(pid: pid)
                    logger.debug("[monitorObservation] Fetched \(currentWindows.count, privacy: .public) AX windows")

                    let cgWindows = try await windowRegistry.listWindows(forPID: pid)
                    let currentWithOrphans = try await handleOrphanedWindows(
                        axWindows: currentWindows,
                        cgWindows: cgWindows,
                        previousWindows: previousWindows,
                        pid: pid,
                    )

                    logger.debug("currentWindows=\(currentWindows.count, privacy: .public), cgWindows=\(cgWindows.count, privacy: .public), currentWithOrphans=\(currentWithOrphans.count, privacy: .public), previousWindows=\(previousWindows.count, privacy: .public)")

                    let windowChanges = detectWindowChanges(previous: previousWindows, current: currentWithOrphans)
                    logger.debug("[monitorObservation] Detected \(windowChanges.count, privacy: .public) window changes")

                    for change in windowChanges {
                        switch change {
                        case let .minimized(w): logger.debug("  MINIMIZED: window \(w.windowID, privacy: .public)")
                        case let .restored(w): logger.debug("  RESTORED: window \(w.windowID, privacy: .public)")
                        case let .hidden(w): logger.debug("  HIDDEN: window \(w.windowID, privacy: .public)")
                        case let .shown(w): logger.debug("  SHOWN: window \(w.windowID, privacy: .public)")
                        case let .created(w): logger.debug("  CREATED: window \(w.windowID, privacy: .public), bounds={{\(w.bounds.origin.x, privacy: .public),\(w.bounds.origin.y, privacy: .public)},{\(w.bounds.size.width, privacy: .public),\(w.bounds.size.height, privacy: .public)}}")
                        case let .destroyed(w): logger.debug("  DESTROYED: window \(w.windowID, privacy: .public)")
                        case let .moved(old, new): logger.debug("  MOVED: window \(new.windowID, privacy: .public), old={\(old.bounds.origin.x, privacy: .public),\(old.bounds.origin.y, privacy: .public)} new={\(new.bounds.origin.x, privacy: .public),\(new.bounds.origin.y, privacy: .public)}")
                        case let .resized(old, new): logger.debug("  RESIZED: window \(new.windowID, privacy: .public), old={\(old.bounds.size.width, privacy: .public),\(old.bounds.size.height, privacy: .public)} new={\(new.bounds.size.width, privacy: .public),\(new.bounds.size.height, privacy: .public)}")
                        }
                    }

                    for change in windowChanges {
                        let event = createWindowObservationEvent(name: name, change: change, sequence: sequence)
                        sequence += 1
                        await publishEvent(name: name, event: event)
                    }
                    previousWindows = currentWithOrphans

                case .applicationChanges: break

                case .attributeChanges:
                    let traverseResult = try await automationCoordinator.handleTraverse(
                        pid: pid,
                        visibleOnly: filter.visibleOnly,
                        shouldActivate: shouldActivate,
                        applicationName: initialState.parent,
                    )
                    let currentElements = traverseResult.elements
                    let changes = detectAttributeChanges(previous: previousElements, current: currentElements, watchedAttributes: filter.attributes)
                    for change in changes {
                        let event = createObservationEvent(name: name, change: change, sequence: sequence)
                        sequence += 1
                        await publishEvent(name: name, event: event)
                    }
                    previousElements = currentElements

                case .unspecified, .UNRECOGNIZED: break
                }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch is CancellationError {
                // Task was cancelled - state already set to .cancelled by cancelObservation
                return
            } catch {
                await monitorDidFail(name: name)
                return
            }
        }
    }

    /// PERFORMANCE FIX: Batch-fetch window attributes in a single IPC call
    /// This eliminates the sequential IPC overhead (4+ round-trips per window)
    private nonisolated func fetchWindowAttributes(_ element: AXUIElement) -> (title: String, minimized: Bool, hidden: Bool, focused: Bool?) {
        let attributes = [
            kAXTitleAttribute as String,
            kAXMinimizedAttribute as String,
            kAXHiddenAttribute as String,
            kAXMainAttribute as String,
        ]

        guard let values = system.copyAXMultipleAttributes(element: element as AnyObject, attributes: attributes) else {
            // Fallback to empty/default values on failure
            return ("", false, false, nil)
        }

        let title = values[kAXTitleAttribute as String] as? String ?? ""
        let minimized = values[kAXMinimizedAttribute as String] as? Bool ?? false
        let hidden = values[kAXHiddenAttribute as String] as? Bool ?? false
        let focused = values[kAXMainAttribute as String] as? Bool

        return (title, minimized, hidden, focused)
    }

    /// GUARANTEED CORRECTNESS FIX:
    /// This function now exhaustively rescues windows that have temporarily dropped out of kAXWindows
    /// but still exist in kAXChildren (orphaned), regardless of their minimized state.
    /// It extracts REAL attributes from the AX element, preventing false DESTROYED events.
    ///
    /// BUG FIX (2025-11-30): The orphan rescue was ONLY checking cgWindows, but after a mutation
    /// (MoveWindow, ResizeWindow, etc.) the window can be temporarily absent from BOTH kAXWindows
    /// AND CGWindowList (due to cache invalidation + CGWindowList staleness). Now we ALSO check
    /// previousWindows directly to rescue windows that were being tracked but dropped from all sources.
    private nonisolated func handleOrphanedWindows(
        axWindows: [AXWindowSnapshot],
        cgWindows: [WindowRegistry.WindowInfo],
        previousWindows: [AXWindowSnapshot],
        pid: pid_t,
    ) async throws -> [AXWindowSnapshot] {
        var result = axWindows
        let axWindowIDs = Set(axWindows.map(\.windowID))
        let cgWindowIDs = Set(cgWindows.map(\.windowID))
        let previousWindowMap = Dictionary(uniqueKeysWithValues: previousWindows.map { ($0.windowID, $0) })

        // Build list of window IDs we need to try to rescue:
        // 1. Windows in cgWindows but not in axWindows (and we were tracking them)
        // 2. Windows in previousWindows but not in axWindows AND not in cgWindows (dropped from both!)
        var orphanCandidateIDs = Set<CGWindowID>()
        for cgWin in cgWindows where !axWindowIDs.contains(cgWin.windowID) && previousWindowMap[cgWin.windowID] != nil {
            orphanCandidateIDs.insert(cgWin.windowID)
        }
        // CRITICAL FIX: Also check previous windows that dropped from BOTH sources
        for prevWin in previousWindows where !axWindowIDs.contains(prevWin.windowID) && !cgWindowIDs.contains(prevWin.windowID) {
            orphanCandidateIDs.insert(prevWin.windowID)
        }

        // If no orphans to rescue, return early
        guard !orphanCandidateIDs.isEmpty else { return result }

        // Fetch kAXChildren for orphan rescue
        guard let appElementAny = system.createAXApplication(pid: pid) else { return result }
        let appElement = unsafeDowncast(appElementAny, to: AXUIElement.self)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let axChildren = childrenValue as? [AXUIElement]
        else {
            return result
        }

        // Build a map of windowID -> AXUIElement from children for fast lookup
        var childWindowMap: [CGWindowID: AXUIElement] = [:]
        for child in axChildren {
            if let axWindowID = system.getAXWindowID(element: child as AnyObject) {
                childWindowMap[axWindowID] = child
            }
        }

        // Attempt to rescue each orphan candidate
        for windowID in orphanCandidateIDs {
            // FIRST try to find in kAXChildren by window ID (best source of truth)
            if let child = childWindowMap[windowID] {
                // FOUND IT! Now fetch its TRUE state using batched IPC.
                let attrs = fetchWindowAttributes(child)

                // Get bounds - Use AX truth, fallback to previous bounds if missing
                var posValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                var axBounds = previousWindowMap[windowID]?.bounds ?? .zero // Fallback to previous bounds

                if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posValue) == .success,
                   let posVal = posValue, CFGetTypeID(posVal) == AXValueGetTypeID()
                {
                    let posAx = unsafeDowncast(posVal, to: AXValue.self)
                    if AXValueGetType(posAx) == .cgPoint {
                        var p = CGPoint.zero
                        AXValueGetValue(posAx, .cgPoint, &p)
                        axBounds.origin = p
                    }
                }

                if AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success,
                   let sizeVal = sizeValue, CFGetTypeID(sizeVal) == AXValueGetTypeID()
                {
                    let sizeAx = unsafeDowncast(sizeVal, to: AXValue.self)
                    if AXValueGetType(sizeAx) == .cgSize {
                        var s = CGSize.zero
                        AXValueGetValue(sizeAx, .cgSize, &s)
                        axBounds.size = s
                    }
                }

                let rescuedWindow = AXWindowSnapshot(
                    windowID: windowID,
                    title: attrs.title,
                    bounds: axBounds,
                    minimized: attrs.minimized,
                    visible: !attrs.minimized && !attrs.hidden,
                    focused: attrs.focused,
                )
                result.append(rescuedWindow)
            } else if cgWindowIDs.contains(windowID), let prevSnapshot = previousWindowMap[windowID] {
                // FALLBACK: Window is still in CGWindowList but _AXUIElementGetWindow failed for all kAXChildren.
                // This can happen during MoveWindow when the window's AX element is temporarily in a weird state.
                // IMPORTANT: Only rescue if the CGWindow is still on-screen (isOnScreen: true). Otherwise,
                // the window may have been closed and CGWindowList is just lagging behind.
                if let cgWin = cgWindows.first(where: { $0.windowID == windowID }), cgWin.isOnScreen {
                    let rescuedWindow = AXWindowSnapshot(
                        windowID: windowID,
                        title: cgWin.title.isEmpty ? prevSnapshot.title : cgWin.title,
                        bounds: cgWin.bounds,
                        minimized: prevSnapshot.minimized,
                        visible: prevSnapshot.visible,
                        focused: prevSnapshot.focused,
                    )
                    result.append(rescuedWindow)
                }
                // If not on screen, don't rescue - window was likely closed
            }
            // If window not found anywhere, let it be destroyed normally
        }

        return result
    }

    private nonisolated func fetchAXWindows(pid: pid_t) async throws -> [AXWindowSnapshot] {
        try await windowRegistry.refreshWindows(forPID: pid)
        let allCGWindows = try await windowRegistry.listWindows(forPID: pid)
        let cgWindows = allCGWindows.filter { win in
            win.bounds.width >= 10 && win.bounds.height >= 10 && win.layer == 0
        }

        // CRITICAL: AX APIs are thread-safe and should NOT block MainActor
        // Perform AX operations in detached context to avoid blocking the main run loop
        guard let appElementAny = system.createAXApplication(pid: pid) else { return [] }
        let appElement = unsafeDowncast(appElementAny, to: AXUIElement.self)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement]
        else {
            return []
        }

        struct AXWindowData {
            let axIndex: Int
            let axElement: AXUIElement
            let axBounds: CGRect
            var cgWindowID: CGWindowID?
        }

        var axWindowsData: [AXWindowData] = []
        for (axIndex, axWindow) in axWindows.enumerated() {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue)
            _ = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue)

            var axBounds = CGRect.zero
            if let posValue, let sizeValue,
               CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
            {
                let posAx = unsafeDowncast(posValue, to: AXValue.self)
                let sizeAx = unsafeDowncast(sizeValue, to: AXValue.self)
                var p = CGPoint.zero
                var s = CGSize.zero
                if AXValueGetType(posAx) == .cgPoint, AXValueGetType(sizeAx) == .cgSize,
                   AXValueGetValue(posAx, .cgPoint, &p), AXValueGetValue(sizeAx, .cgSize, &s)
                {
                    axBounds = CGRect(origin: p, size: s)
                }
            }

            var cgWindowID: CGWindowID?
            if let cgID = system.getAXWindowID(element: axWindow as AnyObject) {
                cgWindowID = cgID
            }

            axWindowsData.append(AXWindowData(axIndex: axIndex, axElement: axWindow, axBounds: axBounds, cgWindowID: cgWindowID))
        }

        var usedAXIndices = Set<Int>()
        var usedCGWindowIDs = Set<CGWindowID>()
        var snapshots: [AXWindowSnapshot] = []

        // PHASE 1: STRICT MATCHING (Private API)
        // We trust the Private API 100% for liveness. If AX returns a valid ID, the window exists.
        for axData in axWindowsData {
            guard let cgID = axData.cgWindowID else { continue }

            // Optional: Simple size filter to reduce noise (1x1 keepalives)
            if axData.axBounds.width < 10 || axData.axBounds.height < 10 {
                continue
            }

            usedAXIndices.insert(axData.axIndex)
            usedCGWindowIDs.insert(cgID)

            let attrs = fetchWindowAttributes(axData.axElement)

            let snapshot = AXWindowSnapshot(
                windowID: cgID,
                title: attrs.title,
                bounds: axData.axBounds,
                minimized: attrs.minimized,
                visible: !attrs.minimized && !attrs.hidden,
                focused: attrs.focused,
            )
            snapshots.append(snapshot)
        }

        // PHASE 2: HEURISTIC MATCHING (Fallback)
        // For windows where Private API failed, we must match against the CG list.
        struct MatchCandidate {
            let axData: AXWindowData
            let cgWindow: WindowRegistry.WindowInfo
            let distance: CGFloat
        }
        var candidates: [MatchCandidate] = []

        for axData in axWindowsData {
            guard !usedAXIndices.contains(axData.axIndex) else { continue }

            // Only compare against CG windows we haven't already matched
            for cgWin in cgWindows where !usedCGWindowIDs.contains(cgWin.windowID) {
                let dist = abs(axData.axBounds.origin.x - cgWin.bounds.origin.x) +
                    abs(axData.axBounds.origin.y - cgWin.bounds.origin.y) +
                    abs(axData.axBounds.size.width - cgWin.bounds.size.width) +
                    abs(axData.axBounds.size.height - cgWin.bounds.size.height)
                candidates.append(MatchCandidate(axData: axData, cgWindow: cgWin, distance: dist))
            }
        }
        candidates.sort { $0.distance < $1.distance }

        for candidate in candidates {
            guard !usedAXIndices.contains(candidate.axData.axIndex), !usedCGWindowIDs.contains(candidate.cgWindow.windowID) else { continue }
            usedAXIndices.insert(candidate.axData.axIndex)
            usedCGWindowIDs.insert(candidate.cgWindow.windowID)

            let attrs = fetchWindowAttributes(candidate.axData.axElement)

            let snapshot = AXWindowSnapshot(
                windowID: candidate.cgWindow.windowID,
                title: attrs.title,
                bounds: candidate.axData.axBounds,
                minimized: attrs.minimized,
                visible: !attrs.minimized && !attrs.hidden,
                focused: attrs.focused,
            )
            snapshots.append(snapshot)
        }

        return snapshots
    }

    private nonisolated func detectElementChanges(previous: [Exactmac_V1_Element], current: [Exactmac_V1_Element]) -> [ElementChange] {
        var changes: [ElementChange] = []
        // Use uniquingKeysWith to handle any duplicate paths gracefully (keep first occurrence)
        let previousMap = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let currentMap = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        for element in current where previousMap[element.path] == nil {
            changes.append(.added(element))
        }
        for element in previous where currentMap[element.path] == nil {
            changes.append(.removed(element))
        }
        for element in current {
            if let prevElement = previousMap[element.path], !elementsEqual(prevElement, element) {
                changes.append(.modified(old: prevElement, new: element))
            }
        }
        return changes
    }

    private nonisolated func detectAttributeChanges(previous: [Exactmac_V1_Element], current: [Exactmac_V1_Element], watchedAttributes: [String]) -> [ElementChange] {
        var changes: [ElementChange] = []
        // Use uniquingKeysWith to handle any duplicate paths gracefully (keep first occurrence)
        let previousMap = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for element in current {
            if let prevElement = previousMap[element.path] {
                let attributeChanges = findAttributeChanges(old: prevElement, new: element, watched: watchedAttributes)
                if !attributeChanges.isEmpty {
                    changes.append(.modified(old: prevElement, new: element))
                }
            }
        }
        return changes
    }

    private nonisolated func findAttributeChanges(old: Exactmac_V1_Element, new: Exactmac_V1_Element, watched: [String]) -> [Exactmac_V1_AttributeChange] {
        var attributeChanges: [Exactmac_V1_AttributeChange] = []
        let attributesToCheck = watched.isEmpty ? Array(old.attributes.keys) + Array(new.attributes.keys) : watched
        for attr in Set(attributesToCheck) {
            let oldValue = old.attributes[attr] ?? ""
            let newValue = new.attributes[attr] ?? ""
            if oldValue != newValue {
                attributeChanges.append(Exactmac_V1_AttributeChange.with { $0.attribute = attr; $0.oldValue = oldValue; $0.newValue = newValue })
            }
        }
        if old.text != new.text {
            attributeChanges.append(Exactmac_V1_AttributeChange.with { $0.attribute = "text"; $0.oldValue = old.text; $0.newValue = new.text })
        }
        if old.enabled != new.enabled {
            attributeChanges.append(Exactmac_V1_AttributeChange.with { $0.attribute = "enabled"; $0.oldValue = "\(old.enabled)"; $0.newValue = "\(new.enabled)" })
        }
        if old.focused != new.focused {
            attributeChanges.append(Exactmac_V1_AttributeChange.with { $0.attribute = "focused"; $0.oldValue = "\(old.focused)"; $0.newValue = "\(new.focused)" })
        }
        return attributeChanges
    }

    private nonisolated func elementsEqual(_ a: Exactmac_V1_Element, _ b: Exactmac_V1_Element) -> Bool {
        a.role == b.role && a.text == b.text && a.enabled == b.enabled && a.focused == b.focused && a.attributes == b.attributes
    }

    private nonisolated func createObservationEvent(name: String, change: ElementChange, sequence: Int64) -> Exactmac_V1_ObservationEvent {
        Exactmac_V1_ObservationEvent.with {
            $0.observation = name
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = sequence
            switch change {
            case let .added(element): $0.eventType = .elementAdded(Exactmac_V1_ElementEvent.with { $0.element = element })
            case let .removed(element): $0.eventType = .elementRemoved(Exactmac_V1_ElementEvent.with { $0.element = element })
            case let .modified(old, new):
                let attributeChanges = findAttributeChanges(old: old, new: new, watched: [])
                $0.eventType = .elementModified(Exactmac_V1_ElementModified.with { $0.oldElement = old; $0.newElement = new; $0.changes = attributeChanges })
            }
        }
    }

    nonisolated func detectWindowChanges(previous: [AXWindowSnapshot], current: [AXWindowSnapshot]) -> [WindowChange] {
        logger.trace("[detectWindowChanges] previous.count=\(previous.count, privacy: .public), current.count=\(current.count, privacy: .public)")
        var changes: [WindowChange] = []
        let previousMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.windowID, $0) })
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        for window in current where previousMap[window.windowID] == nil {
            changes.append(.created(window))
        }
        for window in previous where currentMap[window.windowID] == nil {
            changes.append(.destroyed(window))
        }

        for window in current {
            if let prevWindow = previousMap[window.windowID] {
                if window.bounds.origin != prevWindow.bounds.origin {
                    changes.append(.moved(old: prevWindow, new: window))
                }
                if window.bounds.size != prevWindow.bounds.size {
                    changes.append(.resized(old: prevWindow, new: window))
                }
                if window.minimized != prevWindow.minimized {
                    if window.minimized {
                        changes.append(.minimized(window))
                    } else {
                        changes.append(.restored(window))
                    }
                }
                // Detect visibility changes (hidden/shown via Cmd+H or kAXHiddenAttribute)
                // Note: visibility is calculated as !minimized && !hidden
                // We only emit hidden/shown events if the visibility changed but minimization didn't
                // This guard ensures Cmd+H (ax hidden) produces hidden/shown, while Cmd+M (minimize)
                // produces minimized/restored only — avoiding duplicate/ambiguous events.
                if window.visible != prevWindow.visible, window.minimized == prevWindow.minimized {
                    if window.visible {
                        changes.append(.shown(window))
                    } else {
                        changes.append(.hidden(window))
                    }
                }
            }
        }
        return changes
    }

    private nonisolated func createWindowObservationEvent(name: String, change: WindowChange, sequence: Int64) -> Exactmac_V1_ObservationEvent {
        Exactmac_V1_ObservationEvent.with {
            $0.observation = name
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = sequence
            switch change {
            case let .created(window): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .created; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .destroyed(window): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .destroyed; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .moved(_, new): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .moved; $0.windowID = "\(new.windowID)"; $0.title = new.title })
            case let .resized(_, new): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .resized; $0.windowID = "\(new.windowID)"; $0.title = new.title })
            case let .minimized(window): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .minimized; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .restored(window): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .restored; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .hidden(window): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .hidden; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .shown(window): $0.eventType = .windowEvent(Exactmac_V1_WindowEvent.with { $0.eventType = .shown; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            }
        }
    }
}

private struct ObservationState {
    var observation: Exactmac_V1_Observation
    let parent: String
    let pid: pid_t
    let activate: Bool
}

private enum ElementChange {
    case added(Exactmac_V1_Element)
    case removed(Exactmac_V1_Element)
    case modified(old: Exactmac_V1_Element, new: Exactmac_V1_Element)
}

struct AXWindowSnapshot: Hashable {
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let minimized: Bool
    let visible: Bool
    let focused: Bool?

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: AXWindowSnapshot, rhs: AXWindowSnapshot) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

/// Describes a change detected in window state during observation polling.
enum WindowChange {
    case created(AXWindowSnapshot)
    case destroyed(AXWindowSnapshot)
    case moved(old: AXWindowSnapshot, new: AXWindowSnapshot)
    case resized(old: AXWindowSnapshot, new: AXWindowSnapshot)
    case minimized(AXWindowSnapshot)
    case restored(AXWindowSnapshot)
    case hidden(AXWindowSnapshot)
    case shown(AXWindowSnapshot)
}

/// Errors that can occur during observation lifecycle management.
enum ObservationError: Error, Equatable {
    case admissionClosed
    case alreadyExists
    case notFound
    case alreadyStarted
    case invalidState
}
