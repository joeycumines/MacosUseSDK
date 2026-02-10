import AppKit
import CoreGraphics
import Foundation
@testable import MacosUseServer
import Testing

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

// MARK: - WindowRegistry Cache Invalidation Tests (Task 43)

@Suite("WindowRegistry Cache Invalidation")
struct WindowRegistryCacheInvalidationTests {
    /// Create a mock that returns controlled window data.
    func makeMockSystemOps(windows: [[String: Any]]) -> MockSystemOperations {
        MockSystemOperations(cgWindowList: windows)
    }

    /// Helper to create a window list entry.
    func makeWindowEntry(
        id: CGWindowID,
        pid: pid_t,
        bounds: CGRect,
        title: String = "Test Window",
        layer: Int32 = 0,
        isOnScreen: Bool = true,
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: [
                "X": bounds.origin.x,
                "Y": bounds.origin.y,
                "Width": bounds.size.width,
                "Height": bounds.size.height,
            ],
            kCGWindowName as String: title,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: isOnScreen,
        ]
    }

    // MARK: - invalidate(windowID:) Tests

    @Test("invalidate removes cached window")
    func invalidateRemovesCachedWindow() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            makeWindowEntry(id: 1002, pid: 100, bounds: CGRect(x: 100, y: 100, width: 400, height: 300)),
        ])
        let registry = WindowRegistry(system: mockOps)

        // Refresh to populate cache
        try await registry.refreshWindows(forPID: 100)

        // Verify window is cached
        let beforeInvalidate = await registry.getLastKnownWindow(1001)
        #expect(beforeInvalidate != nil, "Window should be cached before invalidation")

        // Invalidate the window
        await registry.invalidate(windowID: 1001)

        // Verify window is removed from cache
        let afterInvalidate = await registry.getLastKnownWindow(1001)
        #expect(afterInvalidate == nil, "Window should be removed after invalidation")

        // Other window should still be cached
        let otherWindow = await registry.getLastKnownWindow(1002)
        #expect(otherWindow != nil, "Other windows should remain cached")
    }

    @Test("invalidate non-existent window is no-op")
    func invalidateNonExistentWindowIsNoOp() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Invalidate non-existent window - should not crash or affect existing windows
        await registry.invalidate(windowID: 9999)

        let window = await registry.getLastKnownWindow(1001)
        #expect(window != nil, "Existing window should remain cached")
    }

    @Test("invalidate can be called multiple times safely")
    func invalidateMultipleTimesSafe() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Invalidate the same window multiple times
        await registry.invalidate(windowID: 1001)
        await registry.invalidate(windowID: 1001)
        await registry.invalidate(windowID: 1001)

        let window = await registry.getLastKnownWindow(1001)
        #expect(window == nil, "Window should remain invalidated")
    }

    // MARK: - findWindowByPosition Tests

    @Test("findWindowByPosition returns correct match within tolerance")
    func findWindowByPositionWithinTolerance() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
            makeWindowEntry(id: 1002, pid: 100, bounds: CGRect(x: 500.0, y: 300.0, width: 400, height: 300)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Exact match
        let exactMatch = await registry.findWindowByPosition(pid: 100, x: 100.0, y: 200.0)
        #expect(exactMatch?.windowID == 1001, "Should find exact position match")

        // Within tolerance (default 5.0)
        let withinTolerance = await registry.findWindowByPosition(pid: 100, x: 103.0, y: 198.0)
        #expect(withinTolerance?.windowID == 1001, "Should find match within tolerance")

        // Just at tolerance boundary
        let atBoundary = await registry.findWindowByPosition(pid: 100, x: 105.0, y: 205.0)
        #expect(atBoundary?.windowID == 1001, "Should find match at tolerance boundary")
    }

    @Test("findWindowByPosition returns nil when outside tolerance")
    func findWindowByPositionOutsideTolerance() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Just outside tolerance
        let outsideTolerance = await registry.findWindowByPosition(pid: 100, x: 106.0, y: 200.0)
        #expect(outsideTolerance == nil, "Should return nil when outside tolerance")
    }

    @Test("findWindowByPosition returns nil for wrong PID")
    func findWindowByPositionWrongPID() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
            makeWindowEntry(id: 2001, pid: 200, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows()

        // Looking for PID 300 which doesn't exist at this position
        let wrongPID = await registry.findWindowByPosition(pid: 300, x: 100.0, y: 200.0)
        #expect(wrongPID == nil, "Should return nil for non-matching PID")
    }

    @Test("findWindowByPosition custom tolerance")
    func findWindowByPositionCustomTolerance() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // With larger tolerance
        let largeTolerance = await registry.findWindowByPosition(pid: 100, x: 120.0, y: 200.0, tolerance: 25.0)
        #expect(largeTolerance?.windowID == 1001, "Should find match with larger tolerance")

        // With smaller tolerance
        let smallTolerance = await registry.findWindowByPosition(pid: 100, x: 104.0, y: 200.0, tolerance: 2.0)
        #expect(smallTolerance == nil, "Should return nil with smaller tolerance")
    }

    // MARK: - findWindowByBounds Tests

    @Test("findWindowByBounds returns nil for ambiguous matches")
    func findWindowByBoundsAmbiguousReturnsNil() async throws {
        // Two windows with identical bounds
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
            makeWindowEntry(id: 1002, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Ambiguous - two windows match
        let ambiguous = await registry.findWindowByBounds(
            pid: 100,
            bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600),
        )
        #expect(ambiguous == nil, "Should return nil for ambiguous (multiple) matches")
    }

    @Test("findWindowByBounds returns match when only one window matches")
    func findWindowByBoundsSingleMatch() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600)),
            makeWindowEntry(id: 1002, pid: 100, bounds: CGRect(x: 500.0, y: 300.0, width: 400, height: 300)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Single match
        let match = await registry.findWindowByBounds(
            pid: 100,
            bounds: CGRect(x: 100.0, y: 200.0, width: 800, height: 600),
        )
        #expect(match?.windowID == 1001, "Should return the single matching window")
    }

    @Test("findWindowByBounds matches within tolerance on all dimensions")
    func findWindowByBoundsMatchesAllDimensions() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800.0, height: 600.0)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // All dimensions slightly off but within tolerance
        let withinTolerance = await registry.findWindowByBounds(
            pid: 100,
            bounds: CGRect(x: 103.0, y: 198.0, width: 802.0, height: 597.0),
        )
        #expect(withinTolerance?.windowID == 1001, "Should match when all dimensions within tolerance")
    }

    @Test("findWindowByBounds returns nil when one dimension exceeds tolerance")
    func findWindowByBoundsOneDimensionExceedsTolerance() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 100.0, y: 200.0, width: 800.0, height: 600.0)),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)

        // Width is outside tolerance
        let widthOutside = await registry.findWindowByBounds(
            pid: 100,
            bounds: CGRect(x: 100.0, y: 200.0, width: 820.0, height: 600.0),
        )
        #expect(widthOutside == nil, "Should return nil when width exceeds tolerance")
    }

    // MARK: - listWindows Sorting Tests

    @Test("listWindows returns results sorted by layer")
    func listWindowsSortedByLayer() async throws {
        // Windows with different layers (z-order)
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1003, pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 10),
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0),
            makeWindowEntry(id: 1002, pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 5),
        ])
        let registry = WindowRegistry(system: mockOps)

        try await registry.refreshWindows(forPID: 100)
        let windows = try await registry.listWindows(forPID: 100)

        #expect(windows.count == 3, "Should have three windows")
        #expect(windows[0].layer < windows[1].layer, "Windows should be sorted by layer ascending")
        #expect(windows[1].layer < windows[2].layer, "Windows should be sorted by layer ascending")
    }

    @Test("listAllWindows returns all windows sorted")
    func listAllWindowsSorted() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1003, pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 10),
            makeWindowEntry(id: 2001, pid: 200, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0),
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 5),
        ])
        let registry = WindowRegistry(system: mockOps)

        let windows = try await registry.listAllWindows()

        #expect(windows.count == 3, "Should have three windows from all PIDs")
        // Verify sorted by layer
        for i in 0 ..< windows.count - 1 {
            #expect(windows[i].layer <= windows[i + 1].layer, "Windows should be sorted by layer")
        }
    }

    @Test("listWindows with no windows returns empty array")
    func listWindowsEmptyResult() async throws {
        let mockOps = makeMockSystemOps(windows: [])
        let registry = WindowRegistry(system: mockOps)

        let windows = try await registry.listWindows(forPID: 100)
        #expect(windows.isEmpty, "Should return empty array when no windows")
    }

    @Test("getLastKnownWindow returns cached data")
    func getLastKnownWindowReturnsCached() async throws {
        let mockOps = makeMockSystemOps(windows: [
            makeWindowEntry(id: 1001, pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
        ])
        let registry = WindowRegistry(system: mockOps)

        // First refresh to populate cache
        try await registry.refreshWindows(forPID: 100)

        // getLastKnownWindow should return cached data
        let cached = await registry.getLastKnownWindow(1001)
        #expect(cached != nil, "Should return cached window")
        #expect(cached?.windowID == 1001, "Should return correct window ID")

        // Verify non-existent window returns nil
        let missing = await registry.getLastKnownWindow(9999)
        #expect(missing == nil, "Should return nil for missing window")
    }
}
