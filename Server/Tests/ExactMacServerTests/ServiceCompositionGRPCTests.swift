import ApplicationServices
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
struct ServiceCompositionGRPCTests {
    @Test
    func `installed composition defaults to production operations`() {
        let composition = ExactMacServiceComposition()
        let systemType = String(reflecting: type(of: composition.system))
        let serviceSystemType = String(reflecting: type(of: composition.exactMacService.system))
        let expectedType = String(reflecting: ProductionSystemOperations.self)

        #expect(systemType == expectedType)
        #expect(serviceSystemType == expectedType)
    }

    @Test
    func `installed composition injects one coordinator into every physical producer`() {
        let composition = ExactMacServiceComposition()

        #expect(composition.exactMacService.automationCoordinator === composition.automationCoordinator)
        #expect(composition.exactMacService.elementRegistry === composition.elementRegistry)
        #expect(composition.exactMacService.elementLocator === composition.elementLocator)
        #expect(composition.exactMacService.observationManager === composition.observationManager)
        #expect(composition.exactMacService.macroExecutor === composition.macroExecutor)
        #expect(
            composition.exactMacService.inputTransactionExecutor
                === composition.inputTransactionExecutor,
        )
        #expect(
            composition.macroExecutor.inputTransactionExecutor
                === composition.inputTransactionExecutor,
        )
        #expect(composition.inputTransactionExecutor.stateStore === composition.stateStore)
        #expect(composition.inputTransactionExecutor.windowRegistry === composition.windowRegistry)
        #expect(
            composition.inputTransactionExecutor.automationCoordinator
                === composition.automationCoordinator,
        )
        #expect(
            composition.inputTransactionExecutor.system as AnyObject
                === composition.system as AnyObject,
        )
        #expect(composition.exactMacService.sessionManager === composition.sessionManager)
        #expect(composition.exactMacService.scriptExecutor === composition.scriptExecutor)
        #expect(composition.exactMacService.clipboardManager === composition.clipboardManager)
        #expect(composition.exactMacService.clipboardHistoryManager === composition.clipboardHistoryManager)
        #expect(composition.scriptExecutor.mutationGate === composition.automationCoordinator.mutationGate)
        #expect(composition.clipboardManager.mutationGate === composition.automationCoordinator.mutationGate)
        #expect(composition.clipboardManager.historyManager === composition.clipboardHistoryManager)
        #expect(composition.automationCoordinator.elementRegistry === composition.elementRegistry)
        #expect(composition.elementLocator.elementRegistry === composition.elementRegistry)
        #expect(composition.macroExecutor.elementRegistry === composition.elementRegistry)
        #expect(composition.macroExecutor.elementLocator === composition.elementLocator)
        #expect(composition.observationManager.automationCoordinator === composition.automationCoordinator)
        #expect(composition.macroExecutor.automationCoordinator === composition.automationCoordinator)
        #expect(composition.exactMacService.physicalDesktopMutationGate === composition.automationCoordinator.mutationGate)
    }

    @Test
    func `element resource round trips and rejects a foreign application owner`() async throws {
        let composition = ExactMacServiceComposition(legacyPIDResourceNamesForTests: true)
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "button"
                $0.text = "Owned"
            },
            pid: 111,
        )
        let secondElementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "text field"
                $0.text = "Second"
            },
            pid: 111,
        )
        _ = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with { $0.role = "foreign" },
            pid: 222,
        )
        let ownedName = "applications/111/elements/\(elementID)"
        let foreignName = "applications/222/elements/\(elementID)"

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

            let element: Exactmac_V1_Element = try await unary(
                client: client,
                request: Exactmac_V1_GetElementRequest.with { $0.name = ownedName },
                descriptor: Exactmac_V1_ExactMac.Method.GetElement.descriptor,
            )
            #expect(element.name == ownedName)
            #expect(element.elementID == elementID)

            let actions: Exactmac_V1_ElementActions = try await unary(
                client: client,
                request: Exactmac_V1_GetElementActionsRequest.with { $0.name = ownedName },
                descriptor: Exactmac_V1_ExactMac.Method.GetElementActions.descriptor,
            )
            #expect(!actions.actions.isEmpty)

            let firstPage: Exactmac_V1_ListElementsResponse = try await unary(
                client: client,
                request: Exactmac_V1_ListElementsRequest.with {
                    $0.parent = "applications/111"
                    $0.pageSize = 1
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
            )
            #expect(firstPage.elements.count == 1)
            #expect(!firstPage.nextPageToken.isEmpty)
            #expect(firstPage.elements[0].name.hasPrefix("applications/111/elements/"))

            var mutatedTokenBytes = Array(firstPage.nextPageToken.utf8)
            let mutationIndex = mutatedTokenBytes.count / 2
            mutatedTokenBytes[mutationIndex] = mutatedTokenBytes[mutationIndex] == 65 ? 66 : 65
            let mutatedToken = try #require(String(bytes: mutatedTokenBytes, encoding: .utf8))
            do {
                let _: Exactmac_V1_ListElementsResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_ListElementsRequest.with {
                        $0.parent = "applications/111"
                        $0.pageSize = 1
                        $0.pageToken = mutatedToken
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                )
                Issue.record("Expected mutated ListElements page_token to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            let secondPage: Exactmac_V1_ListElementsResponse = try await unary(
                client: client,
                request: Exactmac_V1_ListElementsRequest.with {
                    $0.parent = "applications/111"
                    $0.pageSize = 1
                    $0.pageToken = firstPage.nextPageToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
            )
            #expect(secondPage.elements.count == 1)
            #expect(secondPage.nextPageToken.isEmpty)
            let listedNames = (firstPage.elements + secondPage.elements).map(\.name)
            #expect(listedNames == listedNames.sorted())
            #expect(Set(listedNames) == Set([ownedName, "applications/111/elements/\(secondElementID)"]))

            do {
                let _: Exactmac_V1_ListElementsResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_ListElementsRequest.with {
                        $0.parent = "applications/111/extra"
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                )
                Issue.record("Expected malformed ListElements parent to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            do {
                let _: Exactmac_V1_ListElementsResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_ListElementsRequest.with {
                        $0.parent = "applications/111"
                        $0.pageSize = -1
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                )
                Issue.record("Expected negative ListElements page_size to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            do {
                let _: Exactmac_V1_ListElementsResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_ListElementsRequest.with {
                        $0.parent = "applications/111"
                        $0.pageToken = ParsingHelpers.encodePageToken(
                            offset: 3,
                            queryBinding: ParsingHelpers.pageTokenQuery(
                                method: "ListElements",
                                parameters: [
                                    ("parent", "applications/111"),
                                ],
                            ),
                        )
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                )
                Issue.record("Expected out-of-range ListElements page_token to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            do {
                let _: Exactmac_V1_ListElementsResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_ListElementsRequest.with {
                        $0.parent = "applications/222"
                        $0.pageToken = firstPage.nextPageToken
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                )
                Issue.record("Expected cross-query ListElements token reuse to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            var unknownListBytes = try Exactmac_V1_ListElementsRequest.with {
                $0.parent = "applications/111"
            }.serializedData()
            unknownListBytes.append(contentsOf: [0xA0, 0x06, 0x01])
            let unknownListRequest = try Exactmac_V1_ListElementsRequest(
                serializedBytes: unknownListBytes,
            )
            #expect(!unknownListRequest.unknownFields.data.isEmpty)
            do {
                let _: Exactmac_V1_ListElementsResponse = try await unary(
                    client: client,
                    request: unknownListRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                )
                Issue.record("Expected unknown ListElements intent to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            do {
                let _: Exactmac_V1_Element = try await unary(
                    client: client,
                    request: Exactmac_V1_GetElementRequest.with { $0.name = foreignName },
                    descriptor: Exactmac_V1_ExactMac.Method.GetElement.descriptor,
                )
                Issue.record("Expected foreign-owner GetElement to fail")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }

            var unknownGetBytes = try Exactmac_V1_GetElementRequest.with {
                $0.name = ownedName
            }.serializedData()
            unknownGetBytes.append(contentsOf: [0xA0, 0x06, 0x01])
            let unknownGetRequest = try Exactmac_V1_GetElementRequest(
                serializedBytes: unknownGetBytes,
            )
            do {
                let _: Exactmac_V1_Element = try await unary(
                    client: client,
                    request: unknownGetRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.GetElement.descriptor,
                )
                Issue.record("Expected unknown GetElement intent to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }

            do {
                let _: Exactmac_V1_ElementActions = try await unary(
                    client: client,
                    request: Exactmac_V1_GetElementActionsRequest.with { $0.name = foreignName },
                    descriptor: Exactmac_V1_ExactMac.Method.GetElementActions.descriptor,
                )
                Issue.record("Expected foreign-owner GetElementActions to fail")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }

            var unknownActionsBytes = try Exactmac_V1_GetElementActionsRequest.with {
                $0.name = ownedName
            }.serializedData()
            unknownActionsBytes.append(contentsOf: [0xA0, 0x06, 0x01])
            let unknownActionsRequest = try Exactmac_V1_GetElementActionsRequest(
                serializedBytes: unknownActionsBytes,
            )
            do {
                let _: Exactmac_V1_ElementActions = try await unary(
                    client: client,
                    request: unknownActionsRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.GetElementActions.descriptor,
                )
                Issue.record("Expected unknown GetElementActions intent to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
        }
    }

    @Test
    func `element mutation resolves owner after admission and reaches zero sinks when stale`() async throws {
        let gate = PhysicalDesktopMutationGate()
        let system = MockSystemOperations(setAXAttributeResult: AXError.success.rawValue)
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                Issue.record("Stale element mutation reached the input sink")
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let axElement = AXUIElementCreateSystemWide()
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "AXTextField"
                $0.text = "before"
                $0.x = 10
                $0.y = 10
                $0.width = 100
                $0.height = 30
            },
            axElement: axElement,
            pid: 2468,
        )
        let request = Exactmac_V1_WriteElementValueRequest.with {
            $0.parent = "applications/2468"
            $0.elementID = elementID
            $0.value = "after"
        }

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

            let blocker = BlockingMutationLifecycleRecorder()
            let heldMutation = Task {
                try await gate.withExclusiveOperation {
                    await blocker.execute(label: 1)
                }
            }
            try await waitForMutationLifecycleEntered(blocker, count: 1)

            let write = Task {
                let response: Exactmac_V1_WriteElementValueResponse = try await unary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.WriteElementValue.descriptor,
                )
                return response
            }
            try await waitForMutationQueue(gate, count: 1)
            #expect(system.setAXAttributeCalls.isEmpty)

            _ = await composition.elementRegistry.clearElements(forPid: 2468)
            await blocker.release(label: 1)
            try await heldMutation.value

            do {
                _ = try await write.value
                Issue.record("Expected post-admission element re-resolution to fail")
            } catch let error as RPCError {
                #expect(error.code == .notFound)
            }
            #expect(system.setAXAttributeCalls.isEmpty)
        }
    }

    @Test
    func `cross-parent element mutation fails before every injected sink`() async throws {
        let system = MockSystemOperations(setAXAttributeResult: AXError.success.rawValue)
        let inputRecorder = InputActionCapture()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await inputRecorder.record(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "AXTextField"
                $0.text = "before"
                $0.x = 10
                $0.y = 10
                $0.width = 100
                $0.height = 30
            },
            axElement: AXUIElementCreateSystemWide(),
            pid: 111,
        )

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

            let writeRequest = Exactmac_V1_WriteElementValueRequest.with {
                $0.parent = "applications/222"
                $0.elementID = elementID
                $0.value = "after"
            }
            do {
                let _: Exactmac_V1_WriteElementValueResponse = try await unary(
                    client: client,
                    request: writeRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.WriteElementValue.descriptor,
                )
                Issue.record("Expected cross-parent write rejection")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition)
            }

            let actionRequest = Exactmac_V1_PerformElementActionRequest.with {
                $0.parent = "applications/222"
                $0.elementID = elementID
                $0.action = "AXPress"
            }
            do {
                let _: Exactmac_V1_PerformElementActionResponse = try await unary(
                    client: client,
                    request: actionRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.PerformElementAction.descriptor,
                )
                Issue.record("Expected cross-parent action rejection")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition)
            }

            let clickRequest = Exactmac_V1_ClickElementRequest.with {
                $0.parent = "applications/222"
                $0.elementID = elementID
                $0.clickType = .single
            }
            do {
                let _: Exactmac_V1_ClickElementResponse = try await unary(
                    client: client,
                    request: clickRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.ClickElement.descriptor,
                )
                Issue.record("Expected cross-parent click rejection")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition)
            }

            #expect(system.setAXAttributeCalls.isEmpty)
            #expect(await inputRecorder.snapshot().isEmpty)
        }
    }

    @Test
    func `WriteElementValue returns converged readback from the exact owned element`() async throws {
        let system = MockSystemOperations(
            axAttributes: [
                kAXFrontmostAttribute as String: true,
                kAXRoleAttribute as String: kAXWindowRole as String,
                kAXMainAttribute as String: true,
                kAXFocusedAttribute as String: true,
                kAXValueAttribute as String: "before",
            ],
            setAXAttributeResult: AXError.success.rawValue,
            applySuccessfulAXWritesToAttributes: true,
        )
        let coordinator = AutomationCoordinator(activationSystem: system)
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "AXTextField"
                $0.text = "before"
                $0.x = Double(displayBounds.midX - 50)
                $0.y = Double(displayBounds.midY - 15)
                $0.width = 100
                $0.height = 30
            },
            axElement: AXUIElementCreateSystemWide(),
            pid: 2468,
        )

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

            let response: Exactmac_V1_WriteElementValueResponse = try await unary(
                client: client,
                request: Exactmac_V1_WriteElementValueRequest.with {
                    $0.parent = "applications/2468"
                    $0.elementID = elementID
                    $0.value = "after"
                },
                descriptor: Exactmac_V1_ExactMac.Method.WriteElementValue.descriptor,
            )

            #expect(response.success)
            #expect(response.element.elementID == elementID)
            #expect(response.element.text == "after")
            let valueWrites = system.setAXAttributeCalls.filter {
                $0.attribute == kAXValueAttribute as String
            }
            #expect(valueWrites.count == 1)
            #expect(valueWrites.first?.value as? String == "after")
            #expect(system.copyAXAttributeCalls.contains {
                $0.attribute == kAXValueAttribute as String
            })
            #expect(await composition.elementRegistry.getElement(elementID)?.text == "after")
            #expect(await coordinator.activeMutationCount() == 0)
        }
    }

    @Test
    func `PerformElementAction uses injected AX sink and returns the exact live element`() async throws {
        let system = MockSystemOperations(
            axAttributes: [
                kAXFrontmostAttribute as String: true,
                kAXRoleAttribute as String: kAXWindowRole as String,
                kAXMainAttribute as String: true,
                kAXFocusedAttribute as String: true,
                kAXValueAttribute as String: "Press me",
            ],
            setAXAttributeResult: AXError.success.rawValue,
            performAXActionResult: AXError.success.rawValue,
        )
        let coordinator = AutomationCoordinator(activationSystem: system)
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "AXButton"
                $0.text = "Press me"
            },
            axElement: AXUIElementCreateSystemWide(),
            pid: 9753,
        )

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

            let response: Exactmac_V1_PerformElementActionResponse = try await unary(
                client: client,
                request: Exactmac_V1_PerformElementActionRequest.with {
                    $0.parent = "applications/9753"
                    $0.elementID = elementID
                    $0.action = "AXPress"
                },
                descriptor: Exactmac_V1_ExactMac.Method.PerformElementAction.descriptor,
            )

            #expect(response.success)
            #expect(response.element.elementID == elementID)
            #expect(response.element.text == "Press me")
            #expect(system.performAXActionCalls == [
                .init(action: kAXPressAction as String),
            ])
            #expect(await composition.elementRegistry.getElement(elementID)?.elementID == elementID)
            #expect(await coordinator.activeMutationCount() == 0)
        }
    }

    @Test
    func `C16 PerformElementAction maps a failed AX action to failedPrecondition`() async throws {
        // C16: a failed AX action is a precondition failure (the action does
        // not apply in the element's current state), NOT a server-internal
        // error. The gRPC code MUST be .failedPrecondition, not .internalError.
        let system = MockSystemOperations(
            axAttributes: [
                kAXFrontmostAttribute as String: true,
                kAXRoleAttribute as String: kAXWindowRole as String,
                kAXMainAttribute as String: true,
                kAXFocusedAttribute as String: true,
            ],
            setAXAttributeResult: AXError.success.rawValue,
            // actionUnsupported signals the element does not support the action.
            performAXActionResult: AXError.actionUnsupported.rawValue,
        )
        let coordinator = AutomationCoordinator(activationSystem: system)
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with { $0.role = "AXButton" },
            axElement: AXUIElementCreateSystemWide(),
            pid: 9754,
        )

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

            do {
                let _: Exactmac_V1_PerformElementActionResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_PerformElementActionRequest.with {
                        $0.parent = "applications/9754"
                        $0.elementID = elementID
                        $0.action = "AXPress"
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.PerformElementAction.descriptor,
                )
                Issue.record("Expected a failed AX action to throw")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition, "C16: failed AX action must be failedPrecondition, got \(error.code)")
            }
            #expect(await coordinator.activeMutationCount() == 0)
        }
    }

    @Test
    func `C22 PerformElementAction showMenu failure guides to coordinate right-click`() async throws {
        // C22: when kAXShowMenuAction fails, the error MUST guide the agent to
        // the reliable alternative — a coordinate-based right click (the click
        // tool with button "right") after reading bounds — rather than the old
        // "use click_element or a typed input tool" advice that opens no menu.
        let system = MockSystemOperations(
            axAttributes: [
                kAXFrontmostAttribute as String: true,
                kAXRoleAttribute as String: kAXWindowRole as String,
                kAXMainAttribute as String: true,
                kAXFocusedAttribute as String: true,
            ],
            setAXAttributeResult: AXError.success.rawValue,
            performAXActionResult: AXError.actionUnsupported.rawValue,
        )
        let coordinator = AutomationCoordinator(activationSystem: system)
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let elementID = try await composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with { $0.role = "AXButton" },
            axElement: AXUIElementCreateSystemWide(),
            pid: 9755,
        )

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

            do {
                let _: Exactmac_V1_PerformElementActionResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_PerformElementActionRequest.with {
                        $0.parent = "applications/9755"
                        $0.elementID = elementID
                        $0.action = "AXShowMenu"
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.PerformElementAction.descriptor,
                )
                Issue.record("Expected a failed showMenu to throw")
            } catch let error as RPCError {
                #expect(error.code == .failedPrecondition)
                #expect(error.message.contains("right"), "C22: showMenu failure must mention a right-click alternative (got: \(error.message))")
            }
            #expect(await coordinator.activeMutationCount() == 0)
        }
    }

    @Test
    func `WriteClipboard uses installed pasteboard and rejects invalid or drained work before mutation`() async throws {
        let gate = PhysicalDesktopMutationGate()
        let pasteboard = CompositionClipboardPasteboard()
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
        )
        let composition = ExactMacServiceComposition(
            system: system,
            automationCoordinator: coordinator,
            clipboardPasteboard: pasteboard,
        )
        let validRequest = Exactmac_V1_WriteClipboardRequest.with {
            $0.content = Exactmac_V1_ClipboardContent.with {
                $0.type = .text
                $0.content = .text("composition clipboard value")
            }
        }

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

            let response: Exactmac_V1_WriteClipboardResponse = try await unary(
                client: client,
                request: validRequest,
                descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
            )
            #expect(response.clipboard.name == "clipboard")
            #expect(response.clipboard.content.type == .text)
            #expect(response.clipboard.content.content == .text("composition clipboard value"))

            let successfulCalls = await pasteboard.recordedCalls()
            #expect(successfulCalls == [.clear, .write(.text), .read])
            let history = await composition.clipboardHistoryManager.getHistory()
            #expect(history.entries.count == 1)
            #expect(history.entries.first?.content.type == .text)

            let mismatchedRequest = Exactmac_V1_WriteClipboardRequest.with {
                $0.content = Exactmac_V1_ClipboardContent.with {
                    $0.type = .url
                    $0.content = .text("mismatched discriminator")
                }
            }
            do {
                let _: Exactmac_V1_WriteClipboardResponse = try await unary(
                    client: client,
                    request: mismatchedRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                )
                Issue.record("Expected mismatched clipboard content to fail")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
            let callsAfterInvalidRequest = await pasteboard.recordedCalls()
            #expect(callsAfterInvalidRequest == successfulCalls)

            await gate.beginDraining()
            do {
                let _: Exactmac_V1_WriteClipboardResponse = try await unary(
                    client: client,
                    request: validRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                )
                Issue.record("Expected drained clipboard admission to fail")
            } catch let error as RPCError {
                #expect(error.code == .unavailable)
            }
            let callsAfterDrain = await pasteboard.recordedCalls()
            #expect(callsAfterDrain == successfulCalls)
        }
    }

    @Test
    func `concurrent GetClipboard RPCs cannot overlap pasteboard access`() async throws {
        let pasteboard = BlockingCompositionClipboardPasteboard()
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            clipboardPasteboard: pasteboard,
        )
        let request = Exactmac_V1_GetClipboardRequest.with {
            $0.name = "clipboard"
        }

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

            let first = Task {
                let response: Exactmac_V1_Clipboard = try await unary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.GetClipboard.descriptor,
                )
                return response
            }
            await pasteboard.waitUntilFirstReadEntered()

            let second = Task {
                let response: Exactmac_V1_Clipboard = try await unary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.GetClipboard.descriptor,
                )
                return response
            }

            do {
                try await waitForClipboardAccessQueue(composition.clipboardManager, count: 1)
                #expect(await pasteboard.readCount() == 1)
                #expect(await pasteboard.maximumConcurrentReads() == 1)
                await pasteboard.releaseFirstRead()

                let firstResponse = try await first.value
                let secondResponse = try await second.value
                #expect(firstResponse.name == "clipboard")
                #expect(secondResponse.name == "clipboard")
                #expect(await pasteboard.readCount() == 2)
                #expect(await pasteboard.maximumConcurrentReads() == 1)
            } catch {
                await pasteboard.releaseFirstRead()
                first.cancel()
                second.cancel()
                _ = try? await first.value
                _ = try? await second.value
                throw error
            }
        }
    }

    @Test
    func `serialized MoveWindow mutates injected state and returns observed bounds`() async throws {
        let pid = getpid()
        let windowID: CGWindowID = 707
        let initialBounds = CGRect(x: 40, y: 60, width: 640, height: 480)
        let expectedOrigin = CGPoint(x: 280, y: 190)
        let system = StatefulWindowSystemOperations(
            pid: pid,
            windowID: windowID,
            title: "Injected owned window",
            bounds: initialBounds,
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
        )

        let compositionSystemType = String(reflecting: type(of: composition.system))
        let serviceSystemType = String(reflecting: type(of: composition.exactMacService.system))
        let expectedSystemType = String(reflecting: StatefulWindowSystemOperations.self)
        #expect(compositionSystemType == expectedSystemType)
        #expect(serviceSystemType == expectedSystemType)

        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: inProcess.server,
            services: [composition.exactMacService],
        )
        let client = GRPCClient(transport: inProcess.client)

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                try await server.serve()
            }
            group.addTask {
                try await client.runConnections()
            }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            let parent = "applications/\(pid)"
            let before: Exactmac_V1_ListWindowsResponse = try await unary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let beforeWindow = try #require(before.windows.first)
            let name = beforeWindow.name
            #expect(before.windows.count == 1)
            #expect(name.hasPrefix("\(parent)/windows/"))
            #expect(name != "\(parent)/windows/\(windowID)")
            #expect(beforeWindow.bounds.x == Double(initialBounds.origin.x))
            #expect(beforeWindow.bounds.y == Double(initialBounds.origin.y))

            let mutation: Exactmac_V1_Window = try await unary(
                client: client,
                request: Exactmac_V1_MoveWindowRequest.with {
                    $0.name = name
                    $0.x = expectedOrigin.x
                    $0.y = expectedOrigin.y
                },
                descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
            )
            #expect(mutation.name == name)
            #expect(mutation.bounds.x == Double(expectedOrigin.x))
            #expect(mutation.bounds.y == Double(expectedOrigin.y))

            let observed = try await pollUntilWindow(
                client: client,
                name: name,
                expectedOrigin: expectedOrigin,
            )
            #expect(observed.bounds.width == Double(initialBounds.width))
            #expect(observed.bounds.height == Double(initialBounds.height))

            let snapshot = system.snapshot()
            #expect(snapshot.origin == expectedOrigin)
            #expect(snapshot.positionSetCalls == 1)
            #expect(snapshot.axWindowsReads >= 1)
        }
    }

    @Test
    func `concurrent CreateInput RPCs remain FIFO across suspended execution`() async throws {
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let recorder = BlockingInputExecutionRecorder()
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            automationCoordinator: coordinator,
        )

        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: inProcess.server,
            services: [composition.exactMacService],
        )
        let client = GRPCClient(transport: inProcess.client)

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                try await server.serve()
            }
            group.addTask {
                try await client.runConnections()
            }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            let first = Task {
                let response: Exactmac_V1_Input = try await unary(
                    client: client,
                    request: createInjectedInputRequest(id: "first", x: 1),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                return response
            }
            try await waitForInputEntered(recorder, count: 1)

            let second = Task {
                let response: Exactmac_V1_Input = try await unary(
                    client: client,
                    request: createInjectedInputRequest(id: "second", x: 2),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                return response
            }

            do {
                try await waitForMutationQueue(gate, count: 1)
                let queued = await recorder.snapshot()
                #expect(queued.entered == [1])
                #expect(queued.maximumActive == 1)

                await recorder.release(label: 1)
                try await waitForInputEntered(recorder, count: 2)
                let promoted = await recorder.snapshot()
                #expect(promoted.entered == [1, 2])
                #expect(promoted.maximumActive == 1)
                await recorder.release(label: 2)

                let firstResponse = try await first.value
                let secondResponse = try await second.value
                #expect(firstResponse.name == "applications/-/inputs/first")
                #expect(secondResponse.name == "applications/-/inputs/second")
                #expect(firstResponse.state == .completed)
                #expect(secondResponse.state == .completed)
            } catch {
                first.cancel()
                second.cancel()
                await recorder.release(label: 1)
                await recorder.release(label: 2)
                throw error
            }
        }
    }

    @Test
    func `OpenApplication holds the shared gate through identity and state publication`() async throws {
        let pid: pid_t = 424_243
        let bundle = makeGRPCTestApplicationBundle("Calculator")
        let identity = ApplicationProcessIdentity(
            pid: pid,
            startTimeSeconds: 1_700_000_001,
            startTimeMicroseconds: 123_457,
            bundleIdentifier: "com.example.opened",
            executablePath: "/Applications/Opened.app/Contents/MacOS/Opened",
        )
        let identityBarrier = BlockingApplicationIdentityBarrier(identity: identity)
        let system = MockSystemOperations(
            applicationProcessIdentityHandler: { requestedPID in
                identityBarrier.resolve(pid: requestedPID)
            },
        )
        let stateStore = AppStateStore()
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let inputRecorder = BlockingInputExecutionRecorder()
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await inputRecorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
            applicationOpenExecutor: { applicationURL, _, mode in
                #expect(applicationURL == bundle.bundleURL)
                #expect(mode == .launchOrActivate)
                return ExactMac.AppOpenerResult(
                    pid: pid,
                    appName: "Calculator",
                    processingTimeSeconds: "0.001",
                    actionTaken: .launchedNew,
                    newProcessCreated: true,
                )
            },
        )
        let composition = ExactMacServiceComposition(
            stateStore: stateStore,
            system: system,
            applicationCatalogProvider: GRPCTestApplicationCatalog(bundles: [bundle]),
            automationCoordinator: coordinator,
        )
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

            let open = Task {
                let response: Exactmac_V1_OpenApplicationResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_OpenApplicationRequest.with {
                        $0.name = "applicationBundles/\(bundle.identity)"
                        $0.mode = .launchOrActivate
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.OpenApplication.descriptor,
                )
                return response
            }

            do {
                try await identityBarrier.waitUntilEntered()
                let input = Task {
                    let response: Exactmac_V1_Input = try await unary(
                        client: client,
                        request: createInjectedInputRequest(id: "after-open", x: 3),
                        descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    )
                    return response
                }
                do {
                    try await waitForMutationQueue(gate, count: 1)
                    let heldInput = await inputRecorder.snapshot()
                    let targetBeforeIdentity = await stateStore.getTarget(pid: pid)
                    #expect(heldInput.entered.isEmpty)
                    #expect(targetBeforeIdentity == nil)

                    identityBarrier.release()
                    let openResponse = try await open.value
                    #expect(openResponse.application.name == applicationResourceName(for: identity))
                    #expect(openResponse.application.pid == pid)
                    #expect(openResponse.disposition == .launchedNew)
                    let publishedIdentity = await stateStore.getApplicationProcessIdentity(pid: pid)
                    #expect(publishedIdentity == identity)

                    try await waitForInputEntered(inputRecorder, count: 1)
                    await inputRecorder.release(label: 3)
                    let inputResponse = try await input.value
                    #expect(inputResponse.state == .completed)
                } catch {
                    input.cancel()
                    await inputRecorder.release(label: 3)
                    throw error
                }
            } catch {
                open.cancel()
                identityBarrier.release()
                throw error
            }
        }
    }

    @Test
    func `cancelled queued OpenApplication never reaches its external sink`() async throws {
        let pid: pid_t = 424_244
        let bundle = makeGRPCTestApplicationBundle("Cancelled")
        let identity = ApplicationProcessIdentity(
            pid: pid,
            startTimeSeconds: 1_700_000_002,
            startTimeMicroseconds: 123_458,
            bundleIdentifier: "com.example.cancelled",
            executablePath: "/Applications/Cancelled.app/Contents/MacOS/Cancelled",
        )
        let system = MockSystemOperations(applicationIdentities: [pid: identity])
        let stateStore = AppStateStore()
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let inputRecorder = BlockingInputExecutionRecorder()
        let openRecorder = BlockingApplicationOpenRecorder(pid: pid)
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await inputRecorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
            applicationOpenExecutor: { applicationURL, background, mode in
                await openRecorder.open(
                    applicationURL: applicationURL,
                    background: background,
                    mode: mode,
                )
            },
        )
        let composition = ExactMacServiceComposition(
            stateStore: stateStore,
            system: system,
            applicationCatalogProvider: GRPCTestApplicationCatalog(bundles: [bundle]),
            automationCoordinator: coordinator,
        )
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

            let holder = Task {
                let response: Exactmac_V1_Input = try await unary(
                    client: client,
                    request: createInjectedInputRequest(id: "open-holder", x: 4),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                return response
            }
            try await waitForInputEntered(inputRecorder, count: 1)

            let callOptions: CallOptions = {
                var options = CallOptions.defaults
                options.timeout = .milliseconds(500)
                return options
            }()
            let open = Task {
                let response: Exactmac_V1_OpenApplicationResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_OpenApplicationRequest.with {
                        $0.name = "applicationBundles/\(bundle.identity)"
                        $0.mode = .forceNewInstance
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.OpenApplication.descriptor,
                    options: callOptions,
                )
                return response
            }

            do {
                try await waitForMutationQueue(gate, count: 1)
                try await waitForMutationQueue(gate, count: 0)
                do {
                    _ = try await open.value
                    Issue.record("Expected queued OpenApplication deadline cancellation")
                } catch {
                    // Expected public generated-client deadline cancellation.
                }

                let calls = await openRecorder.calls()
                let target = await stateStore.getTarget(pid: pid)
                #expect(calls.isEmpty)
                #expect(target == nil)

                await inputRecorder.release(label: 4)
                let holderResponse = try await holder.value
                #expect(holderResponse.state == .completed)
            } catch {
                holder.cancel()
                open.cancel()
                await inputRecorder.release(label: 4)
                await openRecorder.release()
                throw error
            }
        }
    }

    @Test
    func `cancelled admitted OpenApplication still publishes exact ownership`() async throws {
        let pid: pid_t = 424_245
        let bundle = makeGRPCTestApplicationBundle("Admitted")
        let identity = ApplicationProcessIdentity(
            pid: pid,
            startTimeSeconds: 1_700_000_003,
            startTimeMicroseconds: 123_459,
            bundleIdentifier: "com.example.admitted",
            executablePath: "/Applications/Admitted.app/Contents/MacOS/Admitted",
        )
        let system = MockSystemOperations(applicationIdentities: [pid: identity])
        let stateStore = AppStateStore()
        let openRecorder = BlockingApplicationOpenRecorder(pid: pid)
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            applicationOpenExecutor: { applicationURL, background, mode in
                await openRecorder.open(
                    applicationURL: applicationURL,
                    background: background,
                    mode: mode,
                )
            },
        )
        let composition = ExactMacServiceComposition(
            stateStore: stateStore,
            system: system,
            applicationCatalogProvider: GRPCTestApplicationCatalog(bundles: [bundle]),
            automationCoordinator: coordinator,
        )
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

            let open = Task {
                let response: Exactmac_V1_OpenApplicationResponse = try await unary(
                    client: client,
                    request: Exactmac_V1_OpenApplicationRequest.with {
                        $0.name = "applicationBundles/\(bundle.identity)"
                        $0.mode = .launchOrActivate
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.OpenApplication.descriptor,
                )
                return response
            }

            do {
                try await waitForApplicationOpenEntered(openRecorder, count: 1)
                open.cancel()
                do {
                    _ = try await open.value
                    Issue.record("Expected admitted caller cancellation")
                } catch {
                    // The caller is cancelled, but admitted external work remains owned.
                }

                await openRecorder.release()
                try await waitForApplicationTarget(stateStore, pid: pid)
                let target = await stateStore.getTarget(pid: pid)
                let publishedIdentity = await stateStore.getApplicationProcessIdentity(pid: pid)
                #expect(target?.name == applicationResourceName(for: identity))
                #expect(publishedIdentity == identity)
            } catch {
                open.cancel()
                await openRecorder.release()
                throw error
            }
        }
    }

    @Test
    func `MoveWindow shares the injected physical desktop gate with CreateInput`() async throws {
        let pid = getpid()
        let windowID: CGWindowID = 708
        let initialBounds = CGRect(x: 40, y: 60, width: 640, height: 480)
        let expectedOrigin = CGPoint(x: 310, y: 220)
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let recorder = BlockingInputExecutionRecorder()
        let system = StatefulWindowSystemOperations(
            pid: pid,
            windowID: windowID,
            title: "Injected gated window",
            bounds: initialBounds,
        )
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )

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

            let input = Task {
                let response: Exactmac_V1_Input = try await unary(
                    client: client,
                    request: createInjectedInputRequest(id: "gate-holder", x: 1),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                return response
            }
            try await waitForInputEntered(recorder, count: 1)

            let parent = "applications/\(pid)"
            let listed: Exactmac_V1_ListWindowsResponse = try await unary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let windowName = try #require(listed.windows.first?.name)
            let move = Task {
                let response: Exactmac_V1_Window = try await unary(
                    client: client,
                    request: Exactmac_V1_MoveWindowRequest.with {
                        $0.name = windowName
                        $0.x = expectedOrigin.x
                        $0.y = expectedOrigin.y
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
                )
                return response
            }

            do {
                try await waitForMutationQueue(gate, count: 1)
                #expect(system.snapshot().positionSetCalls == 0)

                await recorder.release(label: 1)
                let inputResponse = try await input.value
                let movedWindow = try await move.value
                #expect(inputResponse.state == .completed)
                #expect(movedWindow.bounds.x == Double(expectedOrigin.x))
                #expect(movedWindow.bounds.y == Double(expectedOrigin.y))
                #expect(system.snapshot().positionSetCalls == 1)
            } catch {
                input.cancel()
                move.cancel()
                await recorder.release(label: 1)
                throw error
            }
        }
    }

    @Test
    func `MoveWindow holds the gate through observed response construction`() async throws {
        let pid = getpid()
        let windowID: CGWindowID = 709
        let expectedOrigin = CGPoint(x: 330, y: 240)
        let responseBarrier = BlockingWindowListBarrier()
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let recorder = BlockingInputExecutionRecorder()
        let system = StatefulWindowSystemOperations(
            pid: pid,
            windowID: windowID,
            title: "Injected observed window",
            bounds: CGRect(x: 40, y: 60, width: 640, height: 480),
            postMutationWindowListBarrier: responseBarrier,
        )
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )

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

            let parent = "applications/\(pid)"
            let listed: Exactmac_V1_ListWindowsResponse = try await unary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with { $0.parent = parent },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let windowName = try #require(listed.windows.first?.name)
            let move = Task {
                let response: Exactmac_V1_Window = try await unary(
                    client: client,
                    request: Exactmac_V1_MoveWindowRequest.with {
                        $0.name = windowName
                        $0.x = expectedOrigin.x
                        $0.y = expectedOrigin.y
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
                )
                return response
            }

            do {
                try await responseBarrier.waitUntilEntered()
                #expect(system.snapshot().positionSetCalls == 1)

                let input = Task {
                    let response: Exactmac_V1_Input = try await unary(
                        client: client,
                        request: createInjectedInputRequest(id: "post-mutation", x: 2),
                        descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    )
                    return response
                }
                do {
                    try await waitForMutationQueue(gate, count: 1)
                    let heldSnapshot = await recorder.snapshot()
                    #expect(heldSnapshot.entered.isEmpty)

                    responseBarrier.release()
                    let movedWindow = try await move.value
                    #expect(movedWindow.bounds.x == Double(expectedOrigin.x))
                    #expect(movedWindow.bounds.y == Double(expectedOrigin.y))

                    try await waitForInputEntered(recorder, count: 1)
                    await recorder.release(label: 2)
                    let inputResponse = try await input.value
                    #expect(inputResponse.state == .completed)
                } catch {
                    input.cancel()
                    await recorder.release(label: 2)
                    throw error
                }
            } catch {
                move.cancel()
                responseBarrier.release()
                throw error
            }
        }
    }

    @Test
    func `retained input semantics execute through generated CreateInput client`() async throws {
        let recorder = InputActionCapture()
        let eventBackend = ProductionPathInputEventBackend()
        let applicationName = "applications/424247"
        let keyboardSource = KeyboardInputSourceIdentity(
            sourceID: "com.example.retained-input",
            unicodeLayoutSHA256: String(repeating: "2", count: 64),
            keyboardType: 41,
        )
        let system = MockSystemOperations(
            axAttributes: [kAXFrontmostAttribute as String: true],
        )
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputKeyResolver: { key in
                if key == "v" {
                    return ResolvedInputKey(keyCode: 9, sourceIdentity: keyboardSource)
                }
                return ResolvedInputKey(
                    keyCode: ExactMac.KEY_RETURN,
                    sourceIdentity: nil,
                )
            },
            keyboardInputSourceIdentityProvider: { keyboardSource },
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action)
                try await ExactMac.executeInputAction(
                    action,
                    backend: eventBackend,
                )
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
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

            let click: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "click"
                    $0.input.target.desktop = true
                    $0.input.action.mouseClick = Exactmac_V1_MouseClick.with {
                        $0.position = Exactmac_Type_Point.with {
                            $0.x = 10
                            $0.y = 20
                        }
                        $0.clickType = .middle
                        $0.clickCount = 3
                        $0.modifiers = [.command, .capsLock]
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            let typeText: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = applicationName
                    $0.inputID = "type"
                    $0.input.target.application = applicationName
                    $0.input.action.textInput = Exactmac_V1_TextInput.with {
                        $0.text = "ab"
                        $0.charDelay = 0.125
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            let key: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "key"
                    $0.input.target.desktop = true
                    $0.input.action.keyPress = Exactmac_V1_KeyPress.with {
                        $0.key = "return"
                        $0.modifiers = [.option, .control]
                        $0.holdDuration = 0.25
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            let move: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "move"
                    $0.input.target.desktop = true
                    $0.input.action.mouseMove = Exactmac_V1_MouseMove.with {
                        $0.position = Exactmac_Type_Point.with {
                            $0.x = 30
                            $0.y = 40
                        }
                        $0.duration = 0.75
                        $0.modifiers = [.function]
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            let drag: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "drag"
                    $0.input.target.desktop = true
                    $0.input.action.mouseDrag = Exactmac_V1_MouseDrag.with {
                        $0.startPosition = Exactmac_Type_Point.with { $0.x = 1; $0.y = 2 }
                        $0.endPosition = Exactmac_Type_Point.with { $0.x = 5; $0.y = 6 }
                        $0.waypoints = [
                            Exactmac_Type_Point.with { $0.x = 1; $0.y = 2 },
                            Exactmac_Type_Point.with { $0.x = 3; $0.y = 9 },
                            Exactmac_Type_Point.with { $0.x = 5; $0.y = 6 },
                        ]
                        $0.button = .right
                        $0.duration = 1.5
                        $0.modifiers = [.shift]
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            let scroll: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "scroll"
                    $0.input.target.desktop = true
                    $0.input.action.scrollAction = Exactmac_V1_Scroll.with {
                        $0.position = Exactmac_Type_Point.with {
                            $0.x = 100
                            $0.y = 200
                        }
                        $0.horizontal = 3
                        $0.vertical = -7
                        $0.duration = 0.25
                        $0.modifiers = [.shift]
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            let hover: Exactmac_V1_Input = try await unary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "hover"
                    $0.input.target.desktop = true
                    $0.input.action.hoverAction = Exactmac_V1_Hover.with {
                        $0.position = Exactmac_Type_Point.with {
                            $0.x = 300
                            $0.y = 400
                        }
                        $0.duration = 0.5
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )

            let completedInputs = [click, typeText, key, move, drag, scroll, hover]
            #expect(completedInputs.allSatisfy { input in
                input.state == .completed
                    && input.hasCompleteTime
                    && input.error.isEmpty
                    && input.deliveryResult.commitment == .committedAndSettled
                    && input.deliveryResult.routedDeliveryObserved
            })
            #expect(typeText.target.application == applicationName)
            #expect(
                [click, key, move, drag, scroll, hover].map(\.target.desktop)
                    == Array(repeating: true, count: 6),
            )
            #expect(
                completedInputs.map(\.deliveryResult.postedEventCount)
                    == [6, 4, 2, 20, 4, 7, 1],
            )
            #expect(
                completedInputs.map(\.name) == [
                    "applications/-/inputs/click",
                    "\(applicationName)/inputs/type",
                    "applications/-/inputs/key",
                    "applications/-/inputs/move",
                    "applications/-/inputs/drag",
                    "applications/-/inputs/scroll",
                    "applications/-/inputs/hover",
                ],
            )
            let actions = await recorder.snapshot()
            #expect(actions.count == 7)
            if case let .clickSequence(point, button, count, modifiers) = actions[0] {
                #expect(point == CGPoint(x: 10, y: 20))
                #expect(button == .center)
                #expect(count == 3)
                #expect(modifiers == [.maskCommand, .maskAlphaShift])
            } else {
                Issue.record("Expected semantic click sequence")
            }
            if case let .typeText(text, delay) = actions[1] {
                #expect(text == "ab")
                #expect(delay == 0.125)
            } else {
                Issue.record("Expected semantic text action")
            }
            if case let .pressKeyCodeHold(keyCode, modifiers, duration) = actions[2] {
                #expect(keyCode == ExactMac.KEY_RETURN)
                #expect(modifiers == [.maskAlternate, .maskControl])
                #expect(duration == 0.25)
            } else {
                Issue.record("Expected semantic held key action")
            }
            if case let .movePointer(point, duration, modifiers) = actions[3] {
                #expect(point == CGPoint(x: 30, y: 40))
                #expect(duration == 0.75)
                #expect(modifiers == .maskSecondaryFn)
            } else {
                Issue.record("Expected semantic move action")
            }
            if case let .dragPath(points, button, duration, modifiers) = actions[4] {
                #expect(points == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 9), CGPoint(x: 5, y: 6)])
                #expect(button == .right)
                #expect(duration == 1.5)
                #expect(modifiers == .maskShift)
            } else {
                Issue.record("Expected semantic drag path")
            }
            if case let .scroll(point, horizontal, vertical, duration, modifiers) = actions[5] {
                #expect(point == CGPoint(x: 100, y: 200))
                #expect(horizontal == 3)
                #expect(vertical == -7)
                #expect(duration == 0.25)
                #expect(modifiers == .maskShift)
            } else {
                Issue.record("Expected semantic scroll action")
            }
            if case let .hover(point, duration) = actions[6] {
                #expect(point == CGPoint(x: 300, y: 400))
                #expect(duration == 0.5)
            } else {
                Issue.record("Expected semantic hover action")
            }
            assertRetainedInputEvents(eventBackend.snapshot())
        }
    }

    @Test
    func `unknown removed input intent fails before execution and state insertion`() async throws {
        let recorder = InputActionCapture()
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            automationCoordinator: coordinator,
        )
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

            let knownAction = Exactmac_V1_InputAction.with {
                $0.mouseClick = Exactmac_V1_MouseClick.with {
                    $0.position = Exactmac_Type_Point.with { $0.x = 10; $0.y = 20 }
                }
            }
            // Removed field 18 (button_down), length-delimited empty message.
            var actionBytes = try knownAction.serializedData()
            actionBytes.append(contentsOf: [0x92, 0x01, 0x00])
            let action = try Exactmac_V1_InputAction(serializedBytes: actionBytes)
            do {
                let _: Exactmac_V1_Input = try await unary(
                    client: client,
                    request: Exactmac_V1_CreateInputRequest.with {
                        $0.parent = "applications/-"
                        $0.inputID = "removed-intent"
                        $0.input.target.desktop = true
                        $0.input.action = action
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                Issue.record("Expected invalid argument for removed input intent")
            } catch {
                // Expected public-boundary rejection.
            }

            #expect(await recorder.snapshot().isEmpty)
            let inputState = await composition.exactMacService.stateStore.currentState()
            #expect(inputState.inputs.isEmpty)
            #expect(await composition.exactMacService.stateStore.activeInputIdentityCount() == 0)
            #expect(await composition.exactMacService.stateStore.inputStateHistoryCount() == 0)
            #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        }
    }
}

private func makeGRPCTestApplicationBundle(_ name: String) -> ApplicationBundleInfo {
    let url = canonicalApplicationBundleURL(
        URL(fileURLWithPath: "/Applications/\(name).app"),
    )
    return ApplicationBundleInfo(
        identity: applicationBundleIdentity(for: url),
        displayName: name,
        bundleID: "com.example.\(name.lowercased())",
        bundleURL: url,
        version: nil,
    )
}

private final class GRPCTestApplicationCatalog: ApplicationCatalogProvider, @unchecked Sendable {
    private let bundles: [ApplicationBundleInfo]

    init(bundles: [ApplicationBundleInfo]) {
        self.bundles = bundles
    }

    func applicationBundles() async -> [ApplicationBundleInfo] {
        bundles
    }

    func runningApplications() async -> [RunningApplicationInfo] {
        []
    }
}

private actor BlockingApplicationOpenRecorder {
    struct Call: Equatable, Sendable {
        let applicationURL: URL
        let background: Bool
        let mode: ExactMac.AppLaunchMode
    }

    private let pid: pid_t
    private var recordedCalls: [Call] = []
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(pid: pid_t) {
        self.pid = pid
    }

    func open(
        applicationURL: URL,
        background: Bool,
        mode: ExactMac.AppLaunchMode,
    ) async -> ExactMac.AppOpenerResult {
        recordedCalls.append(Call(applicationURL: applicationURL, background: background, mode: mode))
        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
        let action: ExactMac.AppOpenAction = switch mode {
        case .forceNewInstance:
            .launchedNew
        case .launchOrActivate:
            background ? .reusedExisting : .launchedNew
        }
        return ExactMac.AppOpenerResult(
            pid: pid,
            appName: applicationURL.deletingPathExtension().lastPathComponent,
            processingTimeSeconds: "0.001",
            actionTaken: action,
            newProcessCreated: action == .launchedNew,
        )
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

private final class BlockingApplicationIdentityBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let identity: ApplicationProcessIdentity
    private var didEnter = false
    private var didRelease = false

    init(identity: ApplicationProcessIdentity) {
        self.identity = identity
    }

    func resolve(pid: pid_t) -> ApplicationProcessIdentity? {
        guard pid == identity.pid else {
            return nil
        }
        condition.lock()
        didEnter = true
        condition.broadcast()
        while !didRelease {
            condition.wait()
        }
        condition.unlock()
        return identity
    }

    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !snapshotEntered() {
            guard clock.now < deadline else {
                throw InputMutationTestError.convergenceTimeout("application identity capture", 1)
            }
            await Task.yield()
        }
    }

    func release() {
        condition.lock()
        didRelease = true
        condition.broadcast()
        condition.unlock()
    }

    private func snapshotEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return didEnter
    }
}

private func waitForApplicationOpenEntered(
    _ recorder: BlockingApplicationOpenRecorder,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await recorder.calls().count < count {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("application open executions", count)
        }
        await Task.yield()
    }
}

private func waitForApplicationTarget(
    _ stateStore: AppStateStore,
    pid: pid_t,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await stateStore.getTarget(pid: pid) == nil {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("published application targets", 1)
        }
        await Task.yield()
    }
}

private actor InputActionCapture {
    private var actions: [ExactMac.InputAction] = []

    func record(_ action: ExactMac.InputAction) {
        actions.append(action)
    }

    func snapshot() -> [ExactMac.InputAction] {
        actions
    }
}

private func assertRetainedInputEvents(
    _ snapshot: ProductionPathInputEventBackend.Snapshot,
) {
    let events = snapshot.events
    #expect(events.count == 44)
    guard events.count == 44 else {
        Issue.record("Expected the complete retained input event sequence")
        return
    }

    for clickIndex in 1 ... 3 {
        let eventIndex = (clickIndex - 1) * 2
        #expect(events[eventIndex] == .mouseDown(
            point: CGPoint(x: 10, y: 20),
            button: .center,
            modifiers: [.maskCommand, .maskAlphaShift],
            clickCount: Int64(clickIndex),
        ))
        #expect(events[eventIndex + 1] == .mouseUp(
            point: CGPoint(x: 10, y: 20),
            button: .center,
            modifiers: [.maskCommand, .maskAlphaShift],
            clickCount: Int64(clickIndex),
        ))
    }

    #expect(Array(events[6 ..< 10]) == [
        .unicodeKeyDown(text: "a"),
        .unicodeKeyUp(text: "a"),
        .unicodeKeyDown(text: "b"),
        .unicodeKeyUp(text: "b"),
    ])
    #expect(events[10] == .keyDown(
        keyCode: ExactMac.KEY_RETURN,
        flags: [.maskAlternate, .maskControl],
    ))
    #expect(events[11] == .keyUp(
        keyCode: ExactMac.KEY_RETURN,
        flags: [.maskAlternate, .maskControl],
    ))

    #expect(events[12 ..< 32].allSatisfy { event in
        guard case let .mouseMove(_, modifiers) = event else { return false }
        return modifiers == .maskSecondaryFn
    })
    #expect(events[31] == .mouseMove(
        point: CGPoint(x: 30, y: 40),
        modifiers: .maskSecondaryFn,
    ))

    #expect(events[32] == .mouseDown(
        point: CGPoint(x: 1, y: 2),
        button: .right,
        modifiers: .maskShift,
        clickCount: 1,
    ))
    #expect(events[33] == .mouseDrag(
        point: CGPoint(x: 3, y: 9),
        button: .right,
        modifiers: .maskShift,
    ))
    #expect(events[34] == .mouseDrag(
        point: CGPoint(x: 5, y: 6),
        button: .right,
        modifiers: .maskShift,
    ))
    #expect(events[35] == .mouseUp(
        point: CGPoint(x: 5, y: 6),
        button: .right,
        modifiers: .maskShift,
        clickCount: 1,
    ))
    #expect(snapshot.cursorAssociations == [false, true])
    let expectedMoveWarps = (1 ... 20).map { step in
        let fraction = Double(step) / 20
        return CGPoint(x: 30 * fraction, y: 40 * fraction)
    }
    #expect(snapshot.cursorWarps.count == 26)
    if snapshot.cursorWarps.count == 26 {
        #expect(snapshot.cursorWarps[0] == CGPoint(x: 10, y: 20))
        #expect(Array(snapshot.cursorWarps[1 ... 20]) == expectedMoveWarps)
        #expect(Array(snapshot.cursorWarps[21 ... 23]) == [
            CGPoint(x: 1, y: 2),
            CGPoint(x: 3, y: 9),
            CGPoint(x: 5, y: 6),
        ])
        #expect(snapshot.cursorWarps[24] == CGPoint(x: 100, y: 200))
        #expect(snapshot.cursorWarps[25] == CGPoint(x: 300, y: 400))
    }

    var horizontal: Int32 = 0
    var vertical: Int32 = 0
    for event in events[36 ..< 43] {
        guard case let .scroll(point, stepHorizontal, stepVertical, modifiers) = event else {
            Issue.record("Expected SDK scroll event")
            continue
        }
        #expect(point == CGPoint(x: 100, y: 200))
        #expect(modifiers == .maskShift)
        horizontal += stepHorizontal
        vertical += stepVertical
    }
    #expect(horizontal == 3)
    #expect(vertical == -7)
    #expect(events[43] == .mouseMove(
        point: CGPoint(x: 300, y: 400),
        modifiers: [],
    ))

    #expect(snapshot.pauses.contains(125_000_000))
    #expect(snapshot.pauses.contains(250_000_000))
    #expect(snapshot.pauses.contains(39_473_684))
    #expect(snapshot.pauses.contains(41_666_666))
    #expect(snapshot.pauses.contains(500_000_000))
}

private actor CompositionClipboardPasteboard: ClipboardPasteboard {
    enum Call: Equatable, Sendable {
        case clear
        case write(Exactmac_V1_ContentType)
        case read
    }

    private var calls: [Call] = []
    private var changeCountValue = 0
    private var clipboard = Exactmac_V1_Clipboard.with {
        $0.name = "clipboard"
    }

    func read() -> Exactmac_V1_Clipboard {
        calls.append(.read)
        return clipboard
    }

    func changeCount() -> Int {
        changeCountValue
    }

    func clear() {
        calls.append(.clear)
        changeCountValue += 1
        clipboard = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
        }
    }

    func write(_ content: Exactmac_V1_ClipboardContent) -> Bool {
        calls.append(.write(content.type))
        clipboard = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            $0.content = content
            $0.availableTypes = [content.type]
        }
        return true
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private actor BlockingCompositionClipboardPasteboard: ClipboardPasteboard {
    private var clipboard = Exactmac_V1_Clipboard.with {
        $0.name = "clipboard"
    }

    private var changeCountValue = 0
    private var reads = 0
    private var activeReads = 0
    private var maximumReads = 0
    private var shouldBlockFirstRead = true
    private var firstReadContinuation: CheckedContinuation<Void, Never>?
    private var firstReadEnteredContinuations: [CheckedContinuation<Void, Never>] = []

    func read() async -> Exactmac_V1_Clipboard {
        reads += 1
        activeReads += 1
        maximumReads = max(maximumReads, activeReads)
        defer { activeReads -= 1 }

        if reads == 1, shouldBlockFirstRead {
            let continuations = firstReadEnteredContinuations
            firstReadEnteredContinuations.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume()
            }
            await withCheckedContinuation { continuation in
                firstReadContinuation = continuation
            }
        }
        return clipboard
    }

    func changeCount() -> Int {
        changeCountValue
    }

    func clear() {
        changeCountValue += 1
        clipboard = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
        }
    }

    func write(_ content: Exactmac_V1_ClipboardContent) -> Bool {
        clipboard = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            $0.content = content
            $0.availableTypes = [content.type]
        }
        return true
    }

    func waitUntilFirstReadEntered() async {
        guard reads == 0 else { return }
        await withCheckedContinuation { continuation in
            firstReadEnteredContinuations.append(continuation)
        }
    }

    func releaseFirstRead() {
        shouldBlockFirstRead = false
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }

    func readCount() -> Int {
        reads
    }

    func maximumConcurrentReads() -> Int {
        maximumReads
    }
}

private final class ProductionPathInputEventBackend: InputEventBackend, @unchecked Sendable {
    struct Snapshot: Sendable {
        let events: [InputEvent]
        let pauses: [UInt64]
        let cursorWarps: [CGPoint]
        let cursorAssociations: [Bool]
    }

    private struct State {
        var events: [InputEvent] = []
        var pauses: [UInt64] = []
        var now: UInt64 = 0
        var cursorWarps: [CGPoint] = []
        var cursorAssociations: [Bool] = []
    }

    private let lock = NSLock()
    private var state = State()

    func checkPostAccess() throws {}

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        try PreparedInputEvent(event: event) { [self] in
            withState { $0.events.append(event) }
        }
    }

    func pause(nanoseconds: UInt64) async throws {
        withState {
            $0.pauses.append(nanoseconds)
            $0.now += nanoseconds
        }
    }

    func monotonicTimeNanoseconds() -> UInt64 {
        withState { $0.now }
    }

    func cursorPosition() throws -> CGPoint {
        .zero
    }

    func warpCursor(x: Double, y: Double) async throws {
        withState { $0.cursorWarps.append(CGPoint(x: x, y: y)) }
    }

    func setCursorAssociated(_ associated: Bool) async throws {
        withState { $0.cursorAssociations.append(associated) }
    }

    func snapshot() -> Snapshot {
        withState { state in
            Snapshot(
                events: state.events,
                pauses: state.pauses,
                cursorWarps: state.cursorWarps,
                cursorAssociations: state.cursorAssociations,
            )
        }
    }

    private func withState<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private func unary<Request: SwiftProtobuf.Message & Sendable, Response: SwiftProtobuf.Message & Sendable>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
    options: CallOptions = .defaults,
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: options,
    ) { response in
        try response.message
    }
}

private func pollUntilWindow(
    client: GRPCClient<InProcessTransport.Client>,
    name: String,
    expectedOrigin: CGPoint,
) async throws -> Exactmac_V1_Window {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))

    while true {
        let window: Exactmac_V1_Window = try await unary(
            client: client,
            request: Exactmac_V1_GetWindowRequest.with { $0.name = name },
            descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
        )
        if window.bounds.x == expectedOrigin.x,
           window.bounds.y == expectedOrigin.y
        {
            return window
        }
        guard clock.now < deadline else {
            throw InjectedGRPCTestError.convergenceTimeout(
                expected: expectedOrigin,
                actual: CGPoint(x: window.bounds.x, y: window.bounds.y),
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func createInjectedInputRequest(
    id: String,
    x: Double,
) -> Exactmac_V1_CreateInputRequest {
    Exactmac_V1_CreateInputRequest.with {
        $0.parent = "applications/-"
        $0.inputID = id
        $0.input = Exactmac_V1_Input.with {
            $0.target.desktop = true
            $0.action = Exactmac_V1_InputAction.with {
                $0.mouseMove = Exactmac_V1_MouseMove.with {
                    $0.position = Exactmac_Type_Point.with {
                        $0.x = x
                        $0.y = 100
                    }
                }
            }
        }
    }
}

private func waitForMutationQueue(
    _ gate: PhysicalDesktopMutationGate,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await gate.pendingCount() != count {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("queued mutations", count)
        }
        await Task.yield()
    }
}

private func waitForClipboardAccessQueue(
    _ manager: ClipboardManager,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await manager.pendingClipboardAccessCount() != count {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("queued clipboard accesses", count)
        }
        await Task.yield()
    }
}

private enum InjectedGRPCTestError: Error {
    case convergenceTimeout(expected: CGPoint, actual: CGPoint)
    case unexpectedVisualization
}

private final class StatefulWindowSystemOperations: SystemOperations, @unchecked Sendable {
    struct Snapshot {
        let origin: CGPoint
        let positionSetCalls: Int
        let axWindowsReads: Int
    }

    private struct State {
        var bounds: CGRect
        var positionSetCalls = 0
        var axWindowsReads = 0
    }

    private let lock = NSLock()
    private let pid: pid_t
    private let windowID: CGWindowID
    private let title: String
    private let appElement: AXUIElement
    private let windowElement: AXUIElement
    private let postMutationReadbackBarrier: BlockingWindowListBarrier?
    private var state: State

    init(
        pid: pid_t,
        windowID: CGWindowID,
        title: String,
        bounds: CGRect,
        postMutationWindowListBarrier: BlockingWindowListBarrier? = nil,
    ) {
        self.pid = pid
        self.windowID = windowID
        self.title = title
        postMutationReadbackBarrier = postMutationWindowListBarrier
        appElement = AXUIElementCreateApplication(pid)
        windowElement = AXUIElementCreateSystemWide()
        state = State(bounds: bounds)
    }

    func snapshot() -> Snapshot {
        withState { state in
            Snapshot(
                origin: state.bounds.origin,
                positionSetCalls: state.positionSetCalls,
                axWindowsReads: state.axWindowsReads,
            )
        }
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        let bounds = withState { $0.bounds }
        return [[
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: pid,
            kCGWindowBounds as String: [
                "X": bounds.origin.x,
                "Y": bounds.origin.y,
                "Width": bounds.width,
                "Height": bounds.height,
            ],
            kCGWindowName as String: title,
            kCGWindowLayer as String: Int32(0),
            kCGWindowIsOnscreen as String: true,
        ]]
    }

    func getRunningApplicationBundleID(pid _: pid_t) -> String? {
        "com.example.injected-window"
    }

    func createAXApplication(pid _: Int32) -> AnyObject? {
        appElement
    }

    func copyAXAttribute(element _: AnyObject, attribute: String) -> Any? {
        switch attribute {
        case kAXWindowsAttribute:
            withState { $0.axWindowsReads += 1 }
            return [windowElement]
        case kAXRoleAttribute:
            return kAXWindowRole as String
        case kAXTitleAttribute:
            return title
        case kAXMinimizedAttribute, kAXHiddenAttribute:
            return false
        case kAXFocusedAttribute:
            return true
        case kAXPositionAttribute:
            let (currentOrigin, shouldBlock) = withState { state in
                (state.bounds.origin, state.positionSetCalls > 0)
            }
            if shouldBlock {
                postMutationReadbackBarrier?.blockOnce()
            }
            var origin = currentOrigin
            return AXValueCreate(.cgPoint, &origin)
        case kAXSizeAttribute:
            var size = withState { $0.bounds.size }
            return AXValueCreate(.cgSize, &size)
        default:
            return nil
        }
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element _: AnyObject, attribute: String, value: Any) -> Int32 {
        guard attribute == kAXPositionAttribute,
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID()
        else {
            return AXError.attributeUnsupported.rawValue
        }

        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var origin = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &origin) else {
            return AXError.illegalArgument.rawValue
        }

        withState { state in
            state.bounds.origin = origin
            state.positionSetCalls += 1
        }
        return AXError.success.rawValue
    }

    func performAXAction(element _: AnyObject, action _: String) -> Int32 {
        AXError.actionUnsupported.rawValue
    }

    func getAXWindowID(element _: AnyObject) -> CGWindowID? {
        windowID
    }

    private func withState<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private final class BlockingWindowListBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var didRelease = false

    func blockOnce() {
        condition.lock()
        defer { condition.unlock() }
        guard !didEnter else {
            return
        }
        didEnter = true
        condition.broadcast()
        while !didRelease {
            condition.wait()
        }
    }

    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !snapshotEntered() {
            guard clock.now < deadline else {
                throw InputMutationTestError.convergenceTimeout("post-mutation window observation", 1)
            }
            await Task.yield()
        }
    }

    func release() {
        condition.lock()
        didRelease = true
        condition.broadcast()
        condition.unlock()
    }

    private func snapshotEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return didEnter
    }
}
