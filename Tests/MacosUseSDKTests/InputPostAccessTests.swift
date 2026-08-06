import CoreGraphics
@testable import MacosUseSDK
import XCTest

final class InputPostAccessTests: XCTestCase {
    func testEverySemanticActionChecksPostAccessBeforePreparingEvents() async throws {
        let actions: [(String, InputAction)] = [
            ("click", .click(point: CGPoint(x: 1, y: 2))),
            ("double click", .doubleClick(point: CGPoint(x: 1, y: 2))),
            ("right click", .rightClick(point: CGPoint(x: 1, y: 2))),
            (
                "click sequence",
                .clickSequence(
                    point: CGPoint(x: 1, y: 2),
                    button: .center,
                    clickCount: 3,
                    modifiers: .maskCommand,
                ),
            ),
            ("type", .type(text: "a")),
            ("type text", .typeText(text: "a", charDelay: 0.1)),
            ("press", .press(keyName: "return", flags: .maskShift)),
            ("press hold", .pressHold(keyName: "return", flags: [], duration: 0.1)),
            ("move", .move(to: CGPoint(x: 3, y: 4))),
            (
                "move pointer",
                .movePointer(
                    to: CGPoint(x: 3, y: 4),
                    duration: 0.1,
                    modifiers: .maskControl,
                ),
            ),
            (
                "drag",
                .drag(
                    from: CGPoint(x: 1, y: 2),
                    to: CGPoint(x: 3, y: 4),
                    button: .left,
                    duration: 0.1,
                ),
            ),
            (
                "drag path",
                .dragPath(
                    points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
                    button: .right,
                    duration: 0.1,
                    modifiers: .maskAlternate,
                ),
            ),
            (
                "scroll",
                .scroll(
                    at: CGPoint(x: 1, y: 2),
                    horizontal: 1,
                    vertical: -1,
                    duration: 0.1,
                    modifiers: .maskShift,
                ),
            ),
            ("hover", .hover(at: CGPoint(x: 3, y: 4), duration: 0.1)),
        ]

        for (label, action) in actions {
            let backend = DeniedInputEventBackend()
            do {
                try await executeInputAction(action, backend: backend)
                XCTFail("Expected post-access denial for \(label)")
            } catch is InjectedPostAccessError {
                // Expected.
            }
            let snapshot = backend.snapshot()
            XCTAssertEqual(snapshot.accessChecks, 1, label)
            XCTAssertEqual(snapshot.prepareCalls, 0, label)
            XCTAssertEqual(snapshot.pauseCalls, 0, label)
            XCTAssertEqual(snapshot.cursorReads, 0, label)
            XCTAssertEqual(snapshot.cursorWarps, 0, label)
            XCTAssertEqual(snapshot.associationChanges, 0, label)
        }
    }
}

private final class DeniedInputEventBackend: InputEventBackend, @unchecked Sendable {
    struct Snapshot {
        let accessChecks: Int
        let prepareCalls: Int
        let pauseCalls: Int
        let cursorReads: Int
        let cursorWarps: Int
        let associationChanges: Int
    }

    private struct State {
        var accessChecks = 0
        var prepareCalls = 0
        var pauseCalls = 0
        var cursorReads = 0
        var cursorWarps = 0
        var associationChanges = 0
    }

    private let lock = NSLock()
    private var state = State()

    func checkPostAccess() throws {
        lock.withLock { state.accessChecks += 1 }
        throw InjectedPostAccessError.denied
    }

    func prepare(_ event: InputEvent) throws -> PreparedInputEvent {
        lock.withLock { state.prepareCalls += 1 }
        return try PreparedInputEvent(event: event) {}
    }

    func pause(nanoseconds _: UInt64) async throws {
        lock.withLock { state.pauseCalls += 1 }
    }

    func monotonicTimeNanoseconds() -> UInt64 {
        0
    }

    func cursorPosition() throws -> CGPoint {
        lock.withLock { state.cursorReads += 1 }
        return .zero
    }

    func warpCursor(x _: Double, y _: Double) async throws {
        lock.withLock { state.cursorWarps += 1 }
    }

    func setCursorAssociated(_: Bool) async throws {
        lock.withLock { state.associationChanges += 1 }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                accessChecks: state.accessChecks,
                prepareCalls: state.prepareCalls,
                pauseCalls: state.pauseCalls,
                cursorReads: state.cursorReads,
                cursorWarps: state.cursorWarps,
                associationChanges: state.associationChanges,
            )
        }
    }
}

private enum InjectedPostAccessError: Error {
    case denied
}
