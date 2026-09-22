import Foundation
import GRPCCore

enum CaptureWorkLifecycleState: Sendable {
    case accepting
    case draining
    case drained
}

private struct OwnedCaptureWork: Sendable {
    let cancel: @Sendable () -> Void
    let join: @Sendable () async -> Void
}

private actor CaptureWorkStartGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Owns every screenshot task admitted by one service composition.
///
/// Caller cancellation and service drain cancel the exact underlying task, but
/// neither path declares settlement until cancellation-resistant capture work
/// has actually returned. A cancelled caller can therefore never receive late
/// image output, and shutdown can prove that no ScreenCaptureKit work remains.
actor CaptureWorkOwner {
    private var state = CaptureWorkLifecycleState.accepting
    private var activeWork: [UUID: OwnedCaptureWork] = [:]
    private var shutdownTask: Task<Void, Never>?

    func lifecycleState() -> CaptureWorkLifecycleState {
        state
    }

    func activeCaptureCount() -> Int {
        activeWork.count
    }

    func withCapture<Result: Sendable>(
        cancellation: ServerContext.RPCCancellationHandle? = nil,
        _ operation: @escaping @Sendable () async throws -> Result,
    ) async throws -> Result {
        guard state == .accepting else {
            throw RPCError(code: .unavailable, message: "Screenshot capture admission is closed")
        }
        guard !Task.isCancelled, cancellation?.isCancelled != true else {
            throw captureCancellationRPCError()
        }

        let id = UUID()
        let startGate = CaptureWorkStartGate()
        let task = Task<Result, any Error> {
            await startGate.wait()
            do {
                try Task.checkCancellation()
                let result = try await operation()
                // Drain can cancel this exact child without cancelling the
                // handler awaiting it. Re-check inside the owned task so a
                // resistant producer cannot publish success after ownership
                // was revoked.
                try Task.checkCancellation()
                return result
            } catch {
                // Once ownership is cancelled, producer settlement is always
                // cancellation. A resistant producer's late error must not
                // replace the public cancellation result nondeterministically.
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        let cancellationWatcher = cancellation.map { cancellation in
            Task<Void, Never> {
                do {
                    try await cancellation.cancelled
                    task.cancel()
                } catch {
                    // The owner cancels this watcher after producer settlement.
                }
            }
        }
        let supervisor = Task<Void, Never> {
            _ = try? await task.value
            cancellationWatcher?.cancel()
            if let cancellationWatcher {
                await cancellationWatcher.value
            }
            self.finishCapture(id: id)
        }
        activeWork[id] = OwnedCaptureWork(
            cancel: { task.cancel() },
            join: { await supervisor.value },
        )

        do {
            let result = try await withTaskCancellationHandler {
                await startGate.open()
                if Task.isCancelled || cancellation?.isCancelled == true {
                    task.cancel()
                }
                return try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled, cancellation?.isCancelled != true else {
                throw captureCancellationRPCError()
            }
            await supervisor.value
            return result
        } catch {
            await supervisor.value
            if error is CancellationError || Task.isCancelled || cancellation?.isCancelled == true {
                throw captureCancellationRPCError()
            }
            throw error
        }
    }

    private func finishCapture(id: UUID) {
        activeWork.removeValue(forKey: id)
    }

    func beginDraining() {
        guard state == .accepting else { return }
        state = .draining
        for work in activeWork.values {
            work.cancel()
        }
    }

    func shutdown() async {
        let task: Task<Void, Never>
        if let shutdownTask {
            task = shutdownTask
        } else {
            beginDraining()
            let work = Array(activeWork.values)
            task = Task {
                for item in work {
                    await item.join()
                }
            }
            shutdownTask = task
        }

        await task.value
        activeWork.removeAll(keepingCapacity: false)
        state = .drained
    }
}

private func captureCancellationRPCError() -> RPCError {
    RPCError(code: .cancelled, message: "Screenshot capture cancelled")
}
