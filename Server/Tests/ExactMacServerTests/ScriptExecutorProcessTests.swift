import Darwin
@testable import ExactMacServer
import Foundation
import XCTest

final class ScriptExecutorProcessTests: XCTestCase {
    func testUnsafeTimeoutRejectedBeforeOwnedExecutionOrProcess() async throws {
        let processProbe = ScriptProcessInvocationProbe()
        let executor = ScriptExecutor(
            mutationGate: PhysicalDesktopMutationGate(),
            processOperation: { await processProbe.record() },
        )
        let unsafeTimeout = Double(UInt64.max) / 1_000_000_000

        do {
            _ = try await executor.executeAppleScript(
                "return 1",
                timeout: unsafeTimeout,
                compileOnly: true,
            )
            XCTFail("Expected unsafe compile-only timeout rejection")
        } catch let error as ScriptExecutionError {
            guard case .processError = error else {
                return XCTFail("Expected processError, got \(error)")
            }
        }

        do {
            _ = try await executor.executeShellCommand("true", timeout: unsafeTimeout)
            XCTFail("Expected unsafe shell timeout rejection")
        } catch let error as ScriptExecutionError {
            guard case .processError = error else {
                return XCTFail("Expected processError, got \(error)")
            }
        }

        let invocationCount = await processProbe.invocationCount()
        let activeExecutionCount = await executor.activeExecutionCount()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(activeExecutionCount, 0)
    }

    func testExecutionUsesInjectedPhysicalDesktopGate() async throws {
        let gate = PhysicalDesktopMutationGate()
        let gateProbe = BlockingScriptProcessProbe()
        let processProbe = BlockingScriptProcessProbe()
        let executor = ScriptExecutor(
            mutationGate: gate,
            processOperation: { await processProbe.run() },
        )

        let holder = Task {
            try await gate.withExclusiveOperation {
                await gateProbe.run()
            }
        }
        await gateProbe.waitUntilEntered()

        let execution = Task {
            try await executor.executeShellCommand("true")
        }
        try await pollUntilGatePending(gate, expected: 1)
        let processEnteredWhileGateHeld = await processProbe.hasEntered()
        XCTAssertFalse(processEnteredWhileGateHeld)

        await gateProbe.release()
        try await holder.value
        await processProbe.waitUntilEntered()
        await processProbe.release()
        _ = try await execution.value
    }

    func testShutdownAwaitsOwnedExecutionAndClosesAdmission() async throws {
        let probe = BlockingScriptProcessProbe()
        let executor = ScriptExecutor(
            mutationGate: PhysicalDesktopMutationGate(),
            processOperation: { await probe.run() },
        )
        let execution = Task {
            try await executor.executeShellCommand("true")
        }
        await probe.waitUntilEntered()

        let shutdown = Task {
            await executor.shutdown()
            await probe.recordShutdownReturned()
        }
        await probe.waitUntilCancellationObserved()

        let shutdownReturnedBeforeRelease = await probe.didShutdownReturn()
        let activeBeforeRelease = await executor.activeExecutionCount()
        XCTAssertFalse(shutdownReturnedBeforeRelease)
        XCTAssertEqual(activeBeforeRelease, 1)

        await probe.release()
        await shutdown.value
        do {
            _ = try await execution.value
            XCTFail("Expected shutdown to cancel execution")
        } catch is CancellationError {
            // Expected.
        }
        let activeAfterShutdown = await executor.activeExecutionCount()
        XCTAssertEqual(activeAfterShutdown, 0)

        do {
            _ = try await executor.executeShellCommand("true")
            XCTFail("Expected script admission to remain closed")
        } catch let error as ScriptExecutionError {
            guard case .admissionClosed = error else {
                return XCTFail("Expected admissionClosed, got \(error)")
            }
        }
    }

    func testAppleScriptTimeoutInterruptsExactChildPromptly() async throws {
        let executor = ScriptExecutor(mutationGate: PhysicalDesktopMutationGate())
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await executor.executeAppleScript("delay 2", timeout: 0.1)
            XCTFail("Expected AppleScript timeout")
        } catch let error as ScriptExecutionError {
            guard case .timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }

        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testShellTimeoutEscalatesAndReapsTermResistantExactChild() async throws {
        let child = ExactChildPIDRecorder()
        let executor = ScriptExecutor(
            mutationGate: PhysicalDesktopMutationGate(),
            processStartHandler: { child.record($0) },
        )

        let clock = ContinuousClock()
        let start = clock.now
        let execution = Task {
            try await executor.executeShellCommand(
                "trap '' TERM; end=$((SECONDS + 2)); while (( SECONDS < end )); do :; done",
                timeout: 0.1,
            )
        }
        let pid = await child.waitUntilRecorded()
        do {
            _ = try await execution.value
            XCTFail("Expected shell timeout")
        } catch let error as ScriptExecutionError {
            guard case .timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }

        let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(processExists(pid), "Timed-out exact child PID \(pid) must be terminated and reaped")
    }

    func testTaskCancellationEscalatesAndReapsExactChild() async throws {
        let child = ExactChildPIDRecorder()
        let executor = ScriptExecutor(
            mutationGate: PhysicalDesktopMutationGate(),
            processStartHandler: { child.record($0) },
        )

        let execution = Task {
            try await executor.executeShellCommand(
                "trap '' TERM; end=$((SECONDS + 2)); while (( SECONDS < end )); do :; done",
                timeout: 5,
            )
        }
        let pid = await child.waitUntilRecorded()
        let clock = ContinuousClock()
        let cancelStart = clock.now
        execution.cancel()

        do {
            _ = try await execution.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(cancelStart.duration(to: clock.now), .seconds(1))
        XCTAssertFalse(processExists(pid), "Cancelled exact child PID \(pid) must be terminated and reaped")
    }
}

private actor ScriptProcessInvocationProbe {
    private var count = 0

    func record() {
        count += 1
    }

    func invocationCount() -> Int {
        count
    }
}

private final class ExactChildPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var continuations: [CheckedContinuation<pid_t, Never>] = []

    func record(_ pid: pid_t) {
        lock.lock()
        guard self.pid == nil else {
            lock.unlock()
            return
        }
        self.pid = pid
        let continuations = continuations
        self.continuations.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: pid)
        }
    }

    func waitUntilRecorded() async -> pid_t {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pid {
                lock.unlock()
                continuation.resume(returning: pid)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor BlockingScriptProcessProbe {
    private var entered = false
    private var cancellationObserved = false
    private var shutdownReturned = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withTaskCancellationHandler {
            entered = true
            let continuations = enteredContinuations
            enteredContinuations.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellationObserved() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func hasEntered() -> Bool {
        entered
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func recordShutdownReturned() {
        shutdownReturned = true
    }

    func didShutdownReturn() -> Bool {
        shutdownReturned
    }

    private func recordCancellationObserved() {
        cancellationObserved = true
        let continuations = cancellationContinuations
        cancellationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private func pollUntilGatePending(
    _ gate: PhysicalDesktopMutationGate,
    expected: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await gate.pendingCount() == expected {
            return
        }
        await Task.yield()
    }
    throw ScriptExecutionError.processError("Script execution did not queue behind the mutation gate")
}

private func processExists(_ pid: pid_t) -> Bool {
    errno = 0
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}
