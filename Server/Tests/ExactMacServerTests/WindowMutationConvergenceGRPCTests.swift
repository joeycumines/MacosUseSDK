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
struct WindowMutationConvergenceGRPCTests {
    @Test
    func `focus waits for observed AX focus and raises the exact window`() async throws {
        let fixture = await makeWindowMutationFixture()
        fixture.system.setNextFocus(actual: true, afterReads: 2)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let focused: Exactmac_V1_Window = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_FocusWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.FocusWindow.descriptor,
            )

            let snapshot = fixture.system.snapshot()
            #expect(focused.name == name)
            #expect(snapshot.focused)
            #expect(snapshot.focusReads >= 3)
            #expect(snapshot.raiseCalls == 1)
        }
    }

    @Test
    func `focus converges when the optional raise action is unsupported`() async throws {
        // Real windows such as Calculator and utility panels do not implement
        // kAXRaiseAction (AXUIElementPerformAction returns
        // kAXErrorAttributeUnsupported). FocusWindow must still succeed because
        // the authoritative focus path is the kAXFrontmost/kAXMain attribute
        // sets plus the AX-read convergence predicate, not the optional raise.
        let fixture = await makeWindowMutationFixture()
        fixture.system.setRaiseUnsupported(true)
        fixture.system.setNextFocus(actual: true, afterReads: 2)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let focused: Exactmac_V1_Window = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_FocusWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.FocusWindow.descriptor,
            )

            let snapshot = fixture.system.snapshot()
            #expect(focused.name == name)
            #expect(snapshot.focused)
            // raise was attempted (best-effort) even though it reported unsupported
            #expect(snapshot.raiseCalls == 1)
            #expect(snapshot.focusReads >= 3)
        }
    }

    @Test
    func `move accepts settled macOS clamping and returns the observed origin`() async throws {
        let fixture = await makeWindowMutationFixture()
        let clamped = CGPoint(x: 640, y: -180)
        fixture.system.setNextOrigin(actual: clamped, afterReads: 2)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let moved: Exactmac_V1_Window = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_MoveWindowRequest.with {
                    $0.name = name
                    $0.x = 20000
                    $0.y = -20000
                },
                descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
            )

            let snapshot = fixture.system.snapshot()
            #expect(moved.bounds.x == Double(clamped.x))
            #expect(moved.bounds.y == Double(clamped.y))
            #expect(snapshot.origin == clamped)
            #expect(snapshot.positionReads >= 4)
        }
    }

    @Test
    func `resize accepts settled macOS clamping and returns the observed size`() async throws {
        let fixture = await makeWindowMutationFixture()
        let clamped = CGSize(width: 1280, height: 720)
        fixture.system.setNextSize(actual: clamped, afterReads: 2)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let resized: Exactmac_V1_Window = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_ResizeWindowRequest.with {
                    $0.name = name
                    $0.width = 20000
                    $0.height = 20000
                },
                descriptor: Exactmac_V1_ExactMac.Method.ResizeWindow.descriptor,
            )

            let snapshot = fixture.system.snapshot()
            #expect(resized.bounds.width == Double(clamped.width))
            #expect(resized.bounds.height == Double(clamped.height))
            #expect(snapshot.size == clamped)
            #expect(snapshot.sizeReads >= 4)
        }
    }

    @Test(arguments: [false, true])
    func `minimize and restore wait for the requested observed state`(restore: Bool) async throws {
        let fixture = await makeWindowMutationFixture(minimized: restore)
        fixture.system.setNextMinimized(actual: !restore, afterReads: 2)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let response: Exactmac_V1_Window = if restore {
                try await windowMutationUnary(
                    client: client,
                    request: Exactmac_V1_RestoreWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.RestoreWindow.descriptor,
                )
            } else {
                try await windowMutationUnary(
                    client: client,
                    request: Exactmac_V1_MinimizeWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.MinimizeWindow.descriptor,
                )
            }

            let snapshot = fixture.system.snapshot()
            #expect(snapshot.minimized == !restore)
            #expect(snapshot.minimizedReads >= 4)
            #expect(response.visible == restore)
        }
    }

    @Test
    func `close reports success only after exact AX disappearance and retires the binding`() async throws {
        let fixture = await makeWindowMutationFixture()
        fixture.system.setNextClose(afterReads: 2)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let closed: Exactmac_V1_CloseWindowResponse = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_CloseWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.CloseWindow.descriptor,
            )

            let snapshot = fixture.system.snapshot()
            #expect(closed.success)
            #expect(!snapshot.windowPresent)
            #expect(snapshot.windowEnumerationReads >= 3)
            await expectWindowMutationRPCError(.notFound) {
                let _: Exactmac_V1_Window = try await windowMutationUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                )
            }
        }
    }

    @Test
    func `unreadable sibling AX identity fails before close side effects`() async throws {
        let fixture = await makeWindowMutationFixture()
        fixture.system.addUnidentifiedSiblingWindow()

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            await expectWindowMutationRPCError(.unavailable) {
                let _: Exactmac_V1_CloseWindowResponse = try await windowMutationUnary(
                    client: client,
                    request: Exactmac_V1_CloseWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.CloseWindow.descriptor,
                )
            }
            #expect(fixture.system.snapshot().windowPresent)
            let binding = await fixture.composition.windowRegistry.resolveWindowBinding(
                resourceID: String(name.split(separator: "/").last ?? ""),
                applicationName: fixture.applicationName,
                pid: fixture.identity.pid,
                processIdentity: fixture.identity,
            )
            #expect(binding != nil)
        }
    }

    @Test
    func `well typed non-window AX sibling does not hide the exact window`() async throws {
        let fixture = await makeWindowMutationFixture()
        fixture.system.addNonWindowSibling()

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let closed: Exactmac_V1_CloseWindowResponse = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_CloseWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.CloseWindow.descriptor,
            )

            #expect(closed.success)
            #expect(!fixture.system.snapshot().windowPresent)
        }
    }

    @Test
    func `temporary AX and Core Graphics ID disagreement converges before close`() async throws {
        let fixture = await makeWindowMutationFixture()
        fixture.system.setTransientWindowIDMismatch(reads: 1)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            let closed: Exactmac_V1_CloseWindowResponse = try await windowMutationUnary(
                client: client,
                request: Exactmac_V1_CloseWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.CloseWindow.descriptor,
            )

            #expect(closed.success)
            #expect(!fixture.system.snapshot().windowPresent)
            #expect(fixture.system.snapshot().windowEnumerationReads >= 3)
        }
    }

    @Test(arguments: WindowMutationKind.allCases)
    func `setter success without converged readback fails and preserves close binding`(
        mutation: WindowMutationKind,
    ) async throws {
        let fixture = await makeWindowMutationFixture(minimized: mutation == .restore)
        fixture.system.preventNextMutation(mutation)

        try await withWindowMutationClient(fixture.composition) { client in
            let name = try await listedWindowName(client: client, parent: fixture.applicationName)
            await expectWindowMutationRPCError(.deadlineExceeded) {
                try await performWindowMutation(
                    mutation,
                    client: client,
                    name: name,
                )
            }
            if mutation == .close {
                let binding = await fixture.composition.windowRegistry.resolveWindowBinding(
                    resourceID: String(name.split(separator: "/").last ?? ""),
                    applicationName: fixture.applicationName,
                    pid: fixture.identity.pid,
                    processIdentity: fixture.identity,
                )
                #expect(binding != nil)
                #expect(fixture.system.snapshot().windowPresent)
            }
        }
    }

    @Test
    func `caller cancellation stops convergence polling and releases the mutation gate`() async throws {
        let fixture = await makeWindowMutationFixture()
        fixture.system.preventNextMutation(.move)
        let listed = try await fixture.composition.exactMacService.listWindows(
            request: ServerRequest(
                metadata: Metadata(),
                message: Exactmac_V1_ListWindowsRequest.with { $0.parent = fixture.applicationName },
            ),
            context: windowMutationServerContext(Exactmac_V1_ExactMac.Method.ListWindows.descriptor),
        )
        let name = try #require(listed.message.windows.first?.name)
        let baselineReads = fixture.system.snapshot().positionReads

        let task = Task {
            try await fixture.composition.exactMacService.moveWindow(
                request: ServerRequest(
                    metadata: Metadata(),
                    message: Exactmac_V1_MoveWindowRequest.with {
                        $0.name = name
                        $0.x = 900
                        $0.y = 700
                    },
                ),
                context: windowMutationServerContext(Exactmac_V1_ExactMac.Method.MoveWindow.descriptor),
            )
        }
        try await waitForWindowMutationRead(
            system: fixture.system,
            greaterThan: baselineReads,
        )
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation during window convergence")
        } catch is CancellationError {
            // Expected direct-service cancellation.
        } catch let error as RPCError {
            #expect(error.code == .cancelled)
        }
        let settledReads = fixture.system.snapshot().positionReads
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(fixture.system.snapshot().positionReads == settledReads)
        #expect(await fixture.composition.automationCoordinator.mutationGate.pendingCount() == 0)
    }
}

enum WindowMutationKind: String, CaseIterable, Sendable {
    case focus
    case move
    case resize
    case minimize
    case restore
    case close
}

private struct WindowMutationFixture {
    let applicationName: String
    let identity: ApplicationProcessIdentity
    let composition: ExactMacServiceComposition
    let system: WindowMutationSystemOperations
}

private func makeWindowMutationFixture(minimized: Bool = false) async -> WindowMutationFixture {
    let identity = ApplicationProcessIdentity(
        pid: 5101,
        startTimeSeconds: 71,
        startTimeMicroseconds: 72,
        bundleIdentifier: "com.example.window-convergence",
        executablePath: "/Applications/WindowConvergence.app/Contents/MacOS/WindowConvergence",
    )
    let applicationName = applicationResourceName(for: identity)
    let stateStore = AppStateStore()
    let system = WindowMutationSystemOperations(identity: identity, minimized: minimized)
    let composition = ExactMacServiceComposition(
        stateStore: stateStore,
        system: system,
        windowMutationConvergencePolicy: WindowMutationConvergencePolicy(
            // Keep deadline assertions fast while leaving enough scheduler
            // headroom for the full Swift test suite on loaded CI workers.
            timeout: .milliseconds(250),
            pollInterval: .milliseconds(1),
            geometryTolerance: 0.5,
            stableReadCount: 2,
        ),
    )
    await stateStore.addTarget(
        Exactmac_V1_Application.with {
            $0.name = applicationName
            $0.pid = identity.pid
        },
        processIdentity: identity,
    )
    return WindowMutationFixture(
        applicationName: applicationName,
        identity: identity,
        composition: composition,
        system: system,
    )
}

private func withWindowMutationClient(
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

private func listedWindowName(
    client: GRPCClient<InProcessTransport.Client>,
    parent: String,
) async throws -> String {
    let response: Exactmac_V1_ListWindowsResponse = try await windowMutationUnary(
        client: client,
        request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
        descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
    )
    return try #require(response.windows.first?.name)
}

private func performWindowMutation(
    _ mutation: WindowMutationKind,
    client: GRPCClient<InProcessTransport.Client>,
    name: String,
) async throws {
    switch mutation {
    case .focus:
        let _: Exactmac_V1_Window = try await windowMutationUnary(
            client: client,
            request: Exactmac_V1_FocusWindowRequest.with { $0.name = name },
            descriptor: Exactmac_V1_ExactMac.Method.FocusWindow.descriptor,
        )
    case .move:
        let _: Exactmac_V1_Window = try await windowMutationUnary(
            client: client,
            request: Exactmac_V1_MoveWindowRequest.with {
                $0.name = name
                $0.x = 900
                $0.y = 700
            },
            descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
        )
    case .resize:
        let _: Exactmac_V1_Window = try await windowMutationUnary(
            client: client,
            request: Exactmac_V1_ResizeWindowRequest.with {
                $0.name = name
                $0.width = 900
                $0.height = 700
            },
            descriptor: Exactmac_V1_ExactMac.Method.ResizeWindow.descriptor,
        )
    case .minimize:
        let _: Exactmac_V1_Window = try await windowMutationUnary(
            client: client,
            request: Exactmac_V1_MinimizeWindowRequest.with { $0.name = name },
            descriptor: Exactmac_V1_ExactMac.Method.MinimizeWindow.descriptor,
        )
    case .restore:
        let _: Exactmac_V1_Window = try await windowMutationUnary(
            client: client,
            request: Exactmac_V1_RestoreWindowRequest.with { $0.name = name },
            descriptor: Exactmac_V1_ExactMac.Method.RestoreWindow.descriptor,
        )
    case .close:
        let _: Exactmac_V1_CloseWindowResponse = try await windowMutationUnary(
            client: client,
            request: Exactmac_V1_CloseWindowRequest.with { $0.name = name },
            descriptor: Exactmac_V1_ExactMac.Method.CloseWindow.descriptor,
        )
    }
}

private func windowMutationUnary<
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

private func expectWindowMutationRPCError(
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

private func windowMutationServerContext(_ descriptor: MethodDescriptor) -> ServerContext {
    ServerContext(
        descriptor: descriptor,
        remotePeer: "in-process:window-mutation-tests",
        localPeer: "in-process:server",
        cancellation: ServerContext.RPCCancellationHandle(),
    )
}

private func waitForWindowMutationRead(
    system: WindowMutationSystemOperations,
    greaterThan baseline: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while system.snapshot().positionReads <= baseline {
        guard clock.now < deadline else {
            throw WindowMutationTestError.readbackTimeout
        }
        await Task.yield()
    }
}

private enum WindowMutationTestError: Error {
    case readbackTimeout
}

private final class WindowMutationSystemOperations: SystemOperations, @unchecked Sendable {
    struct Snapshot: Sendable {
        let focused: Bool
        let minimized: Bool
        let windowPresent: Bool
        let origin: CGPoint
        let size: CGSize
        let focusReads: Int
        let positionReads: Int
        let sizeReads: Int
        let minimizedReads: Int
        let windowEnumerationReads: Int
        let raiseCalls: Int
    }

    private struct Deferred<Value> {
        let value: Value
        var readsRemaining: Int
        let never: Bool
    }

    private struct State {
        var bounds = CGRect(x: 40, y: 60, width: 640, height: 480)
        var focused = false
        var minimized: Bool
        var windowPresent = true
        var focusReads = 0
        var positionReads = 0
        var sizeReads = 0
        var minimizedReads = 0
        var windowEnumerationReads = 0
        var raiseCalls = 0
        var unidentifiedSiblingPresent = false
        var nonWindowSiblingPresent = false
        var transientWindowIDMismatchReads = 0
        var nextFocus: Deferred<Bool>?
        var pendingFocus: Deferred<Bool>?
        var nextOrigin: Deferred<CGPoint>?
        var pendingOrigin: Deferred<CGPoint>?
        var nextSize: Deferred<CGSize>?
        var pendingSize: Deferred<CGSize>?
        var nextMinimized: Deferred<Bool>?
        var pendingMinimized: Deferred<Bool>?
        var nextClose: Deferred<Bool>?
        var pendingClose: Deferred<Bool>?
        /// When true, the window's kAXRaiseAction reports AttributeUnsupported,
        /// mirroring real windows (Calculator/panels) that omit the optional raise
        /// action yet remain focusable via attribute sets.
        var raiseUnsupported = false
    }

    private let lock = NSLock()
    private let identity: ApplicationProcessIdentity
    private let appElement: AXUIElement
    private let windowElement = AXUIElementCreateApplication(51002)
    private let closeButton = AXUIElementCreateApplication(51003)
    private let unidentifiedSibling = AXUIElementCreateApplication(51004)
    private let nonWindowSibling = AXUIElementCreateApplication(51005)
    private var state: State

    init(identity: ApplicationProcessIdentity, minimized: Bool) {
        self.identity = identity
        appElement = AXUIElementCreateApplication(identity.pid)
        state = State(minimized: minimized)
    }

    func snapshot() -> Snapshot {
        withState { state in
            Snapshot(
                focused: state.focused,
                minimized: state.minimized,
                windowPresent: state.windowPresent,
                origin: state.bounds.origin,
                size: state.bounds.size,
                focusReads: state.focusReads,
                positionReads: state.positionReads,
                sizeReads: state.sizeReads,
                minimizedReads: state.minimizedReads,
                windowEnumerationReads: state.windowEnumerationReads,
                raiseCalls: state.raiseCalls,
            )
        }
    }

    func setNextFocus(actual: Bool, afterReads: Int) {
        withState { $0.nextFocus = .init(value: actual, readsRemaining: afterReads, never: false) }
    }

    /// Configures the window to reject kAXRaiseAction with AttributeUnsupported,
    /// modelling real windows (Calculator, utility panels) that omit the optional
    /// raise action yet remain fully focusable through attribute sets.
    func setRaiseUnsupported(_ unsupported: Bool) {
        withState { $0.raiseUnsupported = unsupported }
    }

    func setNextOrigin(actual: CGPoint, afterReads: Int) {
        withState { $0.nextOrigin = .init(value: actual, readsRemaining: afterReads, never: false) }
    }

    func setNextSize(actual: CGSize, afterReads: Int) {
        withState { $0.nextSize = .init(value: actual, readsRemaining: afterReads, never: false) }
    }

    func setNextMinimized(actual: Bool, afterReads: Int) {
        withState { $0.nextMinimized = .init(value: actual, readsRemaining: afterReads, never: false) }
    }

    func setNextClose(afterReads: Int) {
        withState { $0.nextClose = .init(value: true, readsRemaining: afterReads, never: false) }
    }

    func addUnidentifiedSiblingWindow() {
        withState { $0.unidentifiedSiblingPresent = true }
    }

    func addNonWindowSibling() {
        withState { $0.nonWindowSiblingPresent = true }
    }

    func setTransientWindowIDMismatch(reads: Int) {
        withState { $0.transientWindowIDMismatchReads = reads }
    }

    func preventNextMutation(_ mutation: WindowMutationKind) {
        withState { state in
            switch mutation {
            case .focus:
                state.nextFocus = .init(value: true, readsRemaining: 0, never: true)
            case .move:
                state.nextOrigin = .init(value: CGPoint(x: 900, y: 700), readsRemaining: 0, never: true)
            case .resize:
                state.nextSize = .init(value: CGSize(width: 900, height: 700), readsRemaining: 0, never: true)
            case .minimize:
                state.nextMinimized = .init(value: true, readsRemaining: 0, never: true)
            case .restore:
                state.nextMinimized = .init(value: false, readsRemaining: 0, never: true)
            case .close:
                state.nextClose = .init(value: true, readsRemaining: 0, never: true)
            }
        }
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        withState { state in
            guard state.windowPresent else {
                return []
            }
            return [[
                kCGWindowNumber as String: CGWindowID(601),
                kCGWindowOwnerPID as String: identity.pid,
                kCGWindowBounds as String: [
                    "X": state.bounds.origin.x,
                    "Y": state.bounds.origin.y,
                    "Width": state.bounds.width,
                    "Height": state.bounds.height,
                ],
                kCGWindowName as String: "Converging Window",
                kCGWindowLayer as String: Int32(0),
                kCGWindowIsOnscreen as String: !state.minimized,
            ]]
        }
    }

    func getRunningApplicationBundleID(pid _: pid_t) -> String? {
        identity.bundleIdentifier
    }

    func applicationProcessIdentity(pid: pid_t) -> ApplicationProcessIdentity? {
        pid == identity.pid ? identity : nil
    }

    func isProcessRunning(pid: pid_t) -> Bool {
        pid == identity.pid
    }

    func isApplicationProcessRunning(_ candidate: ApplicationProcessIdentity) -> Bool {
        candidate == identity
    }

    func requestApplicationActivation(_: ApplicationProcessIdentity) -> Bool {
        false
    }

    func requestApplicationTermination(_: ApplicationProcessIdentity, force _: Bool) -> Bool {
        false
    }

    func createAXApplication(pid: Int32) -> AnyObject? {
        pid == identity.pid ? appElement : nil
    }

    func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        let identifier = ObjectIdentifier(element)
        if identifier == ObjectIdentifier(appElement) {
            return withState { state in
                switch attribute {
                case kAXWindowsAttribute as String:
                    state.windowEnumerationReads += 1
                    applyDeferredClose(&state)
                    var windows: [AXUIElement] = state.windowPresent ? [windowElement] : []
                    if state.unidentifiedSiblingPresent {
                        windows.append(unidentifiedSibling)
                    }
                    if state.nonWindowSiblingPresent {
                        windows.append(nonWindowSibling)
                    }
                    return windows
                case kAXHiddenAttribute as String:
                    return false
                case kAXFrontmostAttribute as String:
                    state.focusReads += 1
                    applyDeferred(&state.pendingFocus, to: &state.focused)
                    return state.focused
                case kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String:
                    state.focusReads += 1
                    applyDeferred(&state.pendingFocus, to: &state.focused)
                    return windowElement
                default:
                    return nil
                }
            }
        }
        if identifier == ObjectIdentifier(nonWindowSibling) {
            return attribute == kAXRoleAttribute as String ? kAXScrollAreaRole as String : nil
        }
        guard identifier == ObjectIdentifier(windowElement) else {
            return nil
        }
        return withState { state in
            guard state.windowPresent else {
                return nil
            }
            switch attribute {
            case kAXRoleAttribute as String:
                return kAXWindowRole as String
            case kAXTitleAttribute as String:
                return "Converging Window"
            case kAXPositionAttribute as String:
                state.positionReads += 1
                applyDeferred(&state.pendingOrigin, to: &state.bounds.origin)
                var origin = state.bounds.origin
                return AXValueCreate(.cgPoint, &origin)
            case kAXSizeAttribute as String:
                state.sizeReads += 1
                applyDeferred(&state.pendingSize, to: &state.bounds.size)
                var size = state.bounds.size
                return AXValueCreate(.cgSize, &size)
            case kAXMainAttribute as String, kAXFocusedAttribute as String:
                state.focusReads += 1
                applyDeferred(&state.pendingFocus, to: &state.focused)
                return state.focused
            case kAXMinimizedAttribute as String:
                state.minimizedReads += 1
                applyDeferred(&state.pendingMinimized, to: &state.minimized)
                return state.minimized
            case kAXHiddenAttribute as String:
                return false
            case kAXCloseButtonAttribute as String:
                return closeButton
            default:
                return nil
            }
        }
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element: AnyObject, attribute: String, value: Any) -> Int32 {
        if ObjectIdentifier(element) == ObjectIdentifier(appElement) {
            guard attribute == kAXFrontmostAttribute as String else {
                return AXError.attributeUnsupported.rawValue
            }
            return withState { state in
                scheduleFocusWrite(value, state: &state)
                return AXError.success.rawValue
            }
        }
        guard ObjectIdentifier(element) == ObjectIdentifier(windowElement) else {
            return AXError.invalidUIElement.rawValue
        }
        return withState { state in
            guard state.windowPresent else {
                return AXError.invalidUIElement.rawValue
            }
            switch attribute {
            case kAXMainAttribute as String, kAXFocusedAttribute as String:
                scheduleFocusWrite(value, state: &state)
            case kAXPositionAttribute as String:
                guard let origin = point(from: value) else {
                    return AXError.illegalArgument.rawValue
                }
                if let next = state.nextOrigin {
                    state.pendingOrigin = next
                    state.nextOrigin = nil
                } else {
                    state.bounds.origin = origin
                }
            case kAXSizeAttribute as String:
                guard let size = size(from: value) else {
                    return AXError.illegalArgument.rawValue
                }
                if let next = state.nextSize {
                    state.pendingSize = next
                    state.nextSize = nil
                } else {
                    state.bounds.size = size
                }
            case kAXMinimizedAttribute as String:
                if let next = state.nextMinimized {
                    state.pendingMinimized = next
                    state.nextMinimized = nil
                } else {
                    state.minimized = (value as? Bool) ?? false
                }
            default:
                return AXError.attributeUnsupported.rawValue
            }
            return AXError.success.rawValue
        }
    }

    func performAXAction(element: AnyObject, action: String) -> Int32 {
        let identifier = ObjectIdentifier(element)
        return withState { state in
            if identifier == ObjectIdentifier(windowElement), action == kAXRaiseAction as String {
                state.raiseCalls += 1
                if state.raiseUnsupported {
                    return AXError.attributeUnsupported.rawValue
                }
                if state.pendingFocus == nil {
                    state.focused = true
                }
                return AXError.success.rawValue
            }
            if identifier == ObjectIdentifier(closeButton), action == kAXPressAction as String {
                if let next = state.nextClose {
                    state.pendingClose = next
                    state.nextClose = nil
                } else {
                    state.windowPresent = false
                }
                return AXError.success.rawValue
            }
            return AXError.actionUnsupported.rawValue
        }
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        guard ObjectIdentifier(element) == ObjectIdentifier(windowElement) else {
            return nil
        }
        return withState { state in
            guard state.windowPresent else {
                return nil
            }
            if state.transientWindowIDMismatchReads > 0 {
                state.transientWindowIDMismatchReads -= 1
                return 602
            }
            return 601
        }
    }

    private func applyDeferredClose(_ state: inout State) {
        guard var pending = state.pendingClose, !pending.never else {
            return
        }
        if pending.readsRemaining == 0 {
            state.windowPresent = false
            state.pendingClose = nil
        } else {
            pending.readsRemaining -= 1
            state.pendingClose = pending
        }
    }

    private func scheduleFocusWrite(_ value: Any, state: inout State) {
        if let next = state.nextFocus {
            state.pendingFocus = next
            state.nextFocus = nil
        } else if state.pendingFocus == nil {
            state.focused = (value as? Bool) ?? false
        }
    }

    private func applyDeferred<Value>(_ pending: inout Deferred<Value>?, to value: inout Value) {
        guard var current = pending, !current.never else {
            return
        }
        if current.readsRemaining == 0 {
            value = current.value
            pending = nil
        } else {
            current.readsRemaining -= 1
            pending = current
        }
    }

    private func point(from value: Any) -> CGPoint? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func size(from value: Any) -> CGSize? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func withState<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
