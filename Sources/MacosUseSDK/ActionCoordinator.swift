// swiftlint:disable all -- Largely unchanged from upstream.

import AppKit  // For NSWorkspace, NSRunningApplication, CGPoint, etc.
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
  // Use keyName for easier specification, maps to CGKeyCode internally
  case press(keyName: String, flags: CGEventFlags = [])
  case move(to: CGPoint)
}

/// Defines the main action to be performed.
public enum PrimaryAction: Sendable {
  // Identifier can be name, bundleID, or path
  case open(identifier: String)
  // Encapsulates various input types
  case input(action: InputAction)
  // If only traversal is needed, specify PID via options
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
  public var showAnimation: Bool = true  // Consolidated flag
  /// Duration for input animations and element highlighting.
  public var animationDuration: Double = 0.8
  /// Explicitly provide the PID for traversal if the primary action isn't `open`. Required if traversing without opening.
  public var pidForTraversal: pid_t?
  /// Delay in seconds *after* the primary action completes, but *before* the 'after' traversal starts.
  public var delayAfterAction: Double = 0.2

  // Ensure consistency if showDiff is enabled
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
    pidForTraversal: pid_t? = nil, delayAfterAction: Double = 0.2
  ) {
    self.traverseBefore = traverseBefore
    self.traverseAfter = traverseAfter
    self.showDiff = showDiff
    self.onlyVisibleElements = onlyVisibleElements
    self.showAnimation = showAnimation  // Use the new flag
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

  // Default initializer
  public init(
    openResult: AppOpenerResult? = nil, traversalPid: pid_t? = nil,
    traversalBefore: ResponseData? = nil, traversalAfter: ResponseData? = nil,
    traversalDiff: TraversalDiff? = nil, primaryActionError: String? = nil,
    traversalBeforeError: String? = nil, traversalAfterError: String? = nil
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
  optionsInput: ActionOptions = ActionOptions()
) async -> ActionResult {  // Changed to return ActionResult directly, errors are stored within it
  let options = optionsInput.validated()  // Ensure options are consistent (e.g., showDiff implies traversals)
  var result = ActionResult()
  var effectivePid: pid_t? = options.pidForTraversal
  var primaryActionError: Error?  // Temporary storage for Error objects
  var primaryActionExecuted: Bool = false  // Flag to track if primary action ran

  logger.info("[Coordinator] Starting action: \(String(describing: action), privacy: .public) with options: \(String(describing: options), privacy: .public)")

  // --- 1. Determine Target PID & Execute Open Action ---
  if case .open(let identifier) = action {
    logger.info(
      "[Coordinator] Primary action is 'open', attempting to get PID for '\(identifier, privacy: .private)'...")
    do {
      let openRes = try await openApplication(identifier: identifier)
      result.openResult = openRes
      effectivePid = openRes.pid
      logger.info("[Coordinator] App opened successfully. PID: \(effectivePid!, privacy: .public).")
      primaryActionExecuted = true  // Mark 'open' as executed
      // REMOVED Delay specific to open
    } catch {
      logger.error(
        "[Coordinator] Failed to open application '\(identifier, privacy: .private)': \(error.localizedDescription, privacy: .auto)")
      primaryActionError = error
      if effectivePid == nil {
        result.primaryActionError = error.localizedDescription
        logger.warning(
          "[Coordinator] Cannot proceed with PID-dependent steps (traversal) due to open failure and no provided PID.")
        return result
      } else {
        logger.warning(
          "[Coordinator] Open failed, but continuing with provided PID \(effectivePid!, privacy: .public).")
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
        "[Coordinator] Traversal or animation requested, but no PID could be determined (app open failed or PID not provided).")
      if options.traverseBefore { result.traversalBeforeError = "PID unavailable" }
      if options.traverseAfter { result.traversalAfterError = "PID unavailable" }
    } else {
      logger.info(
        "[Coordinator] No PID determined and no traversal/animation requested. Proceeding with primary action only (if applicable).")
    }
    // If primary action was *not* open, execute it now if PID wasn't available/needed
    if case .input(let inputAction) = action {
      logger.info(
        "[Coordinator] Executing primary input action (no PID context available/needed for traversal)...")
      do {
        try await executeInputAction(inputAction, options: options)
        primaryActionExecuted = true  // Mark 'input' as executed
      } catch {
        logger.error(
          "[Coordinator] Failed to execute input action: \(error.localizedDescription, privacy: .auto)")
        primaryActionError = error
      }
    } else if case .traverseOnly = action {
      // Nothing to execute, no action here. primaryActionExecuted remains false.
    }

    // Apply generic delay if an action was executed *and* a delay is set,
    // even if no traversal follows (though less common use case).
    if primaryActionExecuted && options.delayAfterAction > 0 {
      logger.info(
        "[Coordinator] Primary action finished. Applying delay: \(options.delayAfterAction, privacy: .public)s (before exiting due to no PID/traversal/animation)")
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
        pid: pid, onlyVisibleElements: options.onlyVisibleElements)
      logger.info(
        "[Coordinator] Pre-action traversal complete. Elements: \(result.traversalBefore?.elements.count ?? 0, privacy: .public)")
    } catch {
      logger.error(
        "[Coordinator] Pre-action traversal failed: \(error.localizedDescription, privacy: .auto)")
      result.traversalBeforeError = error.localizedDescription
    }
  }

  // --- 3. Execute Primary Input Action (if not 'open' or 'traverseOnly') ---
  if case .input(let inputAction) = action {
    logger.info("[Coordinator] Executing primary input action...")
    do {
      try await executeInputAction(inputAction, options: options)
      primaryActionExecuted = true  // Mark 'input' as executed
    } catch {
      logger.error(
        "[Coordinator] Failed to execute input action: \(error.localizedDescription, privacy: .auto)")
      primaryActionError = error
    }
  } else if case .traverseOnly = action {
    logger.info(
      "[Coordinator] Primary action is 'traverseOnly', skipping action execution.")
  }  // 'open' action was handled earlier

  // --- 4. Apply Delay AFTER Action, BEFORE Traverse After ---
  // Apply delay only if an action was actually executed and delay > 0
  if primaryActionExecuted && options.delayAfterAction > 0 {
    logger.info(
      "[Coordinator] Primary action finished. Applying delay: \(options.delayAfterAction, privacy: .public)s (before post-action traversal)")
    try? await Task.sleep(nanoseconds: UInt64(options.delayAfterAction * 1_000_000_000))
  }

  // --- 5. Traverse After ---
  var finalTraversalData: ResponseData?
  if options.traverseAfter {
    logger.info("[Coordinator] Performing post-action traversal for PID \(pid, privacy: .public)...")
    do {
      let traversalData = try traverseAccessibilityTree(
        pid: pid, onlyVisibleElements: options.onlyVisibleElements)
      result.traversalAfter = traversalData
      finalTraversalData = traversalData  // Keep for highlighting
      logger.info(
        "[Coordinator] Post-action traversal complete. Elements: \(traversalData.elements.count, privacy: .public)")
    } catch {
      logger.error(
        "[Coordinator] Post-action traversal failed: \(error.localizedDescription, privacy: .auto)")
      result.traversalAfterError = error.localizedDescription
    }
  }

  // --- 6. Calculate Diff ---
  if options.showDiff {
    logger.info("[Coordinator] Calculating detailed traversal diff...")
    if let beforeElements = result.traversalBefore?.elements,
      let afterElements = result.traversalAfter?.elements {

      // --- DETAILED DIFF LOGIC START ---
      var added: [ElementData] = []
      var removed: [ElementData] = []
      var modified: [ModifiedElement] = []

      // FIX: Use let for afterElements copy, since we iterate it but don't mutate this copy directly
      let remainingAfter = afterElements
      var matchedAfterIndices = Set<Int>()  // Keep track of matched 'after' elements

      let positionTolerance: Double = 5.0  // Max distance in points to consider a position match

      // Iterate through 'before' elements to find matches or mark as removed
      for beforeElement in beforeElements {
        var bestMatchIndex: Int?
        var smallestDistanceSq: Double = .greatestFiniteMagnitude

        // Find potential matches in the 'after' list
        for (index, afterElement) in remainingAfter.enumerated() {
          // Skip if already matched or role doesn't match
          if matchedAfterIndices.contains(index) || beforeElement.role != afterElement.role {
            continue
          }

          // Check position proximity (if coordinates exist)
          if let bx = beforeElement.x, let by = beforeElement.y, let ax = afterElement.x,
            let ay = afterElement.y {
            let dx = bx - ax
            let dy = by - ay
            let distanceSq = (dx * dx) + (dy * dy)

            if distanceSq <= (positionTolerance * positionTolerance) {
              // Found a plausible match based on role and position
              // If multiple are close, pick the closest one
              if distanceSq < smallestDistanceSq {
                smallestDistanceSq = distanceSq
                bestMatchIndex = index
              }
            }
          } else if beforeElement.x == nil && afterElement.x == nil && beforeElement.y == nil
            && afterElement.y == nil {
            // If *both* lack position, consider them potentially matched if role matches (and text?)
            // For now, let's focus on positional matching primarily.
            // Maybe add a fallback: if role matches AND text matches (and text exists)
            if let bt = beforeElement.text, let at = afterElement.text, bt == at {
              if bestMatchIndex == nil {  // Only if no positional match found yet
                bestMatchIndex = index
                // Don't update smallestDistanceSq here as it's not a positional match
              }
            }
          }
        }  // End inner loop through 'after' elements

        if let matchIndex = bestMatchIndex {
          // Found a match
          let afterElement = remainingAfter[matchIndex]
          matchedAfterIndices.insert(matchIndex)  // Mark as matched

          // --- UPDATED Attribute Comparison ---
          var attributeChanges: [AttributeChangeDetail] = []

          // Handle TEXT change specifically using the dedicated initializer
          if beforeElement.text != afterElement.text {
            attributeChanges.append(
              AttributeChangeDetail(textBefore: beforeElement.text, textAfter: afterElement.text))
          }

          // Handle other attributes using generic/double initializers
          if !areDoublesEqual(beforeElement.x, afterElement.x) {
            attributeChanges.append(
              AttributeChangeDetail(attribute: "x", before: beforeElement.x, after: afterElement.x))
          }
          if !areDoublesEqual(beforeElement.y, afterElement.y) {
            attributeChanges.append(
              AttributeChangeDetail(attribute: "y", before: beforeElement.y, after: afterElement.y))
          }
          if !areDoublesEqual(beforeElement.width, afterElement.width) {
            attributeChanges.append(
              AttributeChangeDetail(
                attribute: "width", before: beforeElement.width, after: afterElement.width))
          }
          if !areDoublesEqual(beforeElement.height, afterElement.height) {
            attributeChanges.append(
              AttributeChangeDetail(
                attribute: "height", before: beforeElement.height, after: afterElement.height))
          }
          // --- End Updated Attribute Comparison ---

          if !attributeChanges.isEmpty {
            modified.append(
              ModifiedElement(before: beforeElement, after: afterElement, changes: attributeChanges)
            )
          }
        } else {
          // No match found for this 'before' element, it was removed
          removed.append(beforeElement)
        }
      }  // End outer loop through 'before' elements

      // Any 'after' elements not matched are 'added'
      for (index, afterElement) in remainingAfter.enumerated() {
        if !matchedAfterIndices.contains(index) {
          added.append(afterElement)
        }
      }

      // Assign to result (using the TraversalDiff struct from CombinedActions.swift)
      result.traversalDiff = TraversalDiff(added: added, removed: removed, modified: modified)
      logger.info(
        "[Coordinator] Detailed diff calculated: Added=\(added.count, privacy: .public), Removed=\(removed.count, privacy: .public), Modified=\(modified.count, privacy: .public)")
      // --- DETAILED DIFF LOGIC END ---

    } else {
      logger.warning(
        "[Coordinator] Cannot calculate detailed diff because one or both traversals failed or were not performed.")
    }
  }

  // --- 7. Highlight Target Elements (Now controlled by showAnimation) ---
  if options.showAnimation {
    if let elementsToHighlight = finalTraversalData?.elements, !elementsToHighlight.isEmpty {
      logger.info(
        "[Coordinator] Highlighting \(elementsToHighlight.count, privacy: .public) elements from final traversal (showAnimation=true)...")

      let screenHeight = NSScreen.main?.frame.height ?? 1080
      let descriptors = elementsToHighlight.compactMap { OverlayDescriptor(element: $0, screenHeight: screenHeight) }

      if !descriptors.isEmpty {
        let config = VisualsConfig(duration: options.animationDuration, animationStyle: .none)
        Task { @MainActor in
          await presentVisuals(overlays: descriptors, configuration: config)
        }
      }
    } else if finalTraversalData == nil && options.traverseAfter {
      logger.warning(
        "[Coordinator] Animation requested, but post-action traversal failed or was skipped (cannot highlight).")
    } else {
      logger.info(
        "[Coordinator] Animation requested, but no elements found in the final traversal to highlight.")
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
  case .click(let point):
    if options.showAnimation {
      logger.info(
        "simulating click AND visualizing at \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))")
      try await clickMouseAndVisualize(at: point, duration: options.animationDuration)
    } else {
      logger.info("simulating click at \(String(describing: point), privacy: .public) (no visualization)")
      try await clickMouse(at: point)
    }
  case .doubleClick(let point):
    if options.showAnimation {
      logger.info(
        "simulating double-click AND visualizing at \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))")
      try await doubleClickMouseAndVisualize(at: point, duration: options.animationDuration)
    } else {
      logger.info("simulating double-click at \(String(describing: point), privacy: .public) (no visualization)")
      try await doubleClickMouse(at: point)
    }
  case .rightClick(let point):
    if options.showAnimation {
      logger.info(
        "simulating right-click AND visualizing at \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))")
      try await rightClickMouseAndVisualize(at: point, duration: options.animationDuration)
    } else {
      logger.info("simulating right-click at \(String(describing: point), privacy: .public) (no visualization)")
      try await rightClickMouse(at: point)
    }
  case .type(let text):
    if options.showAnimation {
      logger.info(
        "simulating text writing AND visualizing caption \"\(text, privacy: .private)\" (auto duration)")
      try await writeTextAndVisualize(text, duration: nil)  // Use nil to let visualize calculate duration
    } else {
      logger.info("simulating text writing \"\(text, privacy: .private)\" (no visualization)")
      try await writeText(text)
    }
  case .press(let keyName, let flags):
    guard let keyCode = mapKeyNameToKeyCode(keyName) else {
      throw MacosUseSDKError.inputInvalidArgument("Unknown key name: \(keyName)")
    }
    if options.showAnimation {
      logger.info(
        "simulating key press \(keyName, privacy: .public) (\(keyCode, privacy: .public)) AND visualizing (duration: \(options.animationDuration, privacy: .public))")
      try await pressKeyAndVisualize(keyCode: keyCode, flags: flags, duration: options.animationDuration)
    } else {
      logger.info("simulating key press \(keyName, privacy: .public) (\(keyCode, privacy: .public)) (no visualization)")
      try await pressKey(keyCode: keyCode, flags: flags)
    }
  case .move(let point):
    if options.showAnimation {
      logger.info(
        "simulating mouse move AND visualizing to \(String(describing: point), privacy: .public) (duration: \(options.animationDuration, privacy: .public))")
      try await moveMouseAndVisualize(to: point, duration: options.animationDuration)
    } else {
      logger.info("simulating mouse move to \(String(describing: point), privacy: .public) (no visualization)")
      try await moveMouse(to: point)
    }
  }
}

// --- ADD Helper function for comparing optional Doubles ---
private func areDoublesEqual(_ d1: Double?, _ d2: Double?, tolerance: Double = 0.01) -> Bool {
  switch (d1, d2) {
  case (nil, nil):
    return true  // Both nil are considered equal in this context
  case (let val1?, let val2?):
    // Use tolerance for floating point comparison if both exist
    return abs(val1 - val2) < tolerance
  default:
    return false  // One is nil, the other is not
  }
}
