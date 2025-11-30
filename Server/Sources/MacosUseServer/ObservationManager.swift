import ApplicationServices
import Foundation
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

private let logger = MacosUseSDK.sdkLogger(category: "ObservationManager")

/// Manages active observations and coordinates streaming of observation events.
actor ObservationManager {
    nonisolated(unsafe) static var shared: ObservationManager!
    private let windowRegistry: WindowRegistry
    private let system: SystemOperations
    private var observations: [String: ObservationState] = [:]
    private var eventStreams: [String: [UUID: AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation]] = [:]
    private var sequenceCounters: [String: Int64] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(windowRegistry: WindowRegistry, system: SystemOperations = ProductionSystemOperations.shared) {
        self.windowRegistry = windowRegistry
        self.system = system
    }

    func createObservation(
        name: String,
        type: Macosusesdk_V1_ObservationType,
        parent: String,
        filter: Macosusesdk_V1_ObservationFilter?,
        pid: pid_t,
    ) -> Macosusesdk_V1_Observation {
        let now = Date()
        let observation = Macosusesdk_V1_Observation.with {
            $0.name = name
            $0.type = type
            $0.state = .pending
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            if let filter {
                $0.filter = filter
            }
        }

        let state = ObservationState(observation: observation, parent: parent, pid: pid)
        observations[name] = state
        sequenceCounters[name] = 0
        eventStreams[name] = [:]
        return observation
    }

    func startObservation(name: String) async throws {
        guard var state = observations[name] else { throw ObservationError.notFound }
        state.observation.state = .active
        state.observation.startTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state

        let initialState = state
        let manager = self
        let task = Task.detached {
            await manager.monitorObservation(name: name, initialState: initialState)
        }
        tasks[name] = task
    }

    func getObservation(name: String) -> Macosusesdk_V1_Observation? {
        observations[name]?.observation
    }

    func listObservations(parent: String) -> [Macosusesdk_V1_Observation] {
        observations.values.filter { $0.parent == parent }.map(\.observation)
    }

    func getActiveObservationCount() -> Int {
        observations.values.count { $0.observation.state == .active }
    }

    func cancelObservation(name: String) async -> Macosusesdk_V1_Observation? {
        guard var state = observations[name] else { return nil }
        tasks[name]?.cancel()
        tasks.removeValue(forKey: name)
        state.observation.state = .cancelled
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state
        if let continuations = eventStreams[name] {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
        sequenceCounters.removeValue(forKey: name)
        return state.observation
    }

    func completeObservation(name: String) async {
        guard var state = observations[name] else { return }
        state.observation.state = .completed
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state
        tasks[name]?.cancel()
        tasks.removeValue(forKey: name)
        if let continuations = eventStreams[name] {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
    }

    func failObservation(name: String, error _: Error) async {
        guard var state = observations[name] else { return }
        state.observation.state = .failed
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state
        tasks[name]?.cancel()
        tasks.removeValue(forKey: name)
        if let continuations = eventStreams[name] {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
    }

    func createEventStream(name: String) -> AsyncStream<Macosusesdk_V1_ObservationEvent>? {
        guard observations[name] != nil else { return nil }
        let continuationID = UUID()
        return AsyncStream<Macosusesdk_V1_ObservationEvent>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            Task { await self.addStreamContinuation(id: continuationID, name: name, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeStreamContinuation(id: continuationID, name: name) }
            }
        }
    }

    private func addStreamContinuation(id: UUID, name: String, continuation: AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation) async {
        if eventStreams[name] != nil { eventStreams[name]?[id] = continuation } else { eventStreams[name] = [id: continuation] }
    }

    private func removeStreamContinuation(id: UUID, name: String) async {
        eventStreams[name]?.removeValue(forKey: id)
        if eventStreams[name]?.isEmpty == true { eventStreams.removeValue(forKey: name) }
    }

    private nonisolated func publishEvent(name: String, event: Macosusesdk_V1_ObservationEvent) {
        Task.detached {
            let continuations = await self.getCurrentContinuations(name: name)
            for continuation in continuations {
                continuation.yield(event)
            }
        }
    }

    private func getCurrentContinuations(name: String) -> [AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation] {
        guard let continuations = eventStreams[name] else { return [] }
        return Array(continuations.values)
    }

    private nonisolated func monitorObservation(name: String, initialState: ObservationState) async {
        let type = initialState.observation.type
        let filter = initialState.observation.filter
        let pid = initialState.pid
        let pollInterval = (filter.pollInterval > 0) ? filter.pollInterval : 1.0

        var previousElements: [Macosusesdk_Type_Element] = []
        var previousWindows: [AXWindowSnapshot] = []
        var sequence: Int64 = 0

        while !Task.isCancelled {
            await Task.yield()
            do {
                switch type {
                case .elementChanges, .treeChanges:
                    let traverseResult = try await AutomationCoordinator.shared.handleTraverse(pid: pid, visibleOnly: filter.visibleOnly)
                    let currentElements = traverseResult.elements
                    let changes = detectElementChanges(previous: previousElements, current: currentElements)
                    for change in changes {
                        let event = createObservationEvent(name: name, change: change, sequence: sequence)
                        sequence += 1
                        publishEvent(name: name, event: event)
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
                        publishEvent(name: name, event: event)
                    }
                    previousWindows = currentWithOrphans

                case .applicationChanges: break

                case .attributeChanges:
                    let traverseResult = try await AutomationCoordinator.shared.handleTraverse(pid: pid, visibleOnly: filter.visibleOnly)
                    let currentElements = traverseResult.elements
                    let changes = detectAttributeChanges(previous: previousElements, current: currentElements, watchedAttributes: filter.attributes)
                    for change in changes {
                        let event = createObservationEvent(name: name, change: change, sequence: sequence)
                        sequence += 1
                        publishEvent(name: name, event: event)
                    }
                    previousElements = currentElements

                case .unspecified, .UNRECOGNIZED: break
                }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch is CancellationError {
                // Task was cancelled - state already set to .cancelled by cancelObservation
                return
            } catch {
                await ObservationManager.shared.failObservation(name: name, error: error)
                return
            }
        }
    }

    // PERFORMANCE FIX: Batch-fetch window attributes in a single IPC call
    // This eliminates the sequential IPC overhead (4+ round-trips per window)
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

    // GUARANTEED CORRECTNESS FIX:
    // This function now exhaustively rescues windows that have temporarily dropped out of kAXWindows
    // but still exist in kAXChildren (orphaned), regardless of their minimized state.
    // It extracts REAL attributes from the AX element, preventing false DESTROYED events.
    //
    // BUG FIX (2025-11-30): The orphan rescue was ONLY checking cgWindows, but after a mutation
    // (MoveWindow, ResizeWindow, etc.) the window can be temporarily absent from BOTH kAXWindows
    // AND CGWindowList (due to cache invalidation + CGWindowList staleness). Now we ALSO check
    // previousWindows directly to rescue windows that were being tracked but dropped from all sources.
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
            if axData.axBounds.width < 10 || axData.axBounds.height < 10 { continue }

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

    private nonisolated func detectElementChanges(previous: [Macosusesdk_Type_Element], current: [Macosusesdk_Type_Element]) -> [ElementChange] {
        var changes: [ElementChange] = []
        let previousMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.path, $0) })

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

    private nonisolated func detectAttributeChanges(previous: [Macosusesdk_Type_Element], current: [Macosusesdk_Type_Element], watchedAttributes: [String]) -> [ElementChange] {
        var changes: [ElementChange] = []
        let previousMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
        for element in current {
            if let prevElement = previousMap[element.path] {
                let attributeChanges = findAttributeChanges(old: prevElement, new: element, watched: watchedAttributes)
                if !attributeChanges.isEmpty { changes.append(.modified(old: prevElement, new: element)) }
            }
        }
        return changes
    }

    private nonisolated func findAttributeChanges(old: Macosusesdk_Type_Element, new: Macosusesdk_Type_Element, watched: [String]) -> [Macosusesdk_V1_AttributeChange] {
        var attributeChanges: [Macosusesdk_V1_AttributeChange] = []
        let attributesToCheck = watched.isEmpty ? Array(old.attributes.keys) + Array(new.attributes.keys) : watched
        for attr in Set(attributesToCheck) {
            let oldValue = old.attributes[attr] ?? ""
            let newValue = new.attributes[attr] ?? ""
            if oldValue != newValue {
                attributeChanges.append(Macosusesdk_V1_AttributeChange.with { $0.attribute = attr; $0.oldValue = oldValue; $0.newValue = newValue })
            }
        }
        if old.text != new.text { attributeChanges.append(Macosusesdk_V1_AttributeChange.with { $0.attribute = "text"; $0.oldValue = old.text; $0.newValue = new.text }) }
        if old.enabled != new.enabled { attributeChanges.append(Macosusesdk_V1_AttributeChange.with { $0.attribute = "enabled"; $0.oldValue = "\(old.enabled)"; $0.newValue = "\(new.enabled)" }) }
        if old.focused != new.focused { attributeChanges.append(Macosusesdk_V1_AttributeChange.with { $0.attribute = "focused"; $0.oldValue = "\(old.focused)"; $0.newValue = "\(new.focused)" }) }
        return attributeChanges
    }

    private nonisolated func elementsEqual(_ a: Macosusesdk_Type_Element, _ b: Macosusesdk_Type_Element) -> Bool {
        a.role == b.role && a.text == b.text && a.enabled == b.enabled && a.focused == b.focused && a.attributes == b.attributes
    }

    private nonisolated func createObservationEvent(name: String, change: ElementChange, sequence: Int64) -> Macosusesdk_V1_ObservationEvent {
        Macosusesdk_V1_ObservationEvent.with {
            $0.observation = name
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = sequence
            switch change {
            case let .added(element): $0.eventType = .elementAdded(Macosusesdk_V1_ElementEvent.with { $0.element = element })
            case let .removed(element): $0.eventType = .elementRemoved(Macosusesdk_V1_ElementEvent.with { $0.element = element })
            case let .modified(old, new):
                let attributeChanges = findAttributeChanges(old: old, new: new, watched: [])
                $0.eventType = .elementModified(Macosusesdk_V1_ElementModified.with { $0.oldElement = old; $0.newElement = new; $0.changes = attributeChanges })
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
                if window.bounds.origin != prevWindow.bounds.origin { changes.append(.moved(old: prevWindow, new: window)) }
                if window.bounds.size != prevWindow.bounds.size { changes.append(.resized(old: prevWindow, new: window)) }
                if window.minimized != prevWindow.minimized {
                    if window.minimized { changes.append(.minimized(window)) } else { changes.append(.restored(window)) }
                }
                // Detect visibility changes (hidden/shown via Cmd+H or kAXHiddenAttribute)
                // Note: visibility is calculated as !minimized && !hidden
                // We only emit hidden/shown events if the visibility changed but minimization didn't
                // This guard ensures Cmd+H (ax hidden) produces hidden/shown, while Cmd+M (minimize)
                // produces minimized/restored only — avoiding duplicate/ambiguous events.
                if window.visible != prevWindow.visible, window.minimized == prevWindow.minimized {
                    if window.visible { changes.append(.shown(window)) } else { changes.append(.hidden(window)) }
                }
            }
        }
        return changes
    }

    private nonisolated func createWindowObservationEvent(name: String, change: WindowChange, sequence: Int64) -> Macosusesdk_V1_ObservationEvent {
        Macosusesdk_V1_ObservationEvent.with {
            $0.observation = name
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = sequence
            switch change {
            case let .created(window): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .created; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .destroyed(window): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .destroyed; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .moved(_, new): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .moved; $0.windowID = "\(new.windowID)"; $0.title = new.title })
            case let .resized(_, new): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .resized; $0.windowID = "\(new.windowID)"; $0.title = new.title })
            case let .minimized(window): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .minimized; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .restored(window): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .restored; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .hidden(window): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .hidden; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            case let .shown(window): $0.eventType = .windowEvent(Macosusesdk_V1_WindowEvent.with { $0.eventType = .shown; $0.windowID = "\(window.windowID)"; $0.title = window.title })
            }
        }
    }
}

private struct ObservationState {
    var observation: Macosusesdk_V1_Observation
    let parent: String
    let pid: pid_t
}

private enum ElementChange {
    case added(Macosusesdk_Type_Element)
    case removed(Macosusesdk_Type_Element)
    case modified(old: Macosusesdk_Type_Element, new: Macosusesdk_Type_Element)
}

struct AXWindowSnapshot: Hashable {
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let minimized: Bool
    let visible: Bool
    let focused: Bool?

    func hash(into hasher: inout Hasher) { hasher.combine(windowID) }
    static func == (lhs: AXWindowSnapshot, rhs: AXWindowSnapshot) -> Bool { lhs.windowID == rhs.windowID }
}

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

enum ObservationError: Error {
    case notFound
    case alreadyStarted
    case invalidState
}
