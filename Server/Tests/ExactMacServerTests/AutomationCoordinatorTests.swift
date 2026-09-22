import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
@testable import ExactMacServer
import GRPCCore
import XCTest

// NOTE: Tests for `ExactMac.InputAction.requiresAppActivation` live in
// `Tests/ExactMacTests/InputActionAppActivationTests.swift`. `InputAction`
// is a core SDK type; its behavior must be covered in the SDK test target
// (not the Server test target) so the SDK's own contract is verified in
// isolation. If you add a new `InputAction` case, update that test file
// to keep the activation contract exhaustive.

/// Unit tests for AutomationCoordinator pure functions and conversions.
/// These tests focus on testable logic without external dependencies.
final class AutomationCoordinatorTests: XCTestCase {
    func testClosedMutationAdmissionUsesExactFailureResolver() async {
        let coordinator = AutomationCoordinator()
        await coordinator.beginMutationDraining()

        do {
            let _: Void = try await coordinator.withOwnedMutationTask(
                onAdmissionClosed: {
                    RPCError(
                        code: .alreadyExists,
                        message: "Exact input identity already exists",
                    )
                },
            ) { _, _ in
                XCTFail("Closed mutation admission executed a transaction")
            }
            XCTFail("Expected exact closed-admission failure")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .alreadyExists)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let activeCount = await coordinator.activeMutationCount()
        XCTAssertEqual(activeCount, 0)
    }

    @MainActor
    func testPhysicalMutationIsOwnedCancelledAndJoined() async throws {
        let probe = BlockingTraversalExecutionProbe()
        let coordinator = AutomationCoordinator(
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await probe.run()
                try Task.checkCancellation()
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )

        let input = Task { @MainActor in
            _ = try await coordinator.handlePhysicalMutation { context in
                try await context.executeInput(
                    .move(to: CGPoint(x: 10, y: 20)),
                    route: .session,
                )
            }
        }
        await probe.waitUntilEntered()
        let initialActiveMutationCount = await coordinator.activeMutationCount()
        XCTAssertEqual(initialActiveMutationCount, 1)

        let shutdown = Task { await coordinator.shutdownMutations() }
        await probe.waitUntilCancellationObserved()
        let cancellingActiveMutationCount = await coordinator.activeMutationCount()
        XCTAssertEqual(cancellingActiveMutationCount, 1)

        await probe.release()
        await shutdown.value
        do {
            try await input.value
            XCTFail("Expected shutdown to cancel the retained input task")
        } catch is CancellationError {
            // Expected.
        }
        let finalActiveMutationCount = await coordinator.activeMutationCount()
        XCTAssertEqual(finalActiveMutationCount, 0)

        do {
            _ = try await coordinator.handlePhysicalMutation { context in
                try await context.executeInput(
                    .move(to: CGPoint(x: 30, y: 40)),
                    route: .session,
                )
            }
            XCTFail("Expected mutation admission to remain closed")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    // MARK: - CoordinatorError Tests

    func testCoordinatorErrorInvalidKeyNameDescription() {
        let error = CoordinatorError.invalidKeyName("badKey")
        XCTAssertEqual(error.errorDescription, "Invalid key name: badKey")
    }

    func testCoordinatorErrorInvalidKeyComboDescription() {
        let error = CoordinatorError.invalidKeyCombo("cmd+")
        XCTAssertEqual(error.errorDescription, "Invalid key combo: cmd+")
    }

    func testCoordinatorErrorUnknownModifierDescription() {
        let error = CoordinatorError.unknownModifier("meta")
        XCTAssertEqual(error.errorDescription, "Unknown modifier: meta")
    }

    func testCoordinatorErrorInvalidCoordinateDescription() {
        let error = CoordinatorError.invalidCoordinate("click has non-finite x coordinate: nan")
        XCTAssertEqual(error.errorDescription, "Invalid coordinate: click has non-finite x coordinate: nan")
    }

    func testCoordinatorErrorConformsToLocalizedError() throws {
        // Verify all cases conform to LocalizedError properly
        let errors: [CoordinatorError] = [
            .invalidKeyName("test"),
            .invalidKeyCombo("test"),
            .unknownModifier("test"),
            .invalidCoordinate("test"),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(try XCTUnwrap(error.errorDescription?.isEmpty))
        }
    }

    // MARK: - Exact-PID Activation Tests

    @MainActor
    func testTargetActivationUsesAXAndRequiresFrontmostConvergence() async throws {
        let mock = MockSystemOperations(
            axAttributes: [kAXFrontmostAttribute as String: true],
            setAXAttributeResult: AXError.success.rawValue,
        )

        try await AutomationCoordinator.activateTargetApplication(
            pid: 1234,
            system: mock,
            timeout: .milliseconds(10),
            pollInterval: .milliseconds(1),
        )

        XCTAssertEqual(mock.setAXAttributeCalls.count, 1)
        XCTAssertEqual(
            mock.setAXAttributeCalls.first?.attribute,
            kAXFrontmostAttribute as String,
        )
        XCTAssertEqual(mock.setAXAttributeCalls.first?.value as? Bool, true)
    }

    @MainActor
    func testTargetActivationFailsClosedWhenAXSetFails() async {
        let mock = MockSystemOperations(setAXAttributeResult: AXError.invalidUIElement.rawValue)

        do {
            try await AutomationCoordinator.activateTargetApplication(
                pid: 4321,
                system: mock,
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1),
            )
            XCTFail("Expected exact-PID activation to fail")
        } catch let error as InputTargetActivationError {
            XCTAssertEqual(
                error,
                .setFrontmostFailed(
                    pid: 4321,
                    axErrorCode: AXError.invalidUIElement.rawValue,
                ),
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testTargetActivationFailsClosedWithoutConvergence() async {
        let mock = MockSystemOperations(
            axAttributes: [kAXFrontmostAttribute as String: false],
            setAXAttributeResult: AXError.success.rawValue,
        )

        do {
            try await AutomationCoordinator.activateTargetApplication(
                pid: 9876,
                system: mock,
                timeout: .zero,
                pollInterval: .milliseconds(1),
            )
            XCTFail("Expected exact-PID activation convergence to time out")
        } catch let error as InputTargetActivationError {
            XCTAssertEqual(error, .convergenceTimedOut(pid: 9876))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testElementWindowFocusConvergesThroughMainOrFocusedReadback() async throws {
        let mock = MockSystemOperations(
            axAttributes: [
                kAXRoleAttribute as String: kAXWindowRole as String,
                kAXMainAttribute as String: false,
                kAXFocusedAttribute as String: false,
            ],
            setAXAttributeResult: AXError.success.rawValue,
            applySuccessfulAXWritesToAttributes: true,
        )
        let registry = ElementRegistry(idGenerator: { "focus-element" })
        _ = try await registry.registerElement(
            Exactmac_V1_Element.with { $0.role = "AXButton" },
            axElement: AXUIElementCreateSystemWide(),
            pid: 1234,
        )
        let target = try await registry.resolveElementForMutation(
            "focus-element",
            expectedPID: 1234,
        )
        let context = PhysicalDesktopMutationContext(
            system: mock,
            elementRegistry: registry,
            inputPostAccessChecker: { true },
            inputActionExecutor: nil,
        )

        try await context.focusElementWindow(
            target: target,
            timeout: .milliseconds(10),
            pollInterval: .milliseconds(1),
        )

        XCTAssertTrue(mock.setAXAttributeCalls.contains {
            $0.attribute == kAXMainAttribute as String && $0.value as? Bool == true
        })
        XCTAssertTrue(mock.setAXAttributeCalls.contains {
            $0.attribute == kAXFocusedAttribute as String && $0.value as? Bool == true
        })
        XCTAssertTrue(mock.copyAXAttributeCalls.contains {
            $0.attribute == kAXMainAttribute as String
        })
    }

    @MainActor
    func testActivatedTraversalIsOwnedCancelledAndHoldsMutationGate() async throws {
        let gate = PhysicalDesktopMutationGate()
        let traversalProbe = BlockingTraversalExecutionProbe()
        let mock = MockSystemOperations(
            axAttributes: [kAXFrontmostAttribute as String: true],
            setAXAttributeResult: AXError.success.rawValue,
        )
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: mock,
            accessibilityTraversalExecutor: { _, _ in
                await traversalProbe.run()
                return AccessibilityTraversalSnapshot(appName: "Injected app")
            },
        )

        let traversal = Task {
            try await coordinator.handleTraverse(
                pid: 2468,
                visibleOnly: true,
                shouldActivate: true,
            )
        }
        await traversalProbe.waitUntilEntered()

        XCTAssertEqual(mock.setAXAttributeCalls.count, 1)
        let activeTraversalCount = await coordinator.activeTraversalCount()
        XCTAssertEqual(activeTraversalCount, 1)

        let competingMutation = Task {
            try await gate.withExclusiveOperation {}
        }
        try await waitForTraversalMutationPending(gate, count: 1)

        traversal.cancel()
        await traversalProbe.waitUntilCancellationObserved()
        await traversalProbe.release()

        do {
            _ = try await traversal.value
            XCTFail("Expected traversal cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await competingMutation.value

        let finalTraversalCount = await coordinator.activeTraversalCount()
        let finalElementCount = await coordinator.elementRegistry.getCachedElementCount()
        XCTAssertEqual(finalTraversalCount, 0)
        XCTAssertEqual(finalElementCount, 0)
    }

    // MARK: - Modifier Conversion Tests (via Proto Types)

    func testModifierConversionCommand() {
        // Test that the Modifier enum is accessible and has expected cases
        let modifier = Exactmac_V1_KeyPress.Modifier.command
        XCTAssertEqual(modifier.rawValue, 1)
    }

    func testModifierConversionOption() {
        let modifier = Exactmac_V1_KeyPress.Modifier.option
        XCTAssertEqual(modifier.rawValue, 2)
    }

    func testModifierConversionControl() {
        let modifier = Exactmac_V1_KeyPress.Modifier.control
        XCTAssertEqual(modifier.rawValue, 3)
    }

    func testModifierConversionShift() {
        let modifier = Exactmac_V1_KeyPress.Modifier.shift
        XCTAssertEqual(modifier.rawValue, 4)
    }

    func testModifierConversionFunction() {
        let modifier = Exactmac_V1_KeyPress.Modifier.function
        XCTAssertEqual(modifier.rawValue, 5)
    }

    // MARK: - Point Conversion Tests

    func testCGPointFromProtoPosition() {
        // Verify CGPoint construction from proto-like values
        let protoX = 123.5
        let protoY = 456.7
        let point = CGPoint(x: protoX, y: protoY)

        XCTAssertEqual(point.x, 123.5)
        XCTAssertEqual(point.y, 456.7)
    }

    func testCGPointNegativeCoordinates() {
        // Multi-monitor setups can have negative coordinates
        let point = CGPoint(x: -100, y: -50)
        XCTAssertEqual(point.x, -100)
        XCTAssertEqual(point.y, -50)
    }

    func testCGPointLargeCoordinates() {
        // Large display coordinates should work
        let point = CGPoint(x: 5120, y: 2880)
        XCTAssertEqual(point.x, 5120)
        XCTAssertEqual(point.y, 2880)
    }
}

private actor BlockingTraversalExecutionProbe {
    private let cancellationSignal = TraversalCancellationSignal()
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withTaskCancellationHandler {
            entered = true
            let continuations = enteredContinuations
            enteredContinuations.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: { [cancellationSignal] in
            cancellationSignal.record()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        await cancellationSignal.waitUntilRecorded()
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class TraversalCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func record() {
        lock.lock()
        guard !recorded else {
            lock.unlock()
            return
        }
        recorded = true
        let continuations = continuations
        self.continuations.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitUntilRecorded() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if recorded {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

private func waitForTraversalMutationPending(
    _ gate: PhysicalDesktopMutationGate,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await gate.pendingCount() != count {
        guard clock.now < deadline else {
            throw InputMutationTestError.convergenceTimeout("queued traversal mutations", count)
        }
        await Task.yield()
    }
}
