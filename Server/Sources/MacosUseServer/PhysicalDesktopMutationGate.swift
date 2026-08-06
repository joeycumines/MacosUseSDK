import Foundation

enum PhysicalDesktopMutationError: Error, Equatable, LocalizedError {
    case queueFull
    case admissionClosed

    var errorDescription: String? {
        switch self {
        case .queueFull:
            "Physical desktop mutation queue is full"
        case .admissionClosed:
            "Physical desktop mutation admission is closed"
        }
    }
}

enum PhysicalDesktopMutationLifecycle: Equatable, Sendable {
    case accepting
    case draining
    case drained
}

/// Resolves cancellation versus FIFO promotion synchronously. The cancellation
/// handler cannot await actor isolation, so the waiter owns that one-shot race
/// behind a lock instead of launching an unstructured relay task.
final class PhysicalDesktopMutationWaiter: @unchecked Sendable {
    private enum State {
        case awaitingContinuation
        case waiting(CheckedContinuation<Void, any Error>)
        case cancelled
        case promoted
    }

    private let lock = NSLock()
    private var state: State = .awaitingContinuation

    /// Installs the continuation and returns whether the actor should enqueue
    /// this waiter. Cancellation may have won before installation.
    func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        let shouldEnqueue = lock.withLock {
            switch state {
            case .awaitingContinuation:
                state = .waiting(continuation)
                return true
            case .cancelled:
                return false
            case .waiting, .promoted:
                preconditionFailure("physical mutation waiter continuation installed twice")
            }
        }
        if !shouldEnqueue {
            continuation.resume(throwing: CancellationError())
        }
        return shouldEnqueue
    }

    func cancel() {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            switch state {
            case .awaitingContinuation:
                state = .cancelled
                return nil
            case let .waiting(continuation):
                state = .cancelled
                return continuation
            case .cancelled, .promoted:
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// Returns true only when this call won ownership transfer.
    func promote() -> Bool {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard case let .waiting(continuation) = state else {
                return nil
            }
            state = .promoted
            return continuation
        }
        continuation?.resume()
        return continuation != nil
    }

    var isCancelled: Bool {
        lock.withLock {
            if case .cancelled = state {
                return true
            }
            return false
        }
    }
}

/// Serializes complete physical-desktop jobs across actor suspension points.
/// Actor isolation by itself is reentrant at every await and therefore cannot
/// keep a multi-event input sequence atomic.
actor PhysicalDesktopMutationGate {
    private let capacity: Int
    private var isHeld = false
    private var waiters: [PhysicalDesktopMutationWaiter] = []
    private var lifecycle: PhysicalDesktopMutationLifecycle = .accepting
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int = 64) {
        self.capacity = max(0, capacity)
    }

    func withExclusiveOperation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result,
    ) async throws -> Result {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func pendingCount() -> Int {
        pruneCancelledWaiters()
        return waiters.count
    }

    func lifecycleState() -> PhysicalDesktopMutationLifecycle {
        lifecycle
    }

    /// Atomically closes admission. Work admitted before this transition keeps
    /// its FIFO ownership and must settle before the gate becomes drained.
    func beginDraining() {
        guard lifecycle == .accepting else {
            return
        }
        lifecycle = isHeld ? .draining : .drained
        resumeDrainContinuationsIfNeeded()
    }

    /// Closes admission if necessary and returns only after active and
    /// previously queued operations have released the physical desktop.
    func waitUntilDrained() async {
        beginDraining()
        guard lifecycle != .drained else {
            return
        }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard lifecycle == .accepting else {
            throw PhysicalDesktopMutationError.admissionClosed
        }
        if !isHeld {
            isHeld = true
            return
        }
        pruneCancelledWaiters()
        guard waiters.count < capacity else {
            throw PhysicalDesktopMutationError.queueFull
        }

        let waiter = PhysicalDesktopMutationWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if waiter.install(continuation) {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            waiter.cancel()
        }

        do {
            try Task.checkCancellation()
        } catch {
            // Promotion transfers ownership of the held gate to this waiter.
            // If cancellation won immediately afterward, release that ownership
            // before propagating so the next FIFO job cannot deadlock.
            release()
            throw error
        }
    }

    private func release() {
        guard isHeld else {
            return
        }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if next.promote() {
                return
            }
        }
        isHeld = false
        if lifecycle == .draining {
            lifecycle = .drained
            resumeDrainContinuationsIfNeeded()
        }
    }

    private func pruneCancelledWaiters() {
        waiters.removeAll(where: \.isCancelled)
    }

    private func resumeDrainContinuationsIfNeeded() {
        guard lifecycle == .drained, !drainContinuations.isEmpty else {
            return
        }
        let continuations = drainContinuations
        drainContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}
