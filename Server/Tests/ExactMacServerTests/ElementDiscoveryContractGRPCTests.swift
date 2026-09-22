import ApplicationServices
import CoreGraphics
@testable import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct ElementDiscoveryContractGRPCTests {
    @Test
    func `one traversal preserves identical siblings and reuses exact AX identities`() async throws {
        let ids = LockedElementIDSequence(["shared", "shared", "second"])
        let registry = ElementRegistry(idGenerator: { ids.next() })
        let parent = "applications/exact/windows/window-a"
        await registry.bindApplication(name: "applications/exact", pid: 7001)
        let firstAX = AXUIElementCreateApplication(71001)
        let secondAX = AXUIElementCreateApplication(71002)

        let firstScan = try await registry.registerTraversalElements(
            [
                elementData(path: [0], axElement: firstAX),
                elementData(path: [1], axElement: secondAX),
            ],
            pid: 7001,
            scope: parent,
        )
        let secondScan = try await registry.registerTraversalElements(
            [
                elementData(path: [1], axElement: secondAX, text: "updated"),
                elementData(path: [0], axElement: firstAX),
            ],
            pid: 7001,
            scope: parent,
        )

        #expect(firstScan.count == 2)
        #expect(Set(firstScan.map(\.elementID)).count == 2)
        #expect(Dictionary(uniqueKeysWithValues: firstScan.map { ($0.path, $0.elementID) }) ==
            Dictionary(uniqueKeysWithValues: secondScan.map { ($0.path, $0.elementID) }))
        #expect(secondScan.first(where: { $0.path == [1] })?.text == "updated")
        #expect(await registry.getCachedElementCount() == 2)
    }

    @Test
    func `scope replacement retires missing handles and rejects cross-window mutation`() async throws {
        let ids = LockedElementIDSequence(["first", "second"])
        let registry = ElementRegistry(idGenerator: { ids.next() })
        await registry.bindApplication(name: "applications/exact", pid: 7002)
        let firstParent = "applications/exact/windows/window-a"
        let secondParent = "applications/exact/windows/window-b"
        let first = try #require(try await registry.registerTraversalElements(
            [elementData(path: [0], axElement: AXUIElementCreateApplication(72001))],
            pid: 7002,
            scope: firstParent,
        ).first)
        _ = try await registry.registerTraversalElements(
            [elementData(path: [0], axElement: AXUIElementCreateApplication(72002))],
            pid: 7002,
            scope: firstParent,
        )

        await #expect(throws: ElementMutationResolutionError.notFound) {
            _ = try await registry.resolveElementForMutation(
                first.elementID,
                expectedPID: 7002,
                expectedScope: firstParent,
            )
        }

        let current = try #require(await registry.listElements(forPID: 7002).first)
        await #expect(throws: ElementMutationResolutionError.scopeMismatch(
            expected: secondParent,
            actual: firstParent,
        )) {
            _ = try await registry.resolveElementForMutation(
                current.elementID,
                expectedPID: 7002,
                expectedScope: secondParent,
            )
        }
    }

    @Test
    func `generic traversal ownership cancels and joins discovery work during drain`() async throws {
        let coordinator = AutomationCoordinator(inputPostAccessChecker: { false })
        let probe = ElementTraversalProbe()
        let task = Task {
            try await coordinator.withOwnedTraversal {
                try await probe.run()
            }
        }

        try await waitForElementDiscovery { await probe.hasEntered() }
        #expect(await coordinator.activeTraversalCount() == 1)
        let shutdown = Task { await coordinator.shutdownTraversals() }
        try await waitForElementDiscovery { await probe.observedCancellation() }
        #expect(!shutdown.isCancelled)
        await probe.release()
        await shutdown.value
        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
        #expect(await coordinator.activeTraversalCount() == 0)
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.withOwnedTraversal { 1 }
        }
    }

    @Test
    func `window discovery traverses only the exact bound AX root`() async throws {
        let fixture = try await ElementDiscoveryFixture.make()

        let matches = try await fixture.locator.findElements(
            selector: Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
            parent: fixture.parent,
            maxResults: 2,
        )

        #expect(matches.count == 1)
        #expect(fixture.rootProbe.matches(fixture.exactWindow))
        #expect(!fixture.rootProbe.matches(fixture.foreignWindow))
        #expect(matches[0].element.name.hasPrefix("applications/7301/elements/"))
    }

    @Test
    func `exact window fallback checks cancellation before every AX child read`() async throws {
        let system = ElementDiscoverySystem(
            pid: 7301,
            exactWindowID: 731,
            forceChildFallback: true,
            cancelAfterFirstChildRoleRead: true,
        )
        let fixture = try await ElementDiscoveryFixture.make(system: system)
        let task = Task {
            try await fixture.locator.findElements(
                selector: Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                parent: fixture.parent,
            )
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(system.childRoleReadCount() == 1)
        #expect(await fixture.registry.getCachedElementCount() == 0)
    }

    @Test
    func `generated client continuation preserves stable handles without a second force refresh`() async throws {
        let ids = LockedElementIDSequence(["first-page", "second-page", "third-page"])
        let harness = try await ElementDiscoveryServiceHarness.make(
            idSequence: ids,
            elements: [
                elementData(path: [0], axElement: AXUIElementCreateApplication(7401)),
                elementData(path: [1], axElement: AXUIElementCreateApplication(7402)),
                elementData(path: [2], axElement: AXUIElementCreateApplication(7403)),
            ],
        )

        try await withElementDiscoveryClient(harness.service) { client in
            let first: Exactmac_V1_FindElementsResponse = try await elementDiscoveryUnary(
                client: client,
                request: Exactmac_V1_FindElementsRequest.with {
                    $0.parent = harness.parent
                    $0.selector.role = "AXButton"
                    $0.pageSize = 1
                    $0.forceRefresh = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
            )
            let second: Exactmac_V1_FindElementsResponse = try await elementDiscoveryUnary(
                client: client,
                request: Exactmac_V1_FindElementsRequest.with {
                    $0.parent = harness.parent
                    $0.selector.role = "AXButton"
                    $0.pageSize = 1
                    $0.pageToken = first.nextPageToken
                    $0.forceRefresh = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
            )
            let third: Exactmac_V1_FindElementsResponse = try await elementDiscoveryUnary(
                client: client,
                request: Exactmac_V1_FindElementsRequest.with {
                    $0.parent = harness.parent
                    $0.selector.role = "AXButton"
                    $0.pageSize = 1
                    $0.pageToken = second.nextPageToken
                    $0.forceRefresh = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
            )

            #expect(first.elements.map(\.elementID) == ["first-page"])
            #expect(second.elements.map(\.elementID) == ["second-page"])
            #expect(third.elements.map(\.elementID) == ["third-page"])
            #expect(third.nextPageToken.isEmpty)
            #expect(ids.generatedCount() == 3)
            #expect(await harness.registry.getCachedElementCount() == 3)
        }
    }

    @Test
    func `generated client rejects ambiguous mutation selector before activation or input`() async throws {
        let inputCount = LockedElementCounter()
        let harness = try await ElementDiscoveryServiceHarness.make(
            elements: [
                elementData(path: [0], axElement: AXUIElementCreateApplication(7411)),
                elementData(path: [1], axElement: AXUIElementCreateApplication(7412)),
            ],
            inputActionExecutor: { action, route, _ in
                inputCount.increment()
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )

        try await withElementDiscoveryClient(harness.service) { client in
            do {
                let _: Exactmac_V1_ClickElementResponse = try await elementDiscoveryUnary(
                    client: client,
                    request: Exactmac_V1_ClickElementRequest.with {
                        $0.parent = harness.parent
                        $0.selector.role = "AXButton"
                        $0.clickType = .single
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ClickElement.descriptor,
                )
                Issue.record("Expected ambiguous selector to fail closed")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition)
            }

            #expect(harness.system.setCallCount() == 0)
            #expect(inputCount.value() == 0)
        }
    }

    @Test
    func `generated client state wait never rebinds an exact ID to a lookalike`() async throws {
        let ids = LockedElementIDSequence(["tracked", "lookalike"])
        let originalAX = AXUIElementCreateApplication(7431)
        let harness = try await ElementDiscoveryServiceHarness.make(
            idSequence: ids,
            elements: [
                elementData(
                    path: [0],
                    axElement: AXUIElementCreateApplication(7432),
                ),
            ],
        )
        let tracked = try #require(try await harness.registry.registerTraversalElements(
            [elementData(path: [0], axElement: originalAX)],
            pid: 7301,
            scope: harness.parent,
        ).first)

        try await withElementDiscoveryClient(harness.service) { client in
            let operation: Google_Longrunning_Operation = try await elementDiscoveryUnary(
                client: client,
                request: Exactmac_V1_WaitElementStateRequest.with {
                    $0.parent = harness.parent
                    $0.elementID = tracked.elementID
                    $0.condition.enabled = true
                    $0.timeout = 1
                    $0.pollInterval = 0.1
                },
                descriptor: Exactmac_V1_ExactMac.Method.WaitElementState.descriptor,
            )
            try await waitForElementDiscovery {
                await harness.operationStore.getOperation(name: operation.name)?.done == true
            }
            let settled = try #require(await harness.operationStore.getOperation(name: operation.name))

            #expect(settled.done)
            #expect(settled.error.code == Int32(RPCError.Code.notFound.rawValue))
            #expect(ids.generatedCount() == 2)
            #expect(await harness.registry.getElement(tracked.elementID) == nil)
        }
    }

    @Test
    func `stale window binding after traversal prevents registry publication`() async throws {
        let probe = BlockingElementDiscoveryProbe()
        let fixture = try await ElementDiscoveryFixture.make(discoveryExecutor: { _, root, _ in
            try await probe.run(root: root)
        })
        let task = Task {
            try await fixture.locator.findElements(
                selector: Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                parent: fixture.parent,
            )
        }
        try await waitForElementDiscovery { await probe.hasEntered() }

        await fixture.windowRegistry.retireWindowBinding(
            resourceID: fixture.windowResourceID,
            applicationName: "applications/7301",
            pid: 7301,
            processIdentity: nil,
        )
        await probe.release()

        do {
            _ = try await task.value
            Issue.record("Expected stale window binding to reject discovery")
        } catch let error as RPCError {
            #expect(error.code == .notFound)
        }
        #expect(await fixture.registry.getCachedElementCount() == 0)
    }

    @Test
    func `application generation rebind after traversal prevents registry publication`() async throws {
        let probe = BlockingElementDiscoveryProbe()
        let fixture = try await ElementDiscoveryFixture.make(discoveryExecutor: { _, root, _ in
            try await probe.run(root: root)
        })
        let task = Task {
            try await fixture.locator.findElements(
                selector: Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                parent: fixture.parent,
            )
        }
        try await waitForElementDiscovery { await probe.hasEntered() }

        await fixture.registry.bindApplication(
            name: "applications/replacement-generation",
            pid: 7301,
        )
        await probe.release()

        do {
            _ = try await task.value
            Issue.record("Expected application generation rebind to reject discovery")
        } catch let error as RPCError {
            #expect(error.code == .notFound)
        }
        #expect(await fixture.registry.getCachedElementCount() == 0)
    }

    @Test
    func `caller cancellation prevents resistant traversal from publishing late elements`() async throws {
        let registry = ElementRegistry()
        let coordinator = AutomationCoordinator(
            elementRegistry: registry,
            inputPostAccessChecker: { false },
        )
        let probe = BlockingElementDiscoveryProbe()
        let locator = ElementLocator(
            elementRegistry: registry,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
            discoveryExecutor: { _, root, _ in try await probe.run(root: root) },
        )
        let task = Task {
            try await locator.findElements(
                selector: Exactmac_Type_ElementSelector.with { $0.role = "AXButton" },
                parent: "applications/7302",
            )
        }
        try await waitForElementDiscovery { await probe.hasEntered() }
        task.cancel()
        try await waitForElementDiscovery { await probe.observedCancellation() }
        await probe.release()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await registry.getCachedElementCount() == 0)
        #expect(await coordinator.activeTraversalCount() == 0)
    }

    @Test
    func `identifier collision exhaustion fails atomically`() async throws {
        let registry = ElementRegistry(idGenerator: { "collision" })
        await registry.bindApplication(name: "applications/7303", pid: 7303)

        await #expect(throws: ElementRegistryError.identifierExhausted) {
            _ = try await registry.registerTraversalElements(
                [
                    elementData(path: [0], axElement: AXUIElementCreateApplication(7310)),
                    elementData(path: [1], axElement: AXUIElementCreateApplication(7311)),
                ],
                pid: 7303,
                scope: "applications/7303",
            )
        }
        #expect(await registry.getCachedElementCount() == 0)
    }

    @Test
    func `direct registration retries collisions and traversal identity cannot be replaced`() async throws {
        let ids = LockedElementIDSequence(["shared", "shared", "direct-second", "traversed"])
        let registry = ElementRegistry(idGenerator: { ids.next() })
        await registry.bindApplication(name: "applications/7304", pid: 7304)

        let firstID = try await registry.registerElement(
            Exactmac_V1_Element(),
            pid: 7304,
        )
        let secondID = try await registry.registerElement(
            Exactmac_V1_Element(),
            pid: 7304,
        )
        let originalAX = AXUIElementCreateApplication(7421)
        let traversed = try #require(try await registry.registerTraversalElements(
            [elementData(path: [0], axElement: originalAX)],
            pid: 7304,
            scope: "applications/7304",
        ).first)

        #expect(firstID == "shared")
        #expect(secondID == "direct-second")
        #expect(ids.generatedCount() == 4)
        #expect(await registry.updateElement(
            traversed.elementID,
            element: traversed,
            axElement: AXUIElementCreateApplication(7422),
        ) == false)
        let resolved = try await registry.resolveElementForMutation(
            traversed.elementID,
            expectedPID: 7304,
            expectedScope: "applications/7304",
        )
        #expect(resolved.axElement.map { CFEqual($0, originalAX) } == true)
    }
}

private func elementData(
    path: [Int32],
    axElement: AXUIElement,
    text: String = "Identical",
) -> ElementData {
    ElementData(
        role: "AXButton",
        text: text,
        x: 10,
        y: 20,
        width: 100,
        height: 40,
        axElement: SendableAXUIElement(axElement),
        enabled: true,
        focused: false,
        attributes: [:],
        path: path,
    )
}

private actor ElementTraversalProbe {
    private var entered = false
    private var cancellationObserved = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async throws -> Int {
        entered = true
        do {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
            try Task.checkCancellation()
            return 1
        } catch {
            cancellationObserved = true
            throw error
        }
    }

    func hasEntered() -> Bool {
        entered
    }

    func observedCancellation() -> Bool {
        cancellationObserved
    }

    func recordCancellation() {
        cancellationObserved = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct ElementDiscoveryFixture {
    let registry: ElementRegistry
    let windowRegistry: WindowRegistry
    let locator: ElementLocator
    let rootProbe: ElementDiscoveryRootProbe
    let exactWindow: AXUIElement
    let foreignWindow: AXUIElement
    let parent: String
    let windowResourceID: String

    static func make(
        system: ElementDiscoverySystem? = nil,
        discoveryExecutor: ElementDiscoveryExecutor? = nil,
    ) async throws -> ElementDiscoveryFixture {
        let system = system ?? ElementDiscoverySystem(pid: 7301, exactWindowID: 731)
        let windowRegistry = WindowRegistry(system: system)
        let binding = try #require(await windowRegistry.listWindowBindings(
            applicationName: "applications/7301",
            pid: 7301,
            processIdentity: nil,
        ).first)
        let registry = ElementRegistry()
        let coordinator = AutomationCoordinator(
            elementRegistry: registry,
            activationSystem: system,
            inputPostAccessChecker: { false },
        )
        let rootProbe = ElementDiscoveryRootProbe()
        let executor = discoveryExecutor ?? { _, root, _ in
            rootProbe.record(root)
            return AccessibilityTraversalSnapshot(
                appName: "Exact",
                elements: [
                    elementData(
                        path: [0],
                        axElement: AXUIElementCreateApplication(7399),
                    ),
                ],
                count: 1,
            )
        }
        let locator = ElementLocator(
            elementRegistry: registry,
            windowRegistry: windowRegistry,
            legacyPIDResourceNamesForTests: true,
            system: system,
            automationCoordinator: coordinator,
            discoveryExecutor: executor,
        )
        return ElementDiscoveryFixture(
            registry: registry,
            windowRegistry: windowRegistry,
            locator: locator,
            rootProbe: rootProbe,
            exactWindow: system.exactWindow,
            foreignWindow: system.foreignWindow,
            parent: binding.name,
            windowResourceID: binding.resourceID,
        )
    }
}

private struct ElementDiscoveryServiceHarness {
    let service: ExactMacService
    let registry: ElementRegistry
    let operationStore: OperationStore
    let system: ElementDiscoverySystem
    let parent: String

    static func make(
        idSequence: LockedElementIDSequence? = nil,
        elements: [ElementData],
        inputActionExecutor: InputActionExecutor? = nil,
    ) async throws -> ElementDiscoveryServiceHarness {
        let system = ElementDiscoverySystem(pid: 7301, exactWindowID: 731)
        let windowRegistry = WindowRegistry(system: system)
        let binding = try #require(await windowRegistry.listWindowBindings(
            applicationName: "applications/7301",
            pid: 7301,
            processIdentity: nil,
        ).first)
        let registry = ElementRegistry(idGenerator: { idSequence?.next() ?? UUID().uuidString })
        let operationStore = OperationStore()
        let coordinator = AutomationCoordinator(
            elementRegistry: registry,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: inputActionExecutor,
        )
        let locator = ElementLocator(
            elementRegistry: registry,
            windowRegistry: windowRegistry,
            legacyPIDResourceNamesForTests: true,
            system: system,
            automationCoordinator: coordinator,
            discoveryExecutor: { _, _, _ in
                AccessibilityTraversalSnapshot(
                    appName: "Generated client",
                    elements: elements,
                    count: elements.count,
                )
            },
        )
        let service = ExactMacService(
            stateStore: AppStateStore(),
            operationStore: operationStore,
            windowRegistry: windowRegistry,
            legacyPIDResourceNamesForTests: true,
            system: system,
            automationCoordinator: coordinator,
            elementLocator: locator,
        )
        return ElementDiscoveryServiceHarness(
            service: service,
            registry: registry,
            operationStore: operationStore,
            system: system,
            parent: binding.name,
        )
    }
}

private final class ElementDiscoveryRootProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var root: AXUIElement?

    func record(_ root: AXUIElement?) {
        lock.lock()
        self.root = root
        lock.unlock()
    }

    func matches(_ expected: AXUIElement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let root else { return false }
        return CFEqual(root, expected)
    }
}

private actor BlockingElementDiscoveryProbe {
    private var entered = false
    private var cancellationObserved = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(root _: AXUIElement?) async throws -> AccessibilityTraversalSnapshot {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return AccessibilityTraversalSnapshot(
            appName: "Blocked",
            elements: [
                elementData(
                    path: [0],
                    axElement: AXUIElementCreateApplication(7398),
                ),
            ],
            count: 1,
        )
    }

    func hasEntered() -> Bool {
        entered
    }

    func observedCancellation() -> Bool {
        cancellationObserved
    }

    func recordCancellation() {
        cancellationObserved = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ElementDiscoverySystem: SystemOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var setCalls = 0
    private var childRoleReads = 0
    private let forceChildFallback: Bool
    private let cancelAfterFirstChildRoleRead: Bool
    let pid: pid_t
    let exactWindowID: CGWindowID
    let application: AXUIElement
    let exactWindow: AXUIElement
    let foreignWindow: AXUIElement

    init(
        pid: pid_t,
        exactWindowID: CGWindowID,
        forceChildFallback: Bool = false,
        cancelAfterFirstChildRoleRead: Bool = false,
    ) {
        self.pid = pid
        self.exactWindowID = exactWindowID
        self.forceChildFallback = forceChildFallback
        self.cancelAfterFirstChildRoleRead = cancelAfterFirstChildRoleRead
        application = AXUIElementCreateApplication(pid)
        exactWindow = AXUIElementCreateApplication(pid + 1)
        foreignWindow = AXUIElementCreateApplication(pid + 2)
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        [[
            kCGWindowNumber as String: exactWindowID,
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: [
                "X": CGFloat(0),
                "Y": CGFloat(0),
                "Width": CGFloat(100),
                "Height": CGFloat(100),
            ],
            kCGWindowLayer as String: Int32(0),
            kCGWindowIsOnscreen as String: true,
        ]]
    }

    func getRunningApplicationBundleID(pid _: pid_t) -> String? {
        "com.example.discovery"
    }

    func createAXApplication(pid requestedPID: Int32) -> AnyObject? {
        requestedPID == pid ? application : nil
    }

    func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        if CFEqual(element, application) {
            if attribute == kAXWindowsAttribute as String {
                return forceChildFallback ? [] : [foreignWindow, exactWindow]
            }
            if attribute == kAXChildrenAttribute as String {
                return [foreignWindow, exactWindow]
            }
            return nil
        }
        if attribute == kAXRoleAttribute as String,
           CFEqual(element, exactWindow) || CFEqual(element, foreignWindow)
        {
            lock.lock()
            childRoleReads += 1
            let shouldCancel = cancelAfterFirstChildRoleRead && childRoleReads == 1
            lock.unlock()
            if shouldCancel {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return kAXWindowRole as String
        }
        return nil
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element _: AnyObject, attribute _: String, value _: Any) -> Int32 {
        lock.lock()
        setCalls += 1
        lock.unlock()
        return AXError.cannotComplete.rawValue
    }

    func performAXAction(element _: AnyObject, action _: String) -> Int32 {
        AXError.cannotComplete.rawValue
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        if CFEqual(element, exactWindow) {
            return exactWindowID
        }
        if CFEqual(element, foreignWindow) {
            return exactWindowID + 1
        }
        return nil
    }

    func setCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return setCalls
    }

    func childRoleReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return childRoleReads
    }
}

private final class LockedElementIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    private var index = 0

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard index < values.count else {
            defer { index += 1 }
            return "fallback-\(index)"
        }
        defer { index += 1 }
        return values[index]
    }

    func generatedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

private final class LockedElementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func withElementDiscoveryClient(
    _ service: ExactMacService,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let inProcess = InProcessTransport()
    let server = GRPCServer(transport: inProcess.server, services: [service])
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

private func elementDiscoveryUnary<
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

private func waitForElementDiscovery(
    _ condition: @escaping @Sendable () async -> Bool,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await !condition() {
        guard clock.now < deadline else {
            throw ElementDiscoveryTestError.timeout
        }
        await Task.yield()
    }
}

private enum ElementDiscoveryTestError: Error {
    case timeout
}
