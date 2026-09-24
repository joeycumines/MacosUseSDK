import ApplicationServices
import ExactMac
import ExactMacProto
import Foundation
import OSLog

private let logger = ExactMac.sdkLogger(category: "ElementRegistry")

enum ElementRegistryError: Error, Equatable {
    case admissionClosed
    case applicationBindingMismatch
    case duplicateTraversalIdentity
    case identifierExhausted
}

enum ElementMutationResolutionError: Error, Equatable {
    case admissionClosed
    case notFound
    case ownerMismatch(expectedPID: pid_t, actualPID: pid_t)
    case scopeMismatch(expected: String, actual: String)
}

/// One PID-bound registry snapshot resolved after physical-mutation admission.
/// AXUIElement is a Core Foundation reference documented as safe to use across
/// threads; the wrapper makes that ownership decision explicit to Swift.
struct RegisteredElementMutationTarget: @unchecked Sendable {
    let elementID: String
    let element: Exactmac_V1_Element
    let axElement: AXUIElement?
    let pid: pid_t
    let scope: String
}

/// Actor responsible for tracking element IDs and providing stable references.
/// Elements are ephemeral and IDs are generated server-side. This registry
/// maintains mappings between IDs and element data/AXUIElement references.
public actor ElementRegistry {
    private enum TraversalIdentityComponent: Hashable {
        case accessibilityElement(SendableAXUIElement)
        case path([Int32])
    }

    private struct TraversalIdentity: Hashable {
        let pid: pid_t
        let scope: String
        let component: TraversalIdentityComponent
    }

    /// Structure holding cached element information
    private struct CachedElement {
        let element: Exactmac_V1_Element
        let axElement: AXUIElement?
        var timestamp: Date
        let pid: pid_t
        let scope: String
        let traversalIdentity: TraversalIdentity?
    }

    /// In-memory cache of elements by ID
    private var elementCache: [String: CachedElement] = [:]
    private var elementIDsByTraversalIdentity: [TraversalIdentity: String] = [:]

    /// Exact application resource currently owning each PID. Production
    /// callers bind this before registering elements so child names preserve
    /// the opaque process-instance identity rather than exposing a PID.
    private var applicationNamesByPID: [pid_t: String] = [:]

    /// Cache expiration time (elements expire after 30 seconds)
    private let cacheExpiration: TimeInterval

    /// Clock function for testing (returns current Date)
    private let clock: @Sendable () -> Date

    /// ID generator function for testing
    private let idGenerator: @Sendable () -> String
    private let cleanupOperation: (@Sendable () async -> Void)?
    private var cleanupTask: Task<Void, Never>?
    private var acceptingWork = true

    init(
        cacheExpiration: TimeInterval = 30.0,
        clock: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let random = Int.random(in: 0 ..< 1_000_000)
            return "elem_\(timestamp)_\(random)"
        },
        cleanupOperation: (@Sendable () async -> Void)? = nil,
    ) {
        self.cacheExpiration = cacheExpiration
        self.clock = clock
        self.idGenerator = idGenerator
        self.cleanupOperation = cleanupOperation
        logger.info("Initialized")
    }

    func startCleanup() throws {
        guard acceptingWork else { throw ElementRegistryError.admissionClosed }
        guard cleanupTask == nil else { return }

        let cleanupOperation = self.cleanupOperation
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            if let cleanupOperation {
                await cleanupOperation()
            } else {
                await runCleanupLoop()
            }
            await cleanupDidExit()
        }
    }

    func cleanupTaskCount() -> Int {
        cleanupTask == nil ? 0 : 1
    }

    func shutdown() async {
        acceptingWork = false
        let task = cleanupTask
        task?.cancel()
        await task?.value
        cleanupTask = nil
        elementCache.removeAll()
        elementIDsByTraversalIdentity.removeAll()
        applicationNamesByPID.removeAll()
    }

    /// Binds a process ID to one exact application resource name. Rebinding a
    /// reused PID to a different process instance invalidates every cached
    /// element for that PID before the new identity can be observed.
    func bindApplication(name: String, pid: pid_t) {
        if let previousName = applicationNamesByPID[pid], previousName != name {
            removeCachedElements(forPID: pid)
        }
        applicationNamesByPID[pid] = name
    }

    /// Register a new element and generate an ID for it.
    /// - Parameters:
    ///   - element: The element data
    ///   - axElement: Optional AXUIElement reference
    ///   - pid: The process ID this element belongs to
    /// - Returns: The generated element ID
    public func registerElement(
        _ element: Exactmac_V1_Element,
        axElement: AXUIElement? = nil,
        pid: pid_t,
    ) throws -> String {
        guard acceptingWork else { throw ElementRegistryError.admissionClosed }
        return try registerElementUnchecked(element, axElement: axElement, pid: pid)
    }

    private func registerElementUnchecked(
        _ element: Exactmac_V1_Element,
        axElement: AXUIElement?,
        pid: pid_t,
    ) throws -> String {
        var reservedIDs = Set(elementCache.keys)
        let elementId = try allocateElementID(reservedIDs: &reservedIDs)
        var registeredElement = element
        registeredElement.elementID = elementId
        registeredElement.name = resourceName(elementID: elementId, pid: pid)
        if registeredElement.application.isEmpty {
            registeredElement.application = applicationNamesByPID[pid] ?? "applications/\(pid)"
        }
        let cachedElement = CachedElement(
            element: registeredElement,
            axElement: axElement,
            timestamp: clock(),
            pid: pid,
            scope: applicationNamesByPID[pid] ?? "applications/\(pid)",
            traversalIdentity: nil,
        )

        elementCache[elementId] = cachedElement
        logger.info("Registered element \(elementId, privacy: .private) for PID \(pid, privacy: .public)")
        return elementId
    }

    /// Converts and registers every element returned by one SDK traversal.
    /// The returned protobuf identity is the same identity cached for later
    /// GetElement and element-ID mutation calls.
    func registerTraversalElements(
        _ elements: [ExactMac.ElementData],
        pid: pid_t,
        scope requestedScope: String? = nil,
        applicationName expectedApplicationName: String? = nil,
    ) throws -> [Exactmac_V1_Element] {
        guard acceptingWork else { throw ElementRegistryError.admissionClosed }
        try Task.checkCancellation()
        if let expectedApplicationName {
            guard applicationNamesByPID[pid] == expectedApplicationName else {
                throw ElementRegistryError.applicationBindingMismatch
            }
        }

        let scope = requestedScope ?? applicationNamesByPID[pid] ?? "applications/\(pid)"
        var pending: [(
            id: String,
            identity: TraversalIdentity,
            cached: CachedElement,
            element: Exactmac_V1_Element,
        )] = []
        pending.reserveCapacity(elements.count)
        var traversalIdentities = Set<TraversalIdentity>()
        var reservedIDs = Set(elementCache.keys)
        for elementData in elements {
            try Task.checkCancellation()
            let component: TraversalIdentityComponent = if let axElement = elementData.axElement {
                .accessibilityElement(axElement)
            } else {
                .path(elementData.path)
            }
            let identity = TraversalIdentity(
                pid: pid,
                scope: scope,
                component: component,
            )
            guard traversalIdentities.insert(identity).inserted else {
                throw ElementRegistryError.duplicateTraversalIdentity
            }
            let parentApplication = applicationNamesByPID[pid] ?? "applications/\(pid)"
            let protoElement = Self.makeProtoElement(
                from: elementData,
                parentApplication: parentApplication,
            )
            let elementId: String
            if let existingID = elementIDsByTraversalIdentity[identity],
               elementCache[existingID] != nil
            {
                elementId = existingID
            } else {
                elementIDsByTraversalIdentity.removeValue(forKey: identity)
                elementId = try allocateElementID(reservedIDs: &reservedIDs)
            }
            var registeredElement = protoElement
            registeredElement.elementID = elementId
            registeredElement.name = resourceName(elementID: elementId, pid: pid)
            let cachedElement = CachedElement(
                element: registeredElement,
                axElement: elementData.axElement?.element,
                timestamp: clock(),
                pid: pid,
                scope: scope,
                traversalIdentity: identity,
            )
            pending.append((elementId, identity, cachedElement, registeredElement))
        }
        try Task.checkCancellation()

        let currentIDs = Set(pending.map(\.id))
        let staleIDs = elementCache.compactMap { elementID, cached -> String? in
            cached.pid == pid && cached.scope == scope && !currentIDs.contains(elementID)
                ? elementID
                : nil
        }
        for elementID in staleIDs {
            removeCachedElement(elementID)
        }
        for entry in pending {
            elementCache[entry.id] = entry.cached
            elementIDsByTraversalIdentity[entry.identity] = entry.id
            logger.info("Registered element \(entry.id, privacy: .private) for PID \(pid, privacy: .public)")
        }
        return pending.map(\.element)
    }

    private func allocateElementID(reservedIDs: inout Set<String>) throws -> String {
        for _ in 0 ..< 100 {
            let candidate = idGenerator()
            guard !candidate.isEmpty, reservedIDs.insert(candidate).inserted else {
                continue
            }
            return candidate
        }
        throw ElementRegistryError.identifierExhausted
    }

    private static func makeProtoElement(
        from elementData: ExactMac.ElementData,
        parentApplication: String,
    ) -> Exactmac_V1_Element {
        Exactmac_V1_Element.with {
            $0.application = parentApplication
            $0.role = elementData.role
            if let text = elementData.text {
                $0.text = text
            }
            if let x = elementData.x {
                $0.x = x
            }
            if let y = elementData.y {
                $0.y = y
            }
            if let width = elementData.width {
                $0.width = width
            }
            if let height = elementData.height {
                $0.height = height
            }
            if let enabled = elementData.enabled {
                $0.enabled = enabled
            }
            if let focused = elementData.focused {
                $0.focused = focused
            }
            $0.attributes = elementData.attributes
            $0.pathIndices = elementData.path
        }
    }

    /// Get an element by its ID.
    /// - Parameter elementId: The element ID
    /// - Returns: The element data if found and not expired
    /// - Note: This method does NOT refresh the access timestamp. If the element
    ///   expires between this call and its subsequent use (e.g., a click), the AX
    ///   call will fail. Call `touchElement(_:)` after a successful `getElement` to
    ///   extend the element's lifetime if it will be used after a delay. This is a
    ///   best-effort cache — AX elements are inherently ephemeral.
    public func getElement(_ elementId: String) -> Exactmac_V1_Element? {
        guard let cached = elementCache[elementId] else {
            logger.warning("Element \(elementId, privacy: .private) not found in cache")
            return nil
        }

        // Check if expired
        if clock().timeIntervalSince(cached.timestamp) > cacheExpiration {
            logger.warning("Element \(elementId, privacy: .private) expired, removing from cache")
            removeCachedElement(elementId)
            return nil
        }

        return cached.element
    }

    /// List the finite nonexpired element collection for one application.
    /// Results are sorted by canonical resource name for stable pagination.
    func listElements(forPID pid: pid_t) -> [Exactmac_V1_Element] {
        let now = clock()
        var expiredIDs: [String] = []
        var elements: [Exactmac_V1_Element] = []
        for (elementID, cached) in elementCache {
            if now.timeIntervalSince(cached.timestamp) > cacheExpiration {
                expiredIDs.append(elementID)
            } else if cached.pid == pid {
                elements.append(cached.element)
            }
        }
        for elementID in expiredIDs {
            removeCachedElement(elementID)
        }
        return elements.sorted { $0.name < $1.name }
    }

    /// Get an element only when the resource-name owner matches the registry
    /// owner captured during traversal.
    func getElement(_ elementId: String, expectedPID: pid_t) -> Exactmac_V1_Element? {
        guard let cached = elementCache[elementId] else {
            logger.warning("Element \(elementId, privacy: .private) not found in cache")
            return nil
        }
        if clock().timeIntervalSince(cached.timestamp) > cacheExpiration {
            logger.warning("Element \(elementId, privacy: .private) expired, removing from cache")
            removeCachedElement(elementId)
            return nil
        }
        guard cached.pid == expectedPID else {
            logger.warning(
                "Element \(elementId, privacy: .private) owner mismatch for PID \(expectedPID, privacy: .public)",
            )
            return nil
        }
        return cached.element
    }

    /// Refresh the access timestamp for a cached element, extending its lifetime.
    /// Call this after a successful `getElement` if the element will be used
    /// after a non-trivial delay, to avoid a TOCTOU race where the element
    /// expires between retrieval and use.
    /// - Parameter elementId: The element ID
    /// - Returns: True if the element was found and its timestamp refreshed
    public func touchElement(_ elementId: String) -> Bool {
        guard acceptingWork else { return false }
        guard let cached = elementCache[elementId] else { return false }

        if clock().timeIntervalSince(cached.timestamp) > cacheExpiration {
            removeCachedElement(elementId)
            return false
        }

        var updated = cached
        updated.timestamp = clock()
        elementCache[elementId] = updated
        return true
    }

    /// Get the AXUIElement reference for an element ID.
    /// - Parameter elementId: The element ID
    /// - Returns: The AXUIElement if available and not expired
    /// - Note: AXUIElement is thread-safe (CoreFoundation-based), but some callers
    ///         may need to call this from MainActor for other AppKit operations.
    public func getAXElement(_ elementId: String) async -> AXUIElement? {
        guard let cached = elementCache[elementId] else {
            logger.warning("Element \(elementId, privacy: .private) not found")
            return nil
        }

        // Check if expired
        if clock().timeIntervalSince(cached.timestamp) > cacheExpiration {
            logger.warning("Element \(elementId, privacy: .private) expired")
            removeCachedElement(elementId)
            return nil
        }

        return cached.axElement
    }

    /// Get an Accessibility object only when its registered owner matches the
    /// application component of the requested element resource name.
    func getAXElement(_ elementId: String, expectedPID: pid_t) -> AXUIElement? {
        guard let cached = elementCache[elementId] else {
            logger.warning("Element \(elementId, privacy: .private) not found")
            return nil
        }
        if clock().timeIntervalSince(cached.timestamp) > cacheExpiration {
            logger.warning("Element \(elementId, privacy: .private) expired")
            removeCachedElement(elementId)
            return nil
        }
        guard cached.pid == expectedPID else {
            logger.warning(
                "Element \(elementId, privacy: .private) AX owner mismatch for PID \(expectedPID, privacy: .public)",
            )
            return nil
        }
        return cached.axElement
    }

    /// Resolves one exact element only after mutation admission and proves it
    /// belongs to the request's application PID. Successful resolution also
    /// refreshes the ephemeral cache lifetime for the admitted operation.
    func resolveElementForMutation(
        _ elementId: String,
        expectedPID: pid_t,
        expectedScope: String? = nil,
    ) throws -> RegisteredElementMutationTarget {
        guard acceptingWork else {
            throw ElementMutationResolutionError.admissionClosed
        }
        guard var cached = elementCache[elementId] else {
            throw ElementMutationResolutionError.notFound
        }
        let now = clock()
        guard now.timeIntervalSince(cached.timestamp) <= cacheExpiration else {
            removeCachedElement(elementId)
            throw ElementMutationResolutionError.notFound
        }
        guard cached.pid == expectedPID else {
            throw ElementMutationResolutionError.ownerMismatch(
                expectedPID: expectedPID,
                actualPID: cached.pid,
            )
        }
        if let expectedScope, cached.scope != expectedScope {
            throw ElementMutationResolutionError.scopeMismatch(
                expected: expectedScope,
                actual: cached.scope,
            )
        }

        cached.timestamp = now
        elementCache[elementId] = cached
        return RegisteredElementMutationTarget(
            elementID: elementId,
            element: cached.element,
            axElement: cached.axElement,
            pid: cached.pid,
            scope: cached.scope,
        )
    }

    /// Update an existing element's data.
    /// - Parameters:
    ///   - elementId: The element ID
    ///   - element: New element data
    ///   - axElement: Optional new AXUIElement reference
    /// - Returns: True if update succeeded
    public func updateElement(
        _ elementId: String,
        element: Exactmac_V1_Element,
        axElement: AXUIElement? = nil,
    ) -> Bool {
        guard acceptingWork else { return false }
        guard let existing = elementCache[elementId] else { return false }
        if existing.traversalIdentity != nil, let axElement {
            guard let existingAXElement = existing.axElement,
                  CFEqual(existingAXElement, axElement)
            else {
                return false
            }
        }

        var updatedElement = element
        updatedElement.elementID = elementId
        updatedElement.name = resourceName(elementID: elementId, pid: existing.pid)
        let cachedElement = CachedElement(
            element: updatedElement,
            axElement: axElement ?? existing.axElement,
            timestamp: clock(),
            pid: existing.pid,
            scope: existing.scope,
            traversalIdentity: existing.traversalIdentity,
        )

        elementCache[elementId] = cachedElement
        logger.info("Updated element \(elementId, privacy: .private)")
        return true
    }

    private func resourceName(elementID: String, pid: pid_t) -> String {
        let applicationName = applicationNamesByPID[pid] ?? "applications/\(pid)"
        return "\(applicationName)/elements/\(elementID)"
    }

    /// Remove an element from the registry.
    /// - Parameter elementId: The element ID to remove
    public func removeElement(_ elementId: String) {
        if elementCache[elementId] != nil {
            removeCachedElement(elementId)
            logger.info("Removed element \(elementId, privacy: .private)")
        }
    }

    /// Get all element IDs for a specific process.
    /// - Parameter pid: The process ID
    /// - Returns: Array of element IDs belonging to the process
    public func getElementIds(forPid pid: pid_t) -> [String] {
        elementCache.filter { $0.value.pid == pid }.keys.map(\.self)
    }

    /// Clear all elements for a specific process (e.g., when app quits).
    /// - Parameter pid: The process ID
    /// - Returns: The number of cached element entries that were removed.
    public func clearElements(forPid pid: pid_t) -> Int {
        let count = removeCachedElements(forPID: pid)
        applicationNamesByPID.removeValue(forKey: pid)
        logger.info("Cleared \(count, privacy: .public) elements for PID \(pid, privacy: .public)")
        return count
    }

    /// Clears only one exact discovery scope without invalidating sibling
    /// application or window collections owned by the same process.
    public func clearElements(forPid pid: pid_t, scope: String) -> Int {
        let keys = elementCache.compactMap { elementID, cached in
            cached.pid == pid && cached.scope == scope ? elementID : nil
        }
        for elementID in keys {
            removeCachedElement(elementID)
        }
        logger.info(
            "Cleared \(keys.count, privacy: .public) elements for one PID-bound scope",
        )
        return keys.count
    }

    @discardableResult
    private func removeCachedElements(forPID pid: pid_t) -> Int {
        let keysToRemove = elementCache.filter { $0.value.pid == pid }.keys
        let count = keysToRemove.count
        for key in keysToRemove {
            removeCachedElement(key)
        }
        return count
    }

    /// Get cache statistics.
    /// - Returns: Dictionary with cache statistics
    public func getCacheStats() -> [String: Int] {
        let totalElements = elementCache.count
        let now = clock()
        let expiredElements = elementCache.count(where: {
            now.timeIntervalSince($0.value.timestamp) > cacheExpiration
        })

        return [
            "total_elements": totalElements,
            "expired_elements": expiredElements,
            "active_elements": totalElements - expiredElements,
        ]
    }

    /// Get the total count of cached elements.
    /// - Returns: Number of elements currently in cache
    public func getCachedElementCount() -> Int {
        elementCache.count
    }

    private func runCleanupLoop() async {
        // Run cleanup every 10 seconds
        while true {
            do {
                try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                cleanupExpiredElements()
            } catch {
                // Task was cancelled, exit
                break
            }
        }
    }

    private func cleanupDidExit() {
        cleanupTask = nil
    }

    private func cleanupExpiredElements() {
        let now = clock()
        let expiredKeys = elementCache.filter {
            now.timeIntervalSince($0.value.timestamp) > cacheExpiration
        }.keys

        for key in expiredKeys {
            removeCachedElement(key)
        }

        if !expiredKeys.isEmpty {
            logger.info("Cleaned up \(expiredKeys.count, privacy: .public) expired elements")
        }
    }

    /// Manually trigger cleanup of expired elements (for testing).
    func triggerCleanup() {
        cleanupExpiredElements()
    }

    private func removeCachedElement(_ elementID: String) {
        guard let cached = elementCache.removeValue(forKey: elementID) else {
            return
        }
        if let identity = cached.traversalIdentity,
           elementIDsByTraversalIdentity[identity] == elementID
        {
            elementIDsByTraversalIdentity.removeValue(forKey: identity)
        }
    }
}
