import Darwin
import Dispatch
import Foundation

final class ShutdownSignalSource: @unchecked Sendable {
    let stream: AsyncStream<Int32>

    private let continuation: AsyncStream<Int32>.Continuation
    private let sources: [DispatchSourceSignal]

    init(signalNumbers: [Int32] = [SIGINT, SIGTERM]) {
        let streamPair = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        stream = streamPair.stream
        continuation = streamPair.continuation

        var configuredSources: [DispatchSourceSignal] = []
        configuredSources.reserveCapacity(signalNumbers.count)
        for signalNumber in signalNumbers {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated),
            )
            source.setEventHandler { [continuation] in
                continuation.yield(signalNumber)
            }
            source.resume()
            configuredSources.append(source)
        }
        sources = configuredSources
    }

    deinit {
        for source in sources {
            source.cancel()
        }
        continuation.finish()
    }
}

private enum ServerLifecycleEvent: @unchecked Sendable {
    case server(Result<Void, any Error>)
    case signal(Int32?)
}

enum ServerLifecycleError: Error, LocalizedError {
    case signalStreamEnded
    case lifecycleAndCleanup(lifecycle: any Error, cleanup: any Error)

    var errorDescription: String? {
        switch self {
        case .signalStreamEnded:
            "shutdown signal stream ended before the server stopped"
        case let .lifecycleAndCleanup(lifecycle, cleanup):
            "server lifecycle failed: \(lifecycle.localizedDescription); cleanup failed: \(cleanup.localizedDescription)"
        }
    }
}

func waitForServerTermination(
    serverTask: Task<Void, any Error>,
    shutdownSignals: AsyncStream<Int32>,
    beginGracefulShutdown: @escaping @Sendable () async -> Void,
) async throws {
    let result = await withTaskGroup(
        of: ServerLifecycleEvent.self,
        returning: Result<Void, any Error>.self,
    ) { group in
        group.addTask {
            do {
                try await serverTask.value
                return .server(.success(()))
            } catch {
                return .server(.failure(error))
            }
        }
        group.addTask {
            var iterator = shutdownSignals.makeAsyncIterator()
            return await .signal(iterator.next())
        }

        guard let firstEvent = await group.next() else {
            return .failure(ServerLifecycleError.signalStreamEnded)
        }
        switch firstEvent {
        case let .server(serverResult):
            group.cancelAll()
            return serverResult
        case let .signal(signalNumber):
            guard signalNumber != nil else {
                await beginGracefulShutdown()
                group.cancelAll()
                return .failure(ServerLifecycleError.signalStreamEnded)
            }
            await beginGracefulShutdown()
            while let event = await group.next() {
                if case let .server(serverResult) = event {
                    group.cancelAll()
                    return serverResult
                }
            }
            return .failure(ServerLifecycleError.signalStreamEnded)
        }
    }
    try result.get()
}
