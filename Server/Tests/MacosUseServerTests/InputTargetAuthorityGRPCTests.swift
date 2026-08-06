import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
@testable import MacosUseProto
import MacosUseSDK
@testable import MacosUseServer
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct InputTargetAuthorityGRPCTests {
    @Test
    func `window target requires exactly one AX window with the bound private ID`() async throws {
        let missing = try await InputTargetAuthorityFixture.make()
        missing.system.removeAllAXWindows()

        try await withInputTargetAuthorityClient(missing.composition) { client in
            await expectInputTargetAuthorityRPCError(.notFound) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "missing-private-id",
                        parent: missing.applicationName,
                        window: missing.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }
        #expect(await missing.sink.count() == 0)
        #expect(
            await missing.composition.stateStore.getInput(
                name: "\(missing.applicationName)/inputs/missing-private-id",
            ) == nil,
        )
        await missing.composition.serviceLifetime.shutdown()

        let duplicate = try await InputTargetAuthorityFixture.make()
        duplicate.system.duplicateTargetPrivateID()
        try await withInputTargetAuthorityClient(duplicate.composition) { client in
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "duplicate-private-id",
                        parent: duplicate.applicationName,
                        window: duplicate.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }
        #expect(await duplicate.sink.count() == 0)
        #expect(
            await duplicate.composition.stateStore.getInput(
                name: "\(duplicate.applicationName)/inputs/duplicate-private-id",
            ) == nil,
        )
        await duplicate.composition.serviceLifetime.shutdown()
    }

    @Test
    func `malformed AX window authority fails before input publication`() async throws {
        try await expectInitialInputTargetAuthorityFailure(
            id: "invalid-window-role",
            expected: .failedPrecondition,
        ) {
            $0.setTargetRole(kAXButtonRole as String)
        }
        try await expectInitialInputTargetAuthorityFailure(
            id: "invalid-live-bounds",
            expected: .failedPrecondition,
        ) {
            $0.setTargetLiveBounds(CGRect(x: 100, y: 100, width: 0, height: 200))
        }
        try await expectInitialInputTargetAuthorityFailure(
            id: "unreadable-private-id",
            expected: .unavailable,
        ) {
            $0.makeTargetPrivateIDUnreadable()
        }
        try await expectInitialInputTargetAuthorityFailure(
            id: "private-id-permission",
            expected: .permissionDenied,
        ) {
            $0.failPrivateWindowIDRead(with: .apiDisabled)
        }
        try await expectInitialInputTargetAuthorityFailure(
            id: "malformed-window-array",
            expected: .unavailable,
        ) {
            $0.makeWindowArrayMalformed()
        }
    }

    @Test
    func `window containment uses retained live AX bounds instead of stale registry geometry`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            registryBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            liveBounds: CGRect(x: 100, y: 100, width: 100, height: 100),
        )

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: "inside-live-bounds",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 150, y: 150),
                ),
            )
            #expect(completed.state == .completed)
            #expect(completed.deliveryResult.commitment == .committedAndSettled)

            await expectInputTargetAuthorityRPCError(.invalidArgument) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "inside-stale-registry-only",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 50, y: 50),
                    ),
                )
            }
        }

        #expect(await fixture.sink.count() == 1)
        #expect(
            await fixture.composition.stateStore.getInput(
                name: "\(fixture.applicationName)/inputs/inside-stale-registry-only",
            ) == nil,
        )
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `keyboard input focuses and raises the exact retained sibling window`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(includeSibling: true)
        fixture.system.focusSiblingWindow()

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityKeyRequest(
                    id: "exact-window-focus",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                ),
            )
            #expect(completed.state == .completed)
        }

        let snapshot = fixture.system.snapshot()
        #expect(fixture.system.freshEquivalentWindowIsDistinct())
        #expect(snapshot.focusedWindowID == fixture.targetWindowID)
        #expect(snapshot.mainWindowID == fixture.targetWindowID)
        #expect(snapshot.raisedWindowID == fixture.targetWindowID)
        #expect(snapshot.frontmostWrites == 1)
        #expect(snapshot.windowMainWrites == 1)
        #expect(snapshot.windowFocusedWrites == 1)
        #expect(snapshot.hitTestReads == 0)
        #expect(snapshot.pidReads == 0)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `frontmost activation rechecks exact window focus before redundant mutations`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            convergencePolicy: WindowMutationConvergencePolicy(
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1),
                geometryTolerance: 0,
                stableReadCount: 1,
            ),
        )
        fixture.system.failRaise(with: .actionUnsupported)

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: "already-exact-focus",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(completed.state == .completed)
            #expect(completed.deliveryResult.commitment == .committedAndSettled)
        }

        let snapshot = fixture.system.snapshot()
        #expect(snapshot.focusedWindowID == fixture.targetWindowID)
        #expect(snapshot.mainWindowID == fixture.targetWindowID)
        #expect(snapshot.raisedWindowID == nil)
        #expect(snapshot.frontmostWrites == 1)
        #expect(snapshot.windowMainWrites == 0)
        #expect(snapshot.windowFocusedWrites == 0)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `unsupported raise still converges through exact main and focused writes`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            includeSibling: true,
            convergencePolicy: WindowMutationConvergencePolicy(
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1),
                geometryTolerance: 0,
                stableReadCount: 1,
            ),
        )
        fixture.system.focusSiblingWindow()
        fixture.system.failRaise(with: .actionUnsupported)

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityKeyRequest(
                    id: "unsupported-redundant-raise",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                ),
            )
            #expect(completed.state == .completed)
            #expect(completed.deliveryResult.commitment == .committedAndSettled)
        }

        let snapshot = fixture.system.snapshot()
        #expect(snapshot.focusedWindowID == fixture.targetWindowID)
        #expect(snapshot.mainWindowID == fixture.targetWindowID)
        #expect(snapshot.raisedWindowID == nil)
        #expect(snapshot.frontmostWrites == 1)
        #expect(snapshot.windowMainWrites == 1)
        #expect(snapshot.windowFocusedWrites == 1)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `exact main window remains sufficient when focused attribute is false`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            convergencePolicy: WindowMutationConvergencePolicy(
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1),
                geometryTolerance: 0,
                stableReadCount: 1,
            ),
        )
        fixture.system.reportTargetFocusedAttribute(false)
        fixture.system.failRaise(with: .actionUnsupported)

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: "main-without-focused-attribute",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(completed.state == .completed)
            #expect(completed.deliveryResult.commitment == .committedAndSettled)
        }

        let snapshot = fixture.system.snapshot()
        #expect(snapshot.focusedWindowID == fixture.targetWindowID)
        #expect(snapshot.mainWindowID == fixture.targetWindowID)
        #expect(snapshot.raisedWindowID == nil)
        #expect(snapshot.frontmostWrites == 1)
        #expect(snapshot.windowMainWrites == 0)
        #expect(snapshot.windowFocusedWrites == 0)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `window input requires the owning application to become frontmost`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            convergencePolicy: WindowMutationConvergencePolicy(
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1),
                geometryTolerance: 0,
                stableReadCount: 1,
            ),
        )
        fixture.system.ignoreFrontmostWrites()

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.deadlineExceeded) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityKeyRequest(
                        id: "background-window",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                    ),
                )
            }
        }

        let name = "\(fixture.applicationName)/inputs/background-window"
        let failed = try #require(
            await fixture.composition.stateStore.getInput(name: name),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .noEffect)
        #expect(failed.deliveryResult.postedEventCount == 0)
        #expect(failed.deliveryResult.routedDeliveryObserved == false)
        #expect(await fixture.composition.stateStore.inputStateHistory(name: name) == [
            .pending,
            .executing,
            .failed,
        ])
        #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await fixture.sink.count() == 0)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `postpublication role and focus drift fail with exact no effect truth`() async throws {
        let roleDrift = try await InputTargetAuthorityFixture.make(
            executor: { system, sink in
                { action, route, boundary in
                    system.setTargetRole(kAXButtonRole as String)
                    try await boundary.validateEffect(.keyDown(
                        keyCode: 36,
                        flags: [],
                    ))
                    await sink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                }
            },
        )
        try await assertPostpublicationTargetAuthorityFailure(
            fixture: roleDrift,
            id: "postpublication-role-drift",
            expected: .failedPrecondition,
        )

        let focusDrift = try await InputTargetAuthorityFixture.make(
            includeSibling: true,
            executor: { system, sink in
                { action, route, boundary in
                    system.focusSiblingWindow()
                    try await boundary.validateEffect(.keyDown(
                        keyCode: 36,
                        flags: [],
                    ))
                    await sink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                }
            },
        )
        try await assertPostpublicationTargetAuthorityFailure(
            fixture: focusDrift,
            id: "postpublication-focus-drift",
            expected: .failedPrecondition,
        )
    }

    @Test
    func `same private ID with a replacement AX object stops later physical effects`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            executor: { system, sink in
                { action, route, boundary in
                    let point = CGPoint(x: 120, y: 120)
                    try await boundary.validateEffect(.mouseDown(
                        point: point,
                        button: .left,
                        modifiers: [],
                        clickCount: 1,
                    ))
                    await sink.record()
                    system.replaceTargetAXObjectKeepingPrivateID()
                    do {
                        try await boundary.validateEffect(.mouseMove(
                            point: CGPoint(x: 121, y: 121),
                            modifiers: [],
                        ))
                    } catch {
                        throw InputExecutionFailure(
                            underlying: error,
                            route: route,
                            postedEventCount: 1,
                            routedDeliveryObserved: true,
                            physicalEffectOccurred: true,
                        )
                    }
                    await sink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                }
            },
        )

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "same-id-replacement",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }

        #expect(await fixture.sink.count() == 1)
        let terminal = try #require(
            await fixture.composition.stateStore.getInput(
                name: "\(fixture.applicationName)/inputs/same-id-replacement",
            ),
        )
        #expect(terminal.state == .failed)
        #expect(terminal.deliveryResult.commitment == .possiblyCommitted)
        #expect(terminal.deliveryResult.postedEventCount == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `pointer hit testing finishes with the complete exact target lease`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(includeSibling: true)
        fixture.system.replaceTargetDuringNextParentRead()

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "target-replaced-during-hit",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }

        let name = "\(fixture.applicationName)/inputs/target-replaced-during-hit"
        let failed = try #require(
            await fixture.composition.stateStore.getInput(name: name),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .noEffect)
        #expect(failed.deliveryResult.postedEventCount == 0)
        #expect(failed.deliveryResult.routedDeliveryObserved == false)
        #expect(await fixture.composition.stateStore.inputStateHistory(name: name) == [
            .pending,
            .executing,
            .failed,
        ])
        #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await fixture.sink.count() == 0)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `pointer hit proof is the final synchronous authority before dispatch`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            includeSibling: true,
            executor: { system, sink in
                { action, route, boundary in
                    let point = CGPoint(x: 120, y: 120)
                    try await boundary.validateEffect(.mouseDown(
                        point: point,
                        button: .left,
                        modifiers: [],
                        clickCount: 1,
                    ))
                    #expect(system.hitElementDescendsFromTargetWindow())
                    await sink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                }
            },
        )
        fixture.system.replaceHitWithSiblingOnTopologySnapshotAfterHit()

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: "hit-proof-final-authority",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(completed.state == .completed)
        }

        let snapshot = fixture.system.snapshot()
        #expect(snapshot.postHitTopologyMutations == 0)
        #expect(snapshot.hitTestReads == 1)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `window pointer effects require hit test ancestry under the retained window`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(includeSibling: true)

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: "owned-hit",
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(completed.state == .completed)

            fixture.system.hitSiblingWindow()
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "sibling-hit",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }

            fixture.system.hitForeignOverlay()
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "foreign-overlay-hit",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }

            fixture.system.hitOwnedCycle()
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityClickRequest(
                        id: "cycle-hit",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }

        #expect(await fixture.sink.count() == 1)
        let snapshot = fixture.system.snapshot()
        #expect(snapshot.hitTestReads == 4)
        #expect(snapshot.pidReads == 7)
        #expect(snapshot.parentReads == 5)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `window pointer ancestry rejects an intermediate foreign owner`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make()
        fixture.system.hitOwnedElementThroughForeignAncestor()

        try await assertPostpublicationWindowPointerTargetAuthorityFailure(
            fixture: fixture,
            id: "foreign-intermediate-owner",
            expected: .failedPrecondition,
        )

        let snapshot = fixture.system.snapshot()
        #expect(snapshot.hitTestReads == 1)
        #expect(snapshot.pidReads == 2)
        #expect(snapshot.parentReads == 1)
    }

    @Test
    func `every scroll partition revalidates exact pointer ownership`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            executor: { system, sink in
                { action, route, boundary in
                    let point = CGPoint(x: 120, y: 120)
                    try await boundary.validateEffect(.scroll(
                        point: point,
                        horizontal: 0,
                        vertical: -1,
                        modifiers: [],
                    ))
                    await sink.record()
                    system.hitForeignOverlay()
                    do {
                        try await boundary.validateEffect(.scroll(
                            point: point,
                            horizontal: 0,
                            vertical: -1,
                            modifiers: [],
                        ))
                    } catch {
                        throw InputExecutionFailure(
                            underlying: error,
                            route: route,
                            postedEventCount: 1,
                            routedDeliveryObserved: true,
                            physicalEffectOccurred: true,
                        )
                    }
                    await sink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                }
            },
        )

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityScrollRequest(
                        id: "scroll-partition-owner",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }

        let name = "\(fixture.applicationName)/inputs/scroll-partition-owner"
        let failed = try #require(
            await fixture.composition.stateStore.getInput(name: name),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .possiblyCommitted)
        #expect(failed.deliveryResult.postedEventCount == 1)
        #expect(failed.deliveryResult.routedDeliveryObserved)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `application pointer effects require exact hit PID and preserve AX errors`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make()
        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityApplicationClickRequest(
                    id: "owned-application-hit",
                    parent: fixture.applicationName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(completed.state == .completed)

            fixture.system.hitForeignOverlay()
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityApplicationClickRequest(
                        id: "foreign-application-hit",
                        parent: fixture.applicationName,
                        point: CGPoint(x: 120, y: 120),
                    ),
                )
            }
        }
        let snapshot = fixture.system.snapshot()
        #expect(snapshot.hitTestReads == 2)
        #expect(snapshot.pidReads == 2)
        #expect(snapshot.parentReads == 0)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()

        let denied = try await InputTargetAuthorityFixture.make()
        denied.system.failHitTest(with: .apiDisabled)
        try await assertPostpublicationApplicationTargetAuthorityFailure(
            fixture: denied,
            id: "hit-test-permission",
            expected: .permissionDenied,
        )

        let unavailable = try await InputTargetAuthorityFixture.make()
        unavailable.system.failPIDRead(with: .cannotComplete)
        try await assertPostpublicationApplicationTargetAuthorityFailure(
            fixture: unavailable,
            id: "hit-pid-unavailable",
            expected: .unavailable,
        )

        let malformedPID = try await InputTargetAuthorityFixture.make()
        malformedPID.system.returnSuccessfulPIDReadWithoutPID()
        try await assertPostpublicationApplicationTargetAuthorityFailure(
            fixture: malformedPID,
            id: "hit-pid-missing",
            expected: .unavailable,
        )
    }

    @Test
    func `display and desktop effects never consult AX hit test authority`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make()
        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let desktop = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthoritySessionClickRequest(
                    id: "desktop-no-hit-test",
                    target: .desktop(true),
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(desktop.state == .completed)

            let display = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthoritySessionClickRequest(
                    id: "display-no-hit-test",
                    target: .display("displays/1"),
                    point: CGPoint(x: 120, y: 120),
                ),
            )
            #expect(display.state == .completed)
        }

        let snapshot = fixture.system.snapshot()
        #expect(snapshot.hitTestReads == 0)
        #expect(snapshot.pidReads == 0)
        #expect(snapshot.parentReads == 0)
        #expect(await fixture.sink.count() == 2)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `legacy numeric PID authority is explicit and production rejects it`() async throws {
        let identity = ApplicationProcessIdentity(
            pid: 8801,
            startTimeSeconds: 123,
            startTimeMicroseconds: 456,
            bundleIdentifier: "com.example.InputTargetAuthority",
            executablePath: "/Applications/InputTargetAuthority.app/Contents/MacOS/InputTargetAuthority",
        )
        let system = InputTargetAuthoritySystem(
            identity: identity,
            targetWindowID: 8811,
            registryBounds: CGRect(x: 100, y: 100, width: 300, height: 200),
            liveBounds: CGRect(x: 100, y: 100, width: 300, height: 200),
            includeSibling: false,
            frontmostHook: {},
        )
        let sink = InputTargetAuthoritySink()
        func makeCoordinator(recording targetSink: InputTargetAuthoritySink) -> AutomationCoordinator {
            AutomationCoordinator(
                activationSystem: system,
                inputPostAccessChecker: { true },
                inputActionExecutor: { action, route, boundary in
                    try await boundary.validateEffect(.mouseMove(
                        point: CGPoint(x: 120, y: 120),
                        modifiers: [],
                    ))
                    if case let .process(pid) = route {
                        try boundary.validateProcessRoute(pid)
                    }
                    await targetSink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                },
            )
        }

        let directStateStore = AppStateStore()
        let directSink = InputTargetAuthoritySink()
        let directCoordinator = makeCoordinator(recording: directSink)
        let directService = MacosUseService(
            stateStore: directStateStore,
            operationStore: OperationStore(),
            windowRegistry: WindowRegistry(system: system),
            system: system,
            displayTopologyProvider: InputTargetAuthorityTopology(),
            automationCoordinator: directCoordinator,
        )
        try await withInputTargetAuthorityClient(directService) { client in
            await expectInputTargetAuthorityRPCError(.invalidArgument) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityApplicationMoveRequest(
                        id: "numeric-provider-default-rejected",
                        parent: "applications/8801",
                    ),
                )
            }
        }
        #expect(
            await directStateStore.getInput(
                name: "applications/8801/inputs/numeric-provider-default-rejected",
            ) == nil,
        )
        #expect(await directSink.count() == 0)
        await directCoordinator.shutdownMutations()

        let production = MacosUseServiceComposition(
            system: system,
            automationCoordinator: makeCoordinator(recording: sink),
            displayTopologyProvider: InputTargetAuthorityTopology(),
        )
        try await withInputTargetAuthorityClient(production) { client in
            await expectInputTargetAuthorityRPCError(.invalidArgument) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityApplicationMoveRequest(
                        id: "numeric-production-rejected",
                        parent: "applications/8801",
                    ),
                )
            }
        }
        await production.serviceLifetime.shutdown()

        let legacy = MacosUseServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: makeCoordinator(recording: sink),
            displayTopologyProvider: InputTargetAuthorityTopology(),
        )
        try await withInputTargetAuthorityClient(legacy) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityApplicationMoveRequest(
                    id: "numeric-legacy-explicit",
                    parent: "applications/8801",
                ),
            )
            #expect(completed.state == .completed)
        }
        #expect(await sink.count() == 1)
        await legacy.serviceLifetime.shutdown()
    }

    @Test
    func `service system owns activation even when an injected coordinator has another adapter`() async throws {
        let wrongSystem = MockSystemOperations()
        let fixture = try await InputTargetAuthorityFixture.make(
            activationSystem: wrongSystem,
        )

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            let completed = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityApplicationKeyRequest(
                    id: "single-system-activation",
                    parent: fixture.applicationName,
                ),
            )
            #expect(completed.state == .completed)
        }

        #expect(fixture.system.snapshot().frontmostWrites == 1)
        #expect(wrongSystem.setAXAttributeCalls.isEmpty)
        #expect(await fixture.sink.count() == 1)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `application generation replacement during activation reaches no executor sink`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make()
        fixture.system.replaceGenerationOnNextActivation()

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.notFound) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityApplicationKeyRequest(
                        id: "activation-generation-replaced",
                        parent: fixture.applicationName,
                    ),
                )
            }
        }

        #expect(await fixture.sink.count() == 0)
        let failed = try #require(
            await fixture.composition.stateStore.getInput(
                name: "\(fixture.applicationName)/inputs/activation-generation-replaced",
            ),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .noEffect)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `generation retirement during final AX reads blocks host global effects`() async throws {
        let fixture = try await InputTargetAuthorityFixture.make(
            executor: { system, sink in
                { action, route, boundary in
                    system.replaceGenerationAfterNextWindowSizeRead()
                    try await boundary.validateEffect(.cursorWarp(
                        point: CGPoint(x: 120, y: 120),
                    ))
                    await sink.record()
                    return committedInputExecutionReceipt(for: action, route: route)
                }
            },
        )

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.notFound) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityWindowMoveRequest(
                        id: "generation-retired-during-ax-read",
                        parent: fixture.applicationName,
                        window: fixture.targetWindowName,
                    ),
                )
            }
        }

        let name = "\(fixture.applicationName)/inputs/generation-retired-during-ax-read"
        let failed = try #require(
            await fixture.composition.stateStore.getInput(name: name),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .noEffect)
        #expect(failed.deliveryResult.postedEventCount == 0)
        #expect(failed.deliveryResult.routedDeliveryObserved == false)
        #expect(await fixture.composition.stateStore.inputStateHistory(name: name) == [
            .pending,
            .executing,
            .failed,
        ])
        #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await fixture.sink.count() == 0)
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `layout fingerprint replacement during activation reaches no executor sink`() async throws {
        let initial = KeyboardInputSourceIdentity(
            sourceID: "com.example.layout.initial",
            unicodeLayoutSHA256: String(repeating: "1", count: 64),
            keyboardType: 40,
        )
        let replacement = KeyboardInputSourceIdentity(
            sourceID: "com.example.layout.replacement",
            unicodeLayoutSHA256: String(repeating: "2", count: 64),
            keyboardType: 41,
        )
        let layout = InputTargetAuthorityLayout(initial)
        let fixture = try await InputTargetAuthorityFixture.make(
            inputKeyResolver: { _ in
                ResolvedInputKey(
                    keyCode: 0,
                    sourceIdentity: initial,
                )
            },
            keyboardInputSourceIdentityProvider: {
                layout.current()
            },
            frontmostHook: {
                layout.replace(with: replacement)
            },
        )

        try await withInputTargetAuthorityClient(fixture.composition) { client in
            await expectInputTargetAuthorityRPCError(.failedPrecondition) {
                _ = try await createTargetAuthorityInput(
                    client: client,
                    request: targetAuthorityApplicationCharacterRequest(
                        id: "activation-layout-replaced",
                        parent: fixture.applicationName,
                    ),
                )
            }
        }

        #expect(await fixture.sink.count() == 0)
        #expect(fixture.system.snapshot().frontmostWrites == 1)
        let failed = try #require(
            await fixture.composition.stateStore.getInput(
                name: "\(fixture.applicationName)/inputs/activation-layout-replaced",
            ),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .noEffect)
        await fixture.composition.serviceLifetime.shutdown()
    }
}

private struct InputTargetAuthorityFixture {
    let applicationName: String
    let targetWindowName: String
    let targetWindowID: CGWindowID
    let composition: MacosUseServiceComposition
    let system: InputTargetAuthoritySystem
    let sink: InputTargetAuthoritySink

    static func make(
        registryBounds: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200),
        liveBounds: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200),
        includeSibling: Bool = false,
        activationSystem: SystemOperations? = nil,
        inputKeyResolver: @escaping InputKeyResolver = { _ in
            ResolvedInputKey(keyCode: 36, sourceIdentity: nil)
        },
        keyboardInputSourceIdentityProvider: @escaping KeyboardInputSourceIdentityProvider = {
            nil
        },
        frontmostHook: @escaping @Sendable () -> Void = {},
        convergencePolicy: WindowMutationConvergencePolicy = .production,
        executor: (
            (InputTargetAuthoritySystem, InputTargetAuthoritySink) -> InputActionExecutor
        )? = nil,
    ) async throws -> InputTargetAuthorityFixture {
        let identity = ApplicationProcessIdentity(
            pid: 8801,
            startTimeSeconds: 123,
            startTimeMicroseconds: 456,
            bundleIdentifier: "com.example.InputTargetAuthority",
            executablePath: "/Applications/InputTargetAuthority.app/Contents/MacOS/InputTargetAuthority",
        )
        let targetWindowID: CGWindowID = 8811
        let system = InputTargetAuthoritySystem(
            identity: identity,
            targetWindowID: targetWindowID,
            registryBounds: registryBounds,
            liveBounds: liveBounds,
            includeSibling: includeSibling,
            frontmostHook: frontmostHook,
        )
        let sink = InputTargetAuthoritySink()
        let inputExecutor: InputActionExecutor = if let executor {
            executor(system, sink)
        } else {
            { action, route, boundary in
                switch action {
                case let .click(point), let .doubleClick(point), let .rightClick(point):
                    try await boundary.validateEffect(.mouseDown(
                        point: point,
                        button: .left,
                        modifiers: [],
                        clickCount: 1,
                    ))
                case let .clickSequence(point, button, clickCount, modifiers):
                    try await boundary.validateEffect(.mouseDown(
                        point: point,
                        button: button,
                        modifiers: modifiers,
                        clickCount: Int64(clickCount),
                    ))
                case let .pressKeyCode(keyCode, flags),
                     let .pressKeyCodeHold(keyCode, flags, _):
                    try await boundary.validateEffect(.keyDown(
                        keyCode: keyCode,
                        flags: flags,
                    ))
                default:
                    Issue.record("Unexpected target-authority action: \(String(describing: action))")
                }
                if case let .process(pid) = route {
                    try boundary.validateProcessRoute(pid)
                }
                await sink.record()
                return committedInputExecutionReceipt(for: action, route: route)
            }
        }
        let coordinator = AutomationCoordinator(
            activationSystem: activationSystem ?? system,
            inputKeyResolver: inputKeyResolver,
            keyboardInputSourceIdentityProvider: keyboardInputSourceIdentityProvider,
            inputPostAccessChecker: { true },
            inputActionExecutor: inputExecutor,
        )
        let stateStore = AppStateStore()
        let composition = MacosUseServiceComposition(
            stateStore: stateStore,
            system: system,
            automationCoordinator: coordinator,
            displayTopologyProvider: InputTargetAuthorityTopology(system: system),
            windowMutationConvergencePolicy: convergencePolicy,
        )
        let applicationName = applicationResourceName(for: identity)
        await stateStore.addTarget(
            Macosusesdk_V1_Application.with {
                $0.name = applicationName
                $0.pid = Int32(identity.pid)
                $0.displayName = "Input Target Authority"
            },
            processIdentity: identity,
        )
        let bindings = try await composition.windowRegistry.listWindowBindings(
            applicationName: applicationName,
            pid: identity.pid,
            processIdentity: identity,
        )
        let targetBinding = try #require(
            bindings.first(where: { $0.windowID == targetWindowID }),
        )
        return InputTargetAuthorityFixture(
            applicationName: applicationName,
            targetWindowName: targetBinding.name,
            targetWindowID: targetWindowID,
            composition: composition,
            system: system,
            sink: sink,
        )
    }
}

private actor InputTargetAuthoritySink {
    private var invocationCount = 0

    func record() {
        invocationCount += 1
    }

    func count() -> Int {
        invocationCount
    }
}

private final class InputTargetAuthorityLayout: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: KeyboardInputSourceIdentity

    init(_ identity: KeyboardInputSourceIdentity) {
        self.identity = identity
    }

    func current() -> KeyboardInputSourceIdentity {
        lock.withLock { identity }
    }

    func replace(with replacement: KeyboardInputSourceIdentity) {
        lock.withLock { identity = replacement }
    }
}

private final class InputTargetAuthoritySystem: SystemOperations, @unchecked Sendable {
    private struct Window {
        let privateID: CGWindowID
        let syntheticPID: pid_t
        let element: AXUIElement
        var bounds: CGRect
        var role: String
    }

    struct Snapshot: Sendable {
        let focusedWindowID: CGWindowID?
        let mainWindowID: CGWindowID?
        let raisedWindowID: CGWindowID?
        let frontmostWrites: Int
        let windowMainWrites: Int
        let windowFocusedWrites: Int
        let hitTestReads: Int
        let pidReads: Int
        let parentReads: Int
        let postHitTopologyMutations: Int
    }

    private struct State {
        var identity: ApplicationProcessIdentity
        var registryBounds: CGRect
        var windows: [Window]
        var focusedWindow: AXUIElement?
        var mainWindow: AXUIElement?
        var raisedWindow: AXUIElement?
        var hitElement: AXUIElement
        var parents: [ObjectIdentifier: AXUIElement]
        var elementPIDs: [ObjectIdentifier: pid_t]
        var frontmost = false
        var frontmostWrites = 0
        var windowMainWrites = 0
        var windowFocusedWrites = 0
        var hitTestReads = 0
        var pidReads = 0
        var parentReads = 0
        var malformedWindowArray = false
        var unreadablePrivateWindowID: CGWindowID?
        var privateWindowIDError = AXError.success.rawValue
        var hitTestError = AXError.success.rawValue
        var pidReadError = AXError.success.rawValue
        var successfulPIDReadWithoutPID = false
        var replaceGenerationOnActivation = false
        var replaceGenerationAfterWindowSizeRead = false
        var frontmostWritesAffectState = true
        var replaceTargetOnParentRead = false
        var replaceHitOnTopologySnapshotAfterHit = false
        var postHitTopologyMutations = 0
        var raiseError = AXError.success.rawValue
        var targetFocusedAttributeOverride: Bool?
        var nextSyntheticPID: pid_t
    }

    private let lock = NSLock()
    private let applicationElement: AXUIElement
    private let ownedPID: pid_t
    private let targetWindowID: CGWindowID
    private let frontmostHook: @Sendable () -> Void
    private var state: State

    init(
        identity: ApplicationProcessIdentity,
        targetWindowID: CGWindowID,
        registryBounds: CGRect,
        liveBounds: CGRect,
        includeSibling: Bool,
        frontmostHook: @escaping @Sendable () -> Void,
    ) {
        ownedPID = identity.pid
        self.targetWindowID = targetWindowID
        self.frontmostHook = frontmostHook
        applicationElement = AXUIElementCreateApplication(identity.pid)
        let target = Window(
            privateID: targetWindowID,
            syntheticPID: 8901,
            element: AXUIElementCreateApplication(8901),
            bounds: liveBounds,
            role: kAXWindowRole as String,
        )
        var windows = [target]
        if includeSibling {
            windows.append(Window(
                privateID: targetWindowID + 1,
                syntheticPID: 8902,
                element: AXUIElementCreateApplication(8902),
                bounds: liveBounds.offsetBy(dx: 350, dy: 0),
                role: kAXWindowRole as String,
            ))
        }
        let ownedHit = AXUIElementCreateApplication(8911)
        state = State(
            identity: identity,
            registryBounds: registryBounds,
            windows: windows,
            focusedWindow: target.element,
            mainWindow: target.element,
            raisedWindow: nil,
            hitElement: ownedHit,
            parents: [ObjectIdentifier(ownedHit): target.element],
            elementPIDs: [
                ObjectIdentifier(target.element): identity.pid,
                ObjectIdentifier(ownedHit): identity.pid,
            ],
            nextSyntheticPID: 9000,
        )
        if let sibling = windows.dropFirst().first {
            state.elementPIDs[ObjectIdentifier(sibling.element)] = identity.pid
        }
    }

    func snapshot() -> Snapshot {
        withState { state in
            Snapshot(
                focusedWindowID: state.focusedWindow.flatMap { focused in
                    state.windows.first(where: { CFEqual($0.element, focused) })?.privateID
                },
                mainWindowID: state.mainWindow.flatMap { main in
                    state.windows.first(where: { CFEqual($0.element, main) })?.privateID
                },
                raisedWindowID: state.raisedWindow.flatMap { raised in
                    state.windows.first(where: { CFEqual($0.element, raised) })?.privateID
                },
                frontmostWrites: state.frontmostWrites,
                windowMainWrites: state.windowMainWrites,
                windowFocusedWrites: state.windowFocusedWrites,
                hitTestReads: state.hitTestReads,
                pidReads: state.pidReads,
                parentReads: state.parentReads,
                postHitTopologyMutations: state.postHitTopologyMutations,
            )
        }
    }

    func removeAllAXWindows() {
        withState { $0.windows.removeAll() }
    }

    func duplicateTargetPrivateID() {
        withState { state in
            let duplicate = Window(
                privateID: targetWindowID,
                syntheticPID: state.nextSyntheticPID,
                element: AXUIElementCreateApplication(state.nextSyntheticPID),
                bounds: state.windows[0].bounds,
                role: kAXWindowRole as String,
            )
            state.nextSyntheticPID += 1
            state.windows.append(duplicate)
            state.elementPIDs[ObjectIdentifier(duplicate.element)] = ownedPID
        }
    }

    func replaceTargetAXObjectKeepingPrivateID() {
        withState { state in
            replaceTargetAXObject(
                in: &state,
                retainOldAncestry: false,
            )
        }
    }

    func replaceTargetDuringNextParentRead() {
        withState { $0.replaceTargetOnParentRead = true }
    }

    func ignoreFrontmostWrites() {
        withState { $0.frontmostWritesAffectState = false }
    }

    func focusSiblingWindow() {
        withState { state in
            state.focusedWindow = state.windows.first(where: {
                $0.privateID != targetWindowID
            })?.element
            state.mainWindow = state.windows.first(where: {
                $0.privateID != targetWindowID
            })?.element
        }
    }

    func failRaise(with error: AXError) {
        withState { $0.raiseError = error.rawValue }
    }

    func reportTargetFocusedAttribute(_ value: Bool) {
        withState { $0.targetFocusedAttributeOverride = value }
    }

    func hitSiblingWindow() {
        withState { state in
            replaceHitWithSibling(in: &state)
        }
    }

    func replaceHitWithSiblingOnTopologySnapshotAfterHit() {
        withState { $0.replaceHitOnTopologySnapshotAfterHit = true }
    }

    func topologySnapshotOccurred() {
        withState { state in
            guard state.replaceHitOnTopologySnapshotAfterHit,
                  state.hitTestReads > 0
            else {
                return
            }
            state.replaceHitOnTopologySnapshotAfterHit = false
            state.postHitTopologyMutations += 1
            replaceHitWithSibling(in: &state)
        }
    }

    func hitElementDescendsFromTargetWindow() -> Bool {
        withState { state in
            guard let target = state.windows.first(where: {
                $0.privateID == targetWindowID
            }) else {
                return false
            }
            var current = state.hitElement
            var visited = Set<ObjectIdentifier>()
            for _ in 0 ..< 64 {
                let identifier = ObjectIdentifier(current)
                guard visited.insert(identifier).inserted else {
                    return false
                }
                if CFEqual(current, target.element) {
                    return true
                }
                guard let parent = state.parents[identifier] else {
                    return false
                }
                current = parent
            }
            return false
        }
    }

    func hitForeignOverlay() {
        withState { state in
            let overlay = AXUIElementCreateApplication(state.nextSyntheticPID)
            state.nextSyntheticPID += 1
            state.hitElement = overlay
            state.elementPIDs[ObjectIdentifier(overlay)] = ownedPID + 99
            if let target = state.windows.first(where: { $0.privateID == targetWindowID }) {
                state.parents[ObjectIdentifier(overlay)] = target.element
            }
        }
    }

    func hitOwnedCycle() {
        withState { state in
            let first = AXUIElementCreateApplication(state.nextSyntheticPID)
            let second = AXUIElementCreateApplication(state.nextSyntheticPID + 1)
            state.nextSyntheticPID += 2
            state.hitElement = first
            state.parents[ObjectIdentifier(first)] = second
            state.parents[ObjectIdentifier(second)] = first
            state.elementPIDs[ObjectIdentifier(first)] = ownedPID
            state.elementPIDs[ObjectIdentifier(second)] = ownedPID
        }
    }

    func hitOwnedElementThroughForeignAncestor() {
        withState { state in
            guard let target = state.windows.first(where: {
                $0.privateID == targetWindowID
            }) else {
                return
            }
            let hit = AXUIElementCreateApplication(state.nextSyntheticPID)
            let foreignAncestor = AXUIElementCreateApplication(state.nextSyntheticPID + 1)
            state.nextSyntheticPID += 2
            state.hitElement = hit
            state.parents[ObjectIdentifier(hit)] = foreignAncestor
            state.parents[ObjectIdentifier(foreignAncestor)] = target.element
            state.elementPIDs[ObjectIdentifier(hit)] = ownedPID
            state.elementPIDs[ObjectIdentifier(foreignAncestor)] = ownedPID + 99
        }
    }

    func replaceGenerationOnNextActivation() {
        withState { $0.replaceGenerationOnActivation = true }
    }

    func replaceGenerationAfterNextWindowSizeRead() {
        withState { $0.replaceGenerationAfterWindowSizeRead = true }
    }

    func freshEquivalentWindowIsDistinct() -> Bool {
        withState { state in
            guard let target = state.windows.first(where: {
                $0.privateID == targetWindowID
            }) else {
                return false
            }
            let equivalent = AXUIElementCreateApplication(target.syntheticPID)
            return ObjectIdentifier(equivalent) != ObjectIdentifier(target.element)
                && CFEqual(equivalent, target.element)
        }
    }

    func setTargetRole(_ role: String) {
        withState { state in
            guard let index = state.windows.firstIndex(where: {
                $0.privateID == targetWindowID
            }) else {
                return
            }
            state.windows[index].role = role
        }
    }

    func setTargetLiveBounds(_ bounds: CGRect) {
        withState { state in
            guard let index = state.windows.firstIndex(where: {
                $0.privateID == targetWindowID
            }) else {
                return
            }
            state.windows[index].bounds = bounds
        }
    }

    func makeTargetPrivateIDUnreadable() {
        withState { $0.unreadablePrivateWindowID = targetWindowID }
    }

    func failPrivateWindowIDRead(with error: AXError) {
        withState { $0.privateWindowIDError = error.rawValue }
    }

    func makeWindowArrayMalformed() {
        withState { $0.malformedWindowArray = true }
    }

    func failHitTest(with error: AXError) {
        withState { $0.hitTestError = error.rawValue }
    }

    func failPIDRead(with error: AXError) {
        withState { $0.pidReadError = error.rawValue }
    }

    func returnSuccessfulPIDReadWithoutPID() {
        withState { $0.successfulPIDReadWithoutPID = true }
    }

    func cgWindowListCopyWindowInfo(
        options _: CGWindowListOption,
        relativeToWindow _: CGWindowID,
    ) -> [[String: Any]] {
        withState { state in
            var rows: [[String: Any]] = [
                windowDictionary(
                    id: targetWindowID,
                    bounds: state.registryBounds,
                    title: "Target",
                ),
            ]
            if state.windows.contains(where: { $0.privateID == targetWindowID + 1 }) {
                rows.append(windowDictionary(
                    id: targetWindowID + 1,
                    bounds: state.registryBounds.offsetBy(dx: 350, dy: 0),
                    title: "Sibling",
                ))
            }
            return rows
        }
    }

    func getRunningApplicationBundleID(pid: pid_t) -> String? {
        pid == ownedPID ? "com.example.InputTargetAuthority" : nil
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
        pid == ownedPID ? applicationElement : nil
    }

    func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        let identifier = ObjectIdentifier(element)
        return withState { state in
            if identifier == ObjectIdentifier(applicationElement) {
                switch attribute {
                case kAXWindowsAttribute:
                    if state.malformedWindowArray {
                        return ["not-an-AX-element"]
                    }
                    return state.windows.map {
                        AXUIElementCreateApplication($0.syntheticPID)
                    }
                case kAXFrontmostAttribute:
                    return state.frontmost
                case kAXFocusedWindowAttribute:
                    return state.focusedWindow
                case kAXMainWindowAttribute:
                    return state.mainWindow
                case kAXParentAttribute:
                    state.parentReads += 1
                    return nil
                default:
                    return nil
                }
            }
            if let window = state.windows.first(where: {
                CFEqual($0.element, element)
            }) {
                switch attribute {
                case kAXRoleAttribute:
                    return window.role
                case kAXPositionAttribute:
                    var position = window.bounds.origin
                    return AXValueCreate(.cgPoint, &position)
                case kAXSizeAttribute:
                    var size = window.bounds.size
                    let value = AXValueCreate(.cgSize, &size)
                    if state.replaceGenerationAfterWindowSizeRead {
                        state.replaceGenerationAfterWindowSizeRead = false
                        state.identity = replacingInputTargetAuthorityGeneration(
                            state.identity,
                        )
                    }
                    return value
                case kAXMainAttribute:
                    return state.mainWindow.map { CFEqual($0, window.element) } ?? false
                case kAXFocusedAttribute:
                    if window.privateID == targetWindowID,
                       let override = state.targetFocusedAttributeOverride
                    {
                        return override
                    }
                    return state.focusedWindow.map { CFEqual($0, window.element) } ?? false
                case kAXParentAttribute:
                    state.parentReads += 1
                    return nil
                default:
                    return nil
                }
            }
            if attribute == kAXParentAttribute as String {
                state.parentReads += 1
                let parent = state.parents[identifier]
                if state.replaceTargetOnParentRead {
                    state.replaceTargetOnParentRead = false
                    replaceTargetAXObject(
                        in: &state,
                        retainOldAncestry: true,
                    )
                }
                return parent
            }
            return nil
        }
    }

    func copyAXAttributeResult(element: AnyObject, attribute: String) -> AXAttributeRead {
        if let value = copyAXAttribute(element: element, attribute: attribute) {
            return AXAttributeRead(
                errorCode: AXError.success.rawValue,
                value: value,
            )
        }
        if attribute == kAXParentAttribute as String {
            return AXAttributeRead(
                errorCode: AXError.noValue.rawValue,
                value: nil,
            )
        }
        return AXAttributeRead(
            errorCode: AXError.attributeUnsupported.rawValue,
            value: nil,
        )
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element: AnyObject, attribute: String, value: Any) -> Int32 {
        let identifier = ObjectIdentifier(element)
        let result = withState { state in
            if identifier == ObjectIdentifier(applicationElement),
               attribute == kAXFrontmostAttribute as String
            {
                state.frontmostWrites += 1
                if state.frontmostWritesAffectState {
                    state.frontmost = (value as? Bool) == true
                }
                if state.replaceGenerationOnActivation {
                    state.identity = replacingInputTargetAuthorityGeneration(
                        state.identity,
                    )
                    state.replaceGenerationOnActivation = false
                }
                return AXError.success.rawValue
            }
            guard let window = state.windows.first(where: {
                CFEqual($0.element, element)
            }) else {
                return AXError.attributeUnsupported.rawValue
            }
            switch attribute {
            case kAXMainAttribute:
                state.windowMainWrites += 1
                if (value as? Bool) == true {
                    state.mainWindow = window.element
                }
            case kAXFocusedAttribute:
                state.windowFocusedWrites += 1
                if (value as? Bool) == true {
                    state.focusedWindow = window.element
                }
            default:
                return AXError.attributeUnsupported.rawValue
            }
            return AXError.success.rawValue
        }
        if identifier == ObjectIdentifier(applicationElement),
           attribute == kAXFrontmostAttribute as String,
           result == AXError.success.rawValue
        {
            frontmostHook()
        }
        return result
    }

    func performAXAction(element: AnyObject, action: String) -> Int32 {
        guard action == kAXRaiseAction as String else {
            return AXError.actionUnsupported.rawValue
        }
        return withState { state in
            guard state.raiseError == AXError.success.rawValue else {
                return state.raiseError
            }
            guard let window = state.windows.first(where: {
                CFEqual($0.element, element)
            }) else {
                return AXError.invalidUIElement.rawValue
            }
            state.raisedWindow = window.element
            return AXError.success.rawValue
        }
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        let read = readAXWindowID(element: element)
        return read.errorCode == AXError.success.rawValue ? read.windowID : nil
    }

    func readAXWindowID(element: AnyObject) -> AXWindowIDRead {
        withState { state in
            guard state.privateWindowIDError == AXError.success.rawValue else {
                return AXWindowIDRead(
                    errorCode: state.privateWindowIDError,
                    windowID: nil,
                )
            }
            let privateID = state.windows.first(where: {
                CFEqual($0.element, element)
            })?.privateID
            if privateID == state.unreadablePrivateWindowID {
                return AXWindowIDRead(
                    errorCode: Int32.min,
                    windowID: nil,
                )
            }
            return AXWindowIDRead(
                errorCode: privateID == nil
                    ? AXError.invalidUIElement.rawValue
                    : AXError.success.rawValue,
                windowID: privateID,
            )
        }
    }

    func copyAXElementAtPosition(_ point: CGPoint) -> AXElementRead {
        guard point.x.isFinite, point.y.isFinite else {
            return AXElementRead(
                errorCode: AXError.illegalArgument.rawValue,
                element: nil,
            )
        }
        return withState { state in
            state.hitTestReads += 1
            return AXElementRead(
                errorCode: state.hitTestError,
                element: state.hitTestError == AXError.success.rawValue
                    ? state.hitElement
                    : nil,
            )
        }
    }

    func getAXElementPID(element: AnyObject) -> AXElementPIDRead {
        withState { state in
            state.pidReads += 1
            guard state.pidReadError == AXError.success.rawValue else {
                return AXElementPIDRead(
                    errorCode: state.pidReadError,
                    pid: nil,
                )
            }
            if state.successfulPIDReadWithoutPID {
                return AXElementPIDRead(
                    errorCode: AXError.success.rawValue,
                    pid: nil,
                )
            }
            let pid = state.elementPIDs[ObjectIdentifier(element)]
                ?? (state.windows.contains(where: { CFEqual($0.element, element) })
                    ? ownedPID
                    : nil)
            return AXElementPIDRead(
                errorCode: pid == nil
                    ? AXError.invalidUIElement.rawValue
                    : AXError.success.rawValue,
                pid: pid,
            )
        }
    }

    private func windowDictionary(
        id: CGWindowID,
        bounds: CGRect,
        title: String,
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: ownedPID,
            kCGWindowBounds as String: [
                "X": bounds.origin.x,
                "Y": bounds.origin.y,
                "Width": bounds.width,
                "Height": bounds.height,
            ],
            kCGWindowName as String: title,
            kCGWindowLayer as String: Int32(0),
            kCGWindowIsOnscreen as String: true,
        ]
    }

    private func replaceTargetAXObject(
        in state: inout State,
        retainOldAncestry: Bool,
    ) {
        guard let index = state.windows.firstIndex(where: {
            $0.privateID == targetWindowID
        }) else {
            return
        }
        let old = state.windows[index].element
        let replacement = AXUIElementCreateApplication(state.nextSyntheticPID)
        state.nextSyntheticPID += 1
        state.windows[index] = Window(
            privateID: targetWindowID,
            syntheticPID: state.nextSyntheticPID - 1,
            element: replacement,
            bounds: state.windows[index].bounds,
            role: state.windows[index].role,
        )
        if !retainOldAncestry {
            state.elementPIDs.removeValue(forKey: ObjectIdentifier(old))
            state.parents = state.parents.mapValues { parent in
                CFEqual(parent, old) ? replacement : parent
            }
        }
        state.elementPIDs[ObjectIdentifier(replacement)] = ownedPID
        if state.focusedWindow.map({ CFEqual($0, old) }) == true {
            state.focusedWindow = replacement
        }
        if state.mainWindow.map({ CFEqual($0, old) }) == true {
            state.mainWindow = replacement
        }
    }

    private func replaceHitWithSibling(in state: inout State) {
        guard let sibling = state.windows.first(where: {
            $0.privateID != targetWindowID
        }) else {
            return
        }
        let child = AXUIElementCreateApplication(state.nextSyntheticPID)
        state.nextSyntheticPID += 1
        state.hitElement = child
        state.parents[ObjectIdentifier(child)] = sibling.element
        state.elementPIDs[ObjectIdentifier(child)] = ownedPID
    }

    private func withState<Value>(_ body: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private struct InputTargetAuthorityTopology: DisplayTopologyProviding {
    let system: InputTargetAuthoritySystem?

    init(system: InputTargetAuthoritySystem? = nil) {
        self.system = system
    }

    func snapshot() async throws -> DisplayTopologySnapshot {
        system?.topologySnapshotOccurred()
        return DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
                isMain: true,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 120, y: 120)
    }
}

private func replacingInputTargetAuthorityGeneration(
    _ identity: ApplicationProcessIdentity,
) -> ApplicationProcessIdentity {
    ApplicationProcessIdentity(
        pid: identity.pid,
        startTimeSeconds: identity.startTimeSeconds + 1,
        startTimeMicroseconds: identity.startTimeMicroseconds,
        bundleIdentifier: identity.bundleIdentifier,
        executablePath: identity.executablePath,
    )
}

private func targetAuthorityClickRequest(
    id: String,
    parent: String,
    window: String,
    point: CGPoint,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.window = window
        $0.input.action.click.position = Macosusesdk_Type_Point.with {
            $0.x = point.x
            $0.y = point.y
        }
    }
}

private func targetAuthorityKeyRequest(
    id: String,
    parent: String,
    window: String,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.window = window
        $0.input.action.pressKey.key = "return"
    }
}

private func targetAuthorityScrollRequest(
    id: String,
    parent: String,
    window: String,
    point: CGPoint,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.window = window
        $0.input.action.scroll = Macosusesdk_V1_Scroll.with {
            $0.position = Macosusesdk_Type_Point.with {
                $0.x = point.x
                $0.y = point.y
            }
            $0.vertical = -2
        }
    }
}

private func targetAuthorityApplicationKeyRequest(
    id: String,
    parent: String,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.application = parent
        $0.input.action.pressKey.key = "return"
    }
}

private func targetAuthorityApplicationClickRequest(
    id: String,
    parent: String,
    point: CGPoint,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.application = parent
        $0.input.action.click.position = Macosusesdk_Type_Point.with {
            $0.x = point.x
            $0.y = point.y
        }
    }
}

private func targetAuthorityApplicationCharacterRequest(
    id: String,
    parent: String,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.application = parent
        $0.input.action.pressKey.key = "a"
    }
}

private func targetAuthoritySessionClickRequest(
    id: String,
    target: Macosusesdk_V1_InputTarget.OneOf_Destination,
    point: CGPoint,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = "applications/-"
        $0.inputID = id
        $0.input.target.destination = target
        $0.input.action.click.position = Macosusesdk_Type_Point.with {
            $0.x = point.x
            $0.y = point.y
        }
    }
}

private func targetAuthorityApplicationMoveRequest(
    id: String,
    parent: String,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.application = parent
        $0.input.action.moveMouse.position = Macosusesdk_Type_Point.with {
            $0.x = 120
            $0.y = 120
        }
    }
}

private func targetAuthorityWindowMoveRequest(
    id: String,
    parent: String,
    window: String,
) -> Macosusesdk_V1_CreateInputRequest {
    Macosusesdk_V1_CreateInputRequest.with {
        $0.parent = parent
        $0.inputID = id
        $0.input.target.window = window
        $0.input.action.moveMouse.position = Macosusesdk_Type_Point.with {
            $0.x = 120
            $0.y = 120
        }
    }
}

private func expectInitialInputTargetAuthorityFailure(
    id: String,
    expected: RPCError.Code,
    configure: (InputTargetAuthoritySystem) -> Void,
) async throws {
    let fixture = try await InputTargetAuthorityFixture.make()
    configure(fixture.system)
    try await withInputTargetAuthorityClient(fixture.composition) { client in
        await expectInputTargetAuthorityRPCError(expected) {
            _ = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: id,
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
        }
    }
    let name = "\(fixture.applicationName)/inputs/\(id)"
    #expect(await fixture.composition.stateStore.getInput(name: name) == nil)
    #expect(await fixture.composition.stateStore.inputStateHistory(name: name).isEmpty)
    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
    #expect(await fixture.sink.count() == 0)
    await fixture.composition.serviceLifetime.shutdown()
}

private func assertPostpublicationTargetAuthorityFailure(
    fixture: InputTargetAuthorityFixture,
    id: String,
    expected: RPCError.Code,
) async throws {
    try await withInputTargetAuthorityClient(fixture.composition) { client in
        await expectInputTargetAuthorityRPCError(expected) {
            _ = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityKeyRequest(
                    id: id,
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                ),
            )
        }
    }
    let name = "\(fixture.applicationName)/inputs/\(id)"
    let failed = try #require(
        await fixture.composition.stateStore.getInput(name: name),
    )
    #expect(failed.state == .failed)
    #expect(failed.deliveryResult.commitment == .noEffect)
    #expect(failed.deliveryResult.postedEventCount == 0)
    #expect(await fixture.composition.stateStore.inputStateHistory(name: name) == [
        .pending,
        .executing,
        .failed,
    ])
    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
    #expect(await fixture.sink.count() == 0)
    await fixture.composition.serviceLifetime.shutdown()
}

private func assertPostpublicationApplicationTargetAuthorityFailure(
    fixture: InputTargetAuthorityFixture,
    id: String,
    expected: RPCError.Code,
) async throws {
    try await withInputTargetAuthorityClient(fixture.composition) { client in
        await expectInputTargetAuthorityRPCError(expected) {
            _ = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityApplicationClickRequest(
                    id: id,
                    parent: fixture.applicationName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
        }
    }
    let name = "\(fixture.applicationName)/inputs/\(id)"
    let failed = try #require(
        await fixture.composition.stateStore.getInput(name: name),
    )
    #expect(failed.state == .failed)
    #expect(failed.deliveryResult.commitment == .noEffect)
    #expect(failed.deliveryResult.postedEventCount == 0)
    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
    #expect(await fixture.sink.count() == 0)
    await fixture.composition.serviceLifetime.shutdown()
}

private func assertPostpublicationWindowPointerTargetAuthorityFailure(
    fixture: InputTargetAuthorityFixture,
    id: String,
    expected: RPCError.Code,
) async throws {
    try await withInputTargetAuthorityClient(fixture.composition) { client in
        await expectInputTargetAuthorityRPCError(expected) {
            _ = try await createTargetAuthorityInput(
                client: client,
                request: targetAuthorityClickRequest(
                    id: id,
                    parent: fixture.applicationName,
                    window: fixture.targetWindowName,
                    point: CGPoint(x: 120, y: 120),
                ),
            )
        }
    }
    let name = "\(fixture.applicationName)/inputs/\(id)"
    let failed = try #require(
        await fixture.composition.stateStore.getInput(name: name),
    )
    #expect(failed.state == .failed)
    #expect(failed.deliveryResult.commitment == .noEffect)
    #expect(failed.deliveryResult.postedEventCount == 0)
    #expect(failed.deliveryResult.routedDeliveryObserved == false)
    #expect(await fixture.composition.stateStore.inputStateHistory(name: name) == [
        .pending,
        .executing,
        .failed,
    ])
    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
    #expect(await fixture.sink.count() == 0)
    await fixture.composition.serviceLifetime.shutdown()
}

private func withInputTargetAuthorityClient(
    _ composition: MacosUseServiceComposition,
    operation: @escaping @Sendable (
        GRPCClient<InProcessTransport.Client>,
    ) async throws -> Void,
) async throws {
    try await withInputTargetAuthorityClient(
        composition.macosUseService,
        operation: operation,
    )
}

private func withInputTargetAuthorityClient(
    _ service: MacosUseService,
    operation: @escaping @Sendable (
        GRPCClient<InProcessTransport.Client>,
    ) async throws -> Void,
) async throws {
    let transport = InProcessTransport()
    let server = GRPCServer(
        transport: transport.server,
        services: [service],
    )
    let client = GRPCClient(transport: transport.client)
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

private func createTargetAuthorityInput(
    client: GRPCClient<InProcessTransport.Client>,
    request: Macosusesdk_V1_CreateInputRequest,
) async throws -> Macosusesdk_V1_Input {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: Macosusesdk_V1_MacosUse.Method.CreateInput.descriptor,
        serializer: ProtobufSerializer<Macosusesdk_V1_CreateInputRequest>(),
        deserializer: ProtobufDeserializer<Macosusesdk_V1_Input>(),
        options: .defaults,
    ) { response in
        try response.message
    }
}

private func expectInputTargetAuthorityRPCError(
    _ expected: RPCError.Code,
    operation: () async throws -> Void,
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected) RPC error")
    } catch let error as RPCError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Expected RPCError, got \(String(describing: error))")
    }
}
