import ApplicationServices
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog

private let logger = MacosUseSDK.sdkLogger(category: "ElementLocator")

typealias ElementDiscoveryExecutor = @Sendable (
    pid_t,
    AXUIElement?,
    Bool,
) async throws -> AccessibilityTraversalSnapshot

/// Actor responsible for locating UI elements using selectors.
/// Integrates with the accessibility tree traversal to find elements
/// matching various criteria (role, text, position, attributes, etc.).
public actor ElementLocator {
    nonisolated let elementRegistry: ElementRegistry
    private let stateStore: AppStateStore?
    private let windowRegistry: WindowRegistry?
    private let legacyPIDResourceNamesForTests: Bool
    private let system: SystemOperations
    private let automationCoordinator: AutomationCoordinator
    private let discoveryExecutor: ElementDiscoveryExecutor?

    private struct DiscoveryScope: Sendable {
        let parent: String
        let applicationName: String
        let pid: pid_t
        let processIdentity: ApplicationProcessIdentity?
        let windowResourceID: String?
        let windowID: CGWindowID?
    }

    init(
        elementRegistry: ElementRegistry,
        stateStore: AppStateStore? = nil,
        windowRegistry: WindowRegistry? = nil,
        legacyPIDResourceNamesForTests: Bool = true,
        system: SystemOperations = ProductionSystemOperations.shared,
        automationCoordinator: AutomationCoordinator? = nil,
        discoveryExecutor: ElementDiscoveryExecutor? = nil,
    ) {
        self.elementRegistry = elementRegistry
        self.stateStore = stateStore
        self.windowRegistry = windowRegistry
        self.legacyPIDResourceNamesForTests = legacyPIDResourceNamesForTests
        self.system = system
        self.automationCoordinator = automationCoordinator ?? AutomationCoordinator(
            elementRegistry: elementRegistry,
            activationSystem: system,
        )
        self.discoveryExecutor = discoveryExecutor
        logger.info("Initialized")
    }

    /// Find elements matching a selector within an application or window context.
    /// - Parameters:
    ///   - selector: The element selector to match against
    ///   - parent: Exact application or window resource name indicating search scope
    ///   - visibleOnly: Whether to only consider visible elements
    ///   - maxResults: Maximum number of elements to return (0 for unlimited)
    /// - Returns: Array of matching elements with their hierarchy paths
    /// - Note: Selector validation (including regex patterns) is performed by SelectorParser before this method.
    public func findElements(
        selector: Macosusesdk_Type_ElementSelector,
        parent: String,
        visibleOnly: Bool = false,
        maxResults: Int = 0,
    ) async throws -> [(element: Macosusesdk_V1_Element, path: [Int32])] {
        logger.info("Finding elements with selector in parent: \(parent, privacy: .private)")

        let scope = try await parseParent(parent)

        // Get elements with paths
        let elementsWithPaths = try await traverseWithPaths(
            scope: scope,
            visibleOnly: visibleOnly,
        )

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
    /// - Note: Selector validation (including regex patterns) is performed by SelectorParser before this method.
    public func findElementsInRegion(
        region: Macosusesdk_Type_Region,
        selector: Macosusesdk_Type_ElementSelector?,
        parent: String,
        visibleOnly: Bool = false,
        maxResults: Int = 0,
    ) async throws -> [(element: Macosusesdk_V1_Element, path: [Int32])] {
        logger.info("Finding elements in region for parent: \(parent, privacy: .private)")

        let scope = try await parseParent(parent)

        // Get elements with paths
        let elementsWithPaths = try await traverseWithPaths(
            scope: scope,
            visibleOnly: visibleOnly,
        )

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

    /// Refreshes one exact application/window scope without applying a
    /// selector. Stable registry identities let callers continue tracking the
    /// same AX object even when its mutable attributes stop matching.
    func refreshElements(
        parent: String,
        visibleOnly: Bool = false,
    ) async throws -> [(element: Macosusesdk_V1_Element, path: [Int32])] {
        let scope = try await parseParent(parent)
        return try await traverseWithPaths(
            scope: scope,
            visibleOnly: visibleOnly,
        )
    }

    /// Get a specific element by its resource name.
    /// - Parameter name: Exact application-owned element resource name
    /// - Returns: The element if found
    public func getElement(name: String) async throws -> Macosusesdk_V1_Element {
        logger.info("Getting element: \(name, privacy: .public)")

        let resource = try parseElementResourceName(name)
        let pid = try await resolveApplicationPID(applicationName: resource.applicationName)

        // Resolve both the ephemeral element ID and its application owner.
        guard let element = await elementRegistry.getElement(
            resource.elementID,
            expectedPID: pid,
        ) else {
            throw RPCError(code: .notFound, message: "Element not found")
        }

        return element
    }

    private func parseParent(_ parent: String) async throws -> DiscoveryScope {
        let components = parent.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 4,
              components[0] == "applications"
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid parent format")
        }

        let applicationName = components[0 ... 1].joined(separator: "/")
        let application = try await resolveApplication(applicationName: applicationName)
        if components.count == 2 {
            return DiscoveryScope(
                parent: parent,
                applicationName: applicationName,
                pid: application.pid,
                processIdentity: application.processIdentity,
                windowResourceID: nil,
                windowID: nil,
            )
        }
        guard components[2] == "windows" else {
            throw RPCError(code: .invalidArgument, message: "Invalid window resource name")
        }
        let resourceID = try ParsingHelpers.validateResourceID(
            String(components[3]),
            field: "parent",
        )
        guard let windowRegistry else {
            throw RPCError(code: .failedPrecondition, message: "Window resource resolver is unavailable")
        }
        guard let binding = await windowRegistry.resolveWindowBinding(
            resourceID: resourceID,
            applicationName: applicationName,
            pid: application.pid,
            processIdentity: application.processIdentity,
        ) else {
            throw RPCError(code: .notFound, message: "Window not found or binding is stale")
        }
        return DiscoveryScope(
            parent: parent,
            applicationName: applicationName,
            pid: application.pid,
            processIdentity: application.processIdentity,
            windowResourceID: resourceID,
            windowID: binding.windowID,
        )
    }

    private func resolveApplicationPID(applicationName: String) async throws -> pid_t {
        try await resolveApplication(applicationName: applicationName).pid
    }

    private func resolveApplication(
        applicationName: String,
    ) async throws -> (pid: pid_t, processIdentity: ApplicationProcessIdentity?) {
        if legacyPIDResourceNamesForTests {
            let pid = try ParsingHelpers.parsePID(fromName: applicationName)
            await elementRegistry.bindApplication(name: applicationName, pid: pid)
            return (pid, nil)
        }

        _ = try ParsingHelpers.parseOpaqueApplicationName(applicationName)
        guard let stateStore else {
            throw RPCError(code: .failedPrecondition, message: "Application state resolver is unavailable")
        }
        guard let application = await stateStore.getTarget(name: applicationName),
              let identity = await stateStore.getApplicationProcessIdentity(name: applicationName),
              system.isApplicationProcessRunning(identity)
        else {
            throw RPCError(code: .notFound, message: "Application not found or process identity is stale")
        }
        await elementRegistry.bindApplication(name: applicationName, pid: application.pid)
        return (application.pid, identity)
    }

    private func parseElementResourceName(
        _ name: String,
    ) throws -> (applicationName: String, elementID: String) {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "elements",
              !components[3].isEmpty
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid element resource name")
        }
        return (
            components[0 ... 1].joined(separator: "/"),
            String(components[3]),
        )
    }

    private func traverseWithPaths(scope: DiscoveryScope, visibleOnly: Bool) async throws -> [(
        Macosusesdk_V1_Element, [Int32],
    )] {
        let coordinator = automationCoordinator
        let executor = discoveryExecutor
        let registry = elementRegistry
        let stateStore = stateStore
        let windowRegistry = windowRegistry
        let system = system
        return try await coordinator.withOwnedTraversal {
            let root = try Self.resolveExactRoot(scope: scope, system: system)
            let snapshot: AccessibilityTraversalSnapshot = if let executor {
                try await executor(scope.pid, root, visibleOnly)
            } else {
                try await Self.executeSDKTraversal(
                    pid: scope.pid,
                    root: root,
                    visibleOnly: visibleOnly,
                )
            }
            try Task.checkCancellation()
            try await Self.revalidate(
                scope: scope,
                stateStore: stateStore,
                windowRegistry: windowRegistry,
                system: system,
            )
            let registeredElements = try await registry.registerTraversalElements(
                snapshot.elements,
                pid: scope.pid,
                scope: scope.parent,
                applicationName: scope.applicationName,
            )
            try Task.checkCancellation()
            return registeredElements.map { ($0, $0.path) }
        }
    }

    private nonisolated static func executeSDKTraversal(
        pid: pid_t,
        root: AXUIElement?,
        visibleOnly: Bool,
    ) async throws -> AccessibilityTraversalSnapshot {
        let task = Task.detached(priority: .userInitiated) {
            let response = if let root {
                try MacosUseSDK.traverseAccessibilitySubtree(
                    pid: pid,
                    rootElement: root,
                    onlyVisibleElements: visibleOnly,
                )
            } else {
                try MacosUseSDK.traverseAccessibilityTree(
                    pid: pid,
                    onlyVisibleElements: visibleOnly,
                    shouldActivate: false,
                )
            }
            return AccessibilityTraversalSnapshot(response)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func resolveExactRoot(
        scope: DiscoveryScope,
        system: SystemOperations,
    ) throws -> AXUIElement? {
        guard let windowID = scope.windowID else {
            return nil
        }
        try Task.checkCancellation()
        guard let applicationObject = system.createAXApplication(pid: scope.pid),
              CFGetTypeID(applicationObject) == AXUIElementGetTypeID()
        else {
            throw RPCError(code: .notFound, message: "Window owner is unavailable")
        }
        let application = unsafeDowncast(applicationObject, to: AXUIElement.self)
        try Task.checkCancellation()
        var candidates = system.copyAXAttribute(
            element: application,
            attribute: kAXWindowsAttribute as String,
        ) as? [AXUIElement]
        if candidates?.isEmpty != false {
            try Task.checkCancellation()
            let children = system.copyAXAttribute(
                element: application,
                attribute: kAXChildrenAttribute as String,
            ) as? [AXUIElement]
            var windowChildren: [AXUIElement] = []
            for child in children ?? [] {
                try Task.checkCancellation()
                if system.copyAXAttribute(
                    element: child,
                    attribute: kAXRoleAttribute as String,
                ) as? String == kAXWindowRole as String {
                    windowChildren.append(child)
                }
            }
            candidates = windowChildren
        }
        for candidate in candidates ?? [] {
            try Task.checkCancellation()
            if system.getAXWindowID(element: candidate) == windowID {
                return candidate
            }
        }
        throw RPCError(code: .notFound, message: "Exact AX window not found")
    }

    private nonisolated static func revalidate(
        scope: DiscoveryScope,
        stateStore: AppStateStore?,
        windowRegistry: WindowRegistry?,
        system: SystemOperations,
    ) async throws {
        try Task.checkCancellation()
        if let identity = scope.processIdentity {
            guard let stateStore,
                  await stateStore.getTarget(name: scope.applicationName)?.pid == scope.pid,
                  await stateStore.getApplicationProcessIdentity(name: scope.applicationName) == identity,
                  system.isApplicationProcessRunning(identity)
            else {
                throw RPCError(
                    code: .notFound,
                    message: "Application process identity became stale during traversal",
                )
            }
        }
        if let resourceID = scope.windowResourceID, let windowID = scope.windowID {
            guard let windowRegistry,
                  let binding = await windowRegistry.resolveWindowBinding(
                      resourceID: resourceID,
                      applicationName: scope.applicationName,
                      pid: scope.pid,
                      processIdentity: scope.processIdentity,
                  ),
                  binding.windowID == windowID
            else {
                throw RPCError(
                    code: .notFound,
                    message: "Window binding became stale during traversal",
                )
            }
        }
        try Task.checkCancellation()
    }

    /// Check if an element matches a selector.
    /// - Parameters:
    ///   - element: The element to check
    ///   - selector: The selector to match against
    /// - Returns: True if the element matches the selector
    /// - Note: Internal visibility for unit testing with @testable import.
    func matchesSelector(
        _ element: Macosusesdk_V1_Element, selector: Macosusesdk_Type_ElementSelector,
    ) -> Bool {
        switch selector.criteria {
        case let .role(role):
            // SDK roles may include a human-readable description in parentheses
            // (e.g. "AXTextArea (text entry area)"). Match against the canonical
            // role name before any whitespace or "(" on BOTH sides so that a
            // selector copied from verbose find_elements output still matches.
            let elementRole = Self.canonicalRole(element.role)
            let selectorRole = Self.canonicalRole(role)
            return elementRole.lowercased() == selectorRole.lowercased()

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
            // Calculate distance from element CENTER (not top-left corner)
            // Center = (x + width/2, y + height/2)
            let centerX: Double
            let centerY: Double
            if element.hasWidth, element.hasHeight {
                centerX = element.x + element.width / 2.0
                centerY = element.y + element.height / 2.0
            } else {
                // Fallback to top-left if dimensions unavailable
                centerX = element.x
                centerY = element.y
            }
            let distance = hypot(centerX - positionSelector.x, centerY - positionSelector.y)
            return distance <= positionSelector.tolerance

        case let .attributes(attributeSelector):
            for (key, expectedValue) in attributeSelector.attributes {
                guard let actualValue = element.attributes[key] else { return false }
                if actualValue != expectedValue {
                    return false
                }
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
                // NOT(selectors) = true if ANY sub-selector evaluates to false
                // This is equivalent to !(A AND B AND C...) = !A OR !B OR !C...
                // If empty selectors, return false (undefined behavior)
                guard !subMatches.isEmpty else { return false }
                return !subMatches.allSatisfy(\.self)
            case .UNRECOGNIZED:
                return false
            }

        case .none:
            return true // Match all elements if no criteria specified
        }
    }

    /// Strips a human-readable accessibility description suffix (everything from
    /// the first '(' onward) and trims whitespace from a role string. This
    /// makes selectors symmetric: both the element role and the user-supplied
    /// role can safely include verbose SDK descriptions.
    ///
    /// Uses `range(of:)` rather than `split(separator:)` because `split`
    /// omits empty subsequences by default, causing a role that begins with
    /// '(' (e.g. "(text entry area)") to incorrectly return the suffix.
    /// - Note: Internal visibility for unit testing with @testable import.
    static func canonicalRole(_ role: String) -> String {
        if let range = role.range(of: "(") {
            return String(role[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return role.trimmingCharacters(in: .whitespaces)
    }

    private func isElementInRegion(
        _ element: Macosusesdk_V1_Element, region: Macosusesdk_Type_Region,
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
