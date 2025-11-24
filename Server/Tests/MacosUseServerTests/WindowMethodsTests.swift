import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import Testing

@testable import MacosUseProto
@testable import MacosUseServer

@Suite("Window Methods Tests")
struct WindowMethodsTests {
    func makeCGDict(windowID: CGWindowID, pid: pid_t, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, title: String) -> [String: Any] {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
            kCGWindowName as String: title,
            kCGWindowLayer as String: 0,
            kCGWindowIsOnscreen as String: true,
        ]
    }

    @Test("listWindows returns registry data")
    func listWindowsReturnsRegistry() async throws {
        let pid: pid_t = 123
        let cg = makeCGDict(windowID: 42, pid: pid, x: 1, y: 2, w: 100, h: 50, title: "CGWindow")
        let mock = MockSystemOperations(cgWindowList: [cg])

        let registry = WindowRegistry(system: mock)
        try await registry.refreshWindows()

        // Use registry directly — listWindows is a thin wrapper over registry data.
        let wins = try await registry.listWindows(forPID: pid)
        #expect(wins.count == 1, "Expected one window from listWindows")
        #expect(wins.first?.title == "CGWindow", "Title should come from registry data")
    }

    @Test("getWindow uses AX fetch to get authoritative data")
    func getWindowUsesAXFetch() async throws {
        let pid: pid_t = 555
        let winID: CGWindowID = 777

        let cg = makeCGDict(windowID: winID, pid: pid, x: 10, y: 10, w: 200, h: 100, title: "CGOnly")

        // Create a real AX element via AXUIElementCreateApplication so unsafeDowncast works
        let axElement = AXUIElementCreateApplication(pid)
        let axResult = WindowInfoResult(element: axElement as AnyObject, bounds: CGRect(x: 15, y: 15, width: 150, height: 80), title: "AXTitle", minimized: false, hidden: false, focused: true)

        let mock = MockSystemOperations(cgWindowList: [cg], axWindowInfos: ["\(pid):\(winID)": axResult])

        let registry = WindowRegistry(system: mock)
        try await registry.refreshWindows()

        let provider = MacosUseService(stateStore: AppStateStore(), operationStore: OperationStore(), windowRegistry: registry, system: mock)

        let element = try await provider.findWindowElement(pid: pid, windowId: winID)
        let response = try await provider.buildWindowResponseFromAX(name: "applications/\(pid):\(winID)", pid: pid, windowId: winID, window: element, registryInfo: nil)

        let msg = try response.message
        #expect(msg.visible == true, "Window visible should be derived from AX data")
    }

    @Test("Hybrid Authority: GetWindow AX-authoritative for minimized state")
    func hybridAuthorityGetWindowMinimized() async throws {
        let pid: pid_t = 888
        let winID: CGWindowID = 999

        // Registry (CG) says: isOnScreen = true
        let cg = makeCGDict(windowID: winID, pid: pid, x: 0, y: 0, w: 100, h: 100, title: "Test")

        // AX says: minimized = true (authoritative)
        let axElement = AXUIElementCreateApplication(pid)
        let axResult = WindowInfoResult(element: axElement as AnyObject, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), title: "Test", minimized: true, hidden: false, focused: false)

        let mock = MockSystemOperations(cgWindowList: [cg], axWindowInfos: ["\(pid):\(winID)": axResult])

        let registry = WindowRegistry(system: mock)
        try await registry.refreshWindows()

        // Get registry metadata to pass to buildWindowResponseFromAX
        let registryInfo = try await registry.getWindow(winID)

        let provider = MacosUseService(stateStore: AppStateStore(), operationStore: OperationStore(), windowRegistry: registry, system: mock)

        let element = try await provider.findWindowElement(pid: pid, windowId: winID)
        let response = try await provider.buildWindowResponseFromAX(name: "applications/\(pid)/windows/\(winID)", pid: pid, windowId: winID, window: element, registryInfo: registryInfo)

        let msg = try response.message
        #expect(msg.visible == false, "GetWindow MUST return visible=false when AX says minimized=true (AX trumps Registry)")
    }

    @Test("Hybrid Authority: GetWindow AX-authoritative for hidden state")
    func hybridAuthorityGetWindowHidden() async throws {
        let pid: pid_t = 111
        let winID: CGWindowID = 222

        // Registry (CG) says: isOnScreen = true
        let cg = makeCGDict(windowID: winID, pid: pid, x: 0, y: 0, w: 100, h: 100, title: "Test")

        // AX says: hidden = true (authoritative)
        let axElement = AXUIElementCreateApplication(pid)
        let axResult = WindowInfoResult(element: axElement as AnyObject, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), title: "Test", minimized: false, hidden: true, focused: false)

        let mock = MockSystemOperations(cgWindowList: [cg], axWindowInfos: ["\(pid):\(winID)": axResult])

        let registry = WindowRegistry(system: mock)
        try await registry.refreshWindows()

        // Get registry metadata to pass to buildWindowResponseFromAX
        let registryInfo = try await registry.getWindow(winID)

        let provider = MacosUseService(stateStore: AppStateStore(), operationStore: OperationStore(), windowRegistry: registry, system: mock)

        let element = try await provider.findWindowElement(pid: pid, windowId: winID)
        let response = try await provider.buildWindowResponseFromAX(name: "applications/\(pid)/windows/\(winID)", pid: pid, windowId: winID, window: element, registryInfo: registryInfo)

        let msg = try response.message
        #expect(msg.visible == false, "GetWindow MUST return visible=false when AX says hidden=true (AX trumps Registry)")
    }

    @Test("Race condition handling: fetchAXWindowInfo returns nil")
    func raceConditionNotFound() async throws {
        let pid: pid_t = 333
        let winID: CGWindowID = 444

        // Registry has window
        let cg = makeCGDict(windowID: winID, pid: pid, x: 0, y: 0, w: 100, h: 100, title: "Test")

        // AX fetch returns nil (simulating race/not found)
        let mock = MockSystemOperations(cgWindowList: [cg], axWindowInfos: [:])

        let registry = WindowRegistry(system: mock)
        try await registry.refreshWindows()

        let provider = MacosUseService(stateStore: AppStateStore(), operationStore: OperationStore(), windowRegistry: registry, system: mock)

        // findWindowElement should throw NOT_FOUND when AX fetch fails
        await #expect(throws: (any Error).self) {
            _ = try await provider.findWindowElement(pid: pid, windowId: winID)
        }
    }
}
