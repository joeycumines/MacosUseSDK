import CoreGraphics
@testable import ExactMacServer
import Foundation
import GRPCCore
import Testing

struct WindowRegistryDITests {
    final class MockSystemOperations: SystemOperations {
        var windowList: [[String: Any]]

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

    @Test
    func `refreshWindows and listAllWindows uses injected system data`() async throws {
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

    @Test
    func `listWindows filters by PID`() async throws {
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

    @Test
    func `getWindow returns the expected info`() async throws {
        let dict = WindowRegistryDITests.makeWindowDict(windowID: 99, ownerPID: 7, x: 1, y: 2, w: 3, h: 4, title: "Z", layer: 5, isOnScreen: false)
        let mock = MockSystemOperations(windowList: [dict])

        let registry = WindowRegistry(system: mock)

        try await registry.refreshWindows()

        let info = try await registry.getWindow(99)
        #expect(info != nil, "getWindow should return an entry")
        #expect(info?.windowID == 99, "WindowID should match the mocked value")
        #expect(info?.ownerPID == 7, "Owner PID should match the mocked value")
    }

    @Test
    func `malformed owner geometry fails without replacing the last valid snapshot`() async throws {
        let initial = WindowRegistryDITests.makeWindowDict(
            windowID: 99,
            ownerPID: 7,
            x: 1,
            y: 2,
            w: 300,
            h: 200,
            title: "Stable",
            layer: 5,
            isOnScreen: true,
        )
        let mock = MockSystemOperations(windowList: [initial])
        let registry = WindowRegistry(system: mock)
        try await registry.refreshWindows(forPID: 7)

        let malformedBounds: [[String: Any]] = [
            ["X": 1.0, "Y": 2.0, "Height": 200.0],
            ["X": Double.infinity, "Y": 2.0, "Width": 300.0, "Height": 200.0],
            ["X": 1.0, "Y": 2.0, "Width": -1.0, "Height": 200.0],
            [
                "X": Double.greatestFiniteMagnitude,
                "Y": 2.0,
                "Width": Double.greatestFiniteMagnitude,
                "Height": 200.0,
            ],
        ]

        for bounds in malformedBounds {
            var malformed = initial
            malformed[kCGWindowBounds as String] = bounds
            mock.windowList = [malformed]
            do {
                try await registry.refreshWindows(forPID: 7)
                Issue.record("Malformed owner bounds were published: \(bounds)")
            } catch let error as RPCError {
                #expect(error.code == .unavailable)
            } catch {
                Issue.record("Malformed owner bounds returned a non-RPC error: \(error)")
            }

            let retained = await registry.getLastKnownWindow(99, ownerPID: 7)
            #expect(retained?.bounds == CGRect(x: 1, y: 2, width: 300, height: 200))
        }
    }

    @Test
    func `duplicate owner window IDs fail the complete snapshot`() async throws {
        let first = WindowRegistryDITests.makeWindowDict(
            windowID: 99,
            ownerPID: 7,
            x: 1,
            y: 2,
            w: 300,
            h: 200,
            title: "First",
            layer: 5,
            isOnScreen: true,
        )
        let second = WindowRegistryDITests.makeWindowDict(
            windowID: 99,
            ownerPID: 7,
            x: 50,
            y: 60,
            w: 700,
            h: 500,
            title: "Second",
            layer: 6,
            isOnScreen: true,
        )
        let registry = WindowRegistry(system: MockSystemOperations(windowList: [first, second]))

        do {
            try await registry.refreshWindows(forPID: 7)
            Issue.record("Duplicate owner window IDs were collapsed into one arbitrary row")
        } catch let error as RPCError {
            #expect(error.code == .unavailable)
        } catch {
            Issue.record("Duplicate owner window IDs returned a non-RPC error: \(error)")
        }
        #expect(await registry.getLastKnownWindow(99, ownerPID: 7) == nil)
    }

    @Test
    func `zero-sized finite window geometry remains representable`() async throws {
        let zeroSized = WindowRegistryDITests.makeWindowDict(
            windowID: 99,
            ownerPID: 7,
            x: -100,
            y: -200,
            w: 0,
            h: 0,
            title: "Zero",
            layer: 5,
            isOnScreen: false,
        )
        let registry = WindowRegistry(system: MockSystemOperations(windowList: [zeroSized]))

        try await registry.refreshWindows(forPID: 7)
        #expect(await registry.getLastKnownWindow(99, ownerPID: 7)?.bounds == CGRect(x: -100, y: -200, width: 0, height: 0))
    }
}

extension WindowRegistryDITests.MockSystemOperations: @unchecked Sendable {}
