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
struct WindowIdentityContractGRPCTests {
    @Test
    func `ListWindows publishes stable opaque names from one owner snapshot`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Owned", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
                .init(id: 202, pid: 4202, title: "Foreign", bounds: .init(x: 80, y: 90, width: 320, height: 240)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let first = try await listWindows(client: client, parent: fixture.applicationName)
            let second = try await listWindows(client: client, parent: fixture.applicationName)

            let firstWindow = try #require(first.windows.first)
            let secondWindow = try #require(second.windows.first)
            #expect(first.windows.count == 1)
            #expect(second.windows.count == 1)
            #expect(firstWindow.name == secondWindow.name)
            #expect(firstWindow.name.hasPrefix("\(fixture.applicationName)/windows/"))
            #expect(UInt32(firstWindow.name.split(separator: "/").last ?? "") == nil)
            #expect(fixture.system.snapshot().cgSnapshotCalls == 2)
            #expect(fixture.system.snapshot().axSinkCalls == 0)
        }
    }

    @Test(arguments: [1, 3, 5])
    func `ListWindows deterministically enumerates one owner's synthetic multiwindow snapshot`(
        ownedWindowCount: Int,
    ) async throws {
        let ownedIDs = Array([UInt32(105), 101, 103, 102, 104].prefix(ownedWindowCount))
        let orderedOwnedIDs = ownedIDs.sorted()
        let ownedWindows = ownedIDs.enumerated().map { index, windowID in
            WindowIdentitySystemOperations.WindowSpec(
                id: windowID,
                pid: 4101,
                title: "Duplicate",
                bounds: .init(x: 20, y: 30, width: 640, height: 480),
                layer: orderedOwnedIDs.firstIndex(of: windowID) ?? index,
            )
        }
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 900, pid: 4202, title: "Duplicate", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ] + ownedWindows + [
                .init(id: 901, pid: 4303, title: "Duplicate", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let first: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = fixture.applicationName
                    $0.orderBy = "layer"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let afterFirst = fixture.system.snapshot()
            let second: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = fixture.applicationName
                    $0.orderBy = "layer"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let afterSecond = fixture.system.snapshot()

            #expect(first.windows.count == ownedWindowCount)
            #expect(second.windows.count == ownedWindowCount)
            #expect(first.windows.map(\.name) == second.windows.map(\.name))
            #expect(Set(first.windows.map(\.name)).count == ownedWindowCount)
            #expect(first.windows.allSatisfy { $0.title == "Duplicate" })
            #expect(first.windows.map(\.layer) == (0 ..< Int32(ownedWindowCount)).map(\.self))
            #expect(afterFirst.cgSnapshotCalls == 1)
            #expect(afterSecond.cgSnapshotCalls == 2)
            #expect(afterSecond.createAXApplicationCalls == 0)
            #expect(afterSecond.copyAXAttributeCalls == 0)
            #expect(afterSecond.exactIDLookups == 0)
            #expect(afterSecond.axSinkCalls == 0)
        }
    }

    @Test
    func `ListWindows continuation honors a changed page size`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "One", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
                .init(id: 102, pid: 4101, title: "Two", bounds: .init(x: 100, y: 0, width: 100, height: 100)),
                .init(id: 103, pid: 4101, title: "Three", bounds: .init(x: 200, y: 0, width: 100, height: 100)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let first: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = fixture.applicationName
                    $0.pageSize = 1
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let second: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = fixture.applicationName
                    $0.pageSize = 2
                    $0.pageToken = first.nextPageToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )

            #expect(first.windows.count == 1)
            #expect(!first.nextPageToken.isEmpty)
            #expect(second.windows.count == 2)
            #expect(second.nextPageToken.isEmpty)
            #expect(Set((first.windows + second.windows).map(\.name)).count == 3)
        }
    }

    @Test
    func `ListWindows continuation remains bound to its immutable snapshot`() async throws {
        let original = [
            WindowIdentitySystemOperations.WindowSpec(
                id: 101,
                pid: 4101,
                title: "Original One",
                bounds: .init(x: 0, y: 0, width: 100, height: 100),
            ),
            .init(id: 102, pid: 4101, title: "Original Two", bounds: .init(x: 100, y: 0, width: 100, height: 100)),
            .init(id: 103, pid: 4101, title: "Original Three", bounds: .init(x: 200, y: 0, width: 100, height: 100)),
        ]
        let fixture = await makeWindowIdentityFixture(windows: original)

        try await withWindowIdentityClient(fixture.composition) { client in
            let baseline = try await listWindows(client: client, parent: fixture.applicationName)
            let first: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = fixture.applicationName
                    $0.pageSize = 1
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            fixture.system.replaceWindows([
                .init(id: 201, pid: 4101, title: "Replacement One", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
                .init(id: 202, pid: 4101, title: "Replacement Two", bounds: .init(x: 100, y: 0, width: 100, height: 100)),
                .init(id: 203, pid: 4101, title: "Replacement Three", bounds: .init(x: 200, y: 0, width: 100, height: 100)),
            ])

            var names = first.windows.map(\.name)
            var token = first.nextPageToken
            while !token.isEmpty {
                let page: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_ListWindowsRequest.with {
                        $0.parent = fixture.applicationName
                        $0.pageSize = 1
                        $0.pageToken = token
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                )
                names.append(contentsOf: page.windows.map(\.name))
                token = page.nextPageToken
            }

            #expect(names == baseline.windows.map(\.name))
            #expect(fixture.system.snapshot().cgSnapshotCalls == 2)
        }
    }

    @Test
    func `owner replacement during the CG snapshot publishes no windows`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Old owner", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
            ],
        )
        fixture.system.replaceProcessIdentityDuringNextSnapshot()

        try await withWindowIdentityClient(fixture.composition) { client in
            await expectWindowRPCError(.notFound) {
                let _: Exactmac_V1_ListWindowsResponse = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_ListWindowsRequest.with { $0.parent = fixture.applicationName },
                    descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                )
            }
        }
    }

    @Test
    func `missing private window ID never enters heuristic selection`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Exact only", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let listed = try await listWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            fixture.system.failExactWindowIDLookups()

            await expectWindowRPCError(.unavailable) {
                let _: Exactmac_V1_Window = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                )
            }
        }
    }

    @Test
    func `same CG ID on a replacement AX element cannot inherit a binding`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "First AX identity", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let listed = try await listWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            let _: Exactmac_V1_Window = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
            )
            fixture.system.replaceOwnedAXElementKeepingWindowID()

            await expectWindowRPCError(.notFound) {
                let _: Exactmac_V1_Window = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                )
            }
        }
    }

    @Test
    func `duplicate private window ID membership is ambiguous`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "First", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
            ],
        )
        fixture.system.addAXOnlyWindow(
            .init(id: 101, pid: 4101, title: "Second", bounds: .init(x: 100, y: 0, width: 100, height: 100)),
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let listed = try await listWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            await expectWindowRPCError(.failedPrecondition) {
                let _: Exactmac_V1_Window = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                )
            }
        }
    }

    @Test(arguments: [UInt32(999_999), UInt32(202)])
    func `random or cross-owner window child cannot mutate the owner's sole window`(
        requestedWindowID: UInt32,
    ) async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Owned", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
                .init(id: 202, pid: 4202, title: "Foreign", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ],
        )
        let forgedName = "\(fixture.applicationName)/windows/\(requestedWindowID)"

        try await withWindowIdentityClient(fixture.composition) { client in
            await expectWindowRPCError(.notFound) {
                let _: Exactmac_V1_Window = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_FocusWindowRequest.with { $0.name = forgedName },
                    descriptor: Exactmac_V1_ExactMac.Method.FocusWindow.descriptor,
                )
            }
            let snapshot = fixture.system.snapshot()
            #expect(snapshot.axSinkCalls == 0)
        }
    }

    @Test
    func `observed removal retires a name before the same CG ID is reused`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "First generation", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let initial = try await listWindows(client: client, parent: fixture.applicationName)
            let oldName = try #require(initial.windows.first?.name)

            fixture.system.replaceWindows([])
            let absent = try await listWindows(client: client, parent: fixture.applicationName)
            #expect(absent.windows.isEmpty)

            fixture.system.replaceWindows([
                .init(id: 101, pid: 4101, title: "Second generation", bounds: .init(x: 200, y: 230, width: 800, height: 600)),
            ])
            let replacement = try await listWindows(client: client, parent: fixture.applicationName)
            let replacementName = try #require(replacement.windows.first?.name)
            #expect(replacementName != oldName)

            await expectWindowRPCError(.notFound) {
                let _: Exactmac_V1_Window = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_GetWindowRequest.with { $0.name = oldName },
                    descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                )
            }
        }
    }

    @Test
    func `admitted AX element preserves its public name when its CG ID changes`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Mutable ID", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let listed = try await listWindows(client: client, parent: fixture.applicationName)
            let stableName = try #require(listed.windows.first?.name)
            fixture.system.changeWindowIDOnNextPositionWrite(to: 303)

            let moved: Exactmac_V1_Window = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_MoveWindowRequest.with {
                    $0.name = stableName
                    $0.x = 250
                    $0.y = 275
                },
                descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
            )
            #expect(moved.name == stableName)
            #expect(moved.bounds.x == 250)
            #expect(moved.bounds.y == 275)

            let fetched: Exactmac_V1_Window = try await windowIdentityUnary(
                client: client,
                request: Exactmac_V1_GetWindowRequest.with { $0.name = stableName },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
            )
            #expect(fetched.name == stableName)
            #expect(fixture.system.snapshot().currentOwnedWindowID == 303)
        }
    }

    @Test
    func `same PID process replacement between lookup and AX sink cannot mutate`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Old process", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ],
        )

        try await withWindowIdentityClient(fixture.composition) { client in
            let listed = try await listWindows(client: client, parent: fixture.applicationName)
            let name = try #require(listed.windows.first?.name)
            fixture.system.replaceProcessIdentityAfterNextWindowLookup()

            await expectWindowRPCError(.notFound) {
                let _: Exactmac_V1_Window = try await windowIdentityUnary(
                    client: client,
                    request: Exactmac_V1_FocusWindowRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.FocusWindow.descriptor,
                )
            }
            #expect(fixture.system.snapshot().axSinkCalls == 0)
        }
    }

    @Test
    func `cancelling exact lookup releases the mutation without a late AX sink`() async throws {
        let fixture = await makeWindowIdentityFixture(
            windows: [
                .init(id: 101, pid: 4101, title: "Cancellation", bounds: .init(x: 20, y: 30, width: 640, height: 480)),
            ],
        )
        let listed = try await fixture.composition.exactMacService.listWindows(
            request: ServerRequest(
                metadata: Metadata(),
                message: Exactmac_V1_ListWindowsRequest.with { $0.parent = fixture.applicationName },
            ),
            context: windowServerContext(Exactmac_V1_ExactMac.Method.ListWindows.descriptor),
        )
        let name = try #require(listed.message.windows.first?.name)
        fixture.system.failExactWindowIDLookups()

        let task = Task {
            try await fixture.composition.exactMacService.focusWindow(
                request: ServerRequest(
                    metadata: Metadata(),
                    message: Exactmac_V1_FocusWindowRequest.with { $0.name = name },
                ),
                context: windowServerContext(Exactmac_V1_ExactMac.Method.FocusWindow.descriptor),
            )
        }
        try await waitForWindowIdentityLookup(fixture.system)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled window lookup")
        } catch is CancellationError {
            // Expected direct-service cancellation.
        } catch let error as RPCError {
            #expect(error.code == .cancelled)
        }
        #expect(fixture.system.snapshot().axSinkCalls == 0)
        #expect(await fixture.composition.automationCoordinator.mutationGate.pendingCount() == 0)
    }
}

private struct WindowIdentityFixture {
    let applicationName: String
    let composition: ExactMacServiceComposition
    let system: WindowIdentitySystemOperations
}

private func makeWindowIdentityFixture(
    windows: [WindowIdentitySystemOperations.WindowSpec],
) async -> WindowIdentityFixture {
    let pid: pid_t = 4101
    let identity = ApplicationProcessIdentity(
        pid: pid,
        startTimeSeconds: 100,
        startTimeMicroseconds: 200,
        bundleIdentifier: "com.example.window-owner",
        executablePath: "/Applications/WindowOwner.app/Contents/MacOS/WindowOwner",
    )
    let applicationName = applicationResourceName(for: identity)
    let stateStore = AppStateStore()
    let system = WindowIdentitySystemOperations(identity: identity, windows: windows)
    let composition = ExactMacServiceComposition(stateStore: stateStore, system: system)
    await stateStore.addTarget(
        Exactmac_V1_Application.with {
            $0.name = applicationName
            $0.pid = pid
        },
        processIdentity: identity,
    )
    return WindowIdentityFixture(
        applicationName: applicationName,
        composition: composition,
        system: system,
    )
}

private func withWindowIdentityClient(
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

private func listWindows(
    client: GRPCClient<InProcessTransport.Client>,
    parent: String,
) async throws -> Exactmac_V1_ListWindowsResponse {
    try await windowIdentityUnary(
        client: client,
        request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
        descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
    )
}

private func windowIdentityUnary<
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

private func expectWindowRPCError(
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

private func windowServerContext(_ descriptor: MethodDescriptor) -> ServerContext {
    ServerContext(
        descriptor: descriptor,
        remotePeer: "in-process:window-identity-tests",
        localPeer: "in-process:server",
        cancellation: ServerContext.RPCCancellationHandle(),
    )
}

private func waitForWindowIdentityLookup(_ system: WindowIdentitySystemOperations) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while system.snapshot().exactIDLookups == 0 {
        guard clock.now < deadline else {
            throw WindowIdentityTestError.lookupTimeout
        }
        await Task.yield()
    }
}

private enum WindowIdentityTestError: Error {
    case lookupTimeout
}

private final class WindowIdentitySystemOperations: SystemOperations, @unchecked Sendable {
    struct WindowSpec: Sendable {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let bounds: CGRect
        let layer: Int

        init(
            id: CGWindowID,
            pid: pid_t,
            title: String,
            bounds: CGRect,
            layer: Int = 0,
        ) {
            self.id = id
            self.pid = pid
            self.title = title
            self.bounds = bounds
            self.layer = layer
        }
    }

    struct Snapshot: Sendable {
        let cgSnapshotCalls: Int
        let createAXApplicationCalls: Int
        let copyAXAttributeCalls: Int
        let exactIDLookups: Int
        let axSinkCalls: Int
        let currentOwnedWindowID: CGWindowID?
    }

    private struct WindowRecord {
        var id: CGWindowID
        let pid: pid_t
        var title: String
        var bounds: CGRect
        let layer: Int
        var main = false
        var minimized = false
        var element: AXUIElement
        let closeButton: AXUIElement
        let publishedInCG: Bool
    }

    private struct State {
        var identity: ApplicationProcessIdentity
        var windows: [WindowRecord]
        var cgSnapshotCalls = 0
        var createAXApplicationCalls = 0
        var copyAXAttributeCalls = 0
        var exactIDLookups = 0
        var axSinkCalls = 0
        var nextWindowIDAfterPosition: CGWindowID?
        var replaceIdentityAfterLookup = false
        var replaceIdentityDuringSnapshot = false
        var forceIDLookupFailure = false
        var nextSyntheticPID: pid_t = 20000
    }

    private let lock = NSLock()
    private let appElement: AXUIElement
    private let ownedPID: pid_t
    private var state: State

    init(identity: ApplicationProcessIdentity, windows: [WindowSpec]) {
        ownedPID = identity.pid
        appElement = AXUIElementCreateApplication(identity.pid)
        var nextPID: pid_t = 20000
        let records = windows.map { spec -> WindowRecord in
            defer { nextPID += 2 }
            return WindowRecord(
                id: spec.id,
                pid: spec.pid,
                title: spec.title,
                bounds: spec.bounds,
                layer: spec.layer,
                element: AXUIElementCreateApplication(nextPID),
                closeButton: AXUIElementCreateApplication(nextPID + 1),
                publishedInCG: true,
            )
        }
        state = State(identity: identity, windows: records, nextSyntheticPID: nextPID)
    }

    func snapshot() -> Snapshot {
        withState { state in
            Snapshot(
                cgSnapshotCalls: state.cgSnapshotCalls,
                createAXApplicationCalls: state.createAXApplicationCalls,
                copyAXAttributeCalls: state.copyAXAttributeCalls,
                exactIDLookups: state.exactIDLookups,
                axSinkCalls: state.axSinkCalls,
                currentOwnedWindowID: state.windows.first(where: { $0.pid == ownedPID })?.id,
            )
        }
    }

    func replaceWindows(_ windows: [WindowSpec]) {
        withState { state in
            state.windows = windows.map { spec in
                defer { state.nextSyntheticPID += 2 }
                return WindowRecord(
                    id: spec.id,
                    pid: spec.pid,
                    title: spec.title,
                    bounds: spec.bounds,
                    layer: spec.layer,
                    element: AXUIElementCreateApplication(state.nextSyntheticPID),
                    closeButton: AXUIElementCreateApplication(state.nextSyntheticPID + 1),
                    publishedInCG: true,
                )
            }
        }
    }

    func addAXOnlyWindow(_ spec: WindowSpec) {
        withState { state in
            state.windows.append(
                WindowRecord(
                    id: spec.id,
                    pid: spec.pid,
                    title: spec.title,
                    bounds: spec.bounds,
                    layer: spec.layer,
                    element: AXUIElementCreateApplication(state.nextSyntheticPID),
                    closeButton: AXUIElementCreateApplication(state.nextSyntheticPID + 1),
                    publishedInCG: false,
                ),
            )
            state.nextSyntheticPID += 2
        }
    }

    func changeWindowIDOnNextPositionWrite(to windowID: CGWindowID) {
        withState { $0.nextWindowIDAfterPosition = windowID }
    }

    func replaceProcessIdentityAfterNextWindowLookup() {
        withState { $0.replaceIdentityAfterLookup = true }
    }

    func replaceProcessIdentityDuringNextSnapshot() {
        withState { $0.replaceIdentityDuringSnapshot = true }
    }

    func failExactWindowIDLookups() {
        withState { $0.forceIDLookupFailure = true }
    }

    func replaceOwnedAXElementKeepingWindowID() {
        withState { state in
            guard let index = state.windows.firstIndex(where: { $0.pid == ownedPID }) else {
                return
            }
            state.windows[index].element = AXUIElementCreateApplication(state.nextSyntheticPID)
            state.nextSyntheticPID += 1
        }
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        withState { state in
            state.cgSnapshotCalls += 1
            if state.replaceIdentityDuringSnapshot {
                state.identity = ApplicationProcessIdentity(
                    pid: state.identity.pid,
                    startTimeSeconds: state.identity.startTimeSeconds + 1,
                    startTimeMicroseconds: state.identity.startTimeMicroseconds,
                    bundleIdentifier: state.identity.bundleIdentifier,
                    executablePath: state.identity.executablePath,
                )
                state.replaceIdentityDuringSnapshot = false
            }
            return state.windows.filter(\.publishedInCG).map { window in
                [
                    kCGWindowNumber as String: window.id,
                    kCGWindowOwnerPID as String: window.pid,
                    kCGWindowBounds as String: [
                        "X": window.bounds.origin.x,
                        "Y": window.bounds.origin.y,
                        "Width": window.bounds.width,
                        "Height": window.bounds.height,
                    ],
                    kCGWindowName as String: window.title,
                    kCGWindowLayer as String: Int32(window.layer),
                    kCGWindowIsOnscreen as String: true,
                ]
            }
        }
    }

    func getRunningApplicationBundleID(pid: pid_t) -> String? {
        pid == ownedPID ? "com.example.window-owner" : "com.example.foreign"
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
        withState { $0.createAXApplicationCalls += 1 }
        return pid == ownedPID ? appElement : AXUIElementCreateApplication(pid)
    }

    func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        let identifier = ObjectIdentifier(element)
        withState { $0.copyAXAttributeCalls += 1 }
        if identifier == ObjectIdentifier(appElement) {
            return withState { state in
                switch attribute {
                case kAXWindowsAttribute as String, kAXChildrenAttribute as String:
                    state.windows.filter { $0.pid == ownedPID }.map(\.element)
                case kAXHiddenAttribute as String:
                    false
                default:
                    nil
                }
            }
        }

        return withState { state in
            guard let window = state.windows.first(where: { ObjectIdentifier($0.element) == identifier }) else {
                return nil
            }
            switch attribute {
            case kAXRoleAttribute as String:
                return kAXWindowRole as String
            case kAXTitleAttribute as String:
                return window.title
            case kAXPositionAttribute as String:
                var origin = window.bounds.origin
                return AXValueCreate(.cgPoint, &origin)
            case kAXSizeAttribute as String:
                var size = window.bounds.size
                return AXValueCreate(.cgSize, &size)
            case kAXMainAttribute as String, kAXFocusedAttribute as String:
                return window.main
            case kAXMinimizedAttribute as String:
                return window.minimized
            case kAXHiddenAttribute as String:
                return false
            case kAXCloseButtonAttribute as String:
                return window.closeButton
            default:
                return nil
            }
        }
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element: AnyObject, attribute: String, value: Any) -> Int32 {
        let identifier = ObjectIdentifier(element)
        return withState { state in
            guard let index = state.windows.firstIndex(where: { ObjectIdentifier($0.element) == identifier }) else {
                return AXError.invalidUIElement.rawValue
            }
            state.axSinkCalls += 1
            switch attribute {
            case kAXMainAttribute as String:
                state.windows[index].main = (value as? Bool) ?? false
            case kAXMinimizedAttribute as String:
                state.windows[index].minimized = (value as? Bool) ?? false
            case kAXPositionAttribute as String:
                guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
                    return AXError.illegalArgument.rawValue
                }
                let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
                var origin = CGPoint.zero
                guard AXValueGetValue(axValue, .cgPoint, &origin) else {
                    return AXError.illegalArgument.rawValue
                }
                state.windows[index].bounds.origin = origin
                if let nextWindowID = state.nextWindowIDAfterPosition {
                    state.windows[index].id = nextWindowID
                    state.nextWindowIDAfterPosition = nil
                }
            case kAXSizeAttribute as String:
                guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
                    return AXError.illegalArgument.rawValue
                }
                let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
                var size = CGSize.zero
                guard AXValueGetValue(axValue, .cgSize, &size) else {
                    return AXError.illegalArgument.rawValue
                }
                state.windows[index].bounds.size = size
            default:
                return AXError.attributeUnsupported.rawValue
            }
            return AXError.success.rawValue
        }
    }

    func performAXAction(element: AnyObject, action: String) -> Int32 {
        let identifier = ObjectIdentifier(element)
        return withState { state in
            guard action == kAXPressAction as String,
                  let index = state.windows.firstIndex(where: { ObjectIdentifier($0.closeButton) == identifier })
            else {
                return AXError.actionUnsupported.rawValue
            }
            state.axSinkCalls += 1
            state.windows.remove(at: index)
            return AXError.success.rawValue
        }
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        let identifier = ObjectIdentifier(element)
        return withState { state in
            state.exactIDLookups += 1
            if state.replaceIdentityAfterLookup {
                state.identity = ApplicationProcessIdentity(
                    pid: state.identity.pid,
                    startTimeSeconds: state.identity.startTimeSeconds + 1,
                    startTimeMicroseconds: state.identity.startTimeMicroseconds,
                    bundleIdentifier: state.identity.bundleIdentifier,
                    executablePath: state.identity.executablePath,
                )
                state.replaceIdentityAfterLookup = false
            }
            guard !state.forceIDLookupFailure else {
                return nil
            }
            return state.windows.first(where: { ObjectIdentifier($0.element) == identifier })?.id
        }
    }

    func readAXWindowID(element: AnyObject) -> AXWindowIDRead {
        let windowID = getAXWindowID(element: element)
        let forcedFailure = withState { $0.forceIDLookupFailure }
        return AXWindowIDRead(
            errorCode: forcedFailure ? AXError.cannotComplete.rawValue :
                (windowID == nil ? AXError.invalidUIElement.rawValue : AXError.success.rawValue),
            windowID: windowID,
        )
    }

    private func withState<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
