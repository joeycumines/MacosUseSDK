// swiftlint:disable all -- Largely unchanged from upstream.

// The Swift Programming Language
// https://docs.swift.org/swift-book

import AppKit  // For NSWorkspace, NSRunningApplication, NSApplication
@preconcurrency import ApplicationServices  // For Accessibility API (AXUIElement, etc.)
import Foundation  // For basic types, JSONEncoder, Date
import OSLog

private let logger = sdkLogger(category: "AccessibilityTraversal")

// Mark AXUIElement as Sendable - it's safe because it's an opaque CFTypeRef
// managed by the Accessibility framework. We only store/pass references.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// A Sendable and Hashable wrapper around `AXUIElement`.
///
/// `AXUIElement` is a Core Foundation type that does not natively conform to
/// Swift's `Sendable` or `Hashable` protocols. This wrapper provides both,
/// enabling safe use across concurrency domains and in collections like `Set`.
///
/// The underlying `AXUIElement` is thread-safe by nature (CFTypeRef), so
/// the `@unchecked Sendable` conformance is safe.
public struct SendableAXUIElement: @unchecked Sendable, Hashable {
  /// The wrapped accessibility element reference.
  public let element: AXUIElement

  /// Creates a new wrapper around an `AXUIElement`.
  /// - Parameter element: The accessibility element to wrap.
  public init(_ element: AXUIElement) {
    self.element = element
  }

  // Implement Hashable using CFHash for CFTypeRef
  public func hash(into hasher: inout Hasher) {
    hasher.combine(CFHash(element))
  }

  public static func == (lhs: SendableAXUIElement, rhs: SendableAXUIElement) -> Bool {
    return CFEqual(lhs.element, rhs.element)
  }
}

// --- Error Enum ---

/// Errors that can occur during accessibility traversal operations.
public enum MacosUseSDKError: Error, LocalizedError {
  /// Accessibility access is denied. The user must grant permissions in System Settings.
  case accessibilityDenied
  /// No running application was found with the specified PID.
  case appNotFound(pid: Int32)
  /// JSON encoding of the response failed.
  case jsonEncodingFailed(Error)
  /// An unexpected internal error occurred.
  case internalError(String)

  public var errorDescription: String? {
    switch self {
    case .accessibilityDenied:
      return
        "Accessibility access is denied. Please grant permissions in System Settings > Privacy & Security > Accessibility."
    case .appNotFound(let pid):
      return "No running application found with PID \(pid)."
    case .jsonEncodingFailed(let underlyingError):
      return "Failed to encode response to JSON: \(underlyingError.localizedDescription)"
    case .internalError(let message):
      return "Internal SDK error: \(message)"
    }
  }
}

// --- Public Data Structures for API Response ---

/// Represents a single UI element discovered during accessibility traversal.
///
/// Each `ElementData` contains the element's role, text content, position, size,
/// and other accessibility attributes. Elements are uniquely identified within
/// a traversal by their hierarchical `path`.
public struct ElementData: Codable, Hashable, Sendable {
  /// The accessibility role of the element (e.g., "AXButton", "AXTextField").
  public var role: String
  /// The text content of the element, if available.
  public var text: String?
  /// The x-coordinate of the element's top-left corner in global display coordinates.
  public var x: Double?
  /// The y-coordinate of the element's top-left corner in global display coordinates.
  public var y: Double?
  /// The width of the element in points.
  public var width: Double?
  /// The height of the element in points.
  public var height: Double?
  /// The underlying AXUIElement reference for performing accessibility actions.
  /// Excluded from Codable encoding.
  public var axElement: SendableAXUIElement?
  /// Whether the element is enabled for interaction.
  public var enabled: Bool?
  /// Whether the element currently has keyboard focus.
  public var focused: Bool?
  /// Additional accessibility attributes as key-value pairs.
  public var attributes: [String: String]
  /// Hierarchical path from application root to this element.
  /// - Positive indices (0, 1, 2, ...): child index via AXChildren
  /// - Negative indices (-1, -2, ...): window index via AXWindows (encoded as -(windowIndex + 1))
  /// - Special value -10000: main window via AXMainWindow
  public var path: [Int32]

  // Implement Hashable for use in Set
  public func hash(into hasher: inout Hasher) {
    hasher.combine(role)
    hasher.combine(text)
    hasher.combine(x)
    hasher.combine(y)
    hasher.combine(width)
    hasher.combine(height)
    hasher.combine(path)
  }
  public static func == (lhs: ElementData, rhs: ElementData) -> Bool {
    lhs.role == rhs.role && lhs.text == rhs.text && lhs.x == rhs.x && lhs.y == rhs.y
      && lhs.width == rhs.width && lhs.height == rhs.height && lhs.path == rhs.path
  }

  // Add this enum to exclude axElement from Codable
  enum CodingKeys: String, CodingKey {
    case role, text, x, y, width, height, enabled, focused, attributes, path
    // axElement is deliberately excluded - it cannot be encoded/decoded
  }
}

/// Statistics about the accessibility traversal operation.
///
/// Provides counts of collected elements, excluded elements, and breakdowns
/// by element type and reason for exclusion.
public struct Statistics: Codable, Sendable {
  /// Total number of elements collected.
  public var count: Int = 0
  /// Number of elements excluded during traversal.
  public var excluded_count: Int = 0
  /// Number of elements excluded because they have non-interactable roles.
  public var excluded_non_interactable: Int = 0
  /// Number of elements excluded because they have no text content.
  public var excluded_no_text: Int = 0
  /// Number of collected elements that have text content.
  public var with_text_count: Int = 0
  /// Number of collected elements without text content.
  public var without_text_count: Int = 0
  /// Number of elements with valid geometry (position and size).
  public var visible_elements_count: Int = 0
  /// Count of elements by their accessibility role.
  public var role_counts: [String: Int] = [:]
}

/// The result of an accessibility tree traversal operation.
///
/// Contains all collected elements, traversal statistics, and timing information.
public struct ResponseData: Codable, Sendable {
  /// The display name of the application that was traversed.
  public let app_name: String
  /// The collected UI elements from the accessibility tree.
  public var elements: [ElementData]
  /// Statistics about the traversal operation.
  public var stats: Statistics
  /// The time taken to complete the traversal, in seconds (as a formatted string).
  public let processing_time_seconds: String
}

// --- Main Public Function ---

/// Traverses the accessibility tree of an application specified by its PID.
///
/// - Parameter pid: The Process ID (PID) of the target application.
/// - Parameter onlyVisibleElements: If true, only collects elements with valid position and size. Defaults to false.
/// - Returns: A `ResponseData` struct containing the collected elements, statistics, and timing information.
/// - Throws: `MacosUseSDKError` if accessibility is denied, the app is not found, or an internal error occurs.
public func traverseAccessibilityTree(pid: Int32, onlyVisibleElements: Bool = false) throws
  -> ResponseData {
  let operation = AccessibilityTraversalOperation(
    pid: pid, onlyVisibleElements: onlyVisibleElements)
  return try operation.executeTraversal()
}

// --- Internal Implementation Detail ---

// Class to encapsulate the state and logic of a single traversal operation
private class AccessibilityTraversalOperation {
  let pid: Int32
  let onlyVisibleElements: Bool
  var visitedElements: Set<AXUIElement> = []
  var collectedElements: Set<ElementData> = []
  var statistics: Statistics = Statistics()
  var stepStartTime: Date = Date()
  let maxDepth = 100

  // Define roles considered non-interactable by default
  let nonInteractableRoles: Set<String> = [
    "AXGroup", "AXStaticText", "AXUnknown", "AXSeparator",
    "AXHeading", "AXLayoutArea", "AXHelpTag", "AXGrowArea",
    "AXOutline", "AXScrollArea", "AXSplitGroup", "AXSplitter",
    "AXToolbar", "AXDisclosureTriangle"
  ]

  init(pid: Int32, onlyVisibleElements: Bool) {
    self.pid = pid
    self.onlyVisibleElements = onlyVisibleElements
  }

  // --- Main Execution Method ---
  func executeTraversal() throws -> ResponseData {
    let overallStartTime = Date()
    logger.info(
      "starting traversal for pid: \(String(describing: self.pid), privacy: .public) (Visible Only: \(String(describing: self.onlyVisibleElements), privacy: .public))")
    stepStartTime = Date()  // Initialize step timer
    // 1. Accessibility Check
    logger.info("checking accessibility permissions...")
    let checkOptions = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue] as CFDictionary
    let isTrusted = AXIsProcessTrustedWithOptions(checkOptions)

    if !isTrusted {
      logger.error("❌ accessibility access is denied.")
      logger.error(
        "please grant permissions in system settings > privacy & security > accessibility.")
      throw MacosUseSDKError.accessibilityDenied
    }
    logStepCompletion("checking accessibility permissions (granted)")

    // 2. Find Application by PID and Create AXUIElement
    // Remove strict dependency on NSRunningApplication. It is primarily needed for .activate().
    let runningApp = NSRunningApplication(processIdentifier: pid)
    if runningApp == nil {
      logger.warning("NSRunningApplication returned nil for PID \(self.pid, privacy: .public). The app might be in a transient state. Proceeding with raw AX creation.")
    }

    let targetAppName = runningApp?.localizedName ?? "App (PID: \(pid))"

    // Create the AX element directly from the PID. This works at the CoreFoundation level
    // and does not require the Window Server to be fully in sync.
    let appElement = AXUIElementCreateApplication(pid)

    // 3. Activate App if needed (Only if we have a runningApp handle)
    var didActivate = false
    if let app = runningApp, app.activationPolicy == NSApplication.ActivationPolicy.regular {
      if !app.isActive {
        app.activate() // Default options are usually sufficient
        didActivate = true
      }
    }
    if didActivate {
      logStepCompletion("activating application '\(targetAppName)'")
    }

    // 4. Start Traversal
    // fputs("info: starting accessibility tree traversal...\n", stderr) // Optional start log
    walkElementTree(element: appElement, depth: 0, path: [])
    logStepCompletion(
      "traversing accessibility tree (\(collectedElements.count) elements collected)")

    // 5. Process Results
    // fputs("info: sorting elements...\n", stderr) // Optional start log
    let sortedElements = collectedElements.sorted {
      let y0 = $0.y ?? Double.greatestFiniteMagnitude
      let y1 = $1.y ?? Double.greatestFiniteMagnitude
      if y0 != y1 { return y0 < y1 }
      let x0 = $0.x ?? Double.greatestFiniteMagnitude
      let x1 = $1.x ?? Double.greatestFiniteMagnitude
      return x0 < x1
    }
    // logStepCompletion("sorting \(sortedElements.count) elements") // Log implicitly

    // Set the final count statistic
    statistics.count = sortedElements.count

    // --- Calculate Total Time ---
    let overallEndTime = Date()
    let totalProcessingTime = overallEndTime.timeIntervalSince(overallStartTime)
    let formattedTime = String(format: "%.2f", totalProcessingTime)
    logger.info("total execution time: \(formattedTime, privacy: .public) seconds")

    // 6. Prepare Response
    let response = ResponseData(
      app_name: targetAppName,
      elements: sortedElements,
      stats: statistics,
      processing_time_seconds: formattedTime
    )

    return response
    // JSON encoding will be handled by the caller of the library function if needed
  }

  // --- Helper Functions (now methods of the class) ---

  // Safely copy an attribute value
  func copyAttributeValue(element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    if result == .success {
      return value
    } else if result != .attributeUnsupported && result != .noValue {
      // fputs("warning: could not get attribute '\(attribute)' for element: error \(result.rawValue)\n", stderr)
    }
    return nil
  }

  // Extract string value
  func getStringValue(_ value: CFTypeRef?) -> String? {
    guard let value = value else { return nil }
    let typeID = CFGetTypeID(value)
    if typeID == CFStringGetTypeID() {
      let cfString = value as! CFString
      return cfString as String
    } else if typeID == AXValueGetTypeID() {
      // AXValue conversion is complex, return nil for generic string conversion
      return nil
    }
    return nil
  }

  // Extract bool value
  func getBoolValue(_ value: CFTypeRef?) -> Bool? {
    guard let value = value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((value as! CFBoolean))
  }

  // Extract CGPoint
  func getCGPointValue(_ value: CFTypeRef?) -> CGPoint? {
    guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    var pointValue = CGPoint.zero
    if AXValueGetValue(axValue, .cgPoint, &pointValue) {
      return pointValue
    }
    // fputs("warning: failed to extract cgpoint from axvalue.\n", stderr)
    return nil
  }

  // Extract CGSize
  func getCGSizeValue(_ value: CFTypeRef?) -> CGSize? {
    guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    var sizeValue = CGSize.zero
    if AXValueGetValue(axValue, .cgSize, &sizeValue) {
      return sizeValue
    }
    // fputs("warning: failed to extract cgsize from axvalue.\n", stderr)
    return nil
  }

  // Extract attributes, text, and geometry
  func extractElementAttributes(element: AXUIElement) -> (
    role: String, roleDesc: String?, text: String?, allTextParts: [String], position: CGPoint?,
    size: CGSize?, enabled: Bool?, focused: Bool?, attributes: [String: String]
  ) {
    var role = "AXUnknown"
    var roleDesc: String?
    var textParts: [String] = []
    var position: CGPoint?
    var size: CGSize?
    var enabled: Bool?
    var focused: Bool?
    var attributes: [String: String] = [:]

    if let roleValue = copyAttributeValue(element: element, attribute: kAXRoleAttribute as String) {
      role = getStringValue(roleValue) ?? "AXUnknown"
    }
    if let roleDescValue = copyAttributeValue(
      element: element, attribute: kAXRoleDescriptionAttribute as String) {
      roleDesc = getStringValue(roleDescValue)
    }

    let textAttributes = [
      kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String,
      "AXLabel", "AXHelp"
    ]
    for attr in textAttributes {
      if let attrValue = copyAttributeValue(element: element, attribute: attr),
        let text = getStringValue(attrValue),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        textParts.append(text)
      }
    }
    let combinedText =
      textParts.isEmpty
      ? nil : textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

    if let posValue = copyAttributeValue(
      element: element, attribute: kAXPositionAttribute as String) {
      position = getCGPointValue(posValue)
    }

    if let sizeValue = copyAttributeValue(element: element, attribute: kAXSizeAttribute as String) {
      size = getCGSizeValue(sizeValue)
    }

    if let enabledValue = copyAttributeValue(
      element: element, attribute: kAXEnabledAttribute as String) {
      enabled = getBoolValue(enabledValue)
    }

    if let focusedValue = copyAttributeValue(
      element: element, attribute: kAXFocusedAttribute as String) {
      focused = getBoolValue(focusedValue)
    }

    // Add some common attributes
    let commonAttributes = [
      kAXTitleAttribute as String,
      kAXValueAttribute as String,
      kAXDescriptionAttribute as String,
      kAXHelpAttribute as String
    ]
    for attr in commonAttributes {
      if let attrValue = copyAttributeValue(element: element, attribute: attr),
        let strValue = getStringValue(attrValue) {
        attributes[attr] = strValue
      }
    }

    return (role, roleDesc, combinedText, textParts, position, size, enabled, focused, attributes)
  }

  // Recursive traversal function (now a method)
  func walkElementTree(element: AXUIElement, depth: Int, path: [Int32]) {
    // 1. Check for cycles and depth limit
    if visitedElements.contains(element) || depth > maxDepth {
      // fputs("debug: skipping visited or too deep element (depth: \(depth))\n", stderr)
      return
    }
    visitedElements.insert(element)

    // 2. Process the current element
    let (role, roleDesc, combinedText, _, position, size, enabled, focused, attributes) =
      extractElementAttributes(
        element: element)
    let hasText = combinedText != nil && !combinedText!.isEmpty
    let isNonInteractable = nonInteractableRoles.contains(role)
    let roleWithoutAX = role.starts(with: "AX") ? String(role.dropFirst(2)) : role

    statistics.role_counts[role, default: 0] += 1

    // 3. Determine Geometry and Visibility
    var finalX: Double?
    var finalY: Double?
    var finalWidth: Double?
    var finalHeight: Double?
    if let p = position, let s = size, s.width > 0 || s.height > 0 {
      finalX = Double(p.x)
      finalY = Double(p.y)
      finalWidth = s.width > 0 ? Double(s.width) : nil
      finalHeight = s.height > 0 ? Double(s.height) : nil
    }
    let isGeometricallyVisible =
      finalX != nil && finalY != nil && finalWidth != nil && finalHeight != nil

    // Always update the visible_elements_count stat based on geometry, regardless of collection
    if isGeometricallyVisible {
      statistics.visible_elements_count += 1
    }

    // 4. Apply Filtering Logic
    var displayRole = role
    if let desc = roleDesc, !desc.isEmpty, !desc.elementsEqual(roleWithoutAX) {
      displayRole = "\(role) (\(desc))"
    }

    // Determine if the element passes the original filter criteria
    let passesOriginalFilter = !isNonInteractable || hasText

    // Determine if the element should be collected based on the new flag
    let shouldCollectElement =
      passesOriginalFilter && (!onlyVisibleElements || isGeometricallyVisible)

    if shouldCollectElement {
      let elementData = ElementData(
        role: displayRole, text: combinedText,
        x: finalX, y: finalY, width: finalWidth, height: finalHeight,
        axElement: SendableAXUIElement(element), enabled: enabled, focused: focused,
        attributes: attributes,
        path: path
      )

      if collectedElements.insert(elementData).inserted {
        // Log addition (optional)
        // let geometryStatus = isGeometricallyVisible ? "visible" : "not_visible"
        // fputs("debug: + collect [\(geometryStatus)] | r: \(displayRole) | t: '\(combinedText ?? "nil")'\n", stderr)

        // Update text counts only for collected elements
        if hasText { statistics.with_text_count += 1 } else { statistics.without_text_count += 1 }
      } else {
        // Log duplicate (optional)
        // fputs("debug: = skip duplicate | r: \(displayRole) | t: '\(combinedText ?? "nil")'\n", stderr)
      }
    } else {
      // Log exclusion (MODIFIED logic)
      var reasons: [String] = []
      if !passesOriginalFilter {
        if isNonInteractable { reasons.append("non-interactable role '\(role)'") }
        if !hasText { reasons.append("no text") }
      }
      // Add visibility reason only if it was the deciding factor
      if passesOriginalFilter && onlyVisibleElements && !isGeometricallyVisible {
        reasons.append("not visible")
      }
      // fputs("debug: - exclude | r: \(role) | reason(s): \(reasons.joined(separator: ", "))\n", stderr)

      // Update exclusion counts
      statistics.excluded_count += 1
      // Note: The specific exclusion reasons (non-interactable, no-text) might be slightly less precise
      // if an element is excluded *only* because it's invisible, but this keeps the stats simple.
      // We can refine this if needed.
      if isNonInteractable { statistics.excluded_non_interactable += 1 }
      if !hasText { statistics.excluded_no_text += 1 }
    }

    // 5. Recursively traverse children, windows, main window
    // a) Windows (use negative indices starting from -1 to distinguish from regular children)
    if let windowsValue = copyAttributeValue(
      element: element, attribute: kAXWindowsAttribute as String) {
      if let windowsArray = windowsValue as? [AXUIElement] {
        for (windowIndex, windowElement) in windowsArray.enumerated()
        where !visitedElements.contains(windowElement) {
          // Use -(windowIndex + 1) to distinguish windows from children
          let windowPath = path + [Int32(-(windowIndex + 1))]
          walkElementTree(element: windowElement, depth: depth + 1, path: windowPath)
        }
      } else if CFGetTypeID(windowsValue) == CFArrayGetTypeID() {
        // fputs("warning: attribute \(kAXWindowsAttribute) was CFArray but failed bridge to [AXUIElement]\n", stderr)
      }
    }

    // b) Main Window (use special index -10000 to distinguish)
    if let mainWindowValue = copyAttributeValue(
      element: element, attribute: kAXMainWindowAttribute as String) {
      if CFGetTypeID(mainWindowValue) == AXUIElementGetTypeID() {
        let mainWindowElement = mainWindowValue as! AXUIElement
        if !visitedElements.contains(mainWindowElement) {
          let mainWindowPath = path + [Int32(-10000)]
          walkElementTree(element: mainWindowElement, depth: depth + 1, path: mainWindowPath)
        }
      } else {
        // fputs("warning: attribute \(kAXMainWindowAttribute) was not an AXUIElement\n", stderr)
      }
    }

    // c) Regular Children (use 0-based indices)
    if let childrenValue = copyAttributeValue(
      element: element, attribute: kAXChildrenAttribute as String) {
      if let childrenArray = childrenValue as? [AXUIElement] {
        for (childIndex, childElement) in childrenArray.enumerated()
        where !visitedElements.contains(childElement) {
          let childPath = path + [Int32(childIndex)]
          walkElementTree(element: childElement, depth: depth + 1, path: childPath)
        }
      } else if CFGetTypeID(childrenValue) == CFArrayGetTypeID() {
        // fputs("warning: attribute \(kAXChildrenAttribute) was CFArray but failed bridge to [AXUIElement]\n", stderr)
      }
    }
  }

  // Helper function logs duration of the step just completed
  func logStepCompletion(_ stepDescription: String) {
    let endTime = Date()
    let duration = endTime.timeIntervalSince(stepStartTime)
    let durationStr = String(format: "%.3f", duration)
    logger.info("[\(durationStr)s] finished '\(stepDescription)'")
    stepStartTime = endTime  // Reset start time for the next step
  }
}  // End of AccessibilityTraversalOperation class
