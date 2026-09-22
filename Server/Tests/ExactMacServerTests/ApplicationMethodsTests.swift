import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import XCTest

final class ApplicationMethodsTests: XCTestCase {
    func testCloseAlreadyExitedRemovesExactTarget() async throws {
        let identity = makeIdentity(pid: 101, start: 1)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: identity)
        await stateStore.addTarget(application, processIdentity: identity)
        let service = makeService(stateStore: stateStore, system: MockSystemOperations())

        let response = try await service.closeApplication(
            request: closeRequest(name: application.name),
            context: closeContext(),
        ).message

        XCTAssertEqual(response.disposition, .alreadyExited)
        XCTAssertEqual(response.application.name, application.name)
        let retained = await stateStore.getTarget(name: application.name)
        XCTAssertNil(retained)
    }

    func testCloseGracefullyTerminatesOnlyExactIdentity() async throws {
        let identity = makeIdentity(pid: 102, start: 2)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: identity)
        await stateStore.addTarget(application, processIdentity: identity)
        let system = MockSystemOperations(
            runningPIDs: [identity.pid],
            runningApplicationIdentities: [identity],
        )
        let service = makeService(stateStore: stateStore, system: system)

        let response = try await service.closeApplication(
            request: closeRequest(name: application.name),
            context: closeContext(),
        ).message

        XCTAssertEqual(response.disposition, .graceful)
        XCTAssertEqual(
            system.applicationTerminationCalls,
            [.init(identity: identity, force: false)],
        )
        let retained = await stateStore.getTarget(name: application.name)
        XCTAssertNil(retained)
    }

    func testCloseForceEscalatesOnlyAfterExactGracefulProcessDoesNotExit() async throws {
        let identity = makeIdentity(pid: 103, start: 3)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: identity)
        await stateStore.addTarget(application, processIdentity: identity)
        let system = MockSystemOperations(
            runningPIDs: [identity.pid],
            runningApplicationIdentities: [identity],
            stopOnGracefulTermination: false,
        )
        let service = makeService(stateStore: stateStore, system: system)

        let response = try await service.closeApplication(
            request: closeRequest(name: application.name, force: true),
            context: closeContext(),
        ).message

        XCTAssertEqual(response.disposition, .forced)
        XCTAssertEqual(
            system.applicationTerminationCalls,
            [
                .init(identity: identity, force: false),
                .init(identity: identity, force: true),
            ],
        )
    }

    func testCloseWithoutForceRetainsExactLiveTargetOnNonconvergence() async throws {
        let identity = makeIdentity(pid: 104, start: 4)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: identity)
        await stateStore.addTarget(application, processIdentity: identity)
        let system = MockSystemOperations(
            runningPIDs: [identity.pid],
            runningApplicationIdentities: [identity],
            stopOnGracefulTermination: false,
        )
        let service = makeService(stateStore: stateStore, system: system)

        do {
            _ = try await service.closeApplication(
                request: closeRequest(name: application.name),
                context: closeContext(),
            )
            XCTFail("Expected graceful close timeout")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .deadlineExceeded)
        }
        let retained = await stateStore.getTarget(name: application.name)
        XCTAssertNotNil(retained)
        XCTAssertEqual(system.applicationTerminationCalls.count, 1)
    }

    func testCloseRejectsPIDReuseWithZeroTerminationCalls() async throws {
        let stale = makeIdentity(pid: 105, start: 5)
        let replacement = makeIdentity(pid: 105, start: 6)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: stale)
        await stateStore.addTarget(application, processIdentity: stale)
        let system = MockSystemOperations(
            applicationIdentities: [replacement.pid: replacement],
            runningPIDs: [replacement.pid],
            runningApplicationIdentities: [replacement],
        )
        let service = makeService(stateStore: stateStore, system: system)

        do {
            _ = try await service.closeApplication(
                request: closeRequest(name: application.name, force: true),
                context: closeContext(),
            )
            XCTFail("Expected stale identity rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertTrue(system.applicationTerminationCalls.isEmpty)
        let retained = await stateStore.getTarget(name: application.name)
        XCTAssertNotNil(retained)
    }

    func testCloseRejectsUnprovenLiveTargetWithZeroTerminationCalls() async throws {
        let identity = makeIdentity(pid: 106, start: 7)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: identity)
        await stateStore.addTarget(application)
        let system = MockSystemOperations(runningPIDs: [identity.pid])
        let service = makeService(stateStore: stateStore, system: system)

        do {
            _ = try await service.closeApplication(
                request: closeRequest(name: application.name, force: true),
                context: closeContext(),
            )
            XCTFail("Expected missing identity rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertTrue(system.applicationTerminationCalls.isEmpty)
        let retained = await stateStore.getTarget(name: application.name)
        XCTAssertNotNil(retained)
    }

    func testCloseRejectsAfterMutationAdmissionCloses() async throws {
        let identity = makeIdentity(pid: 107, start: 8)
        let stateStore = AppStateStore()
        let application = makeApplication(identity: identity)
        await stateStore.addTarget(application, processIdentity: identity)
        let system = MockSystemOperations(
            runningPIDs: [identity.pid],
            runningApplicationIdentities: [identity],
        )
        let service = makeService(stateStore: stateStore, system: system)
        await service.physicalDesktopMutationGate.beginDraining()

        do {
            _ = try await service.closeApplication(
                request: closeRequest(name: application.name),
                context: closeContext(),
            )
            XCTFail("Expected closed admission rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
        XCTAssertTrue(system.applicationTerminationCalls.isEmpty)
        let retained = await stateStore.getTarget(name: application.name)
        XCTAssertNotNil(retained)
    }

    func testOpenRejectsInvalidModeBeforeAdmissionAndExternalSink() async throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/Exact.app")
        let bundle = ApplicationBundleInfo(
            identity: applicationBundleIdentity(for: bundleURL),
            displayName: "Exact",
            bundleID: "com.example.exact",
            bundleURL: bundleURL,
            version: nil,
        )
        let catalog = ApplicationMethodsCatalog(bundles: [bundle])
        let recorder = ApplicationMethodsOpenRecorder()
        let coordinator = AutomationCoordinator(
            applicationOpenExecutor: { url, background, mode in
                await recorder.open(url: url, background: background, mode: mode)
            },
        )
        let service = ExactMacService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: WindowRegistry(system: MockSystemOperations()),
            applicationCatalogProvider: catalog,
            automationCoordinator: coordinator,
        )
        let request = Exactmac_V1_OpenApplicationRequest.with {
            $0.name = "applicationBundles/\(bundle.identity)"
            $0.mode = .UNRECOGNIZED(73)
        }

        do {
            _ = try await service.openApplication(
                request: ServerRequest(metadata: Metadata(), message: request),
                context: openContext(),
            )
            XCTFail("Expected invalid mode rejection")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        let callCount = await recorder.count()
        XCTAssertEqual(callCount, 0)
    }

    private func makeService(
        stateStore: AppStateStore,
        system: MockSystemOperations,
    ) -> ExactMacService {
        ExactMacService(
            stateStore: stateStore,
            operationStore: OperationStore(),
            windowRegistry: WindowRegistry(system: system),
            applicationCatalogProvider: ApplicationMethodsCatalog(),
            system: system,
            applicationTerminationGracePeriod: .milliseconds(1),
            applicationTerminationForcePeriod: .milliseconds(1),
        )
    }

    private func closeRequest(
        name: String,
        force: Bool = false,
    ) -> ServerRequest<Exactmac_V1_CloseApplicationRequest> {
        ServerRequest(metadata: Metadata(), message: .with {
            $0.name = name
            $0.force = force
        })
    }

    private func makeApplication(identity: ApplicationProcessIdentity) -> Exactmac_V1_Application {
        .with {
            $0.name = applicationResourceName(for: identity)
            $0.pid = Int32(identity.pid)
            $0.displayName = "Application \(identity.pid)"
        }
    }

    private func makeIdentity(pid: pid_t, start: UInt64) -> ApplicationProcessIdentity {
        ApplicationProcessIdentity(
            pid: pid,
            startTimeSeconds: start,
            startTimeMicroseconds: 123,
            bundleIdentifier: "com.example.\(pid)",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
        )
    }

    private func closeContext() -> ServerContext {
        ServerContext(
            descriptor: Exactmac_V1_ExactMac.Method.CloseApplication.descriptor,
            remotePeer: "in-process:test",
            localPeer: "in-process:server",
            cancellation: ServerContext.RPCCancellationHandle(),
        )
    }

    private func openContext() -> ServerContext {
        ServerContext(
            descriptor: Exactmac_V1_ExactMac.Method.OpenApplication.descriptor,
            remotePeer: "in-process:test",
            localPeer: "in-process:server",
            cancellation: ServerContext.RPCCancellationHandle(),
        )
    }
}

private final class ApplicationMethodsCatalog: ApplicationCatalogProvider, @unchecked Sendable {
    private let bundles: [ApplicationBundleInfo]

    init(bundles: [ApplicationBundleInfo] = []) {
        self.bundles = bundles
    }

    func applicationBundles() async -> [ApplicationBundleInfo] {
        bundles
    }

    func runningApplications() async -> [RunningApplicationInfo] {
        []
    }
}

private actor ApplicationMethodsOpenRecorder {
    private var calls = 0

    func open(
        url: URL,
        background _: Bool,
        mode _: AppLaunchMode,
    ) -> AppOpenerResult {
        calls += 1
        return AppOpenerResult(
            pid: 999,
            appName: url.deletingPathExtension().lastPathComponent,
            processingTimeSeconds: "0.001",
            actionTaken: .launchedNew,
            newProcessCreated: true,
        )
    }

    func count() -> Int {
        calls
    }
}
