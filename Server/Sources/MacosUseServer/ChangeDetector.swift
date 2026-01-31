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

    private func handleAppActivated(app: NSRunningApplication) {
        logger.info("App activated: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(app.processIdentifier, privacy: .private))")
    }

    private func handleAppDeactivated(app: NSRunningApplication) {
        logger.info("App deactivated: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(app.processIdentifier, privacy: .private))")
    }

    private func handleAppLaunched(app: NSRunningApplication) {
        logger.info("App launched: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(app.processIdentifier, privacy: .private))")
    }

    private func handleAppTerminated(app: NSRunningApplication) {
        logger.info("App terminated: \(app.localizedName ?? "unknown", privacy: .private) (pid: \(app.processIdentifier, privacy: .private))")
        // Clean up observers for terminated app
        if let observer = observers[app.processIdentifier] {
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode,
            )
            observers.removeValue(forKey: app.processIdentifier)
        }
    }
}

enum ChangeDetectorError: Error {
    case failedToCreateObserver(pid: pid_t)
}
