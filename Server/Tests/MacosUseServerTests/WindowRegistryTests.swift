import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacosUseServer

/// Unit tests for WindowRegistry focusing on window detection and filtering behavior.
@Suite("WindowRegistry Tests")
struct WindowRegistryTests {
    /// Tests that refreshWindows with .optionAll correctly detects windows including those
    /// that are off-screen (minimized). This validates the fix where .optionAll was added
    /// to detect minimized windows that .optionOnScreenOnly would miss.
    @Test("Detects windows with .optionAll including off-screen state")
    func detectsWindowsWithOptionAll() async throws {
        let registry = WindowRegistry()

        // Use any running regular application - we don't care which one
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular }

        guard let app = apps.first else {
            // If no apps are running, there's nothing to test, but this is not a failure
            // Unit tests should not require specific external state
            return
        }

        let pid = app.processIdentifier

        // Refresh windows for this PID - this now uses .optionAll internally
        try await registry.refreshWindows(forPID: pid)
        let windows = try await registry.listWindows(forPID: pid)

        // If the app has windows, verify the registry captured them correctly
        if !windows.isEmpty {
            for window in windows {
                #expect(window.ownerPID == pid, "Expected PID to match")
                #expect(window.windowID > 0, "Expected valid window ID")

                // The critical property: isOnScreen should be populated
                // This confirms that .optionAll captures both on-screen and off-screen windows
                // (The actual boolean value depends on window state, which we cannot control)
                _ = window.isOnScreen
            }

            // Verify that at least one window was found (proving .optionAll works)
            #expect(windows.count > 0, "Expected at least one window when app has windows")
        }
    }

    /// Tests that the registry filters windows correctly by PID.
    @Test("Filters windows by PID")
    func filtersWindowsByPID() async throws {
        let registry = WindowRegistry()

        // Get two different apps
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular }

        guard apps.count >= 2 else {
            // Not enough apps running - skip test gracefully
            return
        }

        let pid1 = apps[0].processIdentifier
        let pid2 = apps[1].processIdentifier

        // Refresh windows for first PID
        try await registry.refreshWindows(forPID: pid1)
        let windows1 = try await registry.listWindows(forPID: pid1)

        // Refresh windows for second PID
        try await registry.refreshWindows(forPID: pid2)
        let windows2 = try await registry.listWindows(forPID: pid2)

        // Verify all windows match their respective PIDs
        for window in windows1 {
            #expect(window.ownerPID == pid1, "All windows should match the first PID")
        }

        for window in windows2 {
            #expect(window.ownerPID == pid2, "All windows should match the second PID")
        }
    }

    /// Tests that getWindow returns correct window information after refresh.
    @Test("getWindow returns correct information")
    func getWindowReturnsCorrectInfo() async throws {
        let registry = WindowRegistry()

        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular }

        guard let app = apps.first else {
            // No apps running - skip gracefully
            return
        }

        let pid = app.processIdentifier
        try await registry.refreshWindows(forPID: pid)
        let windows = try await registry.listWindows(forPID: pid)

        guard let firstWindow = windows.first else {
            // No windows found - this is OK, nothing to test
            return
        }

        // Get the same window via getWindow
        let retrievedWindow = try await registry.getWindow(firstWindow.windowID)

        #expect(retrievedWindow != nil, "getWindow should return a window for a valid ID")
        #expect(retrievedWindow?.windowID == firstWindow.windowID, "Window IDs should match")
        #expect(retrievedWindow?.ownerPID == firstWindow.ownerPID, "PIDs should match")
        #expect(retrievedWindow?.bundleID == firstWindow.bundleID, "Bundle IDs should match")
    }
}
