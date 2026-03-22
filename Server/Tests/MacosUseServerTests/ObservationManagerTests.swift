import CoreGraphics
import Foundation
@testable import MacosUseServer
import Testing

/// Helper to create AXWindowSnapshot for tests
extension AXWindowSnapshot {
    static func testWindow(
        id: CGWindowID = 1001,
        title: String = "Test Window",
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        minimized: Bool = false,
        visible: Bool = true,
        focused: Bool? = nil,
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            windowID: id,
            title: title,
            bounds: bounds,
            minimized: minimized,
            visible: visible,
            focused: focused,
        )
    }
}

/// Unit tests for ObservationManager focusing on window change detection.
struct ObservationManagerTests {
    /// Tests that detectWindowChanges correctly identifies when a window is added.
    @Test
    func `Detects window creation`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = []
        let current: [AXWindowSnapshot] = [.testWindow(title: "New Window")]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.count == 1, "Should detect one window change")
        if case let .created(window) = changes.first {
            #expect(window.windowID == 1001, "Change should be for window 1001")
        } else {
            Issue.record("Expected .created change")
        }
    }

    /// Tests that detectWindowChanges correctly identifies when a window is removed.
    @Test
    func `Detects window destruction`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = [.testWindow(title: "Old Window")]
        let current: [AXWindowSnapshot] = []

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.count == 1, "Should detect one window change")
        if case let .destroyed(window) = changes.first {
            #expect(window.windowID == 1001, "Change should be for window 1001")
        } else {
            Issue.record("Expected .destroyed change")
        }
    }

    @Test
    func `Detects window minimization`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = [.testWindow(minimized: false)]
        let current: [AXWindowSnapshot] = [.testWindow(minimized: true)]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.count == 1, "Should detect one window change")
        if case let .minimized(window) = changes.first {
            #expect(window.windowID == 1001, "Change should be for window 1001")
        } else {
            Issue.record("Expected .minimized change")
        }
    }

    @Test
    func `Detects window restoration`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = [.testWindow(minimized: true)]
        let current: [AXWindowSnapshot] = [.testWindow(minimized: false)]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.count == 1, "Should detect one window change")
        if case let .restored(window) = changes.first {
            #expect(window.windowID == 1001, "Change should be for window 1001")
        } else {
            Issue.record("Expected .restored change")
        }
    }

    @Test
    func `Detects window movement`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = [.testWindow()]
        let current: [AXWindowSnapshot] = [.testWindow(bounds: CGRect(x: 100, y: 100, width: 800, height: 600))]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.count == 1, "Should detect one window change")
        if case let .moved(_, newWindow) = changes.first {
            #expect(newWindow.windowID == 1001, "Change should be for window 1001")
        } else {
            Issue.record("Expected .moved change")
        }
    }

    @Test
    func `Detects window resizing`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = [.testWindow()]
        let current: [AXWindowSnapshot] = [.testWindow(bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.count == 1, "Should detect one window change")
        if case let .resized(_, newWindow) = changes.first {
            #expect(newWindow.windowID == 1001, "Change should be for window 1001")
        } else {
            Issue.record("Expected .resized change")
        }
    }

    @Test
    func `No changes when windows unchanged`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        let previous: [AXWindowSnapshot] = [.testWindow()]
        let current: [AXWindowSnapshot] = [.testWindow()]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        #expect(changes.isEmpty, "Should detect no changes when windows are identical")
    }

    @Test
    func `Detects hidden window (not minimized)`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())
        // Start visible, not minimized
        let previous: [AXWindowSnapshot] = [.testWindow(minimized: false, visible: true)]
        // Becomes hidden (Cmd+H simulation) - NOT minimized
        let current: [AXWindowSnapshot] = [.testWindow(minimized: false, visible: false)]

        let changes = manager.detectWindowChanges(previous: previous, current: current)

        // CRITICAL: The change detection should recognize this as a visibility change
        // NOT a minimization. The visible field changed, minimized stayed false.
        #expect(changes.count >= 1, "Should detect at least one change when window becomes hidden")

        // Verify no .minimized event is emitted
        let hasMinimizedEvent = changes.contains { change in
            if case .minimized = change { return true }
            return false
        }
        #expect(hasMinimizedEvent == false, "MUST NOT emit .minimized when window is hidden (kAXHiddenAttribute)")
    }

    @Test
    func `Distinguishes minimized from hidden`() {
        let manager = ObservationManager(windowRegistry: WindowRegistry())

        // Scenario 1: Window becomes minimized (minimized=true, visible=false)
        let prev1: [AXWindowSnapshot] = [.testWindow(id: 1, minimized: false, visible: true)]
        let curr1: [AXWindowSnapshot] = [.testWindow(id: 1, minimized: true, visible: false)]
        let changes1 = manager.detectWindowChanges(previous: prev1, current: curr1)

        let hasMinimized1 = changes1.contains { if case .minimized = $0 { return true }; return false }
        #expect(hasMinimized1 == true, "MUST emit .minimized when minimized attribute changes to true")

        // Scenario 2: Window becomes hidden (minimized=false, visible=false)
        // This simulates Cmd+H where kAXHiddenAttribute=true but kAXMinimizedAttribute=false
        let prev2: [AXWindowSnapshot] = [.testWindow(id: 2, minimized: false, visible: true)]
        let curr2: [AXWindowSnapshot] = [.testWindow(id: 2, minimized: false, visible: false)]
        let changes2 = manager.detectWindowChanges(previous: prev2, current: curr2)

        let hasMinimized2 = changes2.contains { if case .minimized = $0 { return true }; return false }
        #expect(hasMinimized2 == false, "MUST NOT emit .minimized when only visibility changes (hidden, not minimized)")
    }
}
