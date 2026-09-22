import CoreGraphics

/// One immutable physical input plan.
public enum InputAction: Sendable {
    case click(point: CGPoint)
    case doubleClick(point: CGPoint)
    case rightClick(point: CGPoint)
    case clickSequence(
        point: CGPoint,
        button: CGMouseButton,
        clickCount: Int,
        modifiers: CGEventFlags,
    )
    case type(text: String)
    case typeText(text: String, charDelay: Double)
    case press(keyName: String, flags: CGEventFlags = [])
    case pressHold(keyName: String, flags: CGEventFlags = [], duration: Double)
    case pressKeyCode(keyCode: CGKeyCode, flags: CGEventFlags)
    case pressKeyCodeHold(keyCode: CGKeyCode, flags: CGEventFlags, duration: Double)
    case move(to: CGPoint)
    case movePointer(to: CGPoint, duration: Double, modifiers: CGEventFlags)
    case drag(
        from: CGPoint,
        to: CGPoint,
        button: CGMouseButton = .left,
        duration: Double = 0,
    )
    case dragPath(
        points: [CGPoint],
        button: CGMouseButton,
        duration: Double,
        modifiers: CGEventFlags,
    )
    case scroll(
        at: CGPoint?,
        horizontal: Double,
        vertical: Double,
        duration: Double,
        modifiers: CGEventFlags,
    )
    case hover(at: CGPoint, duration: Double)

    /// Whether the exact target application must own focus before delivery.
    public var requiresAppActivation: Bool {
        switch self {
        case .press, .pressHold, .pressKeyCode, .pressKeyCodeHold,
             .type, .typeText, .click, .doubleClick, .rightClick,
             .clickSequence, .scroll:
            true
        case .move, .movePointer, .drag, .dragPath, .hover:
            false
        }
    }

    /// Exact Core Graphics event invocation count for this frozen plan.
    public var expectedPostedEventCount: Int {
        switch self {
        case .click, .rightClick:
            return 2
        case .doubleClick:
            return 4
        case let .clickSequence(_, _, clickCount, _):
            return clickCount * 2
        case let .type(text), let .typeText(text, _):
            let (count, overflow) = text.count.multipliedReportingOverflow(by: 2)
            return overflow ? Int.max : count
        case .press, .pressHold, .pressKeyCode, .pressKeyCodeHold:
            return 2
        case .move:
            return 1
        case let .movePointer(_, duration, _):
            return duration == 0 ? 1 : 20
        case .drag:
            return 3
        case let .dragPath(points, _, _, _):
            return points.count + 1
        case let .scroll(_, horizontal, vertical, duration, _):
            guard duration > 0 else {
                return 1
            }
            let magnitude = max(
                abs(Int64(horizontal.rounded(.toNearestOrAwayFromZero))),
                abs(Int64(vertical.rounded(.toNearestOrAwayFromZero))),
            )
            return Int(min(20, magnitude))
        case .hover:
            return 1
        }
    }
}
