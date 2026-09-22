import ApplicationServices
import ExactMacProto
@testable import ExactMacServer
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
        )
    }

    /// Creates a minimal test element with the given role and optional text.
    private func makeElement(role: String = "button", text: String? = nil) -> Exactmac_V1_Element {
        var element = Exactmac_V1_Element()
        element.role = role
        if let text {
            element.text = text
        }
        return element
    }

    // MARK: - Registration Tests

    func testRegisterElementReturnsGeneratedId() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["elem_test_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "button", text: "OK")
        let elementId = try await registry.registerElement(element, pid: 1234)

        XCTAssertEqual(elementId, "elem_test_001")
    }

    func testRegisterElementCachesGeneratedIdentity() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["elem_server_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        var element = makeElement(role: "button", text: "OK")
        element.elementID = "untrusted-caller-id"
        element.name = "applications/9999/elements/untrusted-caller-id"
        let elementId = try await registry.registerElement(element, pid: 1234)

        let retrieved = await registry.getElement(elementId)
        XCTAssertEqual(elementId, "elem_server_001")
        XCTAssertEqual(retrieved?.elementID, elementId)
        XCTAssertEqual(retrieved?.name, "applications/1234/elements/elem_server_001")
        XCTAssertNotEqual(retrieved?.elementID, "untrusted-caller-id")
        XCTAssertNotEqual(retrieved?.name, element.name)
    }

    func testRegisterElementIncrementsCount() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["id1", "id2", "id3"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 0)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)

        _ = try await registry.registerElement(makeElement(), pid: 200)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 3)
    }

    func testRegisterElementWithAxElement() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_elem_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // Create a mock AXUIElement (system application - always available)
        let axElement = AXUIElementCreateSystemWide()
        let element = makeElement(role: "group")

        let elementId = try await registry.registerElement(element, axElement: axElement, pid: 9999)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNotNil(storedAx)
    }

    func testRegisterElementWithNilAxElement() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["no_ax_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "text")
        let elementId = try await registry.registerElement(element, axElement: nil, pid: 100)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNil(storedAx)
    }

    // MARK: - Retrieval Tests

    func testGetElementReturnsRegisteredElement() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["get_test_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "checkbox", text: "Enable feature")
        let elementId = try await registry.registerElement(element, pid: 500)

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

    func testGetElementAndAXRejectResourceOwnerMismatch() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["owned_query_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)
        let axElement = AXUIElementCreateSystemWide()
        let elementId = try await registry.registerElement(
            makeElement(role: "button"),
            axElement: axElement,
            pid: 1234,
        )

        let ownedElement = await registry.getElement(elementId, expectedPID: 1234)
        let foreignElement = await registry.getElement(elementId, expectedPID: 5678)
        let ownedAX = await registry.getAXElement(elementId, expectedPID: 1234)
        let foreignAX = await registry.getAXElement(elementId, expectedPID: 5678)

        XCTAssertEqual(ownedElement?.name, "applications/1234/elements/owned_query_001")
        XCTAssertNotNil(ownedAX)
        XCTAssertNil(foreignElement)
        XCTAssertNil(foreignAX)
    }

    func testListElementsReturnsOnlyNonexpiredOwnerResourcesInCanonicalOrder() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["expired", "z-last", "a-first", "foreign"])
        let registry = makeTestRegistry(ttl: 10, currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(role: "expired"), pid: 1234)
        timeMock.advance(by: 11)
        _ = try await registry.registerElement(makeElement(role: "last"), pid: 1234)
        _ = try await registry.registerElement(makeElement(role: "first"), pid: 1234)
        _ = try await registry.registerElement(makeElement(role: "foreign"), pid: 5678)

        let elements = await registry.listElements(forPID: 1234)
        let cachedCount = await registry.getCachedElementCount()

        XCTAssertEqual(elements.map(\.name), [
            "applications/1234/elements/a-first",
            "applications/1234/elements/z-last",
        ])
        XCTAssertEqual(elements.map(\.role), ["first", "last"])
        XCTAssertEqual(cachedCount, 3)
    }

    func testGetAXElementReturnsNilForUnknownId() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: [])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let axElement = await registry.getAXElement("nonexistent_ax_id")
        XCTAssertNil(axElement)
    }

    func testMutationResolutionReturnsExactOwnedSnapshotAndRefreshesTimestamp() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["owned_mutation_001"])
        let registry = makeTestRegistry(ttl: 10, currentTime: timeMock, idSequence: idMock)
        let axElement = AXUIElementCreateSystemWide()
        let elementId = try await registry.registerElement(
            makeElement(role: "AXTextField", text: "before"),
            axElement: axElement,
            pid: 1234,
        )
        timeMock.advance(by: 9)

        let target = try await registry.resolveElementForMutation(
            elementId,
            expectedPID: 1234,
        )
        timeMock.advance(by: 9)

        XCTAssertEqual(target.elementID, elementId)
        XCTAssertEqual(target.pid, 1234)
        XCTAssertEqual(target.element.text, "before")
        XCTAssertNotNil(target.axElement)
        let refreshedElement = await registry.getElement(elementId)
        XCTAssertNotNil(refreshedElement)
    }

    func testMutationResolutionRejectsOwnerMismatchExpiredAndClosedAdmission() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["owned_mutation_002", "owned_mutation_003"])
        let registry = makeTestRegistry(ttl: 10, currentTime: timeMock, idSequence: idMock)
        let elementId = try await registry.registerElement(makeElement(), pid: 111)

        do {
            _ = try await registry.resolveElementForMutation(elementId, expectedPID: 222)
            XCTFail("Expected cross-owner element resolution to fail")
        } catch let error as ElementMutationResolutionError {
            XCTAssertEqual(error, .ownerMismatch(expectedPID: 222, actualPID: 111))
        }

        timeMock.advance(by: 11)
        do {
            _ = try await registry.resolveElementForMutation(elementId, expectedPID: 111)
            XCTFail("Expected expired element resolution to fail")
        } catch let error as ElementMutationResolutionError {
            XCTAssertEqual(error, .notFound)
        }

        let closedId = try await registry.registerElement(makeElement(), pid: 111)
        await registry.shutdown()
        do {
            _ = try await registry.resolveElementForMutation(closedId, expectedPID: 111)
            XCTFail("Expected closed registry admission to fail")
        } catch let error as ElementMutationResolutionError {
            XCTAssertEqual(error, .admissionClosed)
        }
    }

    // MARK: - Update Tests

    func testUpdateElementModifiesStoredData() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["update_test_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let original = makeElement(role: "button", text: "Submit")
        let elementId = try await registry.registerElement(original, pid: 100)

        var updated = makeElement(role: "button", text: "Cancel")
        updated.enabled = true

        let success = await registry.updateElement(elementId, element: updated)
        XCTAssertTrue(success)

        let retrieved = await registry.getElement(elementId)
        XCTAssertEqual(retrieved?.text, "Cancel")
        XCTAssertEqual(retrieved?.enabled, true)
    }

    func testUpdateElementPreservesRegistryIdentity() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["update_identity_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let elementId = try await registry.registerElement(makeElement(role: "button"), pid: 100)
        var updated = makeElement(role: "button", text: "Updated")
        updated.elementID = "wrong-replacement-id"
        updated.name = "applications/999/elements/wrong-replacement-id"

        let success = await registry.updateElement(elementId, element: updated)
        let retrieved = await registry.getElement(elementId)

        XCTAssertTrue(success)
        XCTAssertEqual(retrieved?.elementID, elementId)
        XCTAssertEqual(retrieved?.name, "applications/100/elements/update_identity_001")
        XCTAssertNotEqual(retrieved?.elementID, "wrong-replacement-id")
        XCTAssertNotEqual(retrieved?.name, updated.name)
    }

    func testUpdateElementReturnsFalseForUnknownId() async {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: [])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let success = await registry.updateElement("nonexistent_id", element: element)
        XCTAssertFalse(success)
    }

    func testUpdateElementPreservesAxElementWhenNotProvided() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_preserve_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let axElement = AXUIElementCreateSystemWide()
        let original = makeElement(role: "group")
        let elementId = try await registry.registerElement(original, axElement: axElement, pid: 100)

        let updated = makeElement(role: "toolbar")
        _ = await registry.updateElement(elementId, element: updated, axElement: nil)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNotNil(storedAx, "AXUIElement should be preserved when update doesn't provide a new one")
    }

    func testUpdateElementReplacesAxElementWhenProvided() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_replace_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let original = makeElement(role: "group")
        let elementId = try await registry.registerElement(original, axElement: nil, pid: 100)

        let newAxElement = AXUIElementCreateSystemWide()
        let updated = makeElement(role: "toolbar")
        _ = await registry.updateElement(elementId, element: updated, axElement: newAxElement)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNotNil(storedAx, "AXUIElement should be set when provided in update")
    }

    func testUpdateElementRefreshesTimestamp() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["timestamp_refresh_001"])
        let registry = makeTestRegistry(ttl: 10.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = try await registry.registerElement(element, pid: 100)

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

    func testGetElementReturnsNilWhenExpired() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["expire_test_001"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = try await registry.registerElement(element, pid: 100)

        // Advance time past expiration
        timeMock.advance(by: 31.0)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNil(retrieved, "Element should be nil when expired")
    }

    func testGetAXElementReturnsNilWhenExpired() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["ax_expire_001"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        let axElement = AXUIElementCreateSystemWide()
        let element = makeElement()
        let elementId = try await registry.registerElement(element, axElement: axElement, pid: 100)

        // Advance time past expiration
        timeMock.advance(by: 31.0)

        let storedAx = await registry.getAXElement(elementId)
        XCTAssertNil(storedAx, "AXUIElement should be nil when expired")
    }

    func testElementNotExpiredJustBeforeTTL() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["just_before_ttl_001"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = try await registry.registerElement(element, pid: 100)

        // Advance time to just before expiration (29.9 seconds)
        timeMock.advance(by: 29.9)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved, "Element should still be valid just before TTL")
    }

    func testExpiredElementIsRemovedFromCache() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["remove_on_expire_001"])
        let registry = makeTestRegistry(ttl: 10.0, currentTime: timeMock, idSequence: idMock)

        let element = makeElement()
        let elementId = try await registry.registerElement(element, pid: 100)
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

    func testRemoveElementDecreasesCount() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["remove_001", "remove_002"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let id1 = try await registry.registerElement(makeElement(), pid: 100)
        let id2 = try await registry.registerElement(makeElement(), pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)

        await registry.removeElement(id1)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        await registry.removeElement(id2)
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 0)
    }

    func testRemoveElementMakesItUnretrievable() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["remove_retrieve_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "window")
        let elementId = try await registry.registerElement(element, pid: 100)

        var retrieved = await registry.getElement(elementId)
        XCTAssertNotNil(retrieved)

        await registry.removeElement(elementId)

        retrieved = await registry.getElement(elementId)
        XCTAssertNil(retrieved)
    }

    func testRemoveNonExistentElementIsNoOp() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["existing_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        // Remove nonexistent element - should not affect count
        await registry.removeElement("nonexistent_element_id")
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - PID-Based Operations Tests

    func testGetElementIdsForPidReturnsCorrectIds() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["pid100_a", "pid100_b", "pid200_a"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let id1 = try await registry.registerElement(makeElement(), pid: 100)
        let id2 = try await registry.registerElement(makeElement(), pid: 100)
        let id3 = try await registry.registerElement(makeElement(), pid: 200)

        let pid100Ids = await registry.getElementIds(forPid: 100)
        XCTAssertEqual(Set(pid100Ids), Set([id1, id2]))

        let pid200Ids = await registry.getElementIds(forPid: 200)
        XCTAssertEqual(pid200Ids, [id3])
    }

    func testGetElementIdsForPidReturnsEmptyForUnknownPid() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["some_id"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)

        let unknownPidIds = await registry.getElementIds(forPid: 99999)
        XCTAssertEqual(unknownPidIds, [])
    }

    func testClearElementsForPidRemovesOnlyThatPid() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["p1_a", "p1_b", "p2_a", "p3_a"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 200)
        _ = try await registry.registerElement(makeElement(), pid: 300)
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

    func testClearElementsForPidWithNoMatchingElements() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["pid100_only"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)

        // Clear a PID with no elements - should not affect anything
        let removed = await registry.clearElements(forPid: 999)
        XCTAssertEqual(removed, 0, "Should report zero entries removed for unknown PID")
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)
    }

    func testClearElementsForPidReturnValueReflectsRemovalCount() async throws {
        // The return value of clearElements(forPid:) is consumed by the
        // findElements/findRegionElements forceRefresh path to log how many
        // stale entries were evicted; pin the contract here.
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["p1_a", "p1_b", "p1_c", "p2_a"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 200)

        let removed = await registry.clearElements(forPid: 100)
        XCTAssertEqual(removed, 3, "Should report exactly the count of entries removed for the target PID")

        let count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1, "Other PIDs' entries must remain after a targeted clear")
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

    func testGetCacheStatsWithActiveElements() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["stat1", "stat2", "stat3"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 200)

        let stats = await registry.getCacheStats()
        XCTAssertEqual(stats["total_elements"], 3)
        XCTAssertEqual(stats["expired_elements"], 0)
        XCTAssertEqual(stats["active_elements"], 3)
    }

    func testGetCacheStatsWithMixedActiveAndExpired() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["old1", "old2", "new1"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        // Register 2 elements at time 0
        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)

        // Advance time to 35 seconds (past TTL)
        timeMock.advance(by: 35.0)

        // Register 1 more element at time 35
        _ = try await registry.registerElement(makeElement(), pid: 200)

        let stats = await registry.getCacheStats()
        XCTAssertEqual(stats["total_elements"], 3)
        XCTAssertEqual(stats["expired_elements"], 2)
        XCTAssertEqual(stats["active_elements"], 1)
    }

    // MARK: - Cleanup Tests

    func testTriggerCleanupRemovesExpiredElements() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["cleanup1", "cleanup2", "cleanup3"])
        let registry = makeTestRegistry(ttl: 10.0, currentTime: timeMock, idSequence: idMock)

        // Register 2 elements at time 0
        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)

        // Advance time past TTL
        timeMock.advance(by: 15.0)

        // Register 1 more element at time 15
        _ = try await registry.registerElement(makeElement(), pid: 200)

        var count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 3)

        // Trigger cleanup
        await registry.triggerCleanup()

        // Only the fresh element should remain
        count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 1)
    }

    func testTriggerCleanupWithNoExpiredElements() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["fresh1", "fresh2"])
        let registry = makeTestRegistry(ttl: 30.0, currentTime: timeMock, idSequence: idMock)

        _ = try await registry.registerElement(makeElement(), pid: 100)
        _ = try await registry.registerElement(makeElement(), pid: 100)

        // Don't advance time - elements are fresh
        await registry.triggerCleanup()

        let count = await registry.getCachedElementCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentRegistrations() async throws {
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
        var elements: [Exactmac_V1_Element] = []
        for i in 0 ..< 100 {
            elements.append(makeElement(role: "item\(i)"))
        }

        // Register 100 elements concurrently
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0 ..< 100 {
                let element = elements[i]
                let pid = pid_t(i % 10)
                group.addTask {
                    try await registry.registerElement(element, pid: pid)
                }
            }

            var registeredIds = Set<String>()
            for try await id in group {
                registeredIds.insert(id)
            }
            XCTAssertEqual(registeredIds.count, 100, "All registrations should produce unique IDs")
        }

        let finalCount = await registry.getCachedElementCount()
        XCTAssertEqual(finalCount, 100)
    }

    func testConcurrentReadsAndWrites() async throws {
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
            let id = try await registry.registerElement(makeElement(), pid: 100)
            preIds.append(id)
        }

        // Prepare elements outside of task group to avoid Sendable issues
        let writerElement = makeElement()
        let updaterElement = makeElement(role: "updated")
        let capturedIds = preIds

        // Concurrent reads and writes
        try await withThrowingTaskGroup(of: Void.self) { group in
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
                    _ = try await registry.registerElement(writerElement, pid: 200)
                }
            }

            // Updaters
            for id in capturedIds.prefix(5) {
                group.addTask {
                    _ = await registry.updateElement(id, element: updaterElement)
                }
            }
            try await group.waitForAll()
        }

        // Verify no crashes and count is correct
        let finalCount = await registry.getCachedElementCount()
        XCTAssertEqual(finalCount, 30) // 10 pre + 20 new
    }

    // MARK: - Edge Cases

    func testRegisterWithZeroPid() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["zero_pid_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // PID 0 is a valid edge case (kernel)
        let elementId = try await registry.registerElement(makeElement(), pid: 0)
        let ids = await registry.getElementIds(forPid: 0)
        XCTAssertEqual(ids, [elementId])
    }

    func testRegisterWithNegativePid() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["neg_pid_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        // Negative PIDs shouldn't exist but registry should handle them
        let elementId = try await registry.registerElement(makeElement(), pid: -1)
        let ids = await registry.getElementIds(forPid: -1)
        XCTAssertEqual(ids, [elementId])
    }

    func testElementWithEmptyRole() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["empty_role_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let element = makeElement(role: "")
        let elementId = try await registry.registerElement(element, pid: 100)

        let retrieved = await registry.getElement(elementId)
        XCTAssertEqual(retrieved?.role, "")
    }

    func testMultipleUpdatesToSameElement() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["multi_update_001"])
        let registry = makeTestRegistry(currentTime: timeMock, idSequence: idMock)

        let elementId = try await registry.registerElement(makeElement(text: "v1"), pid: 100)

        for i in 2 ... 10 {
            let updated = makeElement(text: "v\(i)")
            let success = await registry.updateElement(elementId, element: updated)
            XCTAssertTrue(success)
        }

        let final = await registry.getElement(elementId)
        XCTAssertEqual(final?.text, "v10")
    }

    func testVeryShortTTL() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["short_ttl_001"])
        let registry = makeTestRegistry(ttl: 0.001, currentTime: timeMock, idSequence: idMock)

        let elementId = try await registry.registerElement(makeElement(), pid: 100)

        // Even a tiny advance should expire it
        timeMock.advance(by: 0.002)

        let retrieved = await registry.getElement(elementId)
        XCTAssertNil(retrieved)
    }

    func testVeryLongTTL() async throws {
        let timeMock = CurrentTimeMock()
        let idMock = IDSequenceMock(ids: ["long_ttl_001"])
        let registry = makeTestRegistry(ttl: 86400 * 365, currentTime: timeMock, idSequence: idMock) // 1 year

        let elementId = try await registry.registerElement(makeElement(), pid: 100)

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
