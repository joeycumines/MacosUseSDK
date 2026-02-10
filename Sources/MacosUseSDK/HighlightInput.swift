import AppKit // For DispatchQueue
import CoreGraphics
import Foundation
import OSLog

private let logger = sdkLogger(category: "HighlightInput")

// --- Public Functions Combining Input Simulation and Visualization ---

/// Simulates a left mouse click at the specified coordinates and shows visual feedback.
/// - Parameters:
///   - point: The `CGPoint` where the click should occur.
///   - duration: How long the visual feedback should last (in seconds). Default is 0.5s.
/// - Throws: `MacosUseSDKError` if simulation or visualization fails.
public func clickMouseAndVisualize(at point: CGPoint, duration: Double = 0.5) async throws {
    logger.info(
        "simulating left click AND visualize at: (\(point.x, privacy: .public), \(point.y, privacy: .public)), duration: \(duration, privacy: .public)s",
    )
    // Call the original input function
    try await clickMouse(at: point)

    // Restore the correct async dispatch:
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)
        let config = VisualsConfig(duration: duration, animationStyle: .pulseAndFade)
        await presentVisuals(overlays: [descriptor], configuration: config)
    }
    logger.info("left click simulation and visualization dispatched.")
}

/// Simulates a left mouse double click at the specified coordinates and shows visual feedback.
/// - Parameters:
///   - point: The `CGPoint` where the double click should occur.
///   - duration: How long the visual feedback should last (in seconds). Default is 0.5s.
/// - Throws: `MacosUseSDKError` if simulation or visualization fails.
public func doubleClickMouseAndVisualize(at point: CGPoint, duration: Double = 0.5) async throws {
    logger.info(
        "simulating double-click AND visualize at: (\(point.x, privacy: .public), \(point.y, privacy: .public)), duration: \(duration, privacy: .public)s",
    )
    // Call the original input function
    try await doubleClickMouse(at: point)
    // Schedule visualization on the main thread
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)
        let config = VisualsConfig(duration: duration, animationStyle: .pulseAndFade)
        await presentVisuals(overlays: [descriptor], configuration: config)
    }
    logger.info("double-click simulation and visualization dispatched.")
}

/// Simulates a right mouse click at the specified coordinates and shows visual feedback.
/// - Parameters:
///   - point: The `CGPoint` where the right click should occur.
///   - duration: How long the visual feedback should last (in seconds). Default is 0.5s.
/// - Throws: `MacosUseSDKError` if simulation or visualization fails.
public func rightClickMouseAndVisualize(at point: CGPoint, duration: Double = 0.5) async throws {
    logger.info(
        "simulating right-click AND visualize at: (\(point.x, privacy: .public), \(point.y, privacy: .public)), duration: \(duration, privacy: .public)s",
    )
    // Call the original input function
    try await rightClickMouse(at: point)
    // Schedule visualization on the main thread
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)
        let config = VisualsConfig(duration: duration, animationStyle: .pulseAndFade)
        await presentVisuals(overlays: [descriptor], configuration: config)
    }
    logger.info("right-click simulation and visualization dispatched.")
}

/// Moves the mouse cursor to the specified coordinates and shows brief visual feedback at the destination.
/// - Parameters:
///   - point: The `CGPoint` to move the cursor to.
///   - duration: How long the visual feedback should last (in seconds). Default is 0.5s.
/// - Throws: `MacosUseSDKError` if simulation or visualization fails.
public func moveMouseAndVisualize(to point: CGPoint, duration: Double = 0.5) async throws {
    logger.info(
        "moving mouse AND visualize to: (\(point.x, privacy: .public), \(point.y, privacy: .public)), duration: \(duration, privacy: .public)s",
    )
    // Call the original input function
    try await moveMouse(to: point)
    // Schedule visualization on the main thread
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let size: CGFloat = 154
        let originX = point.x - (size / 2.0)
        let originY = screenHeight - point.y - (size / 2.0)
        let frame = CGRect(x: originX, y: originY, width: size, height: size)

        let descriptor = OverlayDescriptor(frame: frame, type: .circle)
        let config = VisualsConfig(duration: duration, animationStyle: .pulseAndFade)
        await presentVisuals(overlays: [descriptor], configuration: config)
    }
    logger.info("mouse move simulation and visualization dispatched.")
}

/// Simulates pressing and releasing a key with optional modifiers. Shows a caption at screen center.
/// - Parameters:
///   - keyCode: The `CGKeyCode` of the key to press.
///   - flags: The modifier flags (`CGEventFlags`).
///   - duration: How long the visual feedback should last (in seconds). Default is 0.8s.
/// - Throws: `MacosUseSDKError` if simulation fails.
public func pressKeyAndVisualize(
    keyCode: CGKeyCode, flags: CGEventFlags = [], duration: Double = 0.8,
) async throws {
    // Define caption constants
    let captionText = "[KEY PRESS]"
    let captionSize = CGSize(width: 250, height: 80) // Size for the key press caption

    logger.info(
        "simulating key press (code: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public)) AND visualizing caption '\(captionText, privacy: .public)', duration: \(duration, privacy: .public)s",
    )
    // Call the original input function first
    try await pressKey(keyCode: keyCode, flags: flags)

    // Always dispatch caption visualization to the main thread at screen center
    Task { @MainActor in
        // Get screen center for caption placement
        if let screenCenter = getMainScreenCenter() {
            logger.info(
                "[Main Thread] Displaying key press caption at screen center: \(String(describing: screenCenter), privacy: .public).",
            )

            let originX = screenCenter.x - (captionSize.width / 2.0)
            let originY = screenCenter.y - (captionSize.height / 2.0)
            let frame = CGRect(x: originX, y: originY, width: captionSize.width, height: captionSize.height)

            let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: captionText))
            let config = VisualsConfig(duration: duration, animationStyle: .scaleInFadeOut)
            await presentVisuals(overlays: [descriptor], configuration: config)
        } else {
            logger.warning(
                "[Main Thread] could not get main screen center for key press caption visualization.",
            )
        }
    }
    logger.info("key press simulation complete, caption visualization dispatched.")
}

/// Simulates typing a string of text. Shows a caption of the text at screen center.
/// - Parameters:
///   - text: The `String` to type.
///   - duration: How long the visual feedback should last (in seconds). Default is calculated or 1.0s min.
/// - Throws: `MacosUseSDKError` if simulation fails.
public func writeTextAndVisualize(_ text: String, duration: Double? = nil) async throws {
    // Define caption constants
    let defaultDuration = 1.0 // Minimum duration
    // Optional: Calculate duration based on text length, e.g., 0.5s + 0.05s per char
    let calculatedDuration = max(defaultDuration, 0.5 + Double(text.count) * 0.05)
    let finalDuration = duration ?? calculatedDuration
    let captionSize = CGSize(width: 450, height: 100) // Adjust size as needed, maybe make dynamic later

    logger.info(
        "simulating text writing AND visualizing caption: \"\(text, privacy: .private)\", duration: \(finalDuration, privacy: .public)s",
    )
    // Call the original input function first
    try await writeText(text)

    // Always dispatch caption visualization to the main thread at screen center
    Task { @MainActor in
        // Get screen center for caption placement
        if let screenCenter = getMainScreenCenter() {
            logger.info(
                "[Main Thread] Displaying text writing caption at screen center: \(String(describing: screenCenter), privacy: .public).",
            )

            let originX = screenCenter.x - (captionSize.width / 2.0)
            let originY = screenCenter.y - (captionSize.height / 2.0)
            let frame = CGRect(x: originX, y: originY, width: captionSize.width, height: captionSize.height)

            let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: text))
            let config = VisualsConfig(duration: finalDuration, animationStyle: .scaleInFadeOut)
            await presentVisuals(overlays: [descriptor], configuration: config)
        } else {
            logger.warning(
                "[Main Thread] could not get main screen center for text writing caption visualization.",
            )
        }
    }
    logger.info("text writing simulation complete, caption visualization dispatched.")
}

// --- Helper Function to Get Main Screen Center ---
// REMOVED: Entire fileprivate getMainScreenCenter() function definition.
// The internal version in DrawVisuals.swift will be used instead.
