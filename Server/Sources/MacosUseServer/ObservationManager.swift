import ApplicationServices
import Foundation
import MacosUseSDKProtos
import SwiftProtobuf

// MARK: - ObservationManager

/// Manages active observations and coordinates streaming of observation events.
///
/// This actor is thread-safe and maintains the state of all active observations.
/// It works with ChangeDetector to monitor UI changes and fan out events to subscribers.
actor ObservationManager {
    /// Shared singleton instance (initialized in main.swift with shared WindowRegistry)
    nonisolated(unsafe) static var shared: ObservationManager!

    /// Shared window registry for consistent window tracking
    private let windowRegistry: WindowRegistry

    /// Active observations keyed by observation name
    private var observations: [String: ObservationState] = [:]

    /// Event streams for active observations
    /// ARCHITECTURAL FIX: Use buffering continuations to decouple producer from consumer
    /// and prevent @MainActor contention deadlock
    /// LIFECYCLE FIX: Use UUID-keyed storage for proper continuation removal on termination
    private var eventStreams: [String: [UUID: AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation]] =
        [:]

    /// Sequence counters for observations
    private var sequenceCounters: [String: Int64] = [:]

    /// Background tasks for active observations
    private var tasks: [String: Task<Void, Never>] = [:]

    init(windowRegistry: WindowRegistry) {
        self.windowRegistry = windowRegistry
    }

    // MARK: - Public Interface

    /// Creates a new observation
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

        let state = ObservationState(
            observation: observation,
            parent: parent,
            pid: pid,
        )

        observations[name] = state
        sequenceCounters[name] = 0
        eventStreams[name] = [:]

        return observation
    }

    /// Starts an observation
    func startObservation(name: String) async throws {
        guard var state = observations[name] else {
            throw ObservationError.notFound
        }

        state.observation.state = .active
        state.observation.startTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state // Write state back to actor

        // Get all data needed by the nonisolated task *before* detaching
        let initialState = state // Copy state by value
        let manager = self // Capture actor reference for detached task

        // Start background monitoring task (detached to avoid blocking this actor)
        let task = Task.detached {
            // Pass state by value (continuations no longer needed, fetched dynamically)
            await manager.monitorObservation(
                name: name,
                initialState: initialState,
                [],
            )
        }
        tasks[name] = task
    }

    /// Gets an observation
    func getObservation(name: String) -> Macosusesdk_V1_Observation? {
        observations[name]?.observation
    }

    /// Lists observations for a parent
    func listObservations(parent: String) -> [Macosusesdk_V1_Observation] {
        observations.values
            .filter { $0.parent == parent }
            .map(\.observation)
    }

    /// Gets the count of active observations
    func getActiveObservationCount() -> Int {
        observations.values.count { $0.observation.state == .active }
    }

    /// Cancels an observation
    func cancelObservation(name: String) async -> Macosusesdk_V1_Observation? {
        guard var state = observations[name] else {
            return nil
        }

        // Cancel the background task
        tasks[name]?.cancel()
        tasks.removeValue(forKey: name)

        // Update state
        state.observation.state = .cancelled
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state

        // Close all event streams
        if let continuations = eventStreams[name] {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
        sequenceCounters.removeValue(forKey: name)

        return state.observation
    }

    /// Marks an observation as completed
    func completeObservation(name: String) async {
        guard var state = observations[name] else { return }

        state.observation.state = .completed
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state

        // Cancel task
        tasks[name]?.cancel()
        tasks.removeValue(forKey: name)

        // Close all event streams
        if let continuations = eventStreams[name] {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
    }

    /// Marks an observation as failed
    func failObservation(name: String, error _: Error) async {
        guard var state = observations[name] else { return }

        state.observation.state = .failed
        state.observation.endTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        observations[name] = state

        // Cancel task
        tasks[name]?.cancel()
        tasks.removeValue(forKey: name)

        // Close all event streams
        if let continuations = eventStreams[name] {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
    }

    /// Creates an event stream for an observation
    /// ARCHITECTURAL FIX: Use buffering limit to prevent producer blocking on slow consumers
    /// LIFECYCLE FIX: Remove continuation on termination to prevent leaks
    func createEventStream(
        name: String,
    ) -> AsyncStream<Macosusesdk_V1_ObservationEvent>? {
        guard observations[name] != nil else {
            return nil
        }

        let continuationID = UUID()
        let stream = AsyncStream<Macosusesdk_V1_ObservationEvent>(
            bufferingPolicy: .bufferingNewest(100),
        ) { continuation in
            Task {
                await self.addStreamContinuation(id: continuationID, name: name, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeStreamContinuation(id: continuationID, name: name)
                }
            }
        }

        return stream
    }

    // MARK: - Private Methods

    private func addStreamContinuation(
        id: UUID,
        name: String,
        continuation: AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation,
    ) async {
        if eventStreams[name] != nil {
            eventStreams[name]?[id] = continuation
        } else {
            eventStreams[name] = [id: continuation]
        }
    }

    private func removeStreamContinuation(
        id: UUID,
        name: String,
    ) async {
        eventStreams[name]?.removeValue(forKey: id)
        if eventStreams[name]?.isEmpty == true {
            eventStreams.removeValue(forKey: name)
        }
    }

    /// Publishes an event to all subscribers (nonisolated, non-blocking via Task dispatch)
    /// ARCHITECTURAL FIX: Use Task.detached to completely decouple event publishing from
    /// the monitoring loop, preventing yield() from blocking on @MainActor contention.
    private nonisolated func publishEvent(
        name: String,
        event: Macosusesdk_V1_ObservationEvent,
    ) {
        // Dispatch event publication to a detached task so we never block the monitoring loop
        Task.detached {
            // Re-fetch current continuations from the actor to handle late subscribers
            let continuations = await self.getCurrentContinuations(name: name)
            for continuation in continuations {
                continuation.yield(event)
            }
        }
    }

    /// Gets current continuations for an observation (actor-isolated helper)
    private func getCurrentContinuations(name: String) -> [AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation] {
        guard let continuations = eventStreams[name] else { return [] }
        return Array(continuations.values)
    }

    /// Monitors an observation in the background
    private nonisolated func monitorObservation(
        name: String,
        initialState: ObservationState,
        _: [AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation],
    ) async {
        let type = initialState.observation.type
        let filter = initialState.observation.filter
        let pid = initialState.pid
        _ = initialState.parent

        // Determine poll interval from filter or use default
        let pollInterval =
            (filter.pollInterval > 0)
                ? filter.pollInterval : 1.0

        // Keep track of previous state for diff detection
        // Start with empty state - first poll will emit "created" events for existing resources
        var previousElements: [Macosusesdk_Type_Element] = []
        var previousWindows: [AXWindowSnapshot] = []
        var sequence: Int64 = 0 // Track sequence locally instead of actor state

        while !Task.isCancelled {
            // CRITICAL: Yield control to allow gRPC executor to dispatch other RPCs
            await Task.yield()

            do {
                // Different monitoring strategies based on observation type
                switch type {
                case .elementChanges, .treeChanges:
                    // Poll for element changes
                    let traverseResult = try await AutomationCoordinator.shared.handleTraverse(
                        pid: pid,
                        visibleOnly: filter.visibleOnly,
                    )

                    let currentElements = traverseResult.elements

                    // Detect changes
                    let changes = detectElementChanges(
                        previous: previousElements,
                        current: currentElements,
                    )

                    // Publish change events
                    for change in changes {
                        let event = createObservationEvent(
                            name: name,
                            change: change,
                            sequence: sequence,
                        )
                        sequence += 1
                        publishEvent(name: name, event: event)
                    }

                    previousElements = currentElements

                case .windowChanges:
                    // Poll AX API directly to detect window changes
                    let currentWindows = try await fetchAXWindows(pid: pid)

                    // Detect window changes
                    let windowChanges = detectWindowChanges(
                        previous: previousWindows,
                        current: currentWindows,
                    )

                    // Publish window change events
                    for change in windowChanges {
                        let event = createWindowObservationEvent(
                            name: name,
                            change: change,
                            sequence: sequence,
                        )
                        sequence += 1
                        publishEvent(name: name, event: event)
                    }

                    previousWindows = currentWindows

                case .applicationChanges:
                    // Application changes are monitored via NSWorkspace notifications
                    // These are handled at a higher level
                    break

                case .attributeChanges:
                    // Monitor specific attribute changes
                    // Similar to element changes but only report attribute diffs
                    let traverseResult = try await AutomationCoordinator.shared.handleTraverse(
                        pid: pid,
                        visibleOnly: filter.visibleOnly,
                    )

                    let currentElements = traverseResult.elements

                    // Detect attribute changes
                    let changes = detectAttributeChanges(
                        previous: previousElements,
                        current: currentElements,
                        watchedAttributes: filter.attributes,
                    )

                    for change in changes {
                        let event = createObservationEvent(
                            name: name,
                            change: change,
                            sequence: sequence,
                        )
                        sequence += 1
                        publishEvent(name: name, event: event)
                    }

                    previousElements = currentElements

                case .unspecified, .UNRECOGNIZED:
                    break
                }

                // Sleep for poll interval
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            } catch {
                // If error occurs, call back to the actor to fail the observation
                await ObservationManager.shared.failObservation(name: name, error: error)
                return
            }
        }
    }

    /// Fetches current window snapshots from AX API (MUST run on MainActor)
    /// Uses CGWindowList IDs for consistency with gRPC API
    private nonisolated func fetchAXWindows(pid: pid_t) async throws -> [AXWindowSnapshot] {
        // Refresh WindowRegistry to get latest CGWindowList data
        try await windowRegistry.refreshWindows(forPID: pid)
        let cgWindows = try await windowRegistry.listWindows(forPID: pid)

        return await MainActor.run {
            let appElement = AXUIElementCreateApplication(pid)

            var windowsValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &windowsValue,
            )
            guard result == .success, let windows = windowsValue as? [AXUIElement] else {
                return [] // No windows or permission denied
            }

            var snapshots: [AXWindowSnapshot] = []
            for window in windows {
                var posValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                let posResult = AXUIElementCopyAttributeValue(
                    window, kAXPositionAttribute as CFString, &posValue,
                )
                let sizeResult = AXUIElementCopyAttributeValue(
                    window, kAXSizeAttribute as CFString, &sizeValue,
                )

                var bounds = CGRect.zero
                if posResult == .success, let unwrappedPosValue = posValue,
                   CFGetTypeID(unwrappedPosValue) == AXValueGetTypeID(),
                   sizeResult == .success, let unwrappedSizeValue = sizeValue,
                   CFGetTypeID(unwrappedSizeValue) == AXValueGetTypeID()
                {
                    let pos = unsafeDowncast(unwrappedPosValue, to: AXValue.self)
                    let size = unsafeDowncast(unwrappedSizeValue, to: AXValue.self)
                    var position = CGPoint.zero
                    var windowSize = CGSize.zero
                    if AXValueGetValue(pos, .cgPoint, &position),
                       AXValueGetValue(size, .cgSize, &windowSize)
                    {
                        bounds = CGRect(origin: position, size: windowSize)
                    }
                }

                // CORRECTNESS FIX: Use best-candidate matching instead of boolean tolerance check.
                // The tolerance approach caused identity loss during resize operations when
                // the delta exceeded 50px, resulting in false destroyed/created events.
                //
                // New strategy: Calculate distance for all candidates, select minimum.
                // Distance = abs(posX_delta) + abs(posY_delta) + abs(width_delta) + abs(height_delta)
                //
                // Edge case: If app has exactly 1 AX window and 1 CGWindowList window,
                // assume they match regardless of distance (handle API lag gracefully).

                var matchedWindow: (id: CGWindowID, bounds: CGRect)?

                if cgWindows.count == 1, windows.count == 1 {
                    // Single-window edge case: assume match regardless of distance
                    matchedWindow = (id: cgWindows[0].windowID, bounds: cgWindows[0].bounds)
                } else if !cgWindows.isEmpty {
                    // Multi-window case: select best candidate by minimum distance
                    var bestCandidate: (id: CGWindowID, bounds: CGRect, distance: CGFloat)?

                    for cgWin in cgWindows {
                        let posXDelta = abs(bounds.origin.x - cgWin.bounds.origin.x)
                        let posYDelta = abs(bounds.origin.y - cgWin.bounds.origin.y)
                        let widthDelta = abs(bounds.size.width - cgWin.bounds.size.width)
                        let heightDelta = abs(bounds.size.height - cgWin.bounds.size.height)

                        let distance = posXDelta + posYDelta + widthDelta + heightDelta

                        if bestCandidate == nil || distance < bestCandidate!.distance {
                            bestCandidate = (id: cgWin.windowID, bounds: cgWin.bounds, distance: distance)
                        }
                    }

                    if let best = bestCandidate {
                        matchedWindow = (id: best.id, bounds: best.bounds)
                    }
                }

                guard let matchedWindow else {
                    // Window not matchable to CGWindowList (might be transient/hidden)
                    continue
                }

                // Get title
                var titleValue: CFTypeRef?
                let titleResult = AXUIElementCopyAttributeValue(
                    window, kAXTitleAttribute as CFString, &titleValue,
                )
                let title = if titleResult == .success, let titleStr = titleValue as? String {
                    titleStr
                } else {
                    ""
                }

                // Get minimized state
                var minValue: CFTypeRef?
                let minimized = if AXUIElementCopyAttributeValue(
                    window, kAXMinimizedAttribute as CFString, &minValue,
                ) == .success, let minBool = minValue as? Bool {
                    minBool
                } else {
                    false
                }

                // Get focused state
                var mainValue: CFTypeRef?
                let focused: Bool? = if AXUIElementCopyAttributeValue(
                    window, kAXMainAttribute as CFString, &mainValue,
                ) == .success, let mainBool = mainValue as? Bool {
                    mainBool
                } else {
                    nil
                }

                // Use CGWindowList bounds (not AX bounds) for observation diffing
                // CGWindowList updates faster and more reliably than AX
                let snapshot = AXWindowSnapshot(
                    windowID: matchedWindow.id,
                    title: title,
                    bounds: matchedWindow.bounds,
                    minimized: minimized,
                    visible: !minimized,
                    focused: focused,
                )
                snapshots.append(snapshot)
            }

            return snapshots
        }
    }

    /// Detects changes between two element snapshots
    private nonisolated func detectElementChanges(
        previous: [Macosusesdk_Type_Element],
        current: [Macosusesdk_Type_Element],
    ) -> [ElementChange] {
        var changes: [ElementChange] = []

        // Create maps for efficient lookup
        let previousMap = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.path, $0) })
        let currentMap = Dictionary(
            uniqueKeysWithValues: current.map { ($0.path, $0) })

        // Find added elements
        for element in current where previousMap[element.path] == nil {
            changes.append(.added(element))
        }

        // Find removed elements
        for element in previous where currentMap[element.path] == nil {
            changes.append(.removed(element))
        }

        // Find modified elements
        for element in current {
            if let prevElement = previousMap[element.path],
               !elementsEqual(prevElement, element)
            {
                changes.append(.modified(old: prevElement, new: element))
            }
        }

        return changes
    }

    /// Detects attribute changes between two element snapshots
    private nonisolated func detectAttributeChanges(
        previous: [Macosusesdk_Type_Element],
        current: [Macosusesdk_Type_Element],
        watchedAttributes: [String],
    ) -> [ElementChange] {
        var changes: [ElementChange] = []

        let previousMap = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.path, $0) })
        _ = Dictionary(
            uniqueKeysWithValues: current.map { ($0.path, $0) })

        // Only look for modified elements
        for element in current {
            if let prevElement = previousMap[element.path] {
                let attributeChanges = findAttributeChanges(
                    old: prevElement,
                    new: element,
                    watched: watchedAttributes,
                )

                if !attributeChanges.isEmpty {
                    changes.append(.modified(old: prevElement, new: element))
                }
            }
        }

        return changes
    }

    /// Finds specific attribute changes between two elements
    private nonisolated func findAttributeChanges(
        old: Macosusesdk_Type_Element,
        new: Macosusesdk_Type_Element,
        watched: [String],
    ) -> [Macosusesdk_V1_AttributeChange] {
        var attributeChanges: [Macosusesdk_V1_AttributeChange] = []

        // If no specific attributes to watch, watch all
        let attributesToCheck =
            watched.isEmpty
                ? Array(old.attributes.keys) + Array(new.attributes.keys)
                : watched

        for attr in Set(attributesToCheck) {
            let oldValue = old.attributes[attr] ?? ""
            let newValue = new.attributes[attr] ?? ""

            if oldValue != newValue {
                attributeChanges.append(
                    Macosusesdk_V1_AttributeChange.with {
                        $0.attribute = attr
                        $0.oldValue = oldValue
                        $0.newValue = newValue
                    })
            }
        }

        // Also check standard fields
        if old.text != new.text {
            attributeChanges.append(
                Macosusesdk_V1_AttributeChange.with {
                    $0.attribute = "text"
                    $0.oldValue = old.text
                    $0.newValue = new.text
                })
        }

        if old.enabled != new.enabled {
            attributeChanges.append(
                Macosusesdk_V1_AttributeChange.with {
                    $0.attribute = "enabled"
                    $0.oldValue = "\(old.enabled)"
                    $0.newValue = "\(new.enabled)"
                })
        }

        if old.focused != new.focused {
            attributeChanges.append(
                Macosusesdk_V1_AttributeChange.with {
                    $0.attribute = "focused"
                    $0.oldValue = "\(old.focused)"
                    $0.newValue = "\(new.focused)"
                })
        }

        return attributeChanges
    }

    /// Checks if two elements are equal
    private nonisolated func elementsEqual(
        _ a: Macosusesdk_Type_Element,
        _ b: Macosusesdk_Type_Element,
    ) -> Bool {
        a.role == b.role
            && a.text == b.text
            && a.enabled == b.enabled
            && a.focused == b.focused
            && a.attributes == b.attributes
    }

    /// Creates an observation event from a change
    private nonisolated func createObservationEvent(
        name: String,
        change: ElementChange,
        sequence: Int64,
    ) -> Macosusesdk_V1_ObservationEvent {
        Macosusesdk_V1_ObservationEvent.with {
            $0.observation = name
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = sequence

            switch change {
            case let .added(element):
                $0.eventType = .elementAdded(
                    Macosusesdk_V1_ElementEvent.with {
                        $0.element = element
                    })

            case let .removed(element):
                $0.eventType = .elementRemoved(
                    Macosusesdk_V1_ElementEvent.with {
                        $0.element = element
                    })

            case let .modified(old, new):
                let attributeChanges = findAttributeChanges(
                    old: old,
                    new: new,
                    watched: [], // Get all changes
                )

                $0.eventType = .elementModified(
                    Macosusesdk_V1_ElementModified.with {
                        $0.oldElement = old
                        $0.newElement = new
                        $0.changes = attributeChanges
                    })
            }
        }
    }

    /// Detects changes between two window snapshots
    nonisolated func detectWindowChanges(
        previous: [AXWindowSnapshot],
        current: [AXWindowSnapshot],
    ) -> [WindowChange] {
        var changes: [WindowChange] = []

        // CORRECTNESS FIX: Now using real CGWindowID extracted from AXUIElement via _AXUIElementGetWindow.
        // This provides stable window identity across polls, fixing the fatal observation bug.
        let previousMap = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.windowID, $0) },
        )
        let currentMap = Dictionary(
            uniqueKeysWithValues: current.map { ($0.windowID, $0) },
        )

        // Find created windows (windowID that didn't exist before)
        for window in current where previousMap[window.windowID] == nil {
            changes.append(.created(window))
        }

        // Find destroyed windows (windowID that no longer exists)
        for window in previous where currentMap[window.windowID] == nil {
            changes.append(.destroyed(window))
        }

        // Find modified windows (same windowID, different properties)
        for window in current {
            if let prevWindow = previousMap[window.windowID] {
                // Check for moved
                if window.bounds.origin != prevWindow.bounds.origin {
                    changes.append(.moved(old: prevWindow, new: window))
                }
                // Check for resized
                if window.bounds.size != prevWindow.bounds.size {
                    changes.append(.resized(old: prevWindow, new: window))
                }
                // Check for visibility changes (minimized/restored)
                if window.minimized != prevWindow.minimized {
                    if window.minimized {
                        changes.append(.minimized(window))
                    } else {
                        changes.append(.restored(window))
                    }
                }
            }
        }

        return changes
    }

    /// Creates a window observation event from a window change
    private nonisolated func createWindowObservationEvent(
        name: String,
        change: WindowChange,
        sequence: Int64,
    ) -> Macosusesdk_V1_ObservationEvent {
        Macosusesdk_V1_ObservationEvent.with {
            $0.observation = name
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = sequence

            switch change {
            case let .created(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .created
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    },
                )

            case let .destroyed(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .destroyed
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    },
                )

            case let .moved(_, new):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .moved
                        $0.windowID = "\(new.windowID)"
                        $0.title = new.title
                    },
                )

            case let .resized(_, new):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .resized
                        $0.windowID = "\(new.windowID)"
                        $0.title = new.title
                    },
                )

            case let .minimized(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .minimized
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    },
                )

            case let .restored(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .restored
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    },
                )
            }
        }
    }
}

// MARK: - Supporting Types

/// State of an observation
private struct ObservationState {
    var observation: Macosusesdk_V1_Observation
    let parent: String
    let pid: pid_t
}

/// Type of element change
private enum ElementChange {
    case added(Macosusesdk_Type_Element)
    case removed(Macosusesdk_Type_Element)
    case modified(old: Macosusesdk_Type_Element, new: Macosusesdk_Type_Element)
}

/// AX-sourced window snapshot for observation diffing.
/// This struct holds ONLY data from the Accessibility API, avoiding the
/// catastrophic state inconsistency with CGWindowList.
struct AXWindowSnapshot: Hashable {
    let windowID: CGWindowID // Stable CGWindowID extracted from AXUIElement via _AXUIElementGetWindow
    let title: String
    let bounds: CGRect
    let minimized: Bool
    let visible: Bool // Derived as !minimized
    let focused: Bool?

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: AXWindowSnapshot, rhs: AXWindowSnapshot) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

/// Type of window change
enum WindowChange {
    case created(AXWindowSnapshot)
    case destroyed(AXWindowSnapshot)
    case moved(old: AXWindowSnapshot, new: AXWindowSnapshot)
    case resized(old: AXWindowSnapshot, new: AXWindowSnapshot)
    case minimized(AXWindowSnapshot)
    case restored(AXWindowSnapshot)
}

/// Observation errors
enum ObservationError: Error {
    case notFound
    case alreadyStarted
    case invalidState
}
