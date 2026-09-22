import CoreGraphics
import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct ApplicationContractGRPCTests {
    @Test
    func `bundle discovery preserves exact locations and binds pagination to the query`() async throws {
        let firstURL = URL(fileURLWithPath: "/Applications/First.app")
        let secondURL = URL(fileURLWithPath: "/Volumes/Other/First.app")
        let first = ApplicationBundleInfo(
            identity: applicationBundleIdentity(for: firstURL),
            displayName: "First",
            bundleID: "com.example.shared",
            bundleURL: firstURL,
            version: "1",
        )
        let second = ApplicationBundleInfo(
            identity: applicationBundleIdentity(for: secondURL),
            displayName: "First Copy",
            bundleID: "com.example.shared",
            bundleURL: secondURL,
            version: "2",
        )
        let catalog = LockedApplicationCatalogProvider(bundles: [second, first])
        let composition = ExactMacServiceComposition(applicationCatalogProvider: catalog)

        try await withApplicationClient(composition) { client in
            let firstPage: Exactmac_V1_ListApplicationBundlesResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationBundlesRequest.with {
                    $0.pageSize = 1
                    $0.orderBy = "display_name"
                    $0.view = .full
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
            )
            #expect(firstPage.applicationBundles.count == 1)
            #expect(!firstPage.nextPageToken.isEmpty)
            #expect(firstPage.applicationBundles[0].bundleURL == firstURL.absoluteString)

            let secondPage: Exactmac_V1_ListApplicationBundlesResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationBundlesRequest.with {
                    $0.pageSize = 1
                    $0.pageToken = firstPage.nextPageToken
                    $0.orderBy = "display_name"
                    $0.view = .full
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
            )
            #expect(secondPage.applicationBundles.count == 1)
            #expect(secondPage.nextPageToken.isEmpty)
            #expect(secondPage.applicationBundles[0].bundleURL == secondURL.absoluteString)
            #expect(firstPage.applicationBundles[0].name != secondPage.applicationBundles[0].name)
            #expect(firstPage.applicationBundles[0].bundleID == secondPage.applicationBundles[0].bundleID)

            let basic: Exactmac_V1_ApplicationBundle = try await applicationUnary(
                client: client,
                request: Exactmac_V1_GetApplicationBundleRequest.with {
                    $0.name = firstPage.applicationBundles[0].name
                },
                descriptor: Exactmac_V1_ExactMac.Method.GetApplicationBundle.descriptor,
            )
            #expect(basic.bundleURL.isEmpty)
            #expect(basic.version.isEmpty)

            do {
                let _: Exactmac_V1_ListApplicationBundlesResponse = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_ListApplicationBundlesRequest.with {
                        $0.pageSize = 1
                        $0.pageToken = firstPage.nextPageToken
                        $0.orderBy = "display_name"
                        $0.filter = "display_name = \"First\""
                        $0.view = .full
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
                )
                Issue.record("Expected query-bound token rejection")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
        }
    }

    @Test
    func `bundle list rejects malformed query and preserved unknown intent`() async throws {
        let catalog = LockedApplicationCatalogProvider()
        let composition = ExactMacServiceComposition(applicationCatalogProvider: catalog)

        try await withApplicationClient(composition) { client in
            let invalidRequests: [Exactmac_V1_ListApplicationBundlesRequest] = [
                .with { $0.pageSize = -1 },
                .with { $0.orderBy = "display_name sideways" },
                .with { $0.filter = "display_name = First" },
                .with { $0.view = .UNRECOGNIZED(91) },
            ]
            for request in invalidRequests {
                do {
                    let _: Exactmac_V1_ListApplicationBundlesResponse = try await applicationUnary(
                        client: client,
                        request: request,
                        descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
                    )
                    Issue.record("Expected invalid application bundle query")
                } catch let error as RPCError {
                    #expect(error.code == .invalidArgument)
                }
            }

            var bytes = try Exactmac_V1_ListApplicationBundlesRequest().serializedData()
            bytes.append(contentsOf: [0xA0, 0x06, 0x01])
            let unknown = try Exactmac_V1_ListApplicationBundlesRequest(serializedBytes: bytes)
            do {
                let _: Exactmac_V1_ListApplicationBundlesResponse = try await applicationUnary(
                    client: client,
                    request: unknown,
                    descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
                )
                Issue.record("Expected unknown-field rejection")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
        }
    }

    @Test
    func `running list discovers preexisting exact process instances`() async throws {
        let first = makeRunningApplication(pid: 501, displayName: "Alpha", active: false)
        let second = makeRunningApplication(pid: 502, displayName: "Bravo", active: true)
        let firstIdentity = makeApplicationIdentity(pid: first.pid, start: 11)
        let secondIdentity = makeApplicationIdentity(pid: second.pid, start: 22)
        let catalog = LockedApplicationCatalogProvider(running: [second, first])
        let system = MockSystemOperations(
            applicationIdentities: [first.pid: firstIdentity, second.pid: secondIdentity],
            runningApplicationIdentities: [firstIdentity, secondIdentity],
        )
        let composition = ExactMacServiceComposition(
            system: system,
            applicationCatalogProvider: catalog,
        )

        try await withApplicationClient(composition) { client in
            let basic: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest.with {
                    $0.orderBy = "display_name"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            #expect(basic.applications.map(\.displayName) == ["Alpha", "Bravo"])
            #expect(basic.applications.allSatisfy { !$0.hasProcessStartTime })
            #expect(basic.applications.allSatisfy { $0.name != "applications/\($0.pid)" })
            #expect(basic.applications.allSatisfy { (try? ParsingHelpers.parseOpaqueApplicationName($0.name)) != nil })

            let exactName = basic.applications[0].name
            let full: Exactmac_V1_Application = try await applicationUnary(
                client: client,
                request: Exactmac_V1_GetApplicationRequest.with {
                    $0.name = exactName
                    $0.view = .full
                },
                descriptor: Exactmac_V1_ExactMac.Method.GetApplication.descriptor,
            )
            #expect(full.name == exactName)
            #expect(full.hasProcessStartTime)
            #expect(full.processStartTime.seconds == 11)

            catalog.setRunning([])
            let retained: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest.with {
                    $0.orderBy = "display_name"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            #expect(retained.applications.map(\.name) == basic.applications.map(\.name))

            system.runningApplicationIdentities = [secondIdentity]
            let pruned: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest.with {
                    $0.orderBy = "display_name"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            #expect(pruned.applications.map(\.displayName) == ["Bravo"])
            #expect(pruned.applications[0].name == applicationResourceName(for: secondIdentity))
        }
    }

    @Test
    func `running list executes only its documented filter and ordering grammar`() async throws {
        let first = makeRunningApplication(pid: 511, displayName: "Alpha", active: false)
        let second = makeRunningApplication(pid: 512, displayName: "Bravo", active: true)
        let firstIdentity = makeApplicationIdentity(pid: first.pid, start: 31)
        let secondIdentity = makeApplicationIdentity(pid: second.pid, start: 32)
        let catalog = LockedApplicationCatalogProvider(running: [second, first])
        let system = MockSystemOperations(
            applicationIdentities: [first.pid: firstIdentity, second.pid: secondIdentity],
            runningApplicationIdentities: [firstIdentity, secondIdentity],
        )
        let composition = ExactMacServiceComposition(
            system: system,
            applicationCatalogProvider: catalog,
        )

        try await withApplicationClient(composition) { client in
            for orderBy in ["name", "pid", "display_name", "bundle_id", "active", "active desc"] {
                let response: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_ListApplicationsRequest.with { $0.orderBy = orderBy },
                    descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
                )
                #expect(response.applications.count == 2)
            }

            let byDisplayName: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest.with {
                    $0.filter = "display_name = \"alpha\""
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            #expect(byDisplayName.applications.map(\.displayName) == ["Alpha"])

            let byBundleID: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest.with {
                    $0.filter = "bundle_id = \"com.example.512\""
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            #expect(byBundleID.applications.map(\.displayName) == ["Bravo"])

            for invalidRequest in [
                Exactmac_V1_ListApplicationsRequest.with { $0.filter = "name = \"Alpha\"" },
                Exactmac_V1_ListApplicationsRequest.with { $0.orderBy = "unknown" },
            ] {
                do {
                    let _: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                        client: client,
                        request: invalidRequest,
                        descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
                    )
                    Issue.record("Expected undocumented application query rejection")
                } catch let error as RPCError {
                    #expect(error.code == .invalidArgument)
                }
            }
        }
    }

    @Test
    func `opaque application parents round trip through windows and elements and reject PID reuse`() async throws {
        let pid: pid_t = 551
        let windowID: CGWindowID = 9101
        let firstIdentity = makeApplicationIdentity(pid: pid, start: 23)
        let replacementIdentity = makeApplicationIdentity(pid: pid, start: 24)
        let running = makeRunningApplication(pid: pid, displayName: "Round Trip", active: true)
        let catalog = LockedApplicationCatalogProvider(running: [running])
        let system = MockSystemOperations(
            cgWindowList: [[
                kCGWindowNumber as String: windowID,
                kCGWindowOwnerPID as String: pid,
                kCGWindowBounds as String: [
                    "X": 10.0,
                    "Y": 20.0,
                    "Width": 300.0,
                    "Height": 200.0,
                ],
                kCGWindowName as String: "Exact Window",
                kCGWindowLayer as String: Int32(0),
                kCGWindowIsOnscreen as String: true,
            ]],
            applicationIdentities: [pid: firstIdentity],
            runningApplicationIdentities: [firstIdentity],
        )
        let composition = ExactMacServiceComposition(
            system: system,
            applicationCatalogProvider: catalog,
        )

        try await withApplicationClient(composition) { client in
            let runningResponse: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest(),
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            let applicationName = try #require(runningResponse.applications.first?.name)
            #expect(applicationName == applicationResourceName(for: firstIdentity))

            let windows: Exactmac_V1_ListWindowsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with { $0.parent = applicationName },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let windowName = try #require(windows.windows.first?.name)
            #expect(windows.windows.count == 1)
            #expect(windowName.hasPrefix("\(applicationName)/windows/"))
            #expect(windowName != "\(applicationName)/windows/\(windowID)")

            do {
                let _: Exactmac_V1_ListWindowsResponse = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_ListWindowsRequest.with {
                        $0.parent = "applications/\(pid)"
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                )
                Issue.record("Expected numeric application parent rejection")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            let elementID = try await composition.elementRegistry.registerElement(
                Exactmac_V1_Element.with { $0.role = "AXButton" },
                pid: pid,
            )
            let elementName = "\(applicationName)/elements/\(elementID)"
            let elements: Exactmac_V1_ListElementsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListElementsRequest.with { $0.parent = applicationName },
                descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
            )
            #expect(elements.elements.map(\.name) == [elementName])
            let element: Exactmac_V1_Element = try await applicationUnary(
                client: client,
                request: Exactmac_V1_GetElementRequest.with { $0.name = elementName },
                descriptor: Exactmac_V1_ExactMac.Method.GetElement.descriptor,
            )
            #expect(element.name == elementName)

            catalog.setRunning([running])
            system.applicationIdentities[pid] = replacementIdentity
            system.runningApplicationIdentities = [replacementIdentity]
            let replacementResponse: Exactmac_V1_ListApplicationsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest(),
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
            )
            let replacementName = try #require(replacementResponse.applications.first?.name)
            #expect(replacementName == applicationResourceName(for: replacementIdentity))

            let replacementElements: Exactmac_V1_ListElementsResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ListElementsRequest.with { $0.parent = replacementName },
                descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
            )
            #expect(replacementElements.elements.isEmpty)
            #expect(await composition.elementRegistry.getElement(elementID) == nil)

            do {
                let _: Exactmac_V1_Element = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_GetElementRequest.with { $0.name = elementName },
                    descriptor: Exactmac_V1_ExactMac.Method.GetElement.descriptor,
                )
                Issue.record("Expected stale child resource rejection after PID reuse")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }
        }
    }

    @Test
    func `open resolves one exact bundle resource and publishes exact process identity`() async throws {
        let bundleURL = URL(fileURLWithPath: "/Volumes/Chosen/Example.app")
        let bundle = ApplicationBundleInfo(
            identity: applicationBundleIdentity(for: bundleURL),
            displayName: "Example",
            bundleID: "com.example.shared",
            bundleURL: bundleURL,
            version: "1",
        )
        let pid: pid_t = 601
        let identity = makeApplicationIdentity(pid: pid, start: 33)
        let running = RunningApplicationInfo(
            pid: pid,
            displayName: "Example",
            bundleID: bundle.bundleID,
            bundleURL: bundleURL,
            bundleIdentity: bundle.identity,
            launchDate: nil,
            active: true,
        )
        let catalog = LockedApplicationCatalogProvider(bundles: [bundle], running: [running])
        let system = MockSystemOperations(
            applicationIdentities: [pid: identity],
            runningApplicationIdentities: [identity],
        )
        let recorder = ExactApplicationOpenRecorder(pid: pid)
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            applicationOpenExecutor: { url, background, mode in
                await recorder.open(url: url, background: background, mode: mode)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            applicationCatalogProvider: catalog,
            automationCoordinator: coordinator,
        )

        try await withApplicationClient(composition) { client in
            let response: Exactmac_V1_OpenApplicationResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_OpenApplicationRequest.with {
                    $0.name = "applicationBundles/\(bundle.identity)"
                    $0.mode = .forceNewInstance
                },
                descriptor: Exactmac_V1_ExactMac.Method.OpenApplication.descriptor,
            )
            #expect(response.application.name == applicationResourceName(for: identity))
            #expect(response.application.applicationBundle == "applicationBundles/\(bundle.identity)")
            #expect(response.disposition == .launchedNew)
            let calls = await recorder.calls()
            #expect(calls.count == 1)
            #expect(calls[0].url == canonicalApplicationBundleURL(bundleURL))
            #expect(calls[0].mode == .forceNewInstance)

            do {
                let _: Exactmac_V1_OpenApplicationResponse = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_OpenApplicationRequest.with { $0.name = "Example" },
                    descriptor: Exactmac_V1_ExactMac.Method.OpenApplication.descriptor,
                )
                Issue.record("Expected free-form application name rejection")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
            #expect(await recorder.calls().count == 1)
        }
    }

    @Test
    func `activation converges on the same exact process and stale identity reaches no sink`() async throws {
        let pid: pid_t = 701
        let identity = makeApplicationIdentity(pid: pid, start: 44)
        let inactive = makeRunningApplication(pid: pid, displayName: "Target", active: false)
        let catalog = LockedApplicationCatalogProvider(running: [inactive])
        let system = MockSystemOperations(
            applicationIdentities: [pid: identity],
            applicationActivationHandler: { requested in
                guard requested == identity else { return false }
                catalog.setRunning([makeRunningApplication(pid: pid, displayName: "Target", active: true)])
                return true
            },
            runningApplicationIdentities: [identity],
        )
        let composition = ExactMacServiceComposition(
            system: system,
            applicationCatalogProvider: catalog,
        )

        try await withApplicationClient(composition) { client in
            let name = applicationResourceName(for: identity)
            let response: Exactmac_V1_ActivateApplicationResponse = try await applicationUnary(
                client: client,
                request: Exactmac_V1_ActivateApplicationRequest.with { $0.name = name },
                descriptor: Exactmac_V1_ExactMac.Method.ActivateApplication.descriptor,
            )
            #expect(response.disposition == .activated)
            #expect(response.application.name == name)
            #expect(response.application.active)
            #expect(system.applicationActivationCalls.count == 1)

            let staleIdentity = makeApplicationIdentity(pid: pid, start: 43)
            do {
                let _: Exactmac_V1_ActivateApplicationResponse = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_ActivateApplicationRequest.with {
                        $0.name = applicationResourceName(for: staleIdentity)
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ActivateApplication.descriptor,
                )
                Issue.record("Expected stale identity rejection")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }
            #expect(system.applicationActivationCalls.count == 1)
        }
    }

    @Test
    func `close rejects PID reuse without a termination sink`() async throws {
        let pid: pid_t = 801
        let stale = makeApplicationIdentity(pid: pid, start: 55)
        let replacement = makeApplicationIdentity(pid: pid, start: 56)
        let stateStore = AppStateStore()
        let staleApplication = Exactmac_V1_Application.with {
            $0.name = applicationResourceName(for: stale)
            $0.pid = Int32(pid)
            $0.displayName = "Stale"
        }
        await stateStore.addTarget(staleApplication, processIdentity: stale)
        let system = MockSystemOperations(
            applicationIdentities: [pid: replacement],
            runningPIDs: [pid],
            runningApplicationIdentities: [replacement],
        )
        let composition = ExactMacServiceComposition(
            stateStore: stateStore,
            system: system,
            applicationCatalogProvider: LockedApplicationCatalogProvider(),
        )

        try await withApplicationClient(composition) { client in
            do {
                let _: Exactmac_V1_CloseApplicationResponse = try await applicationUnary(
                    client: client,
                    request: Exactmac_V1_CloseApplicationRequest.with {
                        $0.name = staleApplication.name
                        $0.force = true
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CloseApplication.descriptor,
                )
                Issue.record("Expected PID reuse rejection")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }
            #expect(system.applicationTerminationCalls.isEmpty)
            #expect(await stateStore.getTarget(name: staleApplication.name) != nil)
        }
    }
}

private final class LockedApplicationCatalogProvider: ApplicationCatalogProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var bundles: [ApplicationBundleInfo]
    private var running: [RunningApplicationInfo]

    init(
        bundles: [ApplicationBundleInfo] = [],
        running: [RunningApplicationInfo] = [],
    ) {
        self.bundles = bundles
        self.running = running
    }

    func applicationBundles() async -> [ApplicationBundleInfo] {
        withLock { bundles }
    }

    func runningApplications() async -> [RunningApplicationInfo] {
        withLock { running }
    }

    func setRunning(_ running: [RunningApplicationInfo]) {
        withLock { self.running = running }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor ExactApplicationOpenRecorder {
    struct Call: Sendable {
        let url: URL
        let background: Bool
        let mode: AppLaunchMode
    }

    private let pid: pid_t
    private var recorded: [Call] = []

    init(pid: pid_t) {
        self.pid = pid
    }

    func open(
        url: URL,
        background: Bool,
        mode: AppLaunchMode,
    ) -> AppOpenerResult {
        recorded.append(Call(url: url, background: background, mode: mode))
        return AppOpenerResult(
            pid: pid,
            appName: url.deletingPathExtension().lastPathComponent,
            processingTimeSeconds: "0.001",
            actionTaken: mode == .forceNewInstance ? .launchedNew : .activatedExisting,
            newProcessCreated: mode == .forceNewInstance,
            active: !background,
        )
    }

    func calls() -> [Call] {
        recorded
    }
}

private func makeApplicationIdentity(
    pid: pid_t,
    start: UInt64,
) -> ApplicationProcessIdentity {
    ApplicationProcessIdentity(
        pid: pid,
        startTimeSeconds: start,
        startTimeMicroseconds: UInt64(pid % 1_000_000),
        bundleIdentifier: "com.example.\(pid)",
        executablePath: "/Applications/Example-\(pid).app/Contents/MacOS/Example",
    )
}

private func makeRunningApplication(
    pid: pid_t,
    displayName: String,
    active: Bool,
) -> RunningApplicationInfo {
    let url = URL(fileURLWithPath: "/Applications/\(displayName).app")
    return RunningApplicationInfo(
        pid: pid,
        displayName: displayName,
        bundleID: "com.example.\(pid)",
        bundleURL: url,
        bundleIdentity: applicationBundleIdentity(for: url),
        launchDate: nil,
        active: active,
    )
}

private func withApplicationClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let inProcess = InProcessTransport()
    let server = GRPCServer(
        transport: inProcess.server,
        services: [composition.exactMacService],
    )
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

private func applicationUnary<
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
