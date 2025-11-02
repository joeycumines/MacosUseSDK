import ApplicationServices
import Foundation
import MacosUseSDK

/// Actor responsible for locating UI elements using selectors.
/// Integrates with the accessibility tree traversal to find elements
/// matching various criteria (role, text, position, attributes, etc.).
public actor ElementLocator {
  public static let shared = ElementLocator()

  private init() {
    fputs("info: [ElementLocator] Initialized\n", stderr)
  }

  /// Find elements matching a selector within an application or window context.
  /// - Parameters:
  ///   - selector: The element selector to match against
  ///   - parent: Resource name indicating search scope ("applications/{pid}" or "applications/{pid}/windows/{windowId}")
  ///   - visibleOnly: Whether to only consider visible elements
  ///   - maxResults: Maximum number of elements to return (0 for unlimited)
  /// - Returns: Array of matching elements with their hierarchy paths
  public func findElements(
    selector: Macosusesdk_Type_ElementSelector,
    parent: String,
    visibleOnly: Bool = false,
    maxResults: Int = 0
  ) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
    fputs("info: [ElementLocator] Finding elements with selector in parent: \(parent)\n", stderr)

    // Parse parent to get PID and optional window ID
    let (pid, windowId) = try parseParent(parent)

    // Get elements with paths
    let elementsWithPaths = try await traverseWithPaths(pid: pid, visibleOnly: visibleOnly)

    // Filter elements based on selector
    let matchingElements = elementsWithPaths.filter { element, path in
      matchesSelector(element, selector: selector)
    }

    // Apply max results limit if specified
    let limitedResults = maxResults > 0 ? Array(matchingElements.prefix(maxResults)) : matchingElements

    fputs("info: [ElementLocator] Found \(limitedResults.count) matching elements\n", stderr)
    return limitedResults
  }

  /// Find elements within a screen region.
  /// - Parameters:
  ///   - region: The screen region to search within
  ///   - selector: Optional additional selector for filtering
  ///   - parent: Resource name indicating search scope
  ///   - visibleOnly: Whether to only consider visible elements
  ///   - maxResults: Maximum number of elements to return
  /// - Returns: Array of elements within the region
  public func findElementsInRegion(
    region: Macosusesdk_V1_Region,
    selector: Macosusesdk_Type_ElementSelector?,
    parent: String,
    visibleOnly: Bool = false,
    maxResults: Int = 0
  ) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
    fputs("info: [ElementLocator] Finding elements in region for parent: \(parent)\n", stderr)

    // Parse parent to get PID and optional window ID
    let (pid, windowId) = try parseParent(parent)

    // Get elements with paths
    let elementsWithPaths = try await traverseWithPaths(pid: pid, visibleOnly: visibleOnly)

    // Filter by region
    var regionElements = elementsWithPaths.filter { element, path in
      isElementInRegion(element, region: region)
    }

    // Apply additional selector filter if provided
    if let selector = selector {
      regionElements = regionElements.filter { element, path in
        matchesSelector(element, selector: selector)
      }
    }

    // Apply max results limit
    let limitedResults = maxResults > 0 ? Array(regionElements.prefix(maxResults)) : regionElements

    fputs("info: [ElementLocator] Found \(limitedResults.count) elements in region\n", stderr)
    return limitedResults
  }

  /// Get a specific element by its resource name.
  /// - Parameter name: Resource name like "applications/{pid}/elements/{elementId}"
  /// - Returns: The element if found
  public func getElement(name: String) async throws -> Macosusesdk_Type_Element {
    fputs("info: [ElementLocator] Getting element: \(name)\n", stderr)

    // Parse the resource name
    let components = name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "elements",
      let pid = pid_t(components[1])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid element name format")
    }

    let elementId = components[3]

    // Get element from registry
    guard let element = ElementRegistry.shared.getElement(elementId) else {
      throw GRPCStatus(code: .notFound, message: "Element not found")
    }

    return element
  }

  // MARK: - Private Helper Methods

  private func parseParent(_ parent: String) throws -> (pid: pid_t, windowId: CGWindowID?) {
    let components = parent.split(separator: "/").map(String.init)

    if components.count == 2 && components[0] == "applications" {
      // "applications/{pid}" - search entire application
      guard let pid = pid_t(components[1]) else {
        throw GRPCStatus(code: .invalidArgument, message: "Invalid application PID")
      }
      return (pid, nil)
    } else if components.count == 4 && components[0] == "applications" && components[2] == "windows" {
      // "applications/{pid}/windows/{windowId}" - search within specific window
      guard let pid = pid_t(components[1]), let windowId = CGWindowID(components[3]) else {
        throw GRPCStatus(code: .invalidArgument, message: "Invalid window resource name")
      }
      return (pid, windowId)
    } else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid parent format")
    }
  }

  private func traverseWithAXElements(pid: pid_t, visibleOnly: Bool) async throws -> [(ElementData, AXUIElement)] {
    // This is a temporary implementation that duplicates traversal logic
    // In a proper implementation, we'd modify the SDK to return AXUIElement references
    
    // For now, we'll use the existing SDK traversal and create dummy AXUIElements
    // This is a workaround until the SDK is modified to preserve AXUIElement references
    let traversalResponse = try await AutomationCoordinator.shared.handleTraverse(pid: pid, visibleOnly: visibleOnly)
    
    // Convert proto elements back to ElementData (lossy conversion)
    let elementsWithAX: [(ElementData, AXUIElement)] = traversalResponse.elements.map { protoElement in
      let elementData = ElementData(
        role: protoElement.role,
        text: protoElement.text.isEmpty ? nil : protoElement.text,
        x: protoElement.x == 0 ? nil : protoElement.x,
        y: protoElement.y == 0 ? nil : protoElement.y,
        width: protoElement.width == 0 ? nil : protoElement.width,
        height: protoElement.height == 0 ? nil : protoElement.height
      )
      
      // FIXME: Create a proper AXUIElement reference
      // For now, create a dummy AXUIElement - this won't work for actions
      let dummyAXElement = AXUIElementCreateSystemWide()
      
      return (elementData, dummyAXElement)
    }
    
    return elementsWithAX
  }

  private func matchesSelector(_ element: Macosusesdk_Type_Element, selector: Macosusesdk_Type_ElementSelector) -> Bool {
    switch selector.criteria {
    case .role(let role):
      return element.role.lowercased() == role.lowercased()

    case .text(let text):
      return element.text == text

    case .textContains(let substring):
      guard let elementText = element.text else { return false }
      return elementText.contains(substring)

    case .textRegex(let pattern):
      guard let elementText = element.text else { return false }
      do {
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: elementText.utf16.count)
        return regex.firstMatch(in: elementText, options: [], range: range) != nil
      } catch {
        fputs("warning: [ElementLocator] Invalid regex pattern: \(pattern)\n", stderr)
        return false
      }

    case .position(let positionSelector):
      guard let elementX = element.x, let elementY = element.y else { return false }
      let distance = hypot(elementX - positionSelector.x, elementY - positionSelector.y)
      return distance <= positionSelector.tolerance

    case .attributes(let attributeSelector):
      for (key, expectedValue) in attributeSelector.attributes {
        guard let actualValue = element.attributes[key] else { return false }
        if actualValue != expectedValue { return false }
      }
      return true

    case .compound(let compoundSelector):
      let subMatches = compoundSelector.selectors.map { matchesSelector(element, selector: $0) }

      switch compoundSelector.operator {
      case .and, .unspecified:
        return subMatches.allSatisfy { $0 }
      case .or:
        return subMatches.contains(true)
      case .not:
        // NOT with single selector
        return compoundSelector.selectors.count == 1 && !subMatches[0]
      }

    case .none:
      return true // Match all elements if no criteria specified
    }
  }

  private func isElementInRegion(_ element: Macosusesdk_Type_Element, region: Macosusesdk_V1_Region) -> Bool {
    guard let x = element.x, let y = element.y,
          let width = element.width, let height = element.height else {
      return false
    }

    // Check if element bounds intersect with region
    let elementRect = CGRect(x: x, y: y, width: width, height: height)
    let regionRect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)

    return elementRect.intersects(regionRect)
  }
}