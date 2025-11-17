import ApplicationServices
import Foundation
import MacosUseSDKProtos
import SwiftProtobuf

/// Manages active observations and coordinates streaming of observation events.
///
/// This actor is thread-safe and maintains the state of all active observations.
/// It works with ChangeDetector to monitor UI changes and fan out events to subscribers.
actor ObservationManager {
    /// Shared singleton instance
    static let shared = ObservationManager()

    /// Active observations keyed by observation name
    private var observations: [String: ObservationState] = [:]

    /// Event streams for active observations
    private var eventStreams: [String: [AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation]] =
        [:]

    /// Sequence counters for observations
    private var sequenceCounters: [String: Int64] = [:]

    /// Background tasks for active observations
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

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
        eventStreams[name] = []

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
        let continuations = eventStreams[name] ?? []
        let initialState = state // Copy state by value

        // Start background monitoring task (detached to avoid blocking this actor)
        let task = Task.detached {
            // Pass state and continuations by value
            await self.monitorObservation(
                name: name,
                initialState: initialState,
                continuations: continuations,
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
            for continuation in continuations {
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
            for continuation in continuations {
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
            for continuation in continuations {
                continuation.finish()
            }
        }
        eventStreams.removeValue(forKey: name)
    }

    /// Creates an event stream for an observation
    func createEventStream(
        name: String,
    ) -> AsyncStream<Macosusesdk_V1_ObservationEvent>? {
        guard observations[name] != nil else {
            return nil
        }

        let stream = AsyncStream<Macosusesdk_V1_ObservationEvent> { continuation in
            Task {
                self.addStreamContinuation(name: name, continuation: continuation)
            }
        }

        return stream
    }

    // MARK: - Private Methods

    private func addStreamContinuation(
        name: String,
        continuation: AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation,
    ) {
        if eventStreams[name] != nil {
            eventStreams[name]?.append(continuation)
        } else {
            eventStreams[name] = [continuation]
        }
    }

    /// Publishes an event to all subscribers (nonisolated to avoid blocking monitoring loop)
    private nonisolated func publishEvent(
        continuations: [AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation],
        event: Macosusesdk_V1_ObservationEvent,
    ) {
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    /// Monitors an observation in the background
    private nonisolated func monitorObservation(
        name: String,
        initialState: ObservationState,
        continuations: [AsyncStream<Macosusesdk_V1_ObservationEvent>.Continuation],
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
        var previousWindows: [WindowRegistry.WindowInfo] = []
        var sequence: Int64 = 0 // Track sequence locally instead of actor state

        fputs("info: [ObservationManager] Starting monitoring loop for \(name) (type: \(type))\n", stderr)

        while !Task.isCancelled {
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
                        publishEvent(continuations: continuations, event: event)
                    }

                    previousElements = currentElements

                case .windowChanges:
                    // Poll window list and detect changes
                    let registry = WindowRegistry()
                    try await registry.refreshWindows(forPID: pid)
                    let currentWindows = try await registry.listWindows(forPID: pid)

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
                        publishEvent(continuations: continuations, event: event)
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
                        publishEvent(continuations: continuations, event: event)
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
    private nonisolated func detectWindowChanges(
        previous: [WindowRegistry.WindowInfo],
        current: [WindowRegistry.WindowInfo],
    ) -> [WindowChange] {
        var changes: [WindowChange] = []

        // Create maps for efficient lookup
        let previousMap = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.windowID, $0) })
        let currentMap = Dictionary(
            uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        // Find created windows
        for window in current where previousMap[window.windowID] == nil {
            changes.append(.created(window))
        }

        // Find destroyed windows
        for window in previous where currentMap[window.windowID] == nil {
            changes.append(.destroyed(window))
        }

        // Find modified windows (moved/resized)
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
                if window.isOnScreen != prevWindow.isOnScreen {
                    if window.isOnScreen {
                        changes.append(.restored(window))
                    } else {
                        changes.append(.minimized(window))
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
                    })

            case let .destroyed(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .destroyed
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    })

            case let .moved(_, new):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .moved
                        $0.windowID = "\(new.windowID)"
                        $0.title = new.title
                    })

            case let .resized(_, new):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .resized
                        $0.windowID = "\(new.windowID)"
                        $0.title = new.title
                    })

            case let .minimized(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .minimized
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    })

            case let .restored(window):
                $0.eventType = .windowEvent(
                    Macosusesdk_V1_WindowEvent.with {
                        $0.eventType = .restored
                        $0.windowID = "\(window.windowID)"
                        $0.title = window.title
                    })
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

/// Type of window change
private enum WindowChange {
    case created(WindowRegistry.WindowInfo)
    case destroyed(WindowRegistry.WindowInfo)
    case moved(old: WindowRegistry.WindowInfo, new: WindowRegistry.WindowInfo)
    case resized(old: WindowRegistry.WindowInfo, new: WindowRegistry.WindowInfo)
    case minimized(WindowRegistry.WindowInfo)
    case restored(WindowRegistry.WindowInfo)
}

/// Observation errors
enum ObservationError: Error {
    case notFound
    case alreadyStarted
    case invalidState
}
