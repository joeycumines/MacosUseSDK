import ApplicationServices
import Foundation
import GRPCCore
import MacosUseSDK
import MacosUseSDKProtos
import OSLog

private let logger = MacosUseSDK.sdkLogger(category: "ElementLocator")

/// Actor responsible for locating UI elements using selectors.
/// Integrates with the accessibility tree traversal to find elements
/// matching various criteria (role, text, position, attributes, etc.).
public actor ElementLocator {
    public static let shared = ElementLocator()

    private init() {
        logger.info("Initialized")
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
        maxResults: Int = 0,
    ) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
        logger.info("Finding elements with selector in parent: \(parent, privacy: .private)")

        // Parse parent to get PID and optional window ID
        let (pid, _) = try parseParent(parent)

        // Get elements with paths
        let elementsWithPaths = try await traverseWithPaths(pid: pid, visibleOnly: visibleOnly)

        // Filter elements based on selector
        let matchingElements = elementsWithPaths.filter { element, _ in
            matchesSelector(element, selector: selector)
        }

        // Apply max results limit if specified
        let limitedResults =
            maxResults > 0 ? Array(matchingElements.prefix(maxResults)) : matchingElements

        logger.info("Found \(limitedResults.count, privacy: .public) matching elements")
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
        region: Macosusesdk_Type_Region,
        selector: Macosusesdk_Type_ElementSelector?,
        parent: String,
        visibleOnly: Bool = false,
        maxResults: Int = 0,
    ) async throws -> [(element: Macosusesdk_Type_Element, path: [Int32])] {
        logger.info("Finding elements in region for parent: \(parent, privacy: .private)")

        // Parse parent to get PID and optional window ID
        let (pid, _) = try parseParent(parent)

        // Get elements with paths
        let elementsWithPaths = try await traverseWithPaths(pid: pid, visibleOnly: visibleOnly)

        // Filter by region
        var regionElements = elementsWithPaths.filter { element, _ in
            isElementInRegion(element, region: region)
        }

        // Apply additional selector filter if provided
        if let selector {
            regionElements = regionElements.filter { element, _ in
                matchesSelector(element, selector: selector)
            }
        }

        // Apply max results limit
        let limitedResults = maxResults > 0 ? Array(regionElements.prefix(maxResults)) : regionElements

        logger.info("Found \(limitedResults.count, privacy: .public) elements in region")
        return limitedResults
    }

    /// Get a specific element by its resource name.
    /// - Parameter name: Resource name like "applications/{pid}/elements/{elementId}"
    /// - Returns: The element if found
    public func getElement(name: String) async throws -> Macosusesdk_Type_Element {
        logger.info("Getting element: \(name, privacy: .public)")

        // Parse the resource name
        let components = name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "elements",
              pid_t(components[1]) != nil
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid element name format")
        }

        let elementId = components[3]

        // Get element from registry
        guard let element = await ElementRegistry.shared.getElement(elementId) else {
            throw RPCError(code: .notFound, message: "Element not found")
        }

        return element
    }

    private func parseParent(_ parent: String) throws -> (pid: pid_t, windowId: CGWindowID?) {
        let components = parent.split(separator: "/").map(String.init)

        if components.count == 2, components[0] == "applications" {
            // "applications/{pid}" - search entire application
            guard let pid = pid_t(components[1]) else {
                throw RPCError(code: .invalidArgument, message: "Invalid application PID")
            }
            return (pid, nil)
        } else if components.count == 4, components[0] == "applications", components[2] == "windows" {
            // "applications/{pid}/windows/{windowId}" - search within specific window
            guard let pid = pid_t(components[1]), let windowId = CGWindowID(components[3]) else {
                throw RPCError(code: .invalidArgument, message: "Invalid window resource name")
            }
            return (pid, windowId)
        } else {
            throw RPCError(code: .invalidArgument, message: "Invalid parent format")
        }
    }

    private func traverseWithPaths(pid: pid_t, visibleOnly: Bool) async throws -> [(
        Macosusesdk_Type_Element, [Int32],
    )] {
        let sdkResponse = try await MainActor.run {
            try MacosUseSDK.traverseAccessibilityTree(pid: pid, onlyVisibleElements: visibleOnly)
        }

        var elementsWithPaths: [(Macosusesdk_Type_Element, [Int32])] = []

        for (index, elementData) in sdkResponse.elements.enumerated() {
            let protoElement = Macosusesdk_Type_Element.with {
                $0.role = elementData.role
                if let text = elementData.text { $0.text = text }
                if let x = elementData.x { $0.x = x }
                if let y = elementData.y { $0.y = y }
                if let width = elementData.width { $0.width = width }
                if let height = elementData.height { $0.height = height }
                if let enabled = elementData.enabled { $0.enabled = enabled }
                if let focused = elementData.focused { $0.focused = focused }
                $0.attributes = elementData.attributes
            }

            let elementId = await ElementRegistry.shared.registerElement(
                protoElement, axElement: elementData.axElement?.element, pid: pid,
            )
            var elementWithId = protoElement
            elementWithId.elementID = elementId

            // For now, use sequential index as path (FIXME: implement proper hierarchical paths)
            elementsWithPaths.append((elementWithId, [Int32(index)]))
        }

        return elementsWithPaths
    }

    private func matchesSelector(
        _ element: Macosusesdk_Type_Element, selector: Macosusesdk_Type_ElementSelector,
    ) -> Bool {
        switch selector.criteria {
        case let .role(role):
            return element.role.lowercased() == role.lowercased()

        case let .text(text):
            return element.text == text

        case let .textContains(substring):
            guard element.hasText else { return false }
            return element.text.contains(substring)

        case let .textRegex(pattern):
            guard element.hasText else { return false }
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let range = NSRange(location: 0, length: element.text.utf16.count)
                return regex.firstMatch(in: element.text, options: [], range: range) != nil
            } catch {
                logger.warning("Invalid regex pattern: \(pattern, privacy: .private)")
                return false
            }

        case let .position(positionSelector):
            guard element.hasX, element.hasY else { return false }
            let distance = hypot(element.x - positionSelector.x, element.y - positionSelector.y)
            return distance <= positionSelector.tolerance

        case let .attributes(attributeSelector):
            for (key, expectedValue) in attributeSelector.attributes {
                guard let actualValue = element.attributes[key] else { return false }
                if actualValue != expectedValue { return false }
            }
            return true

        case let .compound(compoundSelector):
            let subMatches = compoundSelector.selectors.map { matchesSelector(element, selector: $0) }

            switch compoundSelector.operator {
            case .and, .unspecified:
                return subMatches.allSatisfy(\.self)
            case .or:
                return subMatches.contains(true)
            case .not:
                // NOT with single selector
                return compoundSelector.selectors.count == 1 && !subMatches[0]
            case .UNRECOGNIZED:
                return false
            }

        case .none:
            return true // Match all elements if no criteria specified
        }
    }

    private func isElementInRegion(
        _ element: Macosusesdk_Type_Element, region: Macosusesdk_Type_Region,
    )
        -> Bool
    {
        guard element.hasX, element.hasY, element.hasWidth, element.hasHeight else {
            return false
        }

        // Check if element bounds intersect with region
        let elementRect = CGRect(
            x: element.x, y: element.y, width: element.width, height: element.height,
        )
        let regionRect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)

        return elementRect.intersects(regionRect)
    }
}
