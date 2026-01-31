import ApplicationServices
import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for ElementRegistry actor that manages UI element registrations.
/// Uses injectable clock for TTL testing without real delays.
final class ElementRegistryTests: XCTestCase {
    // MARK: - Test Helpers

    /// Creates a test registry with injectable dependencies.
    /// - Parameters:
    ///   - ttl: Cache expiration time
    ///   - currentTime: Mutable reference to simulated current time
    ///   - idSequence: Sequence of IDs to generate
    /// - Returns: Configured ElementRegistry for testing
    private func makeTestRegistry(
        ttl: TimeInterval = 30.0,
        currentTime: CurrentTimeMock,
        idSequence: IDSequenceMock,
    ) -> ElementRegistry {
        ElementRegistry(
            cacheExpiration: ttl,
            clock: { currentTime.now },
            idGenerator: { idSequence.next() },
            startCleanup: false,
        )
    }

    /// Creates a minimal test element with the given role and optional text.
    private func makeElement(role: String = "button", text: String? = nil) -> Macosusesdk_Type_Element {
        var element = Macosusesdk_Type_Element()
        element.role = role
        if let text {
            element.text = text
        }
        return element
    }

    // MARK: - Registration Tests

    func testRegisterElementReturnsGeneratedId() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["elem_test_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "button", text: "OK")
        let elementId = await registry.registerElement(element, pid: 1234)

        XCTAssertEqual(elementId, "elem_test_001")
    }

    func testRegisterElementIncrementsCount() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["id1", "id2", "id3"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 0)

        _ = await registry.registerElement(makeElement(), pid: 100)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        _ = await registry.registerElement(makeElement(), pid: 100)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)

        _ = await registry.registerElement(makeElement(), pid: 200)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 3)
    }

    func testRegisterElementWithAxElement() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_elem_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // Create a mock AXUIElement (system application - always available)
        let axElement = AXUIElementCreateSystemWide()
        let element = makeElement(role: "group")

        let elementId = await registry.registerElement(element, axElement: axElement, pid: 9999)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNotNil(storedAx)
    }

    func testRegisterElementWithNilAxElement() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["no_ax_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "text")
        let elementId = await registry.registerElement(element, axElement: nil, pid: 100)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNil(storedAx)
    }

    // MARK: - Retrieval Tests

    func testGetElementReturnsRegisteredElement() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["get_test_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "checkbox", text: "Enable feature")
        let elementId = await registry.registerElement(element, pid: 500)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.role, "checkbox")
        XCTAssertEqual(retrieved?.text, "Enable feature")
    }

    func testGetElementReturnsNilForUnknownId() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: [])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let retrieved = await registry.getElement("nonexistent_id_12345")
        XCTAssertNil(retrieved)
    }

    func testGetAXElementReturnsNilForUnknownId() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: [])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let axElement = await registry.getAXElement("nonexistent_ax_id")
        XCTAssertNil(axElement)
    }

    // MARK: - Update Tests

    func testUpdateElementModifiesStoredData() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["update_test_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let original = makeElement(role: "button", text: "Submit")
        let elementId = await registry.registerElement(original, pid: 100)

        var updated = makeElement(role: "button", text: "Cancel")
        updated.enabled = true

        let success = await registry.updateElement(elementId, element: updated)
        XCTAssertTrue(success)

        let retrieved = await registry.getElement(elementId)
        XCTAssertEqual(retrieved?.text, "Cancel")
        XCTAssertEqual(retrieved?.enabled, true)
    }

    func testUpdateElementReturnsFalseForUnknownId() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: [])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let success = await registry.updateElement("nonexistent_id", element: element)
        XCTAssertFalse(success)
    }

    func testUpdateElementPreservesAxElementWhenNotProvided() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_preserve_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let axElement = AXUIElementCreateSystemWide()
        let original = makeElement(role: "group")
        let elementId = await registry.registerElement(original, axElement: axElement, pid: 100)

        let updated = makeElement(role: "toolbar")
        _ = await registry.updateElement(elementId, element: updated, axElement: nil)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNotNil(storedAx, "AXUIElement should be preserved when update doesn't provide a new one")
    }

    func testUpdateElementReplacesAxElementWhenProvided() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_replace_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let original = makeElement(role: "group")
        let elementId = await registry.registerElement(original, axElement: nil, pid: 100)

        let newAxElement = AXUIElementCreateSystemWide()
        let updated = makeElement(role: "toolbar")
        _ = await registry.updateElement(elementId, element: updated, axElement: newAxElement)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNotNil(storedAx, "AXUIElement should be set when provided in update")
    }

    func testUpdateElementRefreshesTimestamp() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["timestamp_refresh_001"])
        let registry = makeTestRegistry(ttl: 10.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = await registry.registerElement(element, pid: 100)

        // Advance time to just before expiration
        timeMock.advance(by: 9.0)

        // Update should refresh timestamp
        let updated = makeElement(role: "updated")
        _ = await registry.updateElement(elementId, element: updated)

        // Advance time another 9 seconds (total 18s from start, but only 9s from update)
        timeMock.advance(by: 9.0)

        // Element should still be valid (not expired)
        let retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved, "Element should still be valid after update refreshed timestamp")
    }

    // MARK: - Expiration / TTL Tests

    func testGetElementReturnsNilWhenExpired() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["expire_test_001"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = await registry.registerElement(element, pid: 100)

        // Advance time past expiration
        timeMock.advance(by: 31.0)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNil(retrieved, "Element should be nil when expired")
    }

    func testGetAXElementReturnsNilWhenExpired() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_expire_001"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        let axElement = AXUIElementCreateSystemWide()
        let element = makeElement()
        let elementId = await registry.registerElement(element, axElement: axElement, pid: 100)

        // Advance time past expiration
        timeMock.advance(by: 31.0)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNil(storedAx, "AXUIElement should be nil when expired")
    }

    func testElementNotExpiredJustBeforeTTL() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["just_before_ttl_001"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = await registry.registerElement(element, pid: 100)

        // Advance time to just before expiration (29.9 seconds)
        timeMock.advance(by: 29.9)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved, "Element should still be valid just before TTL")
    }

    func testExpiredElementIsRemovedFromCache() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["remove_on_expire_001"])
        let registry = makeTestRegistry(ttl: 10.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = await registry.registerElement(element, pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        // Advance time past expiration
        timeMock.advance(by: 11.0)

        // Trigger retrieval which removes expired elements
        _ = await registry.getElement(elementId)

        // Element should now be removed from cache
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Removal Tests

    func testRemoveElementDecreasesCount() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["remove_001", "remove_002"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let id1 = await registry.registerElement(makeElement(), pid: 100)
        let id2 = await registry.registerElement(makeElement(), pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)

        await registry.removeElement(id1)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        await registry.removeElement(id2)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 0)
    }

    func testRemoveElementMakesItUnretrievable() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["remove_retrieve_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "window")
        let elementId = await registry.registerElement(element, pid: 100)

        var retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved)

        await registry.removeElement(elementId)

        retrieved = await registry.getElement(elementId)
        XCTAssertNil(retrieved)
    }

    func testRemoveNonExistentElementIsNoOp() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["existing_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = await registry.registerElement(makeElement(), pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        // Remove nonexistent element - should not affect count
        await registry.removeElement("nonexistent_element_id")
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - PID-Based Operations Tests

    func testGetElementIdsForPidReturnsCorrectIds() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["pid100_a", "pid100_b", "pid200_a"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let id1 = await registry.registerElement(makeElement(), pid: 100)
        let id2 = await registry.registerElement(makeElement(), pid: 100)
        let id3 = await registry.registerElement(makeElement(), pid: 200)

        let pid100Ids = await registry.getElementIds(forPid: 100)
        XCTAssertEqual(Set(pid100Ids), Set([id1, id2]))

        let pid200Ids = await registry.getElementIds(forPid: 200)
        XCTAssertEqual(pid200Ids, [id3])
    }

    func testGetElementIdsForPidReturnsEmptyForUnknownPid() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["some_id"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = await registry.registerElement(makeElement(), pid: 100)

        let unknownPidIds = await registry.getElementIds(forPid: 99999)
        XCTAssertEqual(unknownPidIds, [])
    }

    func testClearElementsForPidRemovesOnlyThatPid() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["p1_a", "p1_b", "p2_a", "p3_a"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 200)
        _ = await registry.registerElement(makeElement(), pid: 300)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 4)

        await registry.clearElements(forPid: 100)

        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)
        let pid100Ids = await registry.getElementIds(forPid: 100)
        XCTAssertEqual(pid100Ids, [])
        let pid200Ids = await registry.getElementIds(forPid: 200)
        XCTAssertEqual(pid200Ids.count, 1)
        let pid300Ids = await registry.getElementIds(forPid: 300)
        XCTAssertEqual(pid300Ids.count, 1)
    }

    func testClearElementsForPidWithNoMatchingElements() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["pid100_only"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = await registry.registerElement(makeElement(), pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        // Clear a PID with no elements - should not affect anything
        await registry.clearElements(forPid: 999)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Cache Statistics Tests

    func testGetCacheStatsWithNoElements() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: [])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let stats = await registry.getCacheStats()
        XCTAssertEqual(stats["total_elements"], 0)
        XCTAssertEqual(stats["expired_elements"], 0)
        XCTAssertEqual(stats["active_elements"], 0)
    }

    func testGetCacheStatsWithActiveElements() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["stat1", "stat2", "stat3"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 200)

        let stats = await registry.getCacheStats()
        XCTAssertEqual(stats["total_elements"], 3)
        XCTAssertEqual(stats["expired_elements"], 0)
        XCTAssertEqual(stats["active_elements"], 3)
    }

    func testGetCacheStatsWithMixedActiveAndExpired() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["old1", "old2", "new1"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        // Register 2 elements at time 0
        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 100)

        // Advance time to 35 seconds (past TTL)
        timeMock.advance(by: 35.0)

        // Register 1 more element at time 35
        _ = await registry.registerElement(makeElement(), pid: 200)

        let stats = await registry.getCacheStats()
        XCTAssertEqual(stats["total_elements"], 3)
        XCTAssertEqual(stats["expired_elements"], 2)
        XCTAssertEqual(stats["active_elements"], 1)
    }

    // MARK: - Cleanup Tests

    func testTriggerCleanupRemovesExpiredElements() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["cleanup1", "cleanup2", "cleanup3"])
        let registry = makeTestRegistry(ttl: 10.0, currentTime: timeMock, idSequence: idMock)

        // Register 2 elements at time 0
        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 100)

        // Advance time past TTL
        timeMock.advance(by: 15.0)

        // Register 1 more element at time 15
        _ = await registry.registerElement(makeElement(), pid: 200)

        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 3)

        // Trigger cleanup
        await registry.triggerCleanup()

        // Only the fresh element should remain
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)
    }

    func testTriggerCleanupWithNoExpiredElements() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["fresh1", "fresh2"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        _ = await registry.registerElement(makeElement(), pid: 100)
        _ = await registry.registerElement(makeElement(), pid: 100)

        // Don't advance time - elements are fresh
        await registry.triggerCleanup()

        let count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentRegistrations() async {
        let timeMock = CurrentTimeMock()
        var idCounter = 0
        let lock = NSLock()
        let idMock = IDSequenceMock {
            lock.lock()
            defer { lock.unlock() }
            idCounter += 1
            return "concurrent_\(idCounter)"
        }
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // Prepare elements outside of task group to avoid Sendable issues
        var elements: [Macosusesdk_Type_Element] = []
        for i in 0 ..< 100 {
            elements.append(makeElement(role: "item\(i)"))
        }

        // Register 100 elements concurrently
        await withTaskGroup(of: String.self) { group in
            for i in 0 ..< 100 {
                let element = elements[i]
                let pid = pid_t(i % 10)
                group.addTask {
                    await registry.registerElement(element, pid: pid)
                }
            }

            var registeredIds = Set<String>()
            for await id in group {
                registeredIds.insert(id)
            }
            XCTAssertEqual(registeredIds.count, 100, "All registrations should produce unique IDs")
        }

        let finalCount = await registry.getCachedElementCount()
        XCTAssertEqual(finalCount, 100)
    }

    func testConcurrentReadsAndWrites() async {
        let timeMock = CurrentTimeMock()
        var idCounter = 0
        let lock = NSLock()
        let idMock = IDSequenceMock {
            lock.lock()
            defer { lock.unlock() }
            idCounter += 1
            return "rw_\(idCounter)"
        }
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // Pre-register some elements
        var preIds: [String] = []
        for _ in 0 ..< 10 {
            let id = await registry.registerElement(makeElement(), pid: 100)
            preIds.append(id)
        }

        // Prepare elements outside of task group to avoid Sendable issues
        let writerElement = makeElement()
        let updaterElement = makeElement(role: "updated")
        let capturedIds = preIds

        // Concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            // Readers
            for id in capturedIds {
                group.addTask {
                    for _ in 0 ..< 10 {
                        _ = await registry.getElement(id)
                    }
                }
            }

            // Writers
            for _ in 0 ..< 20 {
                group.addTask {
                    _ = await registry.registerElement(writerElement, pid: 200)
                }
            }

            // Updaters
            for id in capturedIds.prefix(5) {
                group.addTask {
                    _ = await registry.updateElement(id, element: updaterElement)
                }
            }
        }

        // Verify no crashes and count is correct
        let finalCount = await registry.getCachedElementCount()
        XCTAssertEqual(finalCount, 30) // 10 pre + 20 new
    }

    // MARK: - Edge Cases

    func testRegisterWithZeroPid() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["zero_pid_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // PID 0 is a valid edge case (kernel)
        let elementId = await registry.registerElement(makeElement(), pid: 0)
        let ids = await registry.getElementIds(forPid: 0)
        XCTAssertEqual(ids, [elementId])
    }

    func testRegisterWithNegativePid() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["neg_pid_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // Negative PIDs shouldn't exist but registry should handle them
        let elementId = await registry.registerElement(makeElement(), pid: -1)
        let ids = await registry.getElementIds(forPid: -1)
        XCTAssertEqual(ids, [elementId])
    }

    func testElementWithEmptyRole() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["empty_role_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "")
        let elementId = await registry.registerElement(element, pid: 100)

        let retrieved = await registry.getElement(elementId)
        XCTAssertEqual(retrieved?.role, "")
    }

    func testMultipleUpdatesToSameElement() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["multi_update_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let elementId = await registry.registerElement(makeElement(text: "v1"), pid: 100)

        for i in 2 ... 10 {
            let updated = makeElement(text: "v\(i)")
            let success = await registry.updateElement(elementId, element: updated)
            XCTAssertTrue(success)
        }

        let final = await registry.getElement(elementId)
        XCTAssertEqual(final?.text, "v10")
    }

    func testVeryShortTTL() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["short_ttl_001"])
        let registry = makeTestRegistry(ttl: 0.001, currentTime: timeMock, idSequence: idMock)

        let elementId = await registry.registerElement(makeElement(), pid: 100)

        // Even a tiny advance should expire it
        timeMock.advance(by: 0.002)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNil(retrieved)
    }

    func testVeryLongTTL() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["long_ttl_001"])
        let registry = makeTestRegistry(ttl: 86400 * 365, currentTime: timeMock, idSequence: idMock) // 1 year

        let elementId = await registry.registerElement(makeElement(), pid: 100)

        // Advance 364 days - still valid
        timeMock.advance(by: 86400 * 364)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved)
    }
}

// MARK: - Test Mocks

/// Mock for controllable time in tests.
private final class CurrentTimeMock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(startTime: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        _now = startTime
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        lock.unlock()
    }

    func set(to date: Date) {
        lock.lock()
        _now = date
        lock.unlock()
    }
}

/// Mock for generating predictable element IDs.
private final class IDSequenceMock: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]
    private var index = 0
    private let generator: (() -> String)?

    /// Initialize with a fixed sequence of IDs.
    init(ids: [String]) {
        self.ids = ids
        generator = nil
    }

    /// Initialize with a custom generator function.
    init(generator: @escaping () -> String) {
        ids = []
        self.generator = generator
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let generator {
            return generator()
        }

        guard index < ids.count else {
            let fallback = "fallback_\(index)"
            index += 1
            return fallback
        }

        let id = ids[index]
        index += 1
        return id
    }
}
