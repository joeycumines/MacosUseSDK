import AppKit
import Foundation
import OSLog
import QuartzCore

private let inputOverlayLogger = sdkLogger(category: "InputOverlayRenderer")

/// Non-content-bearing visual feedback for one physically delivered input.
public enum InputOverlayContent: Sendable, Equatable {
    case circle
    case caption
}

/// One immutable AppKit-space overlay presentation.
public struct InputOverlayPresentation: Sendable, Equatable {
    public let frame: CGRect
    public let content: InputOverlayContent
    public let duration: TimeInterval

    public init(
        frame: CGRect,
        content: InputOverlayContent,
        duration: TimeInterval,
    ) {
        self.frame = frame
        self.content = content
        self.duration = duration
    }

    @discardableResult
    public func validated() throws -> InputOverlayPresentation {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0,
              frame.maxX.isFinite,
              frame.maxY.isFinite
        else {
            throw MacosUseSDKError.inputInvalidArgument(
                "input overlay frame must be finite and have positive size",
            )
        }
        guard duration.isFinite, duration > 0, duration <= 3600 else {
            throw MacosUseSDKError.inputInvalidArgument(
                "input overlay duration must be finite and between 0 and 3600 seconds",
            )
        }
        return self
    }
}

@MainActor
private final class InputOverlayView: NSView {
    private let content: InputOverlayContent

    init(frame: CGRect, content: InputOverlayContent) {
        self.content = content
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch content {
        case .circle:
            drawCircle()
        case .caption:
            drawCaption()
        }
    }

    private func drawCircle() {
        NSColor.systemGreen.setFill()
        let radius = min(15, bounds.width / 2, bounds.height / 2)
        guard radius > 0 else { return }
        NSBezierPath(
            ovalIn: CGRect(
                x: bounds.midX - radius,
                y: bounds.midY - radius,
                width: radius * 2,
                height: radius * 2,
            ),
        ).fill()
    }

    private func drawCaption() {
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 8,
            yRadius: 8,
        ).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let text = "Input delivered"
        let available = bounds.insetBy(dx: 12, dy: 12)
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
            in: CGRect(
                x: available.minX,
                y: available.midY - height / 2,
                width: available.width,
                height: height,
            ),
            withAttributes: attributes,
        )
    }
}

/// Presents one overlay, propagating presentation, cancellation, and wait
/// failures only after the exact window and animation cleanup has completed.
@MainActor
public func presentInputOverlay(
    _ requestedPresentation: InputOverlayPresentation,
) async throws {
    let presentation = try requestedPresentation.validated()
    try Task.checkCancellation()

    let window = NSWindow(
        contentRect: presentation.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false,
    )
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.isMovableByWindowBackground = false
    window.ignoresMouseEvents = true

    let view = InputOverlayView(
        frame: CGRect(origin: .zero, size: presentation.frame.size),
        content: presentation.content,
    )
    view.wantsLayer = true
    window.contentView = view
    window.orderFront(nil)
    guard window.isVisible else {
        window.close()
        throw MacosUseSDKError.inputSimulationFailed(
            "input overlay window could not be presented",
        )
    }
    applyInputOverlayAnimation(
        to: view,
        content: presentation.content,
        duration: presentation.duration,
    )

    inputOverlayLogger.debug(
        "Presented input overlay for \(presentation.duration, privacy: .public) seconds",
    )
    try await runInputOverlayLifetime(duration: presentation.duration) {
        view.layer?.removeAllAnimations()
        window.orderOut(nil)
        window.close()
    }
}

/// Runs the cancellable portion of an overlay session and always completes
/// caller-provided cleanup before success or failure is returned.
@MainActor
func runInputOverlayLifetime(
    duration: TimeInterval,
    cleanup: () -> Void,
) async throws {
    defer { cleanup() }
    guard duration.isFinite, duration > 0, duration <= 3600 else {
        throw MacosUseSDKError.inputInvalidArgument(
            "input overlay duration must be finite and between 0 and 3600 seconds",
        )
    }
    try Task.checkCancellation()
    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    try Task.checkCancellation()
}

@MainActor
private func applyInputOverlayAnimation(
    to view: NSView,
    content: InputOverlayContent,
    duration: TimeInterval,
) {
    guard let layer = view.layer else { return }
    layer.removeAllAnimations()

    let scale = CABasicAnimation(keyPath: "transform.scale")
    let opacity = CABasicAnimation(keyPath: "opacity")
    switch content {
    case .circle:
        scale.fromValue = 0.7
        scale.toValue = 1.8
        opacity.fromValue = 0.8
        opacity.toValue = 0
    case .caption:
        scale.fromValue = 0.9
        scale.toValue = 1
        opacity.fromValue = 1
        opacity.toValue = 0
    }
    scale.duration = duration
    opacity.duration = duration

    let group = CAAnimationGroup()
    group.animations = [scale, opacity]
    group.duration = duration
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    layer.add(group, forKey: "inputOverlay")
}
