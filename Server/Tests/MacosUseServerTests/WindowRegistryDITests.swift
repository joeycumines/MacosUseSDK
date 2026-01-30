import CoreGraphics
import Foundation
@testable import MacosUseServer
import Testing

@Suite("WindowRegistry DI Tests")
struct WindowRegistryDITests {
    final class MockSystemOperations: SystemOperations {
        let windowList: [[String: Any]]

        init(windowList: [[String: Any]] = []) {
            self.windowList = windowList
        }

        func cgWindowListCopyWindowInfo(options _: CGWindowListOption, relativeToWindow _: CGWindowID) -> [[String: Any]] {
            windowList
        }

        func getRunningApplicationBundleID(pid _: pid_t) -> String? {
            "com.example.test"
        }

        func createAXApplication(pid _: Int32) -> AnyObject? {
            nil
        }

        func copyAXAttribute(element _: AnyObject, attribute _: String) -> Any? {
            nil
        }

        func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
            nil
        }

        func setAXAttribute(element _: AnyObject, attribute _: String, value _: Any) -> Int32 {
            1
        }

        func performAXAction(element _: AnyObject, action _: String) -> Int32 {
            1
        }

        func getAXWindowID(element _: AnyObject) -> CGWindowID? {
            nil
        }

        func fetchAXWindowInfo(pid _: Int32, windowId _: CGWindowID, expectedBounds _: CGRect) -> WindowInfoResult? {
            nil
        }
    }

    static func makeWindowDict(windowID: CGWindowID, ownerPID: pid_t, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, title: String, layer: Int32, isOnScreen: Bool) -> [String: Any] {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
            kCGWindowName as String: title,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: isOnScreen,
        ]
    }

    @Test("refreshWindows and listAllWindows uses injected system data")
    func refreshAndListAll() async throws {
        let dict = WindowRegistryDITests.makeWindowDict(windowID: 100, ownerPID: 42, x: 0, y: 0, w: 100, h: 100, title: "MockWindow", layer: 0, isOnScreen: true)
        let mock = MockSystemOperations(windowList: [dict])

        let registry = WindowRegistry(system: mock)

        try await registry.refreshWindows()
        let allWindows = try await registry.listAllWindows()

        #expect(allWindows.count == 1, "Expected one window in registry")
        if let info = allWindows.first {
            #expect(info.windowID == 100, "WindowID should match")
            #expect(info.ownerPID == 42, "Owner PID should match")
            #expect(info.isOnScreen == true, "isOnScreen should be true")
            #expect(info.title == "MockWindow", "Title should match")
        }
    }

    @Test("listWindows filters by PID")
    func listByPID() async throws {
        let dictA = WindowRegistryDITests.makeWindowDict(windowID: 1, ownerPID: 10, x: 0, y: 0, w: 10, h: 10, title: "A", layer: 1, isOnScreen: true)
        let dictB = WindowRegistryDITests.makeWindowDict(windowID: 2, ownerPID: 20, x: 0, y: 0, w: 10, h: 10, title: "B", layer: 2, isOnScreen: false)
        let mock = MockSystemOperations(windowList: [dictA, dictB])

        let registry = WindowRegistry(system: mock)

        try await registry.refreshWindows()

        let pid10Wins = try await registry.listWindows(forPID: 10)
        let pid20Wins = try await registry.listWindows(forPID: 20)

        #expect(pid10Wins.count == 1, "Expected one window for PID 10")
        #expect(pid20Wins.count == 1, "Expected one window for PID 20")
    }

    @Test("getWindow returns the expected info")
    func getWindowInfo() async throws {
        let dict = WindowRegistryDITests.makeWindowDict(windowID: 99, ownerPID: 7, x: 1, y: 2, w: 3, h: 4, title: "Z", layer: 5, isOnScreen: false)
        let mock = MockSystemOperations(windowList: [dict])

        let registry = WindowRegistry(system: mock)

        try await registry.refreshWindows()

        let info = try await registry.getWindow(99)
        #expect(info != nil, "getWindow should return an entry")
        #expect(info?.windowID == 99, "WindowID should match the mocked value")
        #expect(info?.ownerPID == 7, "Owner PID should match the mocked value")
    }
}

extension WindowRegistryDITests.MockSystemOperations: @unchecked Sendable {}
