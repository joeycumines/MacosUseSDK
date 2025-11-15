// Copyright 2025 Joseph Cumines
//
// WindowRegistry - Thread-safe registry for tracking application windows

import AppKit
import Foundation

/// Thread-safe registry for tracking windows across all applications.
actor WindowRegistry {
    /// Cached window information.
    struct WindowInfo {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let bounds: CGRect
        let title: String
        let layer: Int32
        let isOnScreen: Bool
        let timestamp: Date
    }

    /// Cache of window information by window ID.
    private var windowCache: [CGWindowID: WindowInfo] = [:]

    /// Cache TTL in seconds.
    private let cacheTTL: TimeInterval = 1.0

    /// Refresh the window cache for all or specific application.
    func refreshWindows(forPID pid: pid_t? = nil) async throws {
        let windowList =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []

        let now = Date()

        for windowDict in windowList {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t
            else {
                continue
            }

            // Filter by PID if specified
            if let targetPID = pid, ownerPID != targetPID {
                continue
            }

            let bounds = windowDict[kCGWindowBounds as String] as? [String: CGFloat]
            let rect = CGRect(
                x: bounds?["X"] ?? 0,
                y: bounds?["Y"] ?? 0,
                width: bounds?["Width"] ?? 0,
                height: bounds?["Height"] ?? 0,
            )

            let title = windowDict[kCGWindowName as String] as? String ?? ""
            let layer = windowDict[kCGWindowLayer as String] as? Int32 ?? 0
            let isOnScreen = windowDict[kCGWindowIsOnscreen as String] as? Bool ?? false

            let info = WindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                bounds: rect,
                title: title,
                layer: layer,
                isOnScreen: isOnScreen,
                timestamp: now,
            )

            windowCache[windowID] = info
        }

        // Evict stale entries
        let staleThreshold = now.addingTimeInterval(-cacheTTL)
        windowCache = windowCache.filter { $0.value.timestamp >= staleThreshold }
    }

    /// Get window information by ID.
    func getWindow(_ windowID: CGWindowID) async throws -> WindowInfo? {
        // Refresh if not cached or stale
        if let cached = windowCache[windowID] {
            let age = Date().timeIntervalSince(cached.timestamp)
            if age < cacheTTL {
                return cached
            }
        }

        // Refresh and try again
        try await refreshWindows()
        return windowCache[windowID]
    }

    /// List all windows for a specific PID.
    func listWindows(forPID pid: pid_t) async throws -> [WindowInfo] {
        try await refreshWindows(forPID: pid)
        return windowCache.values.filter { $0.ownerPID == pid }.sorted { $0.layer < $1.layer }
    }

    /// List all windows across all applications.
    func listAllWindows() async throws -> [WindowInfo] {
        try await refreshWindows()
        return windowCache.values.sorted { $0.layer < $1.layer }
    }
}
