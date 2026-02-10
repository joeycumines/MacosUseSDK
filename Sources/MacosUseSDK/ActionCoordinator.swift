import AppKit // For NSWorkspace, NSRunningApplication, CGPoint, etc.
import CoreGraphics
import Foundation
import OSLog

private let logger = sdkLogger(category: "ActionCoordinator")

// --- Enums and Structs for Orchestration ---

/// Defines the specific type of user input simulation.
public enum InputAction: Sendable {
    case click(point: CGPoint)
    case doubleClick(point: CGPoint)
    case rightClick(point: CGPoint)
    case type(text: String)
    /// Use keyName for easier specification, maps to CGKeyCode internally
    case press(keyName: String, flags: CGEventFlags = [])
    /// Hold a key down for a specified duration before releasing
    case pressHold(keyName: String, flags: CGEventFlags = [], duration: Double)
    case move(to: CGPoint)
    /// Press mouse button down without releasing (for stateful drag operations)
    case mouseDown(point: CGPoint, button: CGMouseButton = .left, modifiers: CGEventFlags = [])
    /// Release mouse button (for stateful drag operations)
    case mouseUp(point: CGPoint, button: CGMouseButton = .left, modifiers: CGEventFlags = [])
    /// Perform a complete mouse drag from start position to end position.
    /// Uses `leftMouseDragged` CGEvent type for proper window manager drag recognition.
    /// Duration controls the speed of the drag (0 = instant, >0 = animated with intermediate steps).
    case drag(from: CGPoint, to: CGPoint, button: CGMouseButton = .left, duration: Double = 0)
}

/// Defines the main action to be performed.
public enum PrimaryAction: Sendable {
    /// Identifier can be name, bundleID, or path
    case open(identifier: String)
    /// Encapsulates various input types
    case input(action: InputAction)
    /// If only traversal is needed, specify PID via options
    case traverseOnly
}

/// Configuration options for the orchestrated action.
public struct ActionOptions: Sendable {
    /// Perform traversal before the primary action. Required if `showDiff` is true.
    public var traverseBefore: Bool = false
    /// Perform traversal after the primary action. Required if `showDiff` is true.
    public var traverseAfter: Bool = false
    /// Calculate and return the difference between before/after traversals. Implies `traverseBefore` and `traverseAfter`.
    public var showDiff: Bool = false
    /// Filter traversals to only include elements with position and size > 0.
    public var onlyVisibleElements: Bool = false
    /// Show visual feedback for input actions (e.g., click pulse, typing caption) AND highlight elements found in the *final* traversal.
    public var showAnimation: Bool = true // Consolidated flag
    /// Duration for input animations and element highlighting.
    public var animationDuration: Double = 0.8
    /// Explicitly provide the PID for traversal if the primary action isn't `open`. Required if traversing without opening.
    public var pidForTraversal: pid_t?
    /// Delay in seconds *after* the primary action completes, but *before* the 'after' traversal starts.
    public var delayAfterAction: Double = 0.2

    /// Ensure consistency if showDiff is enabled
    public func validated() -> ActionOptions {
        var options = self
        if options.showDiff {
            options.traverseBefore = true
            options.traverseAfter = true
        }
        return options
    }

    public init(
        traverseBefore: Bool = false, traverseAfter: Bool = false, showDiff: Bool = false,
        onlyVisibleElements: Bool = false, showAnimation: Bool = true, animationDuration: Double = 0.8,
        pidForTraversal: pid_t? = nil, delayAfterAction: Double = 0.2,
    ) {
        self.traverseBefore = traverseBefore
        self.traverseAfter = traverseAfter
        self.showDiff = showDiff
        self.onlyVisibleElements = onlyVisibleElements
        self.showAnimation = showAnimation // Use the new flag
        self.animationDuration = animationDuration
        self.pidForTraversal = pidForTraversal
        self.delayAfterAction = delayAfterAction
    }
}

/// Contains the results of the orchestrated action.
public struct ActionResult: Codable, Sendable {
    /// Result from the `openApplication` action, if performed.
    public var openResult: AppOpenerResult?
    /// The PID used for traversals. Determined by `open` or provided in options.
    public var traversalPid: pid_t?
    /// Traversal data captured *before* the primary action.
    public var traversalBefore: ResponseData?
    /// Traversal data captured *after* the primary action.
    public var traversalAfter: ResponseData?
    /// The calculated difference between traversals, if requested.
    public var traversalDiff: TraversalDiff?
    /// Any error encountered during the primary action (open/input). Traversal errors are handled internally or thrown.
    public var primaryActionError: String?
    /// Any error encountered during the 'before' traversal.
    public var traversalBeforeError: String?
    /// Any error encountered during the 'after' traversal.
    public var traversalAfterError: String?

    /// Default initializer
    public init(
        openResult: AppOpenerResult? = nil, traversalPid: pid_t? = nil,
        traversalBefore: ResponseData? = nil, traversalAfter: ResponseData? = nil,
        traversalDiff: TraversalDiff? = nil, primaryActionError: String? = nil,
        traversalBeforeError: String? = nil, traversalAfterError: String? = nil,
    ) {
        self.openResult = openResult
        self.traversalPid = traversalPid
        self.traversalBefore = traversalBefore
        self.traversalAfter = traversalAfter
        self.traversalDiff = traversalDiff
        self.primaryActionError = primaryActionError
        self.traversalBeforeError = traversalBeforeError
        self.traversalAfterError = traversalAfterError
    }
}

// --- Action Coordinator Logic ---

/// Orchestrates application opening, input simulation, and accessibility traversal.
/// Requires running on the main actor due to UI interactions.
///
/// - Parameters:
///   - action: The primary action to perform (`PrimaryAction`).
///   - options: Configuration for the action execution (`ActionOptions`).
/// - Returns: An `ActionResult` containing the results of the steps performed.
/// - Throws: Can throw errors from underlying SDK functions, particularly during setup or unrecoverable failures.
@MainActor
public func performAction(
    action: PrimaryAction,
    optionsInput: ActionOptions = ActionOptions(),
) async -> ActionResult { // Changed to return ActionResult directly, errors are stored within it
    let options = optionsInput.validated() // Ensure options are consistent (e.g., showDiff implies traversals)
    var result = ActionResult()
    var effectivePid: pid_t? = options.pidForTraversal
    var primaryActionError: Error? // Temporary storage for Error objects
    var primaryActionExecuted = false // Flag to track if primary action ran

    logger.info("[Coordinator] Starting action: \(String(describing: action), privacy: .public) with options: \(String(describing: options), privacy: .public)")

    // --- 1. Determine Target PID & Execute Open Action ---
    if case let .open(identifier) = action {
        logger.info(
            "[Coordinator] Primary action is 'open', attempting to get PID for '\(identifier, privacy: .private)'...",
        )
        do {
            let openRes = try await openApplication(identifier: identifier)
            result.openResult = openRes
            effectivePid = openRes.pid
            logger.info("[Coordinator] App opened successfully. PID: \(effectivePid!, privacy: .public).")
            primaryActionExecuted = true // Mark 'open' as executed
            // REMOVED Delay specific to open
        } catch {
            logger.error(
                "[Coordinator] Failed to open application '\(identifier, privacy: .private)': \(error.localizedDescription, privacy: .public)",
            )
            primaryActionError = error
            if effectivePid == nil {
                result.primaryActionError = error.localizedDescription
                logger.warning(
                    "[Coordinator] Cannot proceed with PID-dependent steps (traversal) due to open failure and no provided PID.",
                )
                return result
            } else {
                logger.warning(
                    "[Coordinator] Open failed, but continuing with provided PID \(effectivePid!, privacy: .public).",
                )
            }
        }
    }

    result.traversalPid = effectivePid

    // --- Check if PID is available for traversal ---
    guard let pid = effectivePid,
          options.traverseBefore || options.traverseAfter || options.showAnimation
    else {
        if options.traverseBefore || options.traverseAfter || options.showAnimation {
            logger.warning(
                "[Coordinator] Traversal or animation requested, but no PID could be determined (app open failed or PID not provided).",
            )
            if options.traverseBefore { result.traversalBeforeError = "PID unavailable" }
            if options.traverseAfter { result.traversalAfterError = "PID unavailable" }
        } else {
            logger.info(
                "[Coordinator] No PID determined and no traversal/animation requested. Proceeding with primary action only (if applicable).",
            )
        }
        // If primary action was *not* open, execute it now if PID wasn't available/needed
        if case let .input(inputAction) = action {
            logger.info(
                "[Coordinator] Executing primary input action (no PID context available/needed for traversal)...",
            )
            do {
                try await executeInputAction(inputAction, options: options)
                primaryActionExecuted = true // Mark 'input' as executed
            } catch {
                logger.error(
                    "[Coordinator] Failed to execute input action: \(error.localizedDescription, privacy: .public)",
                )
                primaryActionError = error
            }
        } else if case .traverseOnly = action {
            // Nothing to execute, no action here. primaryActionExecuted remains false.
        }

        // Apply generic delay if an action was executed *and* a delay is set,
        // even if no traversal follows (though less common use case).
        if primaryActionExecuted, options.delayAfterAction > 0 {
            logger.info(
                "[Coordinator] Primary action finished. Applying delay: \(options.delayAfterAction, privacy: .public)s (before exiting due to no PID/traversal/animation)",
            )
            try? await Task.sleep(nanoseconds: UInt64(options.delayAfterAction * 1_000_000_000))
        }

        result.primaryActionError = primaryActionError?.localizedDescription
        return result
    }

    logger.info("[Coordinator] Effective PID for subsequent steps: \(pid, privacy: .public)")

    // --- 2. Traverse Before ---
    if options.traverseBefore {
        logger.info("[Coordinator] Performing pre-action traversal for PID \(pid, privacy: .public)...")
        do {
            result.traversalBefore = try traverseAccessibilityTree(
                pid: pid, onlyVisibleElements: options.onlyVisibleElements,
            )
            logger.info(
                "[Coordinator] Pre-action traversal complete. Elements: \(result.traversalBefore?.elements.count ?? 0, privacy: .public)",
            )
        } catch {
            logger.error(
                "[Coordinator] Pre-action traversal failed: \(error.localizedDescription, privacy: .public)",
            )
            result.traversalBeforeError = error.localizedDescription
        }
    }

    // --- 3. Execute Primary Input Action (if not 'open' or 'traverseOnly') ---
    if case let .input(inputAction) = action {
        logger.info("[Coordinator] Executing primary input action...")
        do {
            try await executeInputAction(inputAction, options: options)
            primaryActionExecuted = true // Mark 'input' as executed
        } catch {
            logger.error(
                "[Coordinator] Failed to execute input action: \(error.localizedDescription, privacy: .public)",
            )
            primaryActionError = error
        }
    } else if case .traverseOnly = action {
        logger.info(
            "[Coordinator] Primary action is 'traverseOnly', skipping action execution.",
        )
    } // 'open' action was handled earlier

    // --- 4. Apply Delay AFTER Action, BEFORE Traverse After ---
    // Apply delay only if an action was actually executed and delay > 0
    if primaryActionExecuted, options.delayAfterAction > 0 {
        logger.info(
            "[Coordinator] Primary action finished. Applying delay: \(options.delayAfterAction, privacy: .public)s (before post-action traversal)",
        )
        try? await Task.sleep(nanoseconds: UInt64(options.delayAfterAction * 1_000_000_000))
    }

    // --- 5. Traverse After ---
    var finalTraversalData: ResponseData?
    if options.traverseAfter {
        logger.info("[Coordinator] Performing post-action traversal for PID \(pid, privacy: .public)...")
        do {
            let traversalData = try traverseAccessibilityTree(
                pid: pid, onlyVisibleElements: options.onlyVisibleElements,
            )
            result.traversalAfter = traversalData
            finalTraversalData = traversalData // Keep for highlighting
            logger.info(
                "[Coordinator] Post-action traversal complete. Elements: \(traversalData.elements.count, privacy: .public)",
            )
        } catch {
            logger.error(
                "[Coordinator] Post-action traversal failed: \(error.localizedDescription, privacy: .public)",
            )
            result.traversalAfterError = error.localizedDescription
        }
    }

    // --- 6. Calculate Diff ---
    if options.showDiff {
        logger.info("[Coordinator] Calculating detailed traversal diff...")
        if let beforeElements = result.traversalBefore?.elements,
           let afterElements = result.traversalAfter?.elements
        {
            result.traversalDiff = CombinedActions.calculateDiff(
                beforeElements: beforeElements, afterElements: afterElements,
            )
            logger.info(
                "[Coordinator] Detailed diff calculated: Added=\(result.traversalDiff?.added.count ?? 0, privacy: .public), Removed=\(result.traversalDiff?.removed.count ?? 0, privacy: .public), Modified=\(result.traversalDiff?.modified.count ?? 0, privacy: .public)",
            )
        } else {
            logger.warning(
                "[Coordinator] Cannot calculate detailed diff because one or both traversals failed or were not performed.",
            )
        }
    }

    // --- 7. Highlight Target Elements (Now controlled by showAnimation) ---
    if options.showAnimation {
        if let elementsToHighlight = finalTraversalData?.elements, !elementsToHighlight.isEmpty {
            logger.info(
                "[Coordinator] Highlighting \(elementsToHighlight.count, privacy: .public) elements from final traversal (showAnimation=true)...",
            )

            let screenHeight = NSScreen.main?.frame.height ?? 1080
            let descriptors = elementsToHighlight.compactMap { OverlayDescriptor(element: $0, screenHeight: screenHeight) }

            if !descriptors.isEmpty {
                let config = VisualsConfig(duration: options.animationDuration, animationStyle: .none)
                // Fire-and-forget: visualization is a cosmetic side-effect that must not
                // block the ActionResult return. presentVisuals handles its own cleanup
                // (window lifecycle, timer-based removal). The Task is detached so callers
                // receive results immediately while animation plays in the background.
                Task { @MainActor in
                    await presentVisuals(overlays: descriptors, configuration: config)
                }
            }
        } else if finalTraversalData == nil, options.traverseAfter {
            logger.warning(
                "[Coordinator] Animation requested, but post-action traversal failed or was skipped (cannot highlight).",
            )
        } else {
            logger.info(
                "[Coordinator] Animation requested, but no elements found in the final traversal to highlight.",
            )
        }
    } else {
        logger.info("[Coordinator] Skipping element highlighting (showAnimation=false).")
    }

    // Store any primary action error encountered
    result.primaryActionError = primaryActionError?.localizedDescription

    logger.info("[Coordinator] Action sequence finished.")
    return result
}

/// Helper function to execute the specific input action based on type.
@MainActor
private func executeInputAction(_ action: InputAction, options: ActionOptions) async throws {
    switch action {
    case let .click(point):
        if options.showAnimation {
            logger.info(
                "simulating click AND visualizing at \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))",
            )
            try await clickMouseAndVisualize(at: point, duration: options.animationDuration)
        } else {
            logger.info("simulating click at \(String(describing: point), privacy: .public) (no visualization)")
            try await clickMouse(at: point)
        }
    case let .doubleClick(point):
        if options.showAnimation {
            logger.info(
                "simulating double-click AND visualizing at \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))",
            )
            try await doubleClickMouseAndVisualize(at: point, duration: options.animationDuration)
        } else {
            logger.info("simulating double-click at \(String(describing: point), privacy: .public) (no visualization)")
            try await doubleClickMouse(at: point)
        }
    case let .rightClick(point):
        if options.showAnimation {
            logger.info(
                "simulating right-click AND visualizing at \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))",
            )
            try await rightClickMouseAndVisualize(at: point, duration: options.animationDuration)
        } else {
            logger.info("simulating right-click at \(String(describing: point), privacy: .public) (no visualization)")
            try await rightClickMouse(at: point)
        }
    case let .type(text):
        if options.showAnimation {
            logger.info(
                "simulating text writing AND visualizing caption \"\(text, privacy: .private)\" (auto duration)",
            )
            try await writeTextAndVisualize(text, duration: nil) // Use nil to let visualize calculate duration
        } else {
            logger.info("simulating text writing \"\(text, privacy: .private)\" (no visualization)")
            try await writeText(text)
        }
    case let .press(keyName, flags):
        guard let keyCode = mapKeyNameToKeyCode(keyName) else {
            throw MacosUseSDKError.inputInvalidArgument("Unknown key name: \(keyName)")
        }
        if options.showAnimation {
            logger.info(
                "simulating key press \(keyName, privacy: .public) (\(keyCode, privacy: .public)) AND visualizing (duration: \(options.animationDuration, privacy: .public))",
            )
            try await pressKeyAndVisualize(keyCode: keyCode, flags: flags, duration: options.animationDuration)
        } else {
            logger.info("simulating key press \(keyName, privacy: .public) (\(keyCode, privacy: .public)) (no visualization)")
            try await pressKey(keyCode: keyCode, flags: flags)
        }
    case let .move(point):
        if options.showAnimation {
            logger.info(
                "simulating mouse move AND visualizing to \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))",
            )
            try await moveMouseAndVisualize(to: point, duration: options.animationDuration)
        } else {
            logger.info("simulating mouse move to \(String(describing: point), privacy: .public) (no visualization)")
            try await moveMouse(to: point)
        }
    case let .pressHold(keyName, flags, duration):
        guard let keyCode = mapKeyNameToKeyCode(keyName) else {
            throw MacosUseSDKError.inputInvalidArgument("Unknown key name: \(keyName)")
        }
        logger.info(
            "simulating key hold \(keyName, privacy: .public) for \(duration, privacy: .public)s (no visualization for hold)",
        )
        try await pressKeyHold(keyCode: keyCode, flags: flags, duration: duration)
    case let .mouseDown(point, button, modifiers):
        logger.info(
            "simulating mouse button down at \(String(describing: point), privacy: .public) button: \(button.rawValue, privacy: .public)",
        )
        try await mouseButtonDown(at: point, button: button, modifiers: modifiers)
    case let .mouseUp(point, button, modifiers):
        logger.info(
            "simulating mouse button up at \(String(describing: point), privacy: .public) button: \(button.rawValue, privacy: .public)",
        )
        try await mouseButtonUp(at: point, button: button, modifiers: modifiers)
    case let .drag(from, to, button, duration):
        logger.info(
            "simulating drag from \(String(describing: from), privacy: .public) to \(String(describing: to), privacy: .public) button: \(button.rawValue, privacy: .public) duration: \(duration, privacy: .public)s",
        )
        try await performDrag(from: from, to: to, button: button, duration: duration)
    }
}
