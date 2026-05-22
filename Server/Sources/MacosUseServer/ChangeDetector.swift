import AppKit
import ApplicationServices
import Foundation
import MacosUseProto
import MacosUseSDK
import OSLog

private let logger = MacosUseSDK.sdkLogger(category: "ChangeDetector")

/// Detects UI changes using accessibility notifications.
///
/// This component uses AXObserverCreate to register for accessibility notifications
/// and NSWorkspace.shared.notificationCenter for app-level events.
@MainActor
class ChangeDetector {
    /// Shared singleton instance
    static let shared = ChangeDetector()

    /// Active observers keyed by PID
    private var observers: [pid_t: AXObserver] = [:]

    /// Notification handlers keyed by observation name
    private var handlers: [String: (AXUIElement, CFString) -> Void] = [:]

    // MARK: - Self-Activation Tracking

    /// Tracks PIDs that were recently activated by the SDK (e.g. traversal with shouldActivate=true)
    /// so that the resulting workspace notifications can be suppressed and not echoed as real user events.
    private var sdkActivatedPIDs: [pid_t: Date] = [:]

    /// Window within which an activation is considered SDK-triggered.
    private let sdkActivationWindow: TimeInterval = 0.5

    // MARK: - Circuit Breaker

    /// Per-PID activation event counts within a rolling window, used to detect
    /// and suppress runaway activation cycles.
    private var activationEventCounts: [pid_t: (count: Int, windowStart: Date)] = [:]

    /// Maximum number of activation events per PID within `circuitBreakerWindow`
    /// before the circuit breaker trips and suppresses further events.
    private let circuitBreakerThreshold = 5

    /// Rolling window duration for the circuit breaker.
    private let circuitBreakerWindow: TimeInterval = 1.0

    private init() {
        // Set up app-level notifications
        setupAppNotifications()
    }

    /// Registers an observer for a process
    func registerObserver(
        pid: pid_t,
        observationName: String,
        handler: @escaping (AXUIElement, CFString) -> Void,
    ) throws {
        // Store handler
        handlers[observationName] = handler

        // Check if we already have an observer for this PID
        if observers[pid] != nil {
            // Reuse existing observer
            return
        }

        // Create new observer
        var observer: AXObserver?
        let result = AXObserverCreate(
            pid,
            { (_: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) in
                // This callback runs on a background thread
                // Guard against nil refcon (should never happen, but defensive programming)
                guard let refcon else {
                    // Cannot use Logger in C callback; use os_log directly
                    os_log(.fault, "ChangeDetector callback received nil refcon")
                    return
                }
                let detector = Unmanaged<ChangeDetector>.fromOpaque(refcon).takeUnretainedValue()

                // Forward to main actor
                Task { @MainActor in
                    detector.handleNotification(element: element, notification: notification)
                }
            },
            &observer,
        )

        guard result == .success, let observer else {
            throw ChangeDetectorError.failedToCreateObserver(pid: pid)
        }

        // Store observer
        observers[pid] = observer

        // Add observer to run loop
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode,
        )

        // Register for common notifications
        let notifications = [
            kAXValueChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXCreatedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXWindowCreatedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]

        let appElement = AXUIElementCreateApplication(pid)

        for notification in notifications {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
    }

    /// Unregisters an observer for an observation
    func unregisterObserver(observationName: String, pid: pid_t) {
        handlers.removeValue(forKey: observationName)

        // Check if there are any other handlers for this PID
        let hasOtherHandlers = handlers.values.contains { _ in true }

        if !hasOtherHandlers, let observer = observers[pid] {
            // Remove from run loop
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode,
            )

            observers.removeValue(forKey: pid)
        }
    }

    private func setupAppNotifications() {
        let workspace = NSWorkspace.shared

        // Application activated
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            {
                Task { @MainActor in
                    self.handleAppActivated(app: app)
                }
            }
        }

        // Application deactivated
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            {
                Task { @MainActor in
                    self.handleAppDeactivated(app: app)
                }
            }
        }

        // Application launched
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            {
                Task { @MainActor in
                    self.handleAppLaunched(app: app)
                }
            }
        }

        // Application terminated
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            {
                Task { @MainActor in
                    self.handleAppTerminated(app: app)
                }
            }
        }
    }

    private func handleNotification(element: AXUIElement, notification: CFString) {
        // Forward to all handlers
        for handler in handlers.values {
            handler(element, notification)
        }
    }

    // MARK: - SDK Activation API

    /// Records that the SDK is about to activate the given PID, so that the
    /// resulting workspace didActivate / didDeactivate notifications are suppressed.
    func markSDKActivation(pid: pid_t) {
        sdkActivatedPIDs[pid] = Date()
        logger.trace("Marked SDK activation for pid \(pid, privacy: .public)")
    }

    /// Returns true if `pid` was activated by the SDK within the last 500ms.
    func isSDKActivation(pid: pid_t) -> Bool {
        guard let timestamp = sdkActivatedPIDs[pid] else { return false }
        return Date().timeIntervalSince(timestamp) < sdkActivationWindow
    }

    /// Returns true if *any* PID was activated by the SDK within the last 500ms.
    /// Used by deactivation handler: when SDK activates app B, the *previously*
    /// active app A is deactivated. The deactivated PID is A, not B, so we
    /// cannot check the deactivated PID — we check if any SDK activation occurred
    /// recently.
    ///
    /// **Accepted edge case:** If multiple PIDs are SDK-activated in rapid succession,
    /// ALL deactivation events for ANY app are suppressed for 500ms. This is an
    /// accepted trade-off — the suppression window is short and the alternative
    /// (tracking the "previously active" app) is fragile.
    func hasRecentSDKActivation() -> Bool {
        let now = Date()
        // Lazily prune entries older than the activation window
        sdkActivatedPIDs = sdkActivatedPIDs.filter { now.timeIntervalSince($0.value) < sdkActivationWindow }
        return !sdkActivatedPIDs.isEmpty
    }

    /// Increments the per-PID activation counter and returns true if the circuit
    /// breaker has tripped (i.e. the event should be suppressed).
    /// - Note: Internal for testing with @testable import.
    func shouldCircuitBreak(pid: pid_t) -> Bool {
        let now = Date()
        if let entry = activationEventCounts[pid] {
            if now.timeIntervalSince(entry.windowStart) > circuitBreakerWindow {
                // Window expired – reset
                activationEventCounts[pid] = (count: 1, windowStart: now)
                return false
            } else {
                let newCount = entry.count + 1
                activationEventCounts[pid] = (count: newCount, windowStart: entry.windowStart)
                if newCount > circuitBreakerThreshold {
                    let windowSec = circuitBreakerWindow
                    logger.warning("Circuit breaker tripped for pid \(pid, privacy: .public): \(newCount, privacy: .public) activation events in \(windowSec, privacy: .public)s window")
                    return true
                }
                return false
            }
        } else {
            activationEventCounts[pid] = (count: 1, windowStart: now)
            return false
        }
    }

    // MARK: - Test Support (Internal API)

    /// The maximum activation events before the circuit breaker trips.
    /// - Note: Internal for testing with @testable import.
    var testCircuitBreakerThreshold: Int {
        circuitBreakerThreshold
    }

    /// The circuit breaker rolling window duration.
    /// - Note: Internal for testing with @testable import.
    var testCircuitBreakerWindow: TimeInterval {
        circuitBreakerWindow
    }

    /// The SDK activation suppression window.
    /// - Note: Internal for testing with @testable import.
    var testSDKActivationWindow: TimeInterval {
        sdkActivationWindow
    }

    /// Resets all activation tracking state. For testing only.
    /// - Note: Internal for testing with @testable import.
    func resetActivationState() {
        sdkActivatedPIDs.removeAll()
        activationEventCounts.removeAll()
    }

    /// Returns the current activation count for a PID. For testing only.
    /// - Note: Internal for testing with @testable import.
    func testGetActivationCount(pid: pid_t) -> Int? {
        activationEventCounts[pid]?.count
    }

    private func handleAppActivated(app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Suppress SDK-triggered activations
        if isSDKActivation(pid: pid) {
            logger.trace("Suppressing SDK-triggered activation event for pid \(pid, privacy: .public)")
            return
        }

        // Circuit breaker check
        if shouldCircuitBreak(pid: pid) {
            return
        }

        logger.info("App activated: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(pid, privacy: .private))")
    }

    private func handleAppDeactivated(app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Suppress deactivations that are the "other side" of an SDK activation.
        // When the SDK activates app B (markSDKActivation(pid: B)), the previously
        // active app A receives a deactivation event. Since A is NOT the SDK-activated
        // PID, we check whether *any* PID was recently SDK-activated.
        if hasRecentSDKActivation() {
            logger.trace("Suppressing SDK-triggered deactivation event for pid \(pid, privacy: .public)")
            return
        }

        // Circuit breaker check
        if shouldCircuitBreak(pid: pid) {
            return
        }

        logger.info("App deactivated: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(pid, privacy: .private))")
    }

    private func handleAppLaunched(app: NSRunningApplication) {
        logger.info("App launched: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(app.processIdentifier, privacy: .private))")
    }

    private func handleAppTerminated(app: NSRunningApplication) {
        let pid = app.processIdentifier
        logger.info("App terminated: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(pid, privacy: .private))")

        // Clean up activation tracking state for this PID
        sdkActivatedPIDs.removeValue(forKey: pid)
        activationEventCounts.removeValue(forKey: pid)

        // Clean up observers for terminated app
        if let observer = observers[pid] {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode,
            )
            observers.removeValue(forKey: pid)
        }
    }
}

enum ChangeDetectorError: Error {
    case failedToCreateObserver(pid: pid_t)
}
