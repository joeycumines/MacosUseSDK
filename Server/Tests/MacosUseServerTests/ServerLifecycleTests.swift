import Darwin
import Foundation
@testable import MacosUseServer
import Testing

@Suite(.serialized)
struct ServerLifecycleTests {
    @Test
    func `shutdown signal begins drain and waits for server completion`() async throws {
        let serverRelease = AsyncStream.makeStream(of: Void.self)
        let shutdownStarted = AsyncStream.makeStream(of: Void.self)
        let cleanupRelease = AsyncStream.makeStream(of: Void.self)
        let signals = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        let recorder = LifecycleShutdownRecorder()
        let mutationGate = PhysicalDesktopMutationGate()
        let serverTask = Task<Void, any Error> {
            var iterator = serverRelease.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let lifecycleTask = Task {
            try await waitForServerTermination(
                serverTask: serverTask,
                shutdownSignals: signals.stream,
                beginGracefulShutdown: {
                    await mutationGate.beginDraining()
                    recorder.record()
                    shutdownStarted.continuation.yield(())
                    shutdownStarted.continuation.finish()
                    var iterator = cleanupRelease.stream.makeAsyncIterator()
                    _ = await iterator.next()
                },
            )
        }

        signals.continuation.yield(SIGTERM)
        var shutdownIterator = shutdownStarted.stream.makeAsyncIterator()
        _ = await shutdownIterator.next()

        #expect(recorder.snapshot() == 1)
        #expect(await mutationGate.lifecycleState() == .drained)

        serverRelease.continuation.yield(())
        serverRelease.continuation.finish()
        cleanupRelease.continuation.yield(())
        cleanupRelease.continuation.finish()
        try await lifecycleTask.value

        do {
            try await mutationGate.withExclusiveOperation {}
            Issue.record("Expected shutdown to close physical mutation admission")
        } catch let error as PhysicalDesktopMutationError {
            #expect(error == .admissionClosed)
        }
        signals.continuation.finish()
    }

    @Test
    func `serve failure propagates without pretending graceful shutdown`() async throws {
        let signals = AsyncStream.makeStream(of: Int32.self)
        let recorder = LifecycleShutdownRecorder()
        let serverTask = Task<Void, any Error> {
            throw InjectedServerLifecycleError.serveFailure
        }

        do {
            try await waitForServerTermination(
                serverTask: serverTask,
                shutdownSignals: signals.stream,
                beginGracefulShutdown: { recorder.record() },
            )
            Issue.record("Expected serve failure")
        } catch InjectedServerLifecycleError.serveFailure {
            // Expected exact production status propagation.
        }

        #expect(recorder.snapshot() == 0)
        signals.continuation.finish()
    }

    @Test
    @MainActor
    func `preexisting Unix path is rejected without mutation`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("server.sock")
        let marker = Data("preserve-me".utf8)
        try marker.write(to: path)

        let owner = UnixSocketPathOwner(path: path.path)
        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
        #expect(try Data(contentsOf: path) == marker)
    }

    @Test
    @MainActor
    func `overlong Unix path is rejected before bind`() {
        let owner = UnixSocketPathOwner(path: "/tmp/" + String(repeating: "x", count: 200))

        #expect(throws: UnixSocketPathError.self) {
            try owner.prepareForBind()
        }
    }
}

private enum InjectedServerLifecycleError: Error {
    case serveFailure
}

private final class LifecycleShutdownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
