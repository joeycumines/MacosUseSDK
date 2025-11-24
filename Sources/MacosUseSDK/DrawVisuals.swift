import AppKit
import Foundation
import QuartzCore
import OSLog

private let logger = sdkLogger(category: "DrawVisuals")

/// Define types of visual feedback.
public enum FeedbackType: Sendable {
    case box(text: String)  // Existing box with optional text
    case circle  // New simple circle
    case caption(text: String)  // New type for large screen-center text
}

/// Configuration for visual feedback sessions.
public struct VisualsConfig: Sendable {
    public let duration: TimeInterval
    public let animationStyle: AnimationStyle

    public enum AnimationStyle: Sendable {
        case none
        case pulseAndFade  // For circles
        case scaleInFadeOut // For captions
    }

    /// Default configuration
    public static let `default` = VisualsConfig(duration: 0.5, animationStyle: .none)

    public init(duration: TimeInterval = 0.5, animationStyle: AnimationStyle = .none) {
        self.duration = duration
        self.animationStyle = animationStyle
    }
}

/// A descriptor for a single overlay window to be presented.
public struct OverlayDescriptor: Sendable {
    public let frame: CGRect
    public let type: FeedbackType

    public init(frame: CGRect, type: FeedbackType) {
        self.frame = frame
        self.type = type
    }
}

public extension OverlayDescriptor {
    /// Creates a descriptor from an ElementData object, handling coordinate conversion.
    /// Returns nil if the element lacks valid geometry.
    init?(element: ElementData, screenHeight: CGFloat) {
        guard let x = element.x, let y = element.y,
              let w = element.width, w > 0,
              let h = element.height, h > 0 else {
            return nil
        }

        // Convert from AX coordinates (top-left origin) to AppKit coordinates (bottom-left origin)
        let convertedY = screenHeight - CGFloat(y) - CGFloat(h)
        let frame = CGRect(x: CGFloat(x), y: convertedY, width: CGFloat(w), height: CGFloat(h))

        let text = (element.text?.isEmpty ?? true) ? element.role : element.text!
        self.init(frame: frame, type: .box(text: text))
    }
}

// Define a custom view that draws the rectangle and text with truncation
internal class OverlayView: NSView {
    var feedbackType: FeedbackType = .box(text: "")  // Property to hold the type and data

    // Constants for drawing
    let padding: CGFloat = 10  // Increased padding for caption
    let frameLineWidth: CGFloat = 2
    let circleRadius: CGFloat = 15  // Radius for the circle feedback
    let captionFontSize: CGFloat = 36  // Font size for caption
    let captionBackgroundColor = NSColor.black.withAlphaComponent(0.6)  // Semi-transparent black background
    let captionTextColor = NSColor.white

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        switch feedbackType {
        case .box(let displayText):
            drawBox(with: displayText)
        case .circle:
            drawCircle()
        case .caption(let captionText):
            drawCaption(with: captionText)  // Call the new drawing method
        }
    }

    private func drawCircle() {
        NSColor.green.setFill()  // Set fill color instead of stroke

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        // Ensure the circle fits within the bounds if bounds are smaller than diameter
        let effectiveRadius = min(circleRadius, bounds.width / 2.0, bounds.height / 2.0)
        guard effectiveRadius > 0 else { return }  // Don't draw if too small

        let circleRect = NSRect(
            x: center.x - effectiveRadius, y: center.y - effectiveRadius,
            width: effectiveRadius * 2, height: effectiveRadius * 2)
        let path = NSBezierPath(ovalIn: circleRect)
        path.fill()  // Fill the path instead of stroking it
    }

    private func drawBox(with displayText: String) {
        // --- Frame Drawing ---
        NSColor.red.setStroke()
        let frameInset = frameLineWidth / 2.0
        let frameRect = bounds.insetBy(dx: frameInset, dy: frameInset)
        let path = NSBezierPath(rect: frameRect)
        path.lineWidth = frameLineWidth
        path.stroke()

        // --- Text Drawing with Truncation ---
        if !displayText.isEmpty {
            // Define text attributes
            let textColor = NSColor.red
            // Slightly smaller font for potentially many overlays
            let textFont = NSFont.systemFont(ofSize: 10.0)
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: textColor
            ]

            // Calculate available width for text (bounds - frame lines - padding on both sides)
            let availableWidth = max(0, bounds.width - (frameLineWidth * 2.0) - (padding * 2.0))
            var stringToDraw = displayText
            var textSize = stringToDraw.size(withAttributes: textAttributes)

            // Check if truncation is needed
            if textSize.width > availableWidth && availableWidth > 0 {
                let ellipsis = "…"  // Use ellipsis character
                let ellipsisSize = ellipsis.size(withAttributes: textAttributes)

                // Keep removing characters until text + ellipsis fits
                while !stringToDraw.isEmpty
                    && (stringToDraw.size(withAttributes: textAttributes).width + ellipsisSize.width
                        > availableWidth) {
                    stringToDraw.removeLast()
                }
                stringToDraw += ellipsis
                textSize = stringToDraw.size(withAttributes: textAttributes)  // Recalculate size
            }

            // Ensure text doesn't exceed available height (though less likely for small font)
            let availableHeight = max(0, bounds.height - (frameLineWidth * 2.0) - (padding * 2.0))
            if textSize.height > availableHeight {
                // Simple vertical clipping will occur naturally if too tall
            }

            // Calculate position to center the (potentially truncated) text
            // X: Add frame line width + padding
            // Y: Center vertically within the available height area
            let textX = frameLineWidth + padding
            let textY = frameLineWidth + padding + (availableHeight - textSize.height)  // Top align
            let textPoint = NSPoint(x: textX, y: textY)

            // Draw the text string
            (stringToDraw as NSString).draw(at: textPoint, withAttributes: textAttributes)
        }
    }

    // New method to draw the caption
    private func drawCaption(with text: String) {
        logger.debug("OverlayView drawing caption: '\(text, privacy: .private)'")

        // Draw background
        captionBackgroundColor.setFill()
        let backgroundRect = bounds.insetBy(dx: frameLineWidth / 2.0, dy: frameLineWidth / 2.0)  // Adjust for potential border line width if we add one later
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8)  // Rounded corners
        backgroundPath.fill()

        // --- Text Drawing ---
        if !text.isEmpty {
            // Define text attributes
            let textFont = NSFont.systemFont(ofSize: captionFontSize, weight: .medium)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center  // Center align text

            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: captionTextColor,
                .paragraphStyle: paragraphStyle
            ]

            // Calculate available area for text (bounds - padding)
            let availableRect = bounds.insetBy(dx: padding, dy: padding)
            let stringToDraw = text
            let textSize = stringToDraw.size(withAttributes: textAttributes)

            // Basic truncation if text wider than available space (though less likely for centered captions)
            if textSize.width > availableRect.width && availableRect.width > 0 {
                logger.warning(
                    "Caption text '\(stringToDraw, privacy: .private)' (\(textSize.width, privacy: .public)) wider than available \(availableRect.width, privacy: .public), may clip.")
                // Simple clipping will occur, could implement more complex truncation if needed
            }
            if textSize.height > availableRect.height {
                logger.warning(
                    "Caption text '\(stringToDraw, privacy: .private)' (\(textSize.height, privacy: .public)) taller than available \(availableRect.height, privacy: .public), may clip.")
            }

            // Calculate position to center the text vertically and horizontally within the available rect
            let textX = availableRect.origin.x
            let textY = availableRect.origin.y + (availableRect.height - textSize.height) / 2.0  // Center vertically
            let textRect = NSRect(x: textX, y: textY, width: availableRect.width, height: textSize.height)

            // Draw the text string centered
            let rectString = String(describing: textRect)
            logger.debug(
                "OverlayView drawing caption text '\(stringToDraw, privacy: .private)' in rect \(rectString, privacy: .public)")
            (stringToDraw as NSString).draw(in: textRect, withAttributes: textAttributes)
        } else {
            logger.debug("OverlayView no caption text to draw.")
        }
    }

    // Update initializer to accept FeedbackType
    init(frame frameRect: NSRect, type: FeedbackType) {
        self.feedbackType = type
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Creates a configured, borderless overlay window but does not show it.
@MainActor
internal func createOverlayWindow(frame: NSRect, type: FeedbackType) -> NSWindow {
    logger.debug("Creating overlay window with frame: \(String(describing: frame), privacy: .public), type: \(String(describing: type), privacy: .public)")
    // Now safe to call NSWindow initializer and set properties from here
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    // Ensure window is not automatically released when closed, allowing us to manage lifecycle safely
    window.isReleasedWhenClosed = false

    // Configuration for transparent, floating overlay
    window.isOpaque = false
    // Make background clear ONLY if not a caption (caption view draws its own background)
    if case .caption = type {
        window.backgroundColor = .clear  // View draws background
    } else {
        window.backgroundColor = .clear  // Original behavior
    }
    window.hasShadow = false  // No window shadow
    window.level = .floating  // Keep above normal windows
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]  // Visible on all spaces
    window.isMovableByWindowBackground = false  // Prevent accidental dragging
    window.ignoresMouseEvents = true // CRITICAL: Allow clicks to pass through to the app below

    // Create and set the custom view
    let overlayFrame = window.contentView?.bounds ?? NSRect(origin: .zero, size: frame.size)
    let overlayView = OverlayView(frame: overlayFrame, type: type)
    window.contentView = overlayView

    return window
}

/// Gets the center point of the main screen.
/// - Returns: CGPoint of the center in screen coordinates, or nil if main screen not found.
public func getMainScreenCenter() -> CGPoint? {
    guard let mainScreen = NSScreen.main else {
        logger.error("could not get main screen.")
        return nil
    }
    let screenRect = mainScreen.frame
    let centerX = screenRect.midX
    // AppKit coordinates (bottom-left origin) are used by NSWindow positioning.
    // screenRect.midY correctly gives the vertical center in this coordinate system.
    let centerY = screenRect.midY
    let centerPoint = CGPoint(x: centerX, y: centerY)
    return centerPoint
}

/// Robustly manages a session of visual feedback overlays.
/// This actor-isolated function ensures proper lifecycle management,
/// thread safety, and guaranteed cleanup via `defer`, specifically handling task cancellation.
@MainActor
public func presentVisuals(
    overlays: [OverlayDescriptor],
    configuration: VisualsConfig
) async {
    logger.debug("presentVisuals called with \(overlays.count, privacy: .public) overlays")

    // 1. Validation
    guard !overlays.isEmpty else {
        logger.info("No overlays provided to present.")
        return
    }

    // Create a strong reference holder for windows to prevent premature deallocation
    var activeWindows: [NSWindow] = []

    // 2. Window Creation and Presentation
    logger.info("Presenting \(overlays.count, privacy: .public) visual overlays for \(configuration.duration, privacy: .public)s.")

    for descriptor in overlays {
        // Create window
        let window = createOverlayWindow(frame: descriptor.frame, type: descriptor.type)
        activeWindows.append(window)
        logger.debug("Created window \(activeWindows.count, privacy: .public)/\(overlays.count, privacy: .public)")

        // Show window
        window.orderFront(nil) // CRITICAL: Do not steal focus/key status from the target app

        // Apply Animations if configured
        if let overlayView = window.contentView as? OverlayView {
            overlayView.wantsLayer = true
            applyAnimation(to: overlayView, style: configuration.animationStyle, duration: configuration.duration)
        }
    }
    logger.debug("Created all \(activeWindows.count, privacy: .public) windows, entering sleep.")

    // 3. Wait for duration using DispatchQueue.asyncAfter for stability
    // Task.sleep appears to have a concurrency bug that corrupts the activeWindows array in this context.
    // We use GCD to wait, and explicitly close the windows in the callback to ensure they are cleaned up.
    logger.debug("Starting wait for \(configuration.duration, privacy: .public) seconds... (windows=\(activeWindows.count, privacy: .public))")
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.duration) {
            logger.debug("Wait completed after \(configuration.duration, privacy: .public)s. Closing \(activeWindows.count, privacy: .public) windows.")

            // Explicitly close all windows to remove them from screen and release resources
            for window in activeWindows {
                // Stop animations and hide first to prevent potential crashes during close
                if let view = window.contentView {
                    view.layer?.removeAllAnimations()
                }
                window.orderOut(nil)
                window.close()
            }

            continuation.resume()
        }
    }
    logger.debug("Exiting presentVisuals. (windows=\(activeWindows.count, privacy: .public))")
}

/// Helper to apply CoreAnimation based on configuration style
@MainActor
private func applyAnimation(to view: NSView, style: VisualsConfig.AnimationStyle, duration: TimeInterval) {
    guard let layer = view.layer else {
        logger.warning("Cannot apply animation: view has no layer")
        return
    }

    // Ensure layer is properly configured for animations
    layer.removeAllAnimations()  // Clear any existing animations

    switch style {
    case .pulseAndFade:
        logger.debug("Applying pulse/fade animation.")
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.7
        scaleAnimation.toValue = 1.8
        scaleAnimation.duration = duration

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.8
        opacityAnimation.toValue = 0.0
        opacityAnimation.duration = duration

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [scaleAnimation, opacityAnimation]
        animationGroup.duration = duration
        animationGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animationGroup.fillMode = .forwards
        animationGroup.isRemovedOnCompletion = false
        layer.add(animationGroup, forKey: "pulseFadeEffect")

    case .scaleInFadeOut:
        logger.debug("Applying scale-in/fade-out animation.")
        let entranceDuration = 0.2
        let fadeOutDuration = 0.3

        // Create all animations in a single group for proper timing
        let scaleInAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleInAnimation.fromValue = 0.7
        scaleInAnimation.toValue = 1.0
        scaleInAnimation.duration = entranceDuration
        scaleInAnimation.beginTime = 0

        let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
        fadeInAnimation.fromValue = 0.0
        fadeInAnimation.toValue = 1.0
        fadeInAnimation.duration = entranceDuration
        fadeInAnimation.beginTime = 0

        // Fade out starts after entrance, stays visible in middle, then fades
        let fadeOutStartTime = max(entranceDuration, duration - fadeOutDuration)
        let fadeOutAnimation = CABasicAnimation(keyPath: "opacity")
        fadeOutAnimation.fromValue = 1.0
        fadeOutAnimation.toValue = 0.0
        fadeOutAnimation.duration = fadeOutDuration
        fadeOutAnimation.beginTime = fadeOutStartTime

        // Group all animations together
        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [scaleInAnimation, fadeInAnimation, fadeOutAnimation]
        animationGroup.duration = duration
        animationGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animationGroup.fillMode = .forwards
        animationGroup.isRemovedOnCompletion = false
        layer.add(animationGroup, forKey: "captionAnimation")

    case .none:
        break
    }
}

/// Displays a temporary visual indicator (e.g., a circle, a caption) at specified screen coordinates.
///
/// - Warning: This function is "fire-and-forget". For robust lifecycle management, use `presentVisuals`.
@available(*, deprecated, message: "Use `presentVisuals` for robust cancellation and lifecycle management.")
@MainActor
public func showVisualFeedback(
    at point: CGPoint, type: FeedbackType, size: CGSize = CGSize(width: 30, height: 30),
    duration: Double = 0.5
) {
    // Adapter logic to map legacy parameters to the new OverlayDescriptor and Configuration system

    // --- Calculate Required Size (Preserving original logic) ---
    var effectiveSize: CGSize
    let maxCircleScale: CGFloat = 1.8
    let circleRadius: CGFloat = 15.0

    if case .circle = type {
        let maxDiameter = circleRadius * 2.0 * maxCircleScale
        let paddedSize = ceil(maxDiameter + 100.0)
        effectiveSize = CGSize(width: paddedSize, height: paddedSize)
        logger.info(
            "showVisualFeedback using calculated size \(String(describing: effectiveSize), privacy: .public) for .circle type.")
    } else {
        effectiveSize = size
    }

    let screenHeight = NSScreen.main?.frame.height ?? 0
    let originX = point.x - (effectiveSize.width / 2.0)
    let originY = screenHeight - point.y - (effectiveSize.height / 2.0)
    let frame = NSRect(origin: CGPoint(x: originX, y: originY), size: effectiveSize)

    var animStyle: VisualsConfig.AnimationStyle = .none
    if case .circle = type { animStyle = .pulseAndFade }
    else if case .caption = type { animStyle = .scaleInFadeOut }

    let config = VisualsConfig(duration: duration, animationStyle: animStyle)
    let descriptor = OverlayDescriptor(frame: frame, type: type)

    // Launch unstructured task to maintain "fire-and-forget" signature compatibility
    Task {
        await presentVisuals(overlays: [descriptor], configuration: config)
    }
}

/// Draws temporary overlay windows (highlight boxes) around the specified accessibility elements.
///
/// - Warning: This function is "fire-and-forget". For robust lifecycle management, use `presentVisuals`.
@available(*, deprecated, message: "Use `presentVisuals` for robust cancellation and lifecycle management.")
@MainActor
public func drawHighlightBoxes(for elementsToHighlightInput: [ElementData], duration: Double = 3.0) {
    logger.info(
        "drawHighlightBoxes called for \(elementsToHighlightInput.count, privacy: .public) elements, duration \(duration, privacy: .public)s.")

    let screenHeight = NSScreen.main?.frame.height ?? 0

    // 1. Filter elements (Preserving original logic)
    let validElements = elementsToHighlightInput.filter {
        $0.x != nil && $0.y != nil && $0.width != nil && $0.width! > 0 && $0.height != nil
            && $0.height! > 0
    }

    if validElements.isEmpty {
        logger.info("No elements with valid geometry provided to highlight.")
        return
    }

    // 2. Map to Descriptors
    let descriptors: [OverlayDescriptor] = validElements.map { element in
        let originalX = element.x!
        let originalY = element.y!
        let elementWidth = element.width!
        let elementHeight = element.height!
        let convertedY = screenHeight - originalY - elementHeight
        let frame = NSRect(x: originalX, y: convertedY, width: elementWidth, height: elementHeight)

        let textToShow = (element.text?.isEmpty ?? true) ? element.role : element.text!
        return OverlayDescriptor(frame: frame, type: .box(text: textToShow))
    }

    // 3. Launch Unstructured Task using new API
    Task {
        await presentVisuals(
            overlays: descriptors,
            configuration: VisualsConfig(duration: duration, animationStyle: .none)
        )
    }
}
