import ApplicationServices
import CoreGraphics
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct WindowReadTruthContractGRPCTests {
    @Test
    func `GetWindow reads application hidden state and preserves a legitimate empty title`() async throws {
        let fixture = await makeWindowReadTruthFixture()
        fixture.system.setAttributeRead(
            element: .window,
            attribute: kAXTitleAttribute as String,
            error: .noValue,
        )

        try await withWindowReadTruthClient(fixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            let window: Exactmac_V1_Window = try await windowReadTruthUnary(
                client: client,
                request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
            )

            #expect(window.title.isEmpty)
            #expect(window.visible)
            #expect(fixture.system.readCount(element: .application, attribute: kAXHiddenAttribute as String) == 1)
            #expect(fixture.system.readCount(element: .window, attribute: kAXHiddenAttribute as String) == 0)
        }
    }

    @Test
    func `GetWindow rejects transient and wrong-type title reads`() async throws {
        for read in [
            WindowReadTruthOverride(error: .cannotComplete),
            WindowReadTruthOverride(error: .success, value: NSNumber(value: 7)),
        ] {
            let fixture = await makeWindowReadTruthFixture()
            fixture.system.setAttributeRead(
                element: .window,
                attribute: kAXTitleAttribute as String,
                errorCode: read.errorCode,
                value: read.value,
            )

            try await withWindowReadTruthClient(fixture.composition) { client in
                let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
                let name = try #require(listed.windows.first?.name)
                await expectWindowReadTruthRPCError(.unavailable) {
                    let _: Exactmac_V1_Window = try await windowReadTruthUnary(
                        client: client,
                        request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                        descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                    )
                }
            }
        }
    }

    @Test
    func `GetWindow rejects unreadable visibility operands rather than fabricating success`() async throws {
        let cases: [(WindowReadTruthElement, String, WindowReadTruthOverride)] = [
            (.window, kAXMinimizedAttribute as String, .init(error: .cannotComplete)),
            (.window, kAXMinimizedAttribute as String, .init(error: .success, value: "false" as NSString)),
            (.application, kAXHiddenAttribute as String, .init(error: .cannotComplete)),
            (.application, kAXHiddenAttribute as String, .init(error: .success, value: "false" as NSString)),
        ]

        for (element, attribute, read) in cases {
            let fixture = await makeWindowReadTruthFixture()
            fixture.system.setAttributeRead(
                element: element,
                attribute: attribute,
                errorCode: read.errorCode,
                value: read.value,
            )

            try await withWindowReadTruthClient(fixture.composition) { client in
                let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
                let name = try #require(listed.windows.first?.name)
                await expectWindowReadTruthRPCError(.unavailable) {
                    let _: Exactmac_V1_Window = try await windowReadTruthUnary(
                        client: client,
                        request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                        descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                    )
                }
            }
        }
    }

    @Test
    func `GetWindow accepts unsupported optional visibility operands as false`() async throws {
        let fixture = await makeWindowReadTruthFixture()
        fixture.system.setAttributeRead(
            element: .window,
            attribute: kAXMinimizedAttribute as String,
            error: .attributeUnsupported,
        )
        fixture.system.setAttributeRead(
            element: .application,
            attribute: kAXHiddenAttribute as String,
            error: .noValue,
        )

        try await withWindowReadTruthClient(fixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            let window: Exactmac_V1_Window = try await windowReadTruthUnary(
                client: client,
                request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
            )
            #expect(window.visible)
        }
    }

    @Test
    func `GetWindowState derives the exact injected capability matrix`() async throws {
        let fixture = await makeWindowReadTruthFixture()
        fixture.system.setAttributeRead(
            element: .window,
            attribute: kAXSubroleAttribute as String,
            error: .success,
            value: kAXSystemFloatingWindowSubrole as String,
        )

        try await withWindowReadTruthClient(fixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            let state: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                client: client,
                request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
            )

            #expect(state.name == "\(name)/state")
            #expect(state.resizable)
            #expect(state.minimizable)
            #expect(state.closable)
            #expect(!state.modal)
            #expect(state.floating)
            #expect(!state.axHidden)
            #expect(!state.minimized)
            #expect(state.focused)
            #expect(fixture.system.settableReadCount(attribute: kAXSizeAttribute as String) == 1)
            #expect(fixture.system.readCount(element: .application, attribute: kAXHiddenAttribute as String) == 1)
            #expect(fixture.system.readCount(element: .window, attribute: kAXHiddenAttribute as String) == 0)
        }
    }

    @Test
    func `GetWindowState uses exact subrole values rather than substring matches`() async throws {
        let cases: [(String, Bool, Bool)] = [
            (kAXDialogSubrole as String, true, false),
            (kAXSystemDialogSubrole as String, true, false),
            (kAXFloatingWindowSubrole as String, false, true),
            (kAXSystemFloatingWindowSubrole as String, false, true),
            ("AXNotReallyDialogOrFloatingWindow", false, false),
        ]

        for (subrole, expectedModal, expectedFloating) in cases {
            let fixture = await makeWindowReadTruthFixture()
            fixture.system.setAttributeRead(
                element: .window,
                attribute: kAXSubroleAttribute as String,
                error: .success,
                value: subrole,
            )

            try await withWindowReadTruthClient(fixture.composition) { client in
                let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
                let name = try #require(listed.windows.first?.name)
                let state: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
                )
                #expect(state.modal == expectedModal, Comment(rawValue: subrole))
                #expect(state.floating == expectedFloating, Comment(rawValue: subrole))
            }
        }
    }

    @Test
    func `GetWindowState distinguishes optional absence from unreadable capability state`() async throws {
        let optionalFixture = await makeWindowReadTruthFixture()
        optionalFixture.system.setAttributeRead(
            element: .window,
            attribute: kAXMinimizeButtonAttribute as String,
            error: .attributeUnsupported,
        )
        optionalFixture.system.setAttributeRead(
            element: .window,
            attribute: kAXCloseButtonAttribute as String,
            error: .noValue,
        )
        optionalFixture.system.setAttributeRead(
            element: .window,
            attribute: kAXSubroleAttribute as String,
            error: .attributeUnsupported,
        )

        try await withWindowReadTruthClient(optionalFixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: optionalFixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            let state: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                client: client,
                request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
            )
            #expect(!state.minimizable)
            #expect(!state.closable)
            #expect(!state.floating)
        }

        let unreadableCases: [(String, WindowReadTruthOverride)] = [
            (kAXMinimizeButtonAttribute as String, .init(error: .cannotComplete)),
            (kAXCloseButtonAttribute as String, .init(error: .success, value: "not-an-element" as NSString)),
            (kAXSubroleAttribute as String, .init(error: .success, value: NSNumber(value: 1))),
        ]
        for (attribute, read) in unreadableCases {
            let fixture = await makeWindowReadTruthFixture()
            fixture.system.setAttributeRead(
                element: .window,
                attribute: attribute,
                errorCode: read.errorCode,
                value: read.value,
            )
            try await withWindowReadTruthClient(fixture.composition) { client in
                let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
                let name = try #require(listed.windows.first?.name)
                await expectWindowReadTruthRPCError(.unavailable) {
                    let _: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                        client: client,
                        request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                        descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
                    )
                }
            }
        }
    }

    @Test
    func `GetWindowState maps exact AX failures without returning false defaults`() async throws {
        let cases: [(AXError, RPCError.Code)] = [
            (.invalidUIElement, .notFound),
            (.apiDisabled, .permissionDenied),
            (.cannotComplete, .unavailable),
        ]

        for (axError, rpcCode) in cases {
            let fixture = await makeWindowReadTruthFixture()
            fixture.system.setAttributeRead(
                element: .window,
                attribute: kAXMainAttribute as String,
                error: axError,
            )
            try await withWindowReadTruthClient(fixture.composition) { client in
                let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
                let name = try #require(listed.windows.first?.name)
                await expectWindowReadTruthRPCError(rpcCode) {
                    let _: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                        client: client,
                        request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                        descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
                    )
                }
            }
        }
    }

    @Test
    func `GetWindowState fails when AX size settable state is unavailable`() async throws {
        let fixture = await makeWindowReadTruthFixture()
        fixture.system.setSettableRead(error: .cannotComplete, settable: false)

        try await withWindowReadTruthClient(fixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            await expectWindowReadTruthRPCError(.unavailable) {
                let _: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
                )
            }
        }
    }

    @Test
    func `process replacement during GetWindow read cannot update the admitted binding`() async throws {
        let fixture = await makeWindowReadTruthFixture()

        try await withWindowReadTruthClient(fixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            let resourceID = try #require(name.split(separator: "/").last.map(String.init))
            fixture.system.replaceOwnerAndWindowID(onLookup: 2, windowID: 909)

            await expectWindowReadTruthRPCError(.notFound) {
                let _: Exactmac_V1_Window = try await windowReadTruthUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                )
            }

            let binding = await fixture.composition.windowRegistry.resolveWindowBinding(
                resourceID: resourceID,
                applicationName: fixture.applicationName,
                pid: fixture.identity.pid,
                processIdentity: fixture.identity,
            )
            #expect(binding?.windowID == 101)
        }
    }

    @Test
    func `caller cancellation owns a blocked GetWindowState read`() async throws {
        let fixture = await makeWindowReadTruthFixture()

        try await withWindowReadTruthClient(fixture.composition) { client in
            let listed = try await listWindowReadTruthWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            fixture.system.blockNextRead(element: .window, attribute: kAXMainAttribute as String)

            let read = Task {
                let _: Exactmac_V1_WindowState = try await windowReadTruthUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowStateRequest.with { $0.name = "\(name)/state" },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindowState.descriptor,
                )
            }
            let entered = try await fixture.system.waitForBlockedRead()
            #expect(entered)
            read.cancel()
            fixture.system.releaseBlockedRead()

            do {
                try await read.value
                Issue.record("Expected cancelled GetWindowState read")
            } catch is CancellationError {
                // Expected direct caller cancellation.
            } catch let error as RPCError {
                if error.code == .unknown {
                    #expect(error.cause is CancellationError, Comment(rawValue: String(describing: error)))
                } else {
                    #expect(error.code == .cancelled, Comment(rawValue: String(describing: error)))
                }
            }
            // The blocked read clears `blockedReadActive` only after the
            // semaphore release propagates and the read task resumes through
            // its post-wait cleanup. That handoff is asynchronous, so under
            // heavy parallel test load the flag may still be true for a brief
            // window when the cancelled task settles. PollUntil the flag
            // clears (mirroring waitForBlockedRead) instead of asserting it
            // instantly — a real leak would never clear within the deadline.
            let clearClock = ContinuousClock()
            let clearDeadline = clearClock.now.advanced(by: .milliseconds(500))
            while clearClock.now < clearDeadline, fixture.system.blockedReadIsActive() {
                await Task.yield()
            }
            #expect(!fixture.system.blockedReadIsActive())
        }
    }
}

private struct WindowReadTruthFixture {
    let applicationName: String
    let identity: ApplicationProcessIdentity
    let composition: ExactMacServiceComposition
    let system: WindowReadTruthSystemOperations
}

private func makeWindowReadTruthFixture() async -> WindowReadTruthFixture {
    let identity = ApplicationProcessIdentity(
        pid: 5101,
        startTimeSeconds: 50,
        startTimeMicroseconds: 100,
        bundleIdentifier: "com.example.window-read-truth",
        executablePath: "/Applications/WindowReadTruth.app/Contents/MacOS/WindowReadTruth",
    )
    let applicationName = applicationResourceName(for: identity)
    let stateStore = AppStateStore()
    let system = WindowReadTruthSystemOperations(identity: identity)
    let composition = ExactMacServiceComposition(stateStore: stateStore, system: system)
    await stateStore.addTarget(
        Exactmac_V1_Application.with {
            $0.name = applicationName
            $0.pid = identity.pid
        },
        processIdentity: identity,
    )
    return WindowReadTruthFixture(
        applicationName: applicationName,
        identity: identity,
        composition: composition,
        system: system,
    )
}

private func withWindowReadTruthClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let inProcess = InProcessTransport()
    let server = GRPCServer(transport: inProcess.server, services: [composition.exactMacService])
    let client = GRPCClient(transport: inProcess.client)
    try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await server.serve() }
        group.addTask { try await client.runConnections() }
        defer {
            client.beginGracefulShutdown()
            server.beginGracefulShutdown()
        }
        try await operation(client)
    }
}

private func listWindowReadTruthWindows(
    client: GRPCClient<InProcessTransport.Client>,
    parent: String,
) async throws -> Exactmac_V1_ListWindowsResponse {
    try await windowReadTruthUnary(
        client: client,
        request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
        descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
    )
}

private func windowReadTruthUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: .defaults,
    ) { response in
        try response.message
    }
}

private func expectWindowReadTruthRPCError(
    _ expectedCode: RPCError.Code,
    operation: () async throws -> Void,
) async {
    do {
        try await operation()
        Issue.record("Expected RPC error \(expectedCode)")
    } catch let error as RPCError {
        #expect(error.code == expectedCode, Comment(rawValue: String(describing: error)))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }
}

private enum WindowReadTruthElement: Hashable, Sendable {
    case application
    case window
}

private struct WindowReadTruthOverride: @unchecked Sendable {
    let errorCode: Int32
    let value: Any?

    init(error: AXError, value: Any? = nil) {
        errorCode = error.rawValue
        self.value = value
    }

    init(errorCode: Int32, value: Any?) {
        self.errorCode = errorCode
        self.value = value
    }
}

private final class WindowReadTruthSystemOperations: SystemOperations, @unchecked Sendable {
    private struct ReadKey: Hashable {
        let element: WindowReadTruthElement
        let attribute: String
    }

    private struct State {
        var identity: ApplicationProcessIdentity
        var windowID: CGWindowID = 101
        var overrides: [ReadKey: WindowReadTruthOverride] = [:]
        var readCounts: [ReadKey: Int] = [:]
        var settableErrorCode = AXError.success.rawValue
        var settable = true
        var settableReadCounts: [String: Int] = [:]
        var windowIDLookupCount = 0
        var replacementLookup: Int?
        var replacementWindowID: CGWindowID?
        var blockedKey: ReadKey?
        var blockedReadActive = false
    }

    private let lock = NSLock()
    private let blockedReadRelease = DispatchSemaphore(value: 0)
    private let applicationElement: AXUIElement
    private let windowElement: AXUIElement
    private let minimizeButton: AXUIElement
    private let closeButton: AXUIElement
    private var state: State

    init(identity: ApplicationProcessIdentity) {
        applicationElement = AXUIElementCreateApplication(identity.pid)
        windowElement = AXUIElementCreateApplication(identity.pid + 1)
        minimizeButton = AXUIElementCreateApplication(identity.pid + 2)
        closeButton = AXUIElementCreateApplication(identity.pid + 3)
        state = State(identity: identity)
    }

    func setAttributeRead(
        element: WindowReadTruthElement,
        attribute: String,
        error: AXError,
        value: Any? = nil,
    ) {
        setAttributeRead(
            element: element,
            attribute: attribute,
            errorCode: error.rawValue,
            value: value,
        )
    }

    func setAttributeRead(
        element: WindowReadTruthElement,
        attribute: String,
        errorCode: Int32,
        value: Any?,
    ) {
        withState {
            $0.overrides[ReadKey(element: element, attribute: attribute)] = .init(
                errorCode: errorCode,
                value: value,
            )
        }
    }

    func setSettableRead(error: AXError, settable: Bool) {
        withState {
            $0.settableErrorCode = error.rawValue
            $0.settable = settable
        }
    }

    func replaceOwnerAndWindowID(onLookup: Int, windowID: CGWindowID) {
        withState {
            $0.replacementLookup = onLookup
            $0.replacementWindowID = windowID
        }
    }

    func blockNextRead(element: WindowReadTruthElement, attribute: String) {
        withState {
            $0.blockedKey = ReadKey(element: element, attribute: attribute)
        }
    }

    func waitForBlockedRead() async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while clock.now < deadline {
            if blockedReadIsActive() {
                return true
            }
            await Task.yield()
        }
        return blockedReadIsActive()
    }

    func releaseBlockedRead() {
        blockedReadRelease.signal()
    }

    func blockedReadIsActive() -> Bool {
        withState { $0.blockedReadActive }
    }

    func readCount(element: WindowReadTruthElement, attribute: String) -> Int {
        withState { $0.readCounts[ReadKey(element: element, attribute: attribute), default: 0] }
    }

    func settableReadCount(attribute: String) -> Int {
        withState { $0.settableReadCounts[attribute, default: 0] }
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        withState { state in
            [[
                kCGWindowNumber as String: state.windowID,
                kCGWindowOwnerPID as String: state.identity.pid,
                kCGWindowBounds as String: [
                    "X": CGFloat(10),
                    "Y": CGFloat(20),
                    "Width": CGFloat(640),
                    "Height": CGFloat(480),
                ],
                kCGWindowName as String: "Truth Window",
                kCGWindowLayer as String: Int32(0),
                kCGWindowIsOnscreen as String: true,
            ]]
        }
    }

    func getRunningApplicationBundleID(pid _: pid_t) -> String? {
        "com.example.window-read-truth"
    }

    func applicationProcessIdentity(pid: pid_t) -> ApplicationProcessIdentity? {
        withState { $0.identity.pid == pid ? $0.identity : nil }
    }

    func isProcessRunning(pid: pid_t) -> Bool {
        withState { $0.identity.pid == pid }
    }

    func isApplicationProcessRunning(_ identity: ApplicationProcessIdentity) -> Bool {
        withState { $0.identity == identity }
    }

    func requestApplicationActivation(_: ApplicationProcessIdentity) -> Bool {
        false
    }

    func requestApplicationTermination(_: ApplicationProcessIdentity, force _: Bool) -> Bool {
        false
    }

    func createAXApplication(pid: Int32) -> AnyObject? {
        withState { $0.identity.pid == pid ? applicationElement : nil }
    }

    func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        let read = copyAXAttributeResult(element: element, attribute: attribute)
        guard read.errorCode == AXError.success.rawValue else {
            return nil
        }
        return read.value
    }

    func copyAXAttributeResult(element: AnyObject, attribute: String) -> AXAttributeRead {
        let elementKind = kind(of: element)
        let key = ReadKey(element: elementKind, attribute: attribute)
        let shouldBlock = withState { state in
            state.readCounts[key, default: 0] += 1
            guard state.blockedKey == key else {
                return false
            }
            state.blockedKey = nil
            state.blockedReadActive = true
            return true
        }
        if shouldBlock {
            blockedReadRelease.wait()
            withState { $0.blockedReadActive = false }
        }

        return withState { state in
            if let override = state.overrides[key] {
                return AXAttributeRead(errorCode: override.errorCode, value: override.value)
            }
            return defaultAttributeRead(element: elementKind, attribute: attribute, state: state)
        }
    }

    func isAXAttributeSettable(element _: AnyObject, attribute: String) -> AXAttributeSettableRead {
        withState { state in
            state.settableReadCounts[attribute, default: 0] += 1
            return AXAttributeSettableRead(
                errorCode: state.settableErrorCode,
                settable: state.settable,
            )
        }
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element _: AnyObject, attribute _: String, value _: Any) -> Int32 {
        AXError.attributeUnsupported.rawValue
    }

    func performAXAction(element _: AnyObject, action _: String) -> Int32 {
        AXError.actionUnsupported.rawValue
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        guard kind(of: element) == .window else {
            return nil
        }
        return withState { state in
            state.windowIDLookupCount += 1
            if state.replacementLookup == state.windowIDLookupCount,
               let replacementWindowID = state.replacementWindowID
            {
                state.windowID = replacementWindowID
                state.identity = ApplicationProcessIdentity(
                    pid: state.identity.pid,
                    startTimeSeconds: state.identity.startTimeSeconds + 1,
                    startTimeMicroseconds: state.identity.startTimeMicroseconds,
                    bundleIdentifier: state.identity.bundleIdentifier,
                    executablePath: state.identity.executablePath,
                )
            }
            return state.windowID
        }
    }

    private func kind(of element: AnyObject) -> WindowReadTruthElement {
        ObjectIdentifier(element) == ObjectIdentifier(applicationElement) ? .application : .window
    }

    private func defaultAttributeRead(
        element: WindowReadTruthElement,
        attribute: String,
        state: State,
    ) -> AXAttributeRead {
        if element == .application {
            switch attribute {
            case "AXWindows", "AXChildren":
                return .init(errorCode: AXError.success.rawValue, value: [windowElement])
            case "AXHidden":
                return .init(errorCode: AXError.success.rawValue, value: false)
            default:
                return .init(errorCode: AXError.attributeUnsupported.rawValue, value: nil)
            }
        }

        switch attribute {
        case "AXRole":
            return .init(errorCode: AXError.success.rawValue, value: kAXWindowRole as String)
        case "AXTitle":
            return .init(errorCode: AXError.success.rawValue, value: "Truth Window")
        case "AXPosition":
            var position = CGPoint(x: 10, y: 20)
            return .init(errorCode: AXError.success.rawValue, value: AXValueCreate(.cgPoint, &position))
        case "AXSize":
            var size = CGSize(width: 640, height: 480)
            return .init(errorCode: AXError.success.rawValue, value: AXValueCreate(.cgSize, &size))
        case "AXMinimized":
            return .init(errorCode: AXError.success.rawValue, value: false)
        case "AXMain", "AXFocused":
            return .init(errorCode: AXError.success.rawValue, value: true)
        case "AXModal":
            return .init(errorCode: AXError.success.rawValue, value: false)
        case "AXSubrole":
            return .init(errorCode: AXError.success.rawValue, value: kAXStandardWindowSubrole as String)
        case "AXMinimizeButton":
            return .init(errorCode: AXError.success.rawValue, value: minimizeButton)
        case "AXCloseButton":
            return .init(errorCode: AXError.success.rawValue, value: closeButton)
        case "AXHidden":
            return .init(errorCode: AXError.success.rawValue, value: true)
        default:
            _ = state
            return .init(errorCode: AXError.attributeUnsupported.rawValue, value: nil)
        }
    }

    @discardableResult
    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
