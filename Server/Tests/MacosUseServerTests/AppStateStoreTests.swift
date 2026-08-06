import Foundation
import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Tests for the AppStateStore actor
final class AppStateStoreTests: XCTestCase {
    func testAddAndGetTarget() async {
        let store = AppStateStore()
        let target = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "TestApp"
        }

        await store.addTarget(target)
        let retrieved = await store.getTarget(pid: 123)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.pid, 123)
        XCTAssertEqual(retrieved?.displayName, "TestApp")
    }

    func testListTargets() async {
        let store = AppStateStore()
        let target1 = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "App1"
        }
        let target2 = Macosusesdk_V1_Application.with {
            $0.name = "applications/456"
            $0.pid = 456
            $0.displayName = "App2"
        }

        await store.addTarget(target1)
        await store.addTarget(target2)

        let targets = await store.listTargets()
        XCTAssertEqual(targets.count, 2)
    }

    func testRemoveTarget() async {
        let store = AppStateStore()
        let target = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "TestApp"
        }

        await store.addTarget(target)
        let removed = await store.removeTarget(pid: 123)

        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.pid, 123)

        let retrieved = await store.getTarget(pid: 123)
        XCTAssertNil(retrieved)
    }

    func testCurrentState() async {
        let store = AppStateStore()
        let target = Macosusesdk_V1_Application.with {
            $0.name = "applications/123"
            $0.pid = 123
            $0.displayName = "TestApp"
        }

        await store.addTarget(target)
        let state = await store.currentState()

        XCTAssertEqual(state.applications.count, 1)
        XCTAssertNotNil(state.applications[123])
    }

    func testInputManagement() async {
        let store = AppStateStore()
        let input = Macosusesdk_V1_Input.with {
            $0.name = "applications/123/inputs/1"
            $0.state = .failed
            $0.error = "seeded terminal fixture"
            $0.completeTime = .with { $0.seconds = 1 }
            $0.deliveryResult.commitment = .noEffect
        }

        await store.seedInputForTesting(input)
        let retrieved = await store.getInput(name: "applications/123/inputs/1")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.state, .failed)
    }

    func testInputIdentityReservationIsInvisibleUntilPublished() async {
        let store = AppStateStore()
        let ownerID = UUID()
        let name = "applications/-/inputs/invisible"
        let lease: AppStateStore.InputIdentityLease

        switch await store.reserveInputIdentity(name: name, ownerID: ownerID) {
        case let .reserved(reserved):
            lease = reserved
        case .duplicate, .admissionClosed:
            return XCTFail("Expected the first identity reservation to succeed")
        }

        let reservedIdentityExists = await store.containsInputIdentity(name: name)
        let reservedIdentityCount = await store.activeInputIdentityCount()
        let invisibleInput = await store.getInput(name: name)
        let invisibleList = await store.listInputs(parent: "applications/-")
        let invisibleHistory = await store.inputStateHistory(name: name)
        XCTAssertTrue(reservedIdentityExists)
        XCTAssertEqual(reservedIdentityCount, 1)
        XCTAssertNil(invisibleInput)
        XCTAssertTrue(invisibleList.isEmpty)
        XCTAssertTrue(invisibleHistory.isEmpty)

        let published = await store.publishPendingInput(
            lease: lease,
            action: makeInputAction(),
            target: makeDesktopTarget(),
        )
        XCTAssertEqual(published?.name, name)
        XCTAssertEqual(published?.state, .pending)
        XCTAssertTrue(published?.hasCreateTime == true)
        let publishedHistory = await store.inputStateHistory(name: name)
        let publishedIdentityCount = await store.activeInputIdentityCount()
        XCTAssertEqual(publishedHistory, [.pending])
        XCTAssertEqual(publishedIdentityCount, 1)
    }

    func testAbandonedInvisibleIdentityCanBeRetriedButWrongOwnerCannotReleaseIt() async {
        let store = AppStateStore()
        let name = "applications/-/inputs/retry"
        let firstOwner = UUID()
        let firstLease: AppStateStore.InputIdentityLease

        switch await store.reserveInputIdentity(name: name, ownerID: firstOwner) {
        case let .reserved(reserved):
            firstLease = reserved
        case .duplicate, .admissionClosed:
            return XCTFail("Expected the first identity reservation to succeed")
        }

        let wrongLease = AppStateStore.InputIdentityLease(name: name, ownerID: UUID())
        let wrongOwnerAbandoned = await store.abandonInputIdentity(wrongLease)
        let identityRemained = await store.containsInputIdentity(name: name)
        let correctOwnerAbandoned = await store.abandonInputIdentity(firstLease)
        let identityExistsAfterAbandon = await store.containsInputIdentity(name: name)
        let identityCountAfterAbandon = await store.activeInputIdentityCount()
        XCTAssertFalse(wrongOwnerAbandoned)
        XCTAssertTrue(identityRemained)
        XCTAssertTrue(correctOwnerAbandoned)
        XCTAssertFalse(identityExistsAfterAbandon)
        XCTAssertEqual(identityCountAfterAbandon, 0)

        switch await store.reserveInputIdentity(name: name, ownerID: UUID()) {
        case .reserved:
            break
        case .duplicate, .admissionClosed:
            XCTFail("An abandoned pre-publication identity must be retryable")
        }
    }

    func testDuplicateIdentityWinsAfterAdmissionClosesAndTerminalIdentityIsPermanent() async throws {
        let store = AppStateStore()
        let name = "applications/-/inputs/permanent"
        let ownerID = UUID()
        let lease: AppStateStore.InputIdentityLease

        switch await store.reserveInputIdentity(name: name, ownerID: ownerID) {
        case let .reserved(reserved):
            lease = reserved
        case .duplicate, .admissionClosed:
            return XCTFail("Expected the first identity reservation to succeed")
        }
        let published = await store.publishPendingInput(
            lease: lease,
            action: makeInputAction(),
            target: makeDesktopTarget(),
        )
        _ = try XCTUnwrap(published)
        let executing = await store.markInputExecuting(lease: lease)
        _ = try XCTUnwrap(executing)
        let terminalResult = await store.finishInput(
            lease: lease,
            outcome: .completed(.with {
                $0.commitment = .committedAndSettled
                $0.postedEventCount = 2
                $0.routedDeliveryObserved = true
            }),
        )
        guard case let .finished(terminal) = terminalResult else {
            return XCTFail("Expected exact terminal settlement")
        }
        XCTAssertEqual(terminal.state, .completed)

        await store.beginInputDraining()
        switch await store.reserveInputIdentity(name: name, ownerID: UUID()) {
        case .duplicate:
            break
        case .reserved, .admissionClosed:
            XCTFail("A permanent duplicate must win over closed admission")
        }
        switch await store.reserveInputIdentity(
            name: "applications/-/inputs/new-after-drain",
            ownerID: UUID(),
        ) {
        case .admissionClosed:
            break
        case .reserved, .duplicate:
            XCTFail("A new identity must not be admitted after drain")
        }
        let terminalIdentityCount = await store.activeInputIdentityCount()
        let terminalHistory = await store.inputStateHistory(name: name)
        XCTAssertEqual(terminalIdentityCount, 0)
        XCTAssertEqual(terminalHistory, [.pending, .executing, .completed])
    }

    func testMalformedTerminalOutcomeFailsConservativelyAndReleasesExactOwner() async throws {
        let store = AppStateStore()
        let name = "applications/-/inputs/malformed-terminal"
        let lease: AppStateStore.InputIdentityLease
        switch await store.reserveInputIdentity(name: name, ownerID: UUID()) {
        case let .reserved(reserved):
            lease = reserved
        case .duplicate, .admissionClosed:
            return XCTFail("Expected identity reservation")
        }
        let publishedInput = await store.publishPendingInput(
            lease: lease,
            action: makeInputAction(),
            target: makeDesktopTarget(),
        )
        _ = try XCTUnwrap(publishedInput)

        let result = await store.finishInput(
            lease: lease,
            outcome: .completed(.with {
                $0.commitment = .committedAndSettled
                $0.postedEventCount = -1
                $0.routedDeliveryObserved = true
            }),
        )
        guard case let .finished(input) = result else {
            return XCTFail("Malformed outcome must still terminalize its exact owner")
        }
        XCTAssertEqual(input.state, .failed)
        XCTAssertEqual(input.deliveryResult.commitment, .possiblyCommitted)
        XCTAssertEqual(input.deliveryResult.postedEventCount, 1)
        XCTAssertTrue(input.deliveryResult.routedDeliveryObserved)
        let activeIdentityCount = await store.activeInputIdentityCount()
        let identityExists = await store.containsInputIdentity(name: name)
        XCTAssertEqual(activeIdentityCount, 0)
        XCTAssertTrue(identityExists)
    }

    func testMissingPublishedStateReleasesOwnerButKeepsPermanentIdentity() async {
        let store = AppStateStore()
        let name = "applications/-/inputs/missing-published-state"
        let lease: AppStateStore.InputIdentityLease
        switch await store.reserveInputIdentity(name: name, ownerID: UUID()) {
        case let .reserved(reserved):
            lease = reserved
        case .duplicate, .admissionClosed:
            return XCTFail("Expected identity reservation")
        }

        let wrongLease = AppStateStore.InputIdentityLease(
            name: name,
            ownerID: UUID(),
        )
        guard case .leaseLost = await store.finishInput(
            lease: wrongLease,
            outcome: .failed(error: "wrong owner", delivery: .init()),
        ) else {
            return XCTFail("Wrong owner must not finish another lease")
        }
        let activeAfterWrongOwner = await store.activeInputIdentityCount()
        XCTAssertEqual(activeAfterWrongOwner, 1)

        guard case .missingPublishedState = await store.finishInput(
            lease: lease,
            outcome: .failed(error: "missing state", delivery: .init()),
        ) else {
            return XCTFail("Expected typed missing-state result")
        }
        let activeAfterMissingState = await store.activeInputIdentityCount()
        let identityExists = await store.containsInputIdentity(name: name)
        XCTAssertEqual(activeAfterMissingState, 0)
        XCTAssertTrue(identityExists)
        switch await store.reserveInputIdentity(name: name, ownerID: UUID()) {
        case .duplicate:
            break
        case .reserved, .admissionClosed:
            XCTFail("A corrupted published identity must remain permanently reserved")
        }
    }

    func testApplicationProcessGenerationLeaseRejectsIncoherentRowsAndPIDReuse() async {
        let store = AppStateStore()
        let firstIdentity = makeIdentity(pid: 794, start: 1)
        let first = makeApplication(identity: firstIdentity)
        await store.addTarget(first, processIdentity: firstIdentity)

        let firstLease = await store.applicationProcessGenerationLease(name: first.name)
        XCTAssertEqual(firstLease?.name, first.name)
        XCTAssertEqual(firstLease?.pid, firstIdentity.pid)
        XCTAssertEqual(firstLease?.identity, firstIdentity)

        let incoherent = Macosusesdk_V1_Application.with {
            $0.name = "applications/\(String(repeating: "a", count: 64))"
            $0.pid = Int32(firstIdentity.pid)
        }
        await store.addTarget(incoherent, processIdentity: firstIdentity)
        let incoherentLease = await store.applicationProcessGenerationLease(name: incoherent.name)
        let staleLease = await store.applicationProcessGenerationLease(name: first.name)
        XCTAssertNil(incoherentLease)
        XCTAssertNil(staleLease)

        let replacementIdentity = makeIdentity(pid: 794, start: 2)
        let replacement = makeApplication(identity: replacementIdentity)
        await store.addTarget(replacement, processIdentity: replacementIdentity)
        let replacedLease = await store.applicationProcessGenerationLease(name: first.name)
        let replacementLease = await store.applicationProcessGenerationLease(name: replacement.name)
        XCTAssertNil(replacedLease)
        XCTAssertEqual(replacementLease?.identity, replacementIdentity)
    }

    func testExactNameLookupDoesNotResolveReplacedPIDIdentity() async {
        let store = AppStateStore()
        let firstIdentity = makeIdentity(pid: 789, start: 1)
        let secondIdentity = makeIdentity(pid: 789, start: 2)
        let first = makeApplication(identity: firstIdentity)
        let second = makeApplication(identity: secondIdentity)

        await store.addTarget(first, processIdentity: firstIdentity)
        await store.addTarget(second, processIdentity: secondIdentity)

        let stale = await store.getTarget(name: first.name)
        let current = await store.getTarget(name: second.name)
        let currentIdentity = await store.getApplicationProcessIdentity(name: second.name)
        XCTAssertNil(stale)
        XCTAssertEqual(current?.name, second.name)
        XCTAssertEqual(currentIdentity, secondIdentity)
    }

    func testRemoveByStaleNameCannotRemoveReplacementAtSamePID() async {
        let store = AppStateStore()
        let first = makeApplication(identity: makeIdentity(pid: 790, start: 1))
        let secondIdentity = makeIdentity(pid: 790, start: 2)
        let second = makeApplication(identity: secondIdentity)
        await store.addTarget(first, processIdentity: makeIdentity(pid: 790, start: 1))
        await store.addTarget(second, processIdentity: secondIdentity)

        let removed = await store.removeTarget(name: first.name)
        let current = await store.getTarget(name: second.name)

        XCTAssertNil(removed)
        XCTAssertEqual(current?.name, second.name)
    }

    func testReconcileRetainsOnlyKernelLiveOmittedIdentity() async {
        let store = AppStateStore()
        let liveIdentity = makeIdentity(pid: 791, start: 1)
        let exitedIdentity = makeIdentity(pid: 792, start: 1)
        let live = makeApplication(identity: liveIdentity)
        let exited = makeApplication(identity: exitedIdentity)
        await store.addTarget(live, processIdentity: liveIdentity)
        await store.addTarget(exited, processIdentity: exitedIdentity)

        await store.reconcileTargets([]) { identity in
            identity == liveIdentity
        }

        let retained = await store.listTargets()
        let retainedIdentity = await store.getApplicationProcessIdentity(name: live.name)
        let removed = await store.getTarget(name: exited.name)
        XCTAssertEqual(retained.map(\.name), [live.name])
        XCTAssertEqual(retainedIdentity, liveIdentity)
        XCTAssertNil(removed)
    }

    func testApplicationResourceNameUsesOnlyKernelStartIdentity() {
        let sparseIdentity = ApplicationProcessIdentity(
            pid: 793,
            startTimeSeconds: 10,
            startTimeMicroseconds: 20,
            bundleIdentifier: nil,
            executablePath: nil,
        )
        let enrichedIdentity = ApplicationProcessIdentity(
            pid: 793,
            startTimeSeconds: 10,
            startTimeMicroseconds: 20,
            bundleIdentifier: "com.example.Application",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
        )
        let replacementIdentity = ApplicationProcessIdentity(
            pid: 793,
            startTimeSeconds: 10,
            startTimeMicroseconds: 21,
            bundleIdentifier: "com.example.Application",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
        )

        XCTAssertEqual(
            applicationResourceName(for: sparseIdentity),
            applicationResourceName(for: enrichedIdentity),
        )
        XCTAssertNotEqual(
            applicationResourceName(for: enrichedIdentity),
            applicationResourceName(for: replacementIdentity),
        )
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

    private func makeApplication(identity: ApplicationProcessIdentity) -> Macosusesdk_V1_Application {
        .with {
            $0.name = applicationResourceName(for: identity)
            $0.pid = Int32(identity.pid)
            $0.displayName = "Example"
        }
    }

    private func makeInputAction() -> Macosusesdk_V1_InputAction {
        .with {
            $0.click.position = .with {
                $0.x = 10
                $0.y = 20
            }
        }
    }

    private func makeDesktopTarget() -> Macosusesdk_V1_InputTarget {
        .with { $0.desktop = true }
    }
}
