import CoreGraphics
import Foundation

/// One non-cleanup physical effect whose target authority must still be exact
/// immediately before the operating-system sink.
public enum InputPhysicalEffect: Equatable, Sendable {
    case keyDown(keyCode: CGKeyCode, flags: CGEventFlags)
    case unicodeKeyDown
    case mouseDown(
        point: CGPoint,
        button: CGMouseButton,
        modifiers: CGEventFlags,
        clickCount: Int64,
    )
    case mouseMove(point: CGPoint, modifiers: CGEventFlags)
    case mouseDrag(
        point: CGPoint,
        button: CGMouseButton,
        modifiers: CGEventFlags,
    )
    case scroll(
        point: CGPoint,
        horizontal: Int32,
        vertical: Int32,
        modifiers: CGEventFlags,
    )
    case cursorWarp(point: CGPoint)
    case cursorDisassociation
}

/// A process route whose frozen generation no longer identifies the process
/// that owns the input transaction. This is permanent for that transaction:
/// cleanup must not retry against a reused PID.
public struct InputProcessRouteRetired: Error, Equatable, Sendable {
    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }
}

/// Frozen target-authority callbacks shared by one complete input execution.
///
/// Effect validation may consult async server-owned state. Process validation
/// is synchronous so it can remain adjacent to observer installation,
/// recovery, and the final Core Graphics sink.
public struct InputExecutionBoundary: Sendable {
    private let effectValidator:
        @Sendable (InputPhysicalEffect) async throws -> Void
    private let processRouteValidator:
        @Sendable (pid_t) throws -> Void

    public init(
        validateEffect:
        @escaping @Sendable (InputPhysicalEffect) async throws -> Void,
        validateProcessRoute:
        @escaping @Sendable (pid_t) throws -> Void,
    ) {
        effectValidator = validateEffect
        processRouteValidator = validateProcessRoute
    }

    public func validateEffect(
        _ effect: InputPhysicalEffect,
    ) async throws {
        try await effectValidator(effect)
    }

    public func validateProcessRoute(_ pid: pid_t) throws {
        try processRouteValidator(pid)
    }

    static let unrestricted = InputExecutionBoundary(
        validateEffect: { _ in },
        validateProcessRoute: { _ in },
    )
}

extension InputEvent {
    var physicalEffect: InputPhysicalEffect? {
        switch self {
        case let .keyDown(keyCode, flags):
            .keyDown(keyCode: keyCode, flags: flags)
        case .unicodeKeyDown:
            .unicodeKeyDown
        case let .mouseDown(point, button, modifiers, clickCount):
            .mouseDown(
                point: point,
                button: button,
                modifiers: modifiers,
                clickCount: clickCount,
            )
        case let .mouseMove(point, modifiers):
            .mouseMove(point: point, modifiers: modifiers)
        case let .mouseDrag(point, button, modifiers):
            .mouseDrag(
                point: point,
                button: button,
                modifiers: modifiers,
            )
        case let .scroll(point?, horizontal, vertical, modifiers):
            .scroll(
                point: point,
                horizontal: horizontal,
                vertical: vertical,
                modifiers: modifiers,
            )
        case .keyUp, .unicodeKeyUp, .mouseUp:
            nil
        case .scroll(nil, _, _, _):
            nil
        }
    }
}
