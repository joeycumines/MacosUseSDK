@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import XCTest

final class ClipboardOwnershipTests: XCTestCase {
    func testWriteUsesInjectedGateThroughObservedReadAndHistoryPublication() async throws {
        let gate = PhysicalDesktopMutationGate()
        let history = ClipboardHistoryManager(sourceApplication: { "Injected source" })
        let pasteboard = BlockingClipboardPasteboard(blockRead: true)
        let manager = ClipboardManager(
            mutationGate: gate,
            historyManager: history,
            pasteboard: pasteboard,
        )
        let competitor = ClipboardGateProbe()
        let content = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("owned clipboard value")
        }

        let write = Task {
            try await manager.writeClipboard(content: content)
        }
        await pasteboard.waitUntilReadEntered()

        let competingMutation = Task {
            try await gate.withExclusiveOperation {
                await competitor.enter()
            }
        }
        try await pollUntilClipboardGatePending(gate, expected: 1)

        let callsWhileReadBlocked = await pasteboard.recordedCalls()
        let competitorEnteredWhileReadBlocked = await competitor.hasEntered()
        XCTAssertEqual(callsWhileReadBlocked, [.clear, .write(.text), .read])
        XCTAssertFalse(competitorEnteredWhileReadBlocked)

        await pasteboard.releaseRead()
        let observed = try await write.value
        try await competingMutation.value

        XCTAssertEqual(observed.content.type, .text)
        guard case let .text(observedText) = observed.content.content else {
            return XCTFail("Expected observed text clipboard content")
        }
        XCTAssertEqual(observedText, "owned clipboard value")
        let historySnapshot = await history.getHistory()
        let entries = historySnapshot.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sourceApplication, "Injected source")
        guard let firstEntry = entries.first,
              case let .text(historyText) = firstEntry.content.content
        else {
            return XCTFail("Expected text clipboard history content")
        }
        XCTAssertEqual(historyText, "owned clipboard value")
    }

    func testDrainedGateRejectsWriteWithoutPasteboardOrHistoryMutation() async throws {
        let gate = PhysicalDesktopMutationGate()
        let history = ClipboardHistoryManager(sourceApplication: { "Injected source" })
        let pasteboard = BlockingClipboardPasteboard(blockRead: false)
        let manager = ClipboardManager(
            mutationGate: gate,
            historyManager: history,
            pasteboard: pasteboard,
        )
        let content = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("must not be written")
        }
        await gate.beginDraining()

        do {
            _ = try await manager.writeClipboard(content: content)
            XCTFail("Expected closed physical mutation admission")
        } catch let error as PhysicalDesktopMutationError {
            XCTAssertEqual(error, .admissionClosed)
        }

        let calls = await pasteboard.recordedCalls()
        let historySnapshot = await history.getHistory()
        let entries = historySnapshot.entries
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(entries.isEmpty)
    }

    func testClearUsesInjectedGateAndReturnsObservedEmptyClipboard() async throws {
        let gate = PhysicalDesktopMutationGate()
        let history = ClipboardHistoryManager(sourceApplication: { "Injected source" })
        let pasteboard = BlockingClipboardPasteboard(
            blockRead: false,
            initialText: "existing value",
        )
        let manager = ClipboardManager(
            mutationGate: gate,
            historyManager: history,
            pasteboard: pasteboard,
        )

        let observed = try await manager.clearClipboard()
        let calls = await pasteboard.recordedCalls()
        let historySnapshot = await history.getHistory()

        XCTAssertTrue(observed.availableTypes.isEmpty)
        XCTAssertEqual(calls, [.clear, .read])
        XCTAssertTrue(historySnapshot.entries.isEmpty)
    }
}

private actor BlockingClipboardPasteboard: ClipboardPasteboard {
    enum Call: Equatable {
        case clear
        case write(Exactmac_V1_ContentType)
        case read
    }

    private var calls: [Call] = []
    private var changeCountValue = 0
    private var snapshot: Exactmac_V1_Clipboard
    private var blockRead: Bool
    private var readEntered = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var readEnteredContinuations: [CheckedContinuation<Void, Never>] = []

    init(blockRead: Bool, initialText: String? = nil) {
        self.blockRead = blockRead
        snapshot = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            if let initialText {
                $0.content = Exactmac_V1_ClipboardContent.with {
                    $0.type = .text
                    $0.content = .text(initialText)
                }
                $0.availableTypes = [.text]
            }
        }
    }

    func read() async -> Exactmac_V1_Clipboard {
        calls.append(.read)
        if blockRead {
            readEntered = true
            let continuations = readEnteredContinuations
            readEnteredContinuations.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
            await withCheckedContinuation { continuation in
                readContinuation = continuation
            }
        }
        return snapshot
    }

    func changeCount() -> Int {
        changeCountValue
    }

    func clear() async {
        calls.append(.clear)
        changeCountValue += 1
        snapshot = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
        }
    }

    func write(_ content: Exactmac_V1_ClipboardContent) async -> Bool {
        calls.append(.write(content.type))
        snapshot = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            $0.content = content
            $0.availableTypes = [content.type]
        }
        return true
    }

    func waitUntilReadEntered() async {
        guard !readEntered else { return }
        await withCheckedContinuation { continuation in
            readEnteredContinuations.append(continuation)
        }
    }

    func releaseRead() {
        blockRead = false
        readContinuation?.resume()
        readContinuation = nil
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private actor ClipboardGateProbe {
    private var entered = false

    func enter() {
        entered = true
    }

    func hasEntered() -> Bool {
        entered
    }
}

private func pollUntilClipboardGatePending(
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
    throw ClipboardError.writeFailed("Clipboard mutation did not hold the physical gate")
}
