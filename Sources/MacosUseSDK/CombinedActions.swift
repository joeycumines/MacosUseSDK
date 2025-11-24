// swiftlint:disable all -- Largely unchanged from upstream.

import AppKit // Needed for NSScreen
import CoreGraphics  // Needed for CGPoint, CGKeyCode, CGEventFlags
import OSLog

private let logger = sdkLogger(category: "CombinedActions")

/// Represents a change in a specific attribute of an accessibility element.
public struct AttributeChangeDetail: Codable, Sendable {
  public let attributeName: String

  // --- Fields for Simple Text Diff ---
  /// Text added (e.g., if newValue = oldValue + addedText). Populated only for text attribute changes.
  public let addedText: String?
  /// Text removed (e.g., if oldValue = newValue + removedText). Populated only for text attribute changes.
  public let removedText: String?

  // --- Fallback Fields ---
  /// Full old value, used for non-text attributes OR complex text changes.
  public let oldValue: String?
  /// Full new value, used for non-text attributes OR complex text changes.
  public let newValue: String?

  // --- Initializers ---

  // Initializer for non-text attributes (simple old/new)
  init<T: CustomStringConvertible>(attribute: String, before: T?, after: T?) {
    guard attribute != "text" else {
      // This initializer should not be called directly for text.
      // Handle text changes via the dedicated text initializer below.
      // For safety, provide a basic fallback if called incorrectly.
      logger.warning(
        "Generic AttributeChangeDetail initializer called for 'text'. Use text-specific init.")
      self.attributeName = attribute
      self.oldValue = before.map { $0.description }
      self.newValue = after.map { $0.description }
      self.addedText = nil
      self.removedText = nil
      return
    }
    self.attributeName = attribute
    self.oldValue = before.map { $0.description }
    self.newValue = after.map { $0.description }
    self.addedText = nil  // Not applicable
    self.removedText = nil  // Not applicable
  }

  // Initializer for Doubles (position/size)
  init(attribute: String, before: Double?, after: Double?, format: String = "%.1f") {
    self.attributeName = attribute
    self.oldValue = before.map { String(format: format, $0) }
    self.newValue = after.map { String(format: format, $0) }
    self.addedText = nil
    self.removedText = nil
  }

  // --- UPDATED Initializer for Text Changes using CollectionDifference ---
  init(textBefore: String?, textAfter: String?) {
    self.attributeName = "text"

    let old = textBefore ?? ""
    let new = textAfter ?? ""

    // Use CollectionDifference to find insertions and removals
    let diff = new.difference(from: old)

    var addedChars: [Character] = []
    var removedChars: [Character] = []

    // Process the calculated difference
    for change in diff {
      switch change {
      case .insert(_, let element, _):
        addedChars.append(element)
      case .remove(_, let element, _):
        removedChars.append(element)
      }
    }

    // Assign collected characters to the respective fields, or nil if empty
    self.addedText = addedChars.isEmpty ? nil : String(addedChars)
    self.removedText = removedChars.isEmpty ? nil : String(removedChars)

    // Since we now have potentially more granular diff info,
    // we consistently set oldValue/newValue to nil for text changes
    // to avoid redundancy in the output, as decided previously.
    self.oldValue = nil
    self.newValue = nil
  }
}

/// Represents an element identified as potentially the same logical entity
/// across two traversals, but with modified attributes.
public struct ModifiedElement: Codable, Sendable {
  /// The element data from the 'before' traversal.
  public let before: ElementData
  /// The element data from the 'after' traversal.
  public let after: ElementData
  /// A list detailing the specific attributes that changed.
  public let changes: [AttributeChangeDetail]
}

/// Represents the difference between two accessibility traversals,
/// now including added, removed, and modified elements with attribute details.
public struct TraversalDiff: Codable, Sendable {
  public let added: [ElementData]
  public let removed: [ElementData]
  /// Elements identified as modified, along with their specific changes.
  public let modified: [ModifiedElement]
}

/// Holds the results of an action performed between two accessibility traversals,
/// including the state before, the state after, and the calculated difference.
public struct ActionDiffResult: Codable, Sendable {
  public let afterAction: ResponseData
  public let diff: TraversalDiff
}

/// Defines combined, higher-level actions using the SDK's core functionalities.
public enum CombinedActions {

  /// Opens or activates an application and then immediately traverses its accessibility tree.
  ///
  /// This combines the functionality of `openApplication` and `traverseAccessibilityTree`.
  /// Logs detailed steps to stderr.
  ///
  /// - Parameters:
  ///   - identifier: The application name (e.g., "Calculator"), bundle ID (e.g., "com.apple.calculator"), or full path (e.g., "/System/Applications/Calculator.app").
  ///   - onlyVisibleElements: If true, the traversal only collects elements with valid position and size. Defaults to false.
  /// - Returns: A `ResponseData` struct containing the collected elements, statistics, and timing information from the traversal.
  /// - Throws: `MacosUseSDKError` if either the application opening/activation or the accessibility traversal fails.
  @MainActor  // Ensures UI-related parts like activation happen on the main thread
  public static func openAndTraverseApp(identifier: String, onlyVisibleElements: Bool = false)
    async throws -> ResponseData {
    logger.info(
      "starting combined action 'openAndTraverseApp' for identifier: '\(identifier, privacy: .private)'")

    // Step 1: Open or Activate the Application
    logger.info("calling openApplication...")
    let openResult = try await MacosUseSDK.openApplication(identifier: identifier)
    logger.info(
      "openApplication completed successfully. PID: \(openResult.pid, privacy: .public), App Name: \(openResult.appName, privacy: .private)")

    // Step 2: Traverse the Accessibility Tree of the opened/activated application
    logger.info(
      "calling traverseAccessibilityTree for PID \(openResult.pid, privacy: .public) (Visible Only: \(onlyVisibleElements, privacy: .public))...")
    let traversalResult = try MacosUseSDK.traverseAccessibilityTree(
      pid: openResult.pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traverseAccessibilityTree completed successfully.")

    // Step 3: Return the traversal result
    logger.info("combined action 'openAndTraverseApp' finished.")
    return traversalResult
  }

  // --- Input Action followed by Traversal ---

  /// Simulates a left mouse click at the specified coordinates, then traverses the accessibility tree of the target application.
  ///
  /// - Parameters:
  ///   - point: The `CGPoint` where the click should occur (screen coordinates).
  ///   - pid: The Process ID (PID) of the application to traverse after the click.
  ///   - onlyVisibleElements: If true, the traversal only collects elements with valid position and size. Defaults to false.
  /// - Returns: A `ResponseData` struct containing the collected elements, statistics, and timing information from the traversal.
  /// - Throws: `MacosUseSDKError` if the click simulation or the accessibility traversal fails.
  @MainActor  // Added for consistency, although core CGEvent might not strictly require it
  public static func clickAndTraverseApp(
    point: CGPoint, pid: Int32, onlyVisibleElements: Bool = false
  ) async throws -> ResponseData {
    logger.info(
      "starting combined action 'clickAndTraverseApp' at (\(point.x, privacy: .public), \(point.y, privacy: .public)) for PID \(pid, privacy: .public)")

    // Step 1: Perform the click
    logger.info("calling clickMouse...")
    try await MacosUseSDK.clickMouse(at: point)
    logger.info("clickMouse completed successfully.")

    // Add a small delay to allow UI to potentially update after the click
    try await Task.sleep(nanoseconds: 100_000_000)  // 100 milliseconds

    // Step 2: Traverse the Accessibility Tree
    logger.info(
      "calling traverseAccessibilityTree for PID \(pid, privacy: .public) (Visible Only: \(onlyVisibleElements, privacy: .public))...")
    let traversalResult = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traverseAccessibilityTree completed successfully.")

    // Step 3: Return the traversal result
    logger.info("combined action 'clickAndTraverseApp' finished.")
    return traversalResult
  }

  /// Simulates pressing a key with optional modifiers, then traverses the accessibility tree of the target application.
  ///
  /// - Parameters:
  ///   - keyCode: The `CGKeyCode` of the key to press.
  ///   - flags: The modifier flags (`CGEventFlags`) to apply.
  ///   - pid: The Process ID (PID) of the application to traverse after the key press.
  ///   - onlyVisibleElements: If true, the traversal only collects elements with valid position and size. Defaults to false.
  /// - Returns: A `ResponseData` struct containing the collected elements, statistics, and timing information from the traversal.
  /// - Throws: `MacosUseSDKError` if the key press simulation or the accessibility traversal fails.
  @MainActor
  public static func pressKeyAndTraverseApp(
    keyCode: CGKeyCode, flags: CGEventFlags = [], pid: Int32, onlyVisibleElements: Bool = false
  ) async throws -> ResponseData {
    logger.info(
      "starting combined action 'pressKeyAndTraverseApp' (key: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public)) for PID \(pid, privacy: .public)")

    // Step 1: Perform the key press
    logger.info("calling pressKey...")
    try await MacosUseSDK.pressKey(keyCode: keyCode, flags: flags)
    logger.info("pressKey completed successfully.")

    // Add a small delay
    try await Task.sleep(nanoseconds: 100_000_000)  // 100 milliseconds

    // Step 2: Traverse the Accessibility Tree
    logger.info(
      "calling traverseAccessibilityTree for PID \(pid, privacy: .public) (Visible Only: \(onlyVisibleElements, privacy: .public))...")
    let traversalResult = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traverseAccessibilityTree completed successfully.")

    // Step 3: Return the traversal result
    logger.info("combined action 'pressKeyAndTraverseApp' finished.")
    return traversalResult
  }

  /// Simulates typing text, then traverses the accessibility tree of the target application.
  ///
  /// - Parameters:
  ///   - text: The `String` to type.
  ///   - pid: The Process ID (PID) of the application to traverse after typing the text.
  ///   - onlyVisibleElements: If true, the traversal only collects elements with valid position and size. Defaults to false.
  /// - Returns: A `ResponseData` struct containing the collected elements, statistics, and timing information from the traversal.
  /// - Throws: `MacosUseSDKError` if the text writing simulation or the accessibility traversal fails.
  @MainActor
  public static func writeTextAndTraverseApp(
    text: String, pid: Int32, onlyVisibleElements: Bool = false
  ) async throws -> ResponseData {
    logger.info(
      "starting combined action 'writeTextAndTraverseApp' (text: \"\(text, privacy: .private)\") for PID \(pid, privacy: .public)")

    // Step 1: Perform the text writing
    logger.info("calling writeText...")
    try await MacosUseSDK.writeText(text)
    logger.info("writeText completed successfully.")

    // Add a small delay
    try await Task.sleep(nanoseconds: 100_000_000)  // 100 milliseconds

    // Step 2: Traverse the Accessibility Tree
    logger.info(
      "calling traverseAccessibilityTree for PID \(pid, privacy: .public) (Visible Only: \(onlyVisibleElements, privacy: .public))...")
    let traversalResult = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traverseAccessibilityTree completed successfully.")

    // Step 3: Return the traversal result
    logger.info("combined action 'writeTextAndTraverseApp' finished.")
    return traversalResult
  }

  // You can add similar functions for doubleClick, rightClick, moveMouse etc. if needed

  // --- Helper Function for Diffing ---

  /// Calculates the difference between two sets of ElementData based on set operations.
  /// - Parameters:
  ///   - beforeElements: The list of elements from the first traversal.
  ///   - afterElements: The list of elements from the second traversal.
  /// - Returns: A `TraversalDiff` struct containing added and removed elements.
  private static func calculateDiff(beforeElements: [ElementData], afterElements: [ElementData])
    -> TraversalDiff {
    logger.debug(
      "calculating diff between \(beforeElements.count, privacy: .public) (before) and \(afterElements.count, privacy: .public) (after) elements.")
    // Convert arrays to Sets for efficient comparison. Relies on ElementData being Hashable.
    let beforeSet = Set(beforeElements)
    let afterSet = Set(afterElements)

    // Elements present in 'after' but not in 'before' are added.
    let addedElements = Array(afterSet.subtracting(beforeSet))
    logger.debug("diff calculation - found \(addedElements.count, privacy: .public) added elements.")

    // Elements present in 'before' but not in 'after' are removed.
    let removedElements = Array(beforeSet.subtracting(afterSet))
    logger.debug("diff calculation - found \(removedElements.count, privacy: .public) removed elements.")

    // Sort results for consistent output (optional, but helpful)
    let sortedAdded = addedElements.sorted(by: elementSortPredicate)
    let sortedRemoved = removedElements.sorted(by: elementSortPredicate)

    return TraversalDiff(added: sortedAdded, removed: sortedRemoved, modified: [])
  }

  // Helper sorting predicate (consistent with AccessibilityTraversalOperation)
  private static var elementSortPredicate: (ElementData, ElementData) -> Bool {
    return { e1, e2 in
      let y1 = e1.y ?? Double.greatestFiniteMagnitude
      let y2 = e2.y ?? Double.greatestFiniteMagnitude
      if y1 != y2 { return y1 < y2 }
      let x1 = e1.x ?? Double.greatestFiniteMagnitude
      let x2 = e2.x ?? Double.greatestFiniteMagnitude
      return x1 < x2
    }
  }

  // --- Combined Actions with Diffing ---

  /// Performs a left mouse click, bracketed by accessibility traversals, and returns the diff.
  ///
  /// - Parameters:
  ///   - point: The `CGPoint` where the click should occur (screen coordinates).
  ///   - pid: The Process ID (PID) of the application to traverse.
  ///   - onlyVisibleElements: If true, traversals only collect elements with valid position/size. Defaults to false.
  ///   - delayAfterActionNano: Nanoseconds to wait after the action before the second traversal. Default 100ms.
  /// - Returns: An `ActionDiffResult` containing traversals before/after the click and the diff.
  /// - Throws: `MacosUseSDKError` if any step (traversal, click) fails.
  @MainActor
  public static func clickWithDiff(
    point: CGPoint,
    pid: Int32,
    onlyVisibleElements: Bool = false,
    delayAfterActionNano: UInt64 = 100_000_000  // 100 ms default
  ) async throws -> ActionDiffResult {
    logger.info(
      "starting combined action 'clickWithDiff' at (\(point.x, privacy: .public), \(point.y, privacy: .public)) for PID \(pid, privacy: .public)")

    // Step 1: Traverse Before Action
    logger.info("calling traverseAccessibilityTree (before action)...")
    let beforeTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (before action) completed.")

    // Step 2: Perform the Click
    logger.info("calling clickMouse...")
    try await MacosUseSDK.clickMouse(at: point)
    logger.info("clickMouse completed successfully.")

    // Step 3: Wait for UI to Update
    logger.info(
      "waiting \(Double(delayAfterActionNano) / 1_000_000_000.0, privacy: .public) seconds after action...")
    try await Task.sleep(nanoseconds: delayAfterActionNano)

    // Step 4: Traverse After Action
    logger.info("calling traverseAccessibilityTree (after action)...")
    let afterTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (after action) completed.")

    // Step 5: Calculate Diff
    logger.info("calculating traversal diff...")
    let diff = calculateDiff(
      beforeElements: beforeTraversal.elements, afterElements: afterTraversal.elements)
    logger.info("diff calculation completed.")

    // Step 6: Prepare and Return Result
    let result = ActionDiffResult(
      afterAction: afterTraversal,
      diff: diff
    )
    logger.info("combined action 'clickWithDiff' finished.")
    return result
  }

  /// Presses a key, bracketed by accessibility traversals, and returns the diff.
  ///
  /// - Parameters:
  ///   - keyCode: The `CGKeyCode` of the key to press.
  ///   - flags: The modifier flags (`CGEventFlags`).
  ///   - pid: The Process ID (PID) of the application to traverse.
  ///   - onlyVisibleElements: If true, traversals only collect elements with valid position/size. Defaults to false.
  ///   - delayAfterActionNano: Nanoseconds to wait after the action before the second traversal. Default 100ms.
  /// - Returns: An `ActionDiffResult` containing traversals before/after the key press and the diff.
  /// - Throws: `MacosUseSDKError` if any step fails.
  @MainActor
  public static func pressKeyWithDiff(
    keyCode: CGKeyCode,
    flags: CGEventFlags = [],
    pid: Int32,
    onlyVisibleElements: Bool = false,
    delayAfterActionNano: UInt64 = 100_000_000  // 100 ms default
  ) async throws -> ActionDiffResult {
    logger.info(
      "starting combined action 'pressKeyWithDiff' (key: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public)) for PID \(pid, privacy: .public)")

    // Step 1: Traverse Before Action
    logger.info("calling traverseAccessibilityTree (before action)...")
    let beforeTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (before action) completed.")

    // Step 2: Perform the Key Press
    logger.info("calling pressKey...")
    try await MacosUseSDK.pressKey(keyCode: keyCode, flags: flags)
    logger.info("pressKey completed successfully.")

    // Step 3: Wait for UI to Update
    logger.info(
      "waiting \(Double(delayAfterActionNano) / 1_000_000_000.0, privacy: .public) seconds after action...")
    try await Task.sleep(nanoseconds: delayAfterActionNano)

    // Step 4: Traverse After Action
    logger.info("calling traverseAccessibilityTree (after action)...")
    let afterTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (after action) completed.")

    // Step 5: Calculate Diff
    logger.info("calculating traversal diff...")
    let diff = calculateDiff(
      beforeElements: beforeTraversal.elements, afterElements: afterTraversal.elements)
    logger.info("diff calculation completed.")

    // Step 6: Prepare and Return Result
    let result = ActionDiffResult(
      afterAction: afterTraversal,
      diff: diff
    )
    logger.info("combined action 'pressKeyWithDiff' finished.")
    return result
  }

  /// Types text, bracketed by accessibility traversals, and returns the diff.
  ///
  /// - Parameters:
  ///   - text: The `String` to type.
  ///   - pid: The Process ID (PID) of the application to traverse.
  ///   - onlyVisibleElements: If true, traversals only collect elements with valid position/size. Defaults to false.
  ///   - delayAfterActionNano: Nanoseconds to wait after the action before the second traversal. Default 100ms.
  /// - Returns: An `ActionDiffResult` containing traversals before/after typing and the diff.
  /// - Throws: `MacosUseSDKError` if any step fails.
  @MainActor
  public static func writeTextWithDiff(
    text: String,
    pid: Int32,
    onlyVisibleElements: Bool = false,
    delayAfterActionNano: UInt64 = 100_000_000  // 100 ms default
  ) async throws -> ActionDiffResult {
    logger.info(
      "starting combined action 'writeTextWithDiff' (text: \"\(text, privacy: .private)\") for PID \(pid, privacy: .public)")

    // Step 1: Traverse Before Action
    logger.info("calling traverseAccessibilityTree (before action)...")
    let beforeTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (before action) completed.")

    // Step 2: Perform the Text Writing
    logger.info("calling writeText...")
    try await MacosUseSDK.writeText(text)
    logger.info("writeText completed successfully.")

    // Step 3: Wait for UI to Update
    logger.info(
      "waiting \(Double(delayAfterActionNano) / 1_000_000_000.0, privacy: .public) seconds after action...")
    try await Task.sleep(nanoseconds: delayAfterActionNano)

    // Step 4: Traverse After Action
    logger.info("calling traverseAccessibilityTree (after action)...")
    let afterTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (after action) completed.")

    // Step 5: Calculate Diff
    logger.info("calculating traversal diff...")
    let diff = calculateDiff(
      beforeElements: beforeTraversal.elements, afterElements: afterTraversal.elements)
    logger.info("diff calculation completed.")

    // Step 6: Prepare and Return Result
    let result = ActionDiffResult(
      afterAction: afterTraversal,
      diff: diff
    )
    logger.info("combined action 'writeTextWithDiff' finished.")
    return result
  }

  // Add similar '...WithDiff' functions for doubleClick, rightClick, etc. as needed

  // --- NEW: Combined Actions with Action Visualization AND Traversal Highlighting ---

  /// Performs a left click with visual feedback, bracketed by traversals (before action, after action),
  /// highlights the elements from the second traversal, and returns the diff.
  ///
  /// - Parameters:
  ///   - point: The `CGPoint` where the click should occur.
  ///   - pid: The Process ID (PID) of the application.
  ///   - onlyVisibleElements: If true, traversals only collect elements with valid position/size. Default false.
  ///   - actionHighlightDuration: Duration (seconds) for the click's visual feedback pulse. Default 0.5s.
  ///   - traversalHighlightDuration: Duration (seconds) for highlighting elements found in the second traversal. Default 3.0s.
  ///   - delayAfterActionNano: Nanoseconds to wait after the click before the second traversal. Default 100ms.
  /// - Returns: An `ActionDiffResult` containing the second traversal's data and the diff.
  /// - Throws: `MacosUseSDKError` if any step fails.
  @MainActor
  public static func clickWithActionAndTraversalHighlight(
    point: CGPoint,
    pid: Int32,
    onlyVisibleElements: Bool = false,
    actionHighlightDuration: Double = 0.5,  // Duration for the click pulse
    traversalHighlightDuration: Double = 3.0,  // Duration for highlighting elements
    delayAfterActionNano: UInt64 = 100_000_000  // 100 ms default
  ) async throws -> ActionDiffResult {
    logger.info(
      "starting combined action 'clickWithActionAndTraversalHighlight' at (\(point.x, privacy: .public), \(point.y, privacy: .public)) for PID \(pid, privacy: .public)")

    // Step 1: Traverse Before Action
    logger.info("calling traverseAccessibilityTree (before action)...")
    let beforeTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (before action) completed.")

    // Step 2a: Perform the Click (Input Simulation Only)
    logger.info("calling clickMouse...")
    try await MacosUseSDK.clickMouse(at: point)
    logger.info("clickMouse completed successfully.")

    // Step 2b: Dispatch Click Visualization
    logger.info(
      "dispatching visual feedback for click (duration: \(actionHighlightDuration, privacy: .public)s)...")
    // Use Task to ensure it runs on MainActor
    Task { @MainActor in
      let screenHeight = NSScreen.main?.frame.height ?? 0
      // Calculate frame for circle feedback (approx 154x154 based on legacy logic)
      let size: CGFloat = 154
      let originX = point.x - (size / 2.0)
      let originY = screenHeight - point.y - (size / 2.0)
      let frame = CGRect(x: originX, y: originY, width: size, height: size)

      let descriptor = OverlayDescriptor(frame: frame, type: .circle)
      let config = VisualsConfig(duration: actionHighlightDuration, animationStyle: .pulseAndFade)
      await presentVisuals(overlays: [descriptor], configuration: config)
    }
    logger.info("visual feedback for click dispatched.")

    // Step 3: Wait for UI to Update (after action, before second traversal)
    logger.info(
      "waiting \(Double(delayAfterActionNano) / 1_000_000_000.0, privacy: .public) seconds after action...")
    try await Task.sleep(nanoseconds: delayAfterActionNano)

    // Step 4: Traverse After Action (Standard Traversal)
    logger.info("calling traverseAccessibilityTree (after action)...")
    let afterTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (after action) completed.")

    // Step 5: Calculate Diff using data from the two traversals
    logger.info("calculating traversal diff...")
    let diff = calculateDiff(
      beforeElements: beforeTraversal.elements, afterElements: afterTraversal.elements)
    logger.info("diff calculation completed.")

    // Step 6: Dispatch Highlighting of the "After" Elements
    logger.info(
      "dispatching highlight overlays (duration: \(traversalHighlightDuration, privacy: .public)s) for afterTraversal elements...")

    let elementsToHighlight = afterTraversal.elements
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let descriptors = elementsToHighlight.compactMap { OverlayDescriptor(element: $0, screenHeight: screenHeight) }

        if !descriptors.isEmpty {
            let config = VisualsConfig(duration: traversalHighlightDuration, animationStyle: .none)
            await presentVisuals(overlays: descriptors, configuration: config)
        }
    }
    logger.info("highlight overlays dispatched.")

    // Step 7: Prepare and Return Result (using data from the *second* traversal)
    let result = ActionDiffResult(
      afterAction: afterTraversal,  // Contains data from the second traversal
      diff: diff
    )
    logger.info(
      "combined action 'clickWithActionAndTraversalHighlight' finished returning result.")
    // IMPORTANT: Highlighting cleanup happens asynchronously later.
    return result
  }

  /// Presses a key with visual feedback (caption), bracketed by traversals (before action, after action),
  /// highlights the elements from the second traversal, and returns the diff.
  ///
  /// - Parameters:
  ///   - keyCode: The `CGKeyCode` of the key to press.
  ///   - flags: The modifier flags (`CGEventFlags`).
  ///   - pid: The Process ID (PID) of the application.
  ///   - onlyVisibleElements: If true, traversals only collect elements with valid position/size. Default false.
  ///   - actionHighlightDuration: Duration (seconds) for the key press visual feedback caption. Default 0.8s.
  ///   - traversalHighlightDuration: Duration (seconds) for highlighting elements found in the second traversal. Default 3.0s.
  ///   - delayAfterActionNano: Nanoseconds to wait after the key press before the second traversal. Default 100ms.
  /// - Returns: An `ActionDiffResult` containing the second traversal's data and the diff.
  /// - Throws: `MacosUseSDKError` if any step fails.
  @MainActor
  public static func pressKeyWithActionAndTraversalHighlight(
    keyCode: CGKeyCode,
    flags: CGEventFlags = [],
    pid: Int32,
    onlyVisibleElements: Bool = false,
    actionHighlightDuration: Double = 0.8,  // Duration for visualization caption
    traversalHighlightDuration: Double = 3.0,  // Duration for highlighting elements
    delayAfterActionNano: UInt64 = 100_000_000  // 100 ms default
  ) async throws -> ActionDiffResult {
    logger.info(
      "starting combined action 'pressKeyWithActionAndTraversalHighlight' (key: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public)) for PID \(pid, privacy: .public)")

    // Step 1: Traverse Before Action
    logger.info("calling traverseAccessibilityTree (before action)...")
    let beforeTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (before action) completed.")

    // Step 2a: Perform the Key Press (Input Simulation Only)
    logger.info("calling pressKey (key: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public))...")
    try await MacosUseSDK.pressKey(keyCode: keyCode, flags: flags)
    logger.info("pressKey completed successfully.")

    // Step 2b: Dispatch Key Press Visualization (Caption)
    let captionText = "[KEY PRESS]"
    let captionSize = CGSize(width: 250, height: 80)
    logger.info(
      "dispatching visual feedback for key press (duration: \(actionHighlightDuration, privacy: .public)s)...")
    Task { @MainActor in
      if let screenCenter = getMainScreenCenter() {
        // screenCenter is in AppKit coordinates (bottom-left origin), so no flip needed
        let originX = screenCenter.x - (captionSize.width / 2.0)
        let originY = screenCenter.y - (captionSize.height / 2.0)
        let frame = CGRect(x: originX, y: originY, width: captionSize.width, height: captionSize.height)

        let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: captionText))
        let config = VisualsConfig(duration: actionHighlightDuration, animationStyle: .scaleInFadeOut)
        await presentVisuals(overlays: [descriptor], configuration: config)
      } else {
        logger.warning(
          "[\(#function, privacy: .public)] could not get screen center for key press caption.")
      }
    }
    logger.info("visual feedback for key press dispatched.")

    // Step 3: Wait for UI to Update
    logger.info(
      "waiting \(Double(delayAfterActionNano) / 1_000_000_000.0, privacy: .public) seconds after action...")
    try await Task.sleep(nanoseconds: delayAfterActionNano)

    // Step 4: Traverse After Action
    logger.info("calling traverseAccessibilityTree (after action)...")
    let afterTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (after action) completed.")

    // Step 5: Calculate Diff
    logger.info("calculating traversal diff...")
    let diff = calculateDiff(
      beforeElements: beforeTraversal.elements, afterElements: afterTraversal.elements)
    logger.info("diff calculation completed.")

    // Step 6: Dispatch Highlighting of the "After" Elements
    logger.info(
      "dispatching highlight overlays (duration: \(traversalHighlightDuration, privacy: .public)s) for afterTraversal elements...")

    let elementsToHighlight = afterTraversal.elements
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let descriptors = elementsToHighlight.compactMap { OverlayDescriptor(element: $0, screenHeight: screenHeight) }

        if !descriptors.isEmpty {
            let config = VisualsConfig(duration: traversalHighlightDuration, animationStyle: .none)
            await presentVisuals(overlays: descriptors, configuration: config)
        }
    }
    logger.info("highlight overlays dispatched.")

    // Step 7: Prepare and Return Result
    let result = ActionDiffResult(
      afterAction: afterTraversal,
      diff: diff
    )
    logger.info(
      "combined action 'pressKeyWithActionAndTraversalHighlight' finished returning result.")
    // IMPORTANT: Highlighting cleanup happens asynchronously later.
    return result
  }

  /// Types text with visual feedback (caption), bracketed by traversals (before action, after action),
  /// highlights the elements from the second traversal, and returns the diff.
  ///
  /// - Parameters:
  ///   - text: The `String` to type.
  ///   - pid: The Process ID (PID) of the application.
  ///   - onlyVisibleElements: If true, traversals only collect elements with valid position/size. Default false.
  ///   - actionHighlightDuration: Duration (seconds) for the text input visual feedback caption. Default calculated or 1.0s.
  ///   - traversalHighlightDuration: Duration (seconds) for highlighting elements found in the second traversal. Default 3.0s.
  ///   - delayAfterActionNano: Nanoseconds to wait after typing before the second traversal. Default 100ms.
  /// - Returns: An `ActionDiffResult` containing the second traversal's data and the diff.
  /// - Throws: `MacosUseSDKError` if any step fails.
  @MainActor
  public static func writeTextWithActionAndTraversalHighlight(
    text: String,
    pid: Int32,
    onlyVisibleElements: Bool = false,
    actionHighlightDuration: Double? = nil,  // Duration for visualization caption (optional, calculated if nil)
    traversalHighlightDuration: Double = 3.0,  // Duration for highlighting elements
    delayAfterActionNano: UInt64 = 100_000_000  // 100 ms default
  ) async throws -> ActionDiffResult {
    logger.info(
      "starting combined action 'writeTextWithActionAndTraversalHighlight' (text: \"\(text, privacy: .private)\") for PID \(pid, privacy: .public)")

    // Step 1: Traverse Before Action
    logger.info("calling traverseAccessibilityTree (before action)...")
    let beforeTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (before action) completed.")

    // Step 2a: Perform the Text Writing (Input Simulation Only)
    logger.info("calling writeText (\"\(text, privacy: .private)\")...")
    try await MacosUseSDK.writeText(text)
    logger.info("writeText completed successfully.")

    // Step 2b: Dispatch Text Writing Visualization (Caption)
    let defaultDuration = 1.0
    let calculatedDuration = max(defaultDuration, 0.5 + Double(text.count) * 0.05)
    let finalDuration = actionHighlightDuration ?? calculatedDuration
    let captionSize = CGSize(width: 450, height: 100)
    logger.info(
      "dispatching visual feedback for write text (duration: \(finalDuration, privacy: .public)s)...")
    Task { @MainActor in
      if let screenCenter = getMainScreenCenter() {
        // screenCenter is in AppKit coordinates (bottom-left origin), so no flip needed
        let originX = screenCenter.x - (captionSize.width / 2.0)
        let originY = screenCenter.y - (captionSize.height / 2.0)
        let frame = CGRect(x: originX, y: originY, width: captionSize.width, height: captionSize.height)

        let descriptor = OverlayDescriptor(frame: frame, type: .caption(text: text))
        let config = VisualsConfig(duration: finalDuration, animationStyle: .scaleInFadeOut)
        await presentVisuals(overlays: [descriptor], configuration: config)
      } else {
        logger.warning(
          "[\(#function, privacy: .public)] could not get screen center for write text caption.")
      }
    }
    logger.info("visual feedback for write text dispatched.")

    // Step 3: Wait for UI to Update
    logger.info(
      "waiting \(Double(delayAfterActionNano) / 1_000_000_000.0, privacy: .public) seconds after action...")
    try await Task.sleep(nanoseconds: delayAfterActionNano)

    // Step 4: Traverse After Action
    logger.info("calling traverseAccessibilityTree (after action)...")
    let afterTraversal = try MacosUseSDK.traverseAccessibilityTree(
      pid: pid, onlyVisibleElements: onlyVisibleElements)
    logger.info("traversal (after action) completed.")

    // Step 5: Calculate Diff
    logger.info("calculating traversal diff...")
    let diff = calculateDiff(
      beforeElements: beforeTraversal.elements, afterElements: afterTraversal.elements)
    logger.info("diff calculation completed.")

    // Step 6: Dispatch Highlighting of the "After" Elements
    logger.info(
      "dispatching highlight overlays (duration: \(traversalHighlightDuration, privacy: .public)s) for afterTraversal elements...")

    let elementsToHighlight = afterTraversal.elements
    Task { @MainActor in
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let descriptors = elementsToHighlight.compactMap { OverlayDescriptor(element: $0, screenHeight: screenHeight) }

        if !descriptors.isEmpty {
            let config = VisualsConfig(duration: traversalHighlightDuration, animationStyle: .none)
            await presentVisuals(overlays: descriptors, configuration: config)
        }
    }
    logger.info("highlight overlays dispatched.")

    // Step 7: Prepare and Return Result
    let result = ActionDiffResult(
      afterAction: afterTraversal,
      diff: diff
    )
    logger.info(
      "combined action 'writeTextWithActionAndTraversalHighlight' finished returning result.")
    // IMPORTANT: Highlighting cleanup happens asynchronously later.
    return result
  }

}
