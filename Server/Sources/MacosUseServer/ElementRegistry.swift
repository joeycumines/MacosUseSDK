import ApplicationServices
import Foundation
import MacosUseProto
import MacosUseSDK
import OSLog

private let logger = MacosUseSDK.sdkLogger(category: "ElementRegistry")

/// Actor responsible for tracking element IDs and providing stable references.
/// Elements are ephemeral and IDs are generated server-side. This registry
/// maintains mappings between IDs and element data/AXUIElement references.
public actor ElementRegistry {
    public static let shared = ElementRegistry()

    /// Structure holding cached element information
    private struct CachedElement {
        let element: Macosusesdk_Type_Element
        let axElement: AXUIElement?
        let timestamp: Date
        let pid: pid_t
    }

    /// In-memory cache of elements by ID
    private var elementCache: [String: CachedElement] = [:]

    /// Cache expiration time (elements expire after 30 seconds)
    private let cacheExpiration: TimeInterval = 30.0

    private init() {
        logger.info("Initialized")

        // Start cleanup task
        Task {
            await startCleanupTask()
        }
    }

    /// Register a new element and generate an ID for it.
    /// - Parameters:
    ///   - element: The element data
    ///   - axElement: Optional AXUIElement reference
    ///   - pid: The process ID this element belongs to
    /// - Returns: The generated element ID
    public func registerElement(
        _ element: Macosusesdk_Type_Element,
        axElement: AXUIElement? = nil,
        pid: pid_t,
    ) -> String {
        let elementId = generateElementId()
        let cachedElement = CachedElement(
            element: element,
            axElement: axElement,
            timestamp: Date(),
            pid: pid,
        )

        elementCache[elementId] = cachedElement
        logger.info("Registered element \(elementId, privacy: .private) for PID \(pid, privacy: .public)")
        return elementId
    }

    /// Get an element by its ID.
    /// - Parameter elementId: The element ID
    /// - Returns: The element data if found and not expired
    public func getElement(_ elementId: String) -> Macosusesdk_Type_Element? {
        guard let cached = elementCache[elementId] else {
            logger.warning("Element \(elementId, privacy: .private) not found in cache")
            return nil
        }

        // Check if expired
        if Date().timeIntervalSince(cached.timestamp) > cacheExpiration {
            logger.warning("Element \(elementId, privacy: .private) expired, removing from cache")
            elementCache.removeValue(forKey: elementId)
            return nil
        }

        return cached.element
    }

    /// Get the AXUIElement reference for an element ID.
    /// - Parameter elementId: The element ID
    /// - Returns: The AXUIElement if available and not expired
    /// - Note: This MUST be called from MainActor context since AXUIElement requires it
    public func getAXElement(_ elementId: String) async -> AXUIElement? {
        guard let cached = elementCache[elementId] else {
            logger.warning("Element \(elementId, privacy: .private) not found")
            return nil
        }

        // Check if expired
        if Date().timeIntervalSince(cached.timestamp) > cacheExpiration {
            logger.warning("Element \(elementId, privacy: .private) expired")
            elementCache.removeValue(forKey: elementId)
            return nil
        }

        return cached.axElement
    }

    /// Update an existing element's data.
    /// - Parameters:
    ///   - elementId: The element ID
    ///   - element: New element data
    ///   - axElement: Optional new AXUIElement reference
    /// - Returns: True if update succeeded
    public func updateElement(
        _ elementId: String,
        element: Macosusesdk_Type_Element,
        axElement: AXUIElement? = nil,
    ) -> Bool {
        guard let existing = elementCache[elementId] else { return false }

        let cachedElement = CachedElement(
            element: element,
            axElement: axElement ?? existing.axElement,
            timestamp: Date(),
            pid: existing.pid,
        )

        elementCache[elementId] = cachedElement
        logger.info("Updated element \(elementId, privacy: .private)")
        return true
    }

    /// Remove an element from the registry.
    /// - Parameter elementId: The element ID to remove
    public func removeElement(_ elementId: String) {
        if elementCache.removeValue(forKey: elementId) != nil {
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
    public func clearElements(forPid pid: pid_t) {
        let keysToRemove = elementCache.filter { $0.value.pid == pid }.keys
        for key in keysToRemove {
            elementCache.removeValue(forKey: key)
        }
        logger.info("Cleared \(keysToRemove.count, privacy: .public) elements for PID \(pid, privacy: .public)")
    }

    /// Get cache statistics.
    /// - Returns: Dictionary with cache statistics
    public func getCacheStats() -> [String: Int] {
        let totalElements = elementCache.count
        let expiredElements = elementCache.count(where: {
            Date().timeIntervalSince($0.value.timestamp) > cacheExpiration
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

    private func generateElementId() -> String {
        // Generate a unique ID using timestamp and random component
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = Int.random(in: 0 ..< 1_000_000)
        return "elem_\(timestamp)_\(random)"
    }

    private func startCleanupTask() async {
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

    private func cleanupExpiredElements() {
        let now = Date()
        let expiredKeys = elementCache.filter {
            now.timeIntervalSince($0.value.timestamp) > cacheExpiration
        }.keys

        for key in expiredKeys {
            elementCache.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            logger.info("Cleaned up \(expiredKeys.count, privacy: .public) expired elements")
        }
    }
}
