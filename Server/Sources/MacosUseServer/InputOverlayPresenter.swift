import CoreGraphics
import Foundation
import GRPCCore
import MacosUseSDK

typealias InputOverlayRenderer = @MainActor @Sendable (
    InputOverlayPresentation,
) async throws -> Void

struct InputOverlayReservation: Hashable, Sendable {
    fileprivate let id: UUID
}

enum InputOverlayPresenterLifecycleState: Sendable, Equatable {
    case accepting
    case draining
    case drained
}

enum InputOverlayPlanning {
    private static let circleSize = CGSize(width: 64, height: 64)
    private static let captionSize = CGSize(width: 320, height: 72)

    static func presentation(
        for action: MacosUseSDK.InputAction,
        topology: [DisplayTopologyDisplay],
        requestedDuration: Double,
    ) throws -> InputOverlayPresentation {
        let mainDisplays = topology.filter(\.isMain)
        guard mainDisplays.count == 1, let mainDisplay = mainDisplays.first else {
            throw RPCError(
                code: .unavailable,
                message: "Input overlay requires one exact main display",
            )
        }
        let duration = requestedDuration == 0 ? 0.5 : requestedDuration
        let globalFrame: CGRect
        let content: InputOverlayContent
        switch action {
        case let .click(point),
             let .doubleClick(point),
             let .rightClick(point),
             let .clickSequence(point, _, _, _),
             let .move(to: point),
             let .movePointer(to: point, _, _):
            globalFrame = CGRect(
                x: point.x - circleSize.width / 2,
                y: point.y - circleSize.height / 2,
                width: circleSize.width,
                height: circleSize.height,
            )
            content = .circle
        case .type, .typeText, .press, .pressKeyCode:
            globalFrame = CGRect(
                x: mainDisplay.visibleFrame.midX - captionSize.width / 2,
                y: mainDisplay.visibleFrame.midY - captionSize.height / 2,
                width: captionSize.width,
                height: captionSize.height,
            )
            content = .caption
        case .pressHold, .pressKeyCodeHold, .drag, .dragPath, .scroll, .hover:
            throw RPCError(
                code: .invalidArgument,
                message: "Input action does not support visualization",
            )
        }

        let appKitFrame = CGRect(
            x: globalFrame.minX,
            y: mainDisplay.frame.height - globalFrame.maxY,
            width: globalFrame.width,
            height: globalFrame.height,
        )
        return try InputOverlayPresentation(
            frame: appKitFrame,
            content: content,
            duration: duration,
        ).validated()
    }
}

/// Owns overlay admission, presentation, cancellation, cleanup, and drain for
/// the exact service composition. A reservation is created before physical
/// input and triggered only after a complete physical receipt.
actor InputOverlayPresenter {
    private enum Entry {
        case reserved(InputOverlayPresentation)
        case running(Task<Void, any Error>)
    }

    private let renderer: InputOverlayRenderer
    private var entries: [UUID: Entry] = [:]
    private var state = InputOverlayPresenterLifecycleState.accepting
    private var shutdownTask: Task<Void, Never>?

    init(
        renderer: @escaping InputOverlayRenderer = { presentation in
            try await presentInputOverlay(presentation)
        },
    ) {
        self.renderer = renderer
    }

    func reserve(
        _ requestedPresentation: InputOverlayPresentation,
    ) throws -> InputOverlayReservation {
        guard state == .accepting else {
            throw RPCError(
                code: .unavailable,
                message: "Input overlay admission is closed",
            )
        }
        let presentation = try requestedPresentation.validated()
        let reservation = InputOverlayReservation(id: UUID())
        entries[reservation.id] = .reserved(presentation)
        return reservation
    }

    func present(_ reservation: InputOverlayReservation) async throws {
        guard state == .accepting,
              case let .reserved(presentation)? = entries[reservation.id]
        else {
            throw CancellationError()
        }
        let renderer = renderer
        let task = Task { @MainActor in
            try await renderer(presentation)
        }
        entries[reservation.id] = .running(task)

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            entries.removeValue(forKey: reservation.id)
        } catch {
            task.cancel()
            _ = await task.result
            entries.removeValue(forKey: reservation.id)
            throw error
        }
    }

    func cancelAndJoin(_ reservation: InputOverlayReservation) async {
        guard let entry = entries[reservation.id] else {
            return
        }
        switch entry {
        case .reserved:
            entries.removeValue(forKey: reservation.id)
        case let .running(task):
            task.cancel()
            _ = await task.result
            entries.removeValue(forKey: reservation.id)
        }
    }

    func beginDraining() {
        guard state == .accepting else { return }
        state = .draining
        var reservedIDs: [UUID] = []
        for (id, entry) in entries {
            switch entry {
            case .reserved:
                reservedIDs.append(id)
            case let .running(task):
                task.cancel()
            }
        }
        for id in reservedIDs {
            entries.removeValue(forKey: id)
        }
    }

    func shutdown() async {
        let task: Task<Void, Never>
        if let shutdownTask {
            task = shutdownTask
        } else {
            task = Task { await self.performShutdown() }
            shutdownTask = task
        }
        await task.value
    }

    func activeReservationCount() -> Int {
        entries.count
    }

    func lifecycleState() -> InputOverlayPresenterLifecycleState {
        state
    }

    private func performShutdown() async {
        beginDraining()
        let running = entries.compactMap { id, entry -> (UUID, Task<Void, any Error>)? in
            guard case let .running(task) = entry else { return nil }
            return (id, task)
        }
        for (_, task) in running {
            task.cancel()
        }
        for (id, task) in running {
            _ = await task.result
            entries.removeValue(forKey: id)
        }
        state = .drained
    }
}
