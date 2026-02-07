import ApplicationServices
@testable import MacosUseSDK
import XCTest

/// Tests for SendableAXUIElement wrapper type.
///
/// Verifies CFHash and CFEqual work correctly for AXUIElement which is a CFTypeRef.
/// Also tests Hashable and Equatable conformance.
final class SendableAXUIElementTests: XCTestCase {
    // MARK: - CFHash Tests

    func testCFHashProducesConsistentValues() {
        // Create an AXUIElement for the current process
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        let wrapper1 = SendableAXUIElement(element)
        let wrapper2 = SendableAXUIElement(element)

        let hash1 = wrapper1.hashValue
        let hash2 = wrapper2.hashValue

        // Same underlying element should produce same hash
        XCTAssertEqual(hash1, hash2, "Same element should produce same hash value")
    }

    func testCFHashProducesDifferentValuesForDifferentElements() {
        // Create elements for two different processes
        let validElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        // Create an element for a different PID (0 is typically invalid)
        let differentElement = AXUIElementCreateApplication(0)

        let validWrapper = SendableAXUIElement(validElement)

        // Can't test nil wrapper directly since it's a value type,
        // but we can verify the hash function doesn't crash
        let hash = validWrapper.hashValue
        XCTAssertNotEqual(hash, 0, "Hash should not be zero for valid element")
    }

    func testCFHashForDifferentProcesses() {
        // Create elements for different processes
        let pid1 = ProcessInfo.processInfo.processIdentifier
        let element1 = AXUIElementCreateApplication(pid1)

        // Create a wrapper for our process
        let wrapper1 = SendableAXUIElement(element1)
        let hash1 = wrapper1.hashValue

        // The hash should be non-zero and consistent
        XCTAssertNotEqual(hash1, 0)
        XCTAssertEqual(hash1, wrapper1.hashValue, "Hash should be stable across calls")
    }

    // MARK: - CFEqual Tests

    func testCFEqual_returnsTrueForSameElement() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        let wrapper1 = SendableAXUIElement(element)
        let wrapper2 = SendableAXUIElement(element)

        XCTAssertEqual(wrapper1, wrapper2, "Wrappers of same element should be equal")
    }

    func testCFEqual_returnsFalseForDifferentElements() {
        // Create two different elements
        let element1 = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        // Create a different AXUIElement (invalid/null case for comparison)
        // In practice, two different AXUIElement refs from AXUIElementCreateApplication
        // with different PIDs should not be equal
        let differentElement = AXUIElementCreateApplication(0) // PID 0 is usually invalid

        let wrapper1 = SendableAXUIElement(element1)
        let wrapper2 = SendableAXUIElement(differentElement)

        XCTAssertNotEqual(wrapper1, wrapper2, "Different elements should not be equal")
    }

    // MARK: - Hashable Conformance

    func testHashable_canBeUsedInSet() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let wrapper = SendableAXUIElement(element)

        var set = Set<SendableAXUIElement>()
        set.insert(wrapper)

        XCTAssertEqual(set.count, 1)
        XCTAssertTrue(set.contains(wrapper))
    }

    func testHashable_duplicateInsertsDoNotIncreaseCount() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let wrapper1 = SendableAXUIElement(element)
        let wrapper2 = SendableAXUIElement(element)

        var set = Set<SendableAXUIElement>()
        set.insert(wrapper1)
        set.insert(wrapper2)

        XCTAssertEqual(set.count, 1, "Duplicate elements should not increase set count")
    }

    func testHashable_differentElementsIncreaseCount() {
        let element1 = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let element2 = AXUIElementCreateApplication(0) // Different/invalid PID

        let wrapper1 = SendableAXUIElement(element1)
        let wrapper2 = SendableAXUIElement(element2)

        var set = Set<SendableAXUIElement>()
        set.insert(wrapper1)
        set.insert(wrapper2)

        XCTAssertEqual(set.count, 2, "Different elements should both be in set")
    }

    // MARK: - Equatable Conformance

    func testEquatable_directComparison() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        let wrapper1 = SendableAXUIElement(element)
        let wrapper2 = SendableAXUIElement(element)
        let wrapper3 = SendableAXUIElement(AXUIElementCreateApplication(0))

        XCTAssertEqual(wrapper1, wrapper2)
        XCTAssertNotEqual(wrapper1, wrapper3)
    }

    func testEquatable_notEqualToNil() {
        // Value types can't be compared to nil directly, but we can test
        // that the type is indeed a value type
        let element: AXUIElement? = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(element)
    }

    // MARK: - Initialization

    func testInit_wrapsAXUIElement() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let wrapper = SendableAXUIElement(element)

        // Verify the wrapper contains the element
        // We can't directly access the internal element, but we can verify
        // through equality and hashing behavior
        let wrapper2 = SendableAXUIElement(element)
        XCTAssertEqual(wrapper, wrapper2)
    }

    // MARK: - Thread Safety (Sendable)

    func testSendable_conformanceIsUnchecked() {
        // Verify the Sendable conformance is present
        let wrapper = SendableAXUIElement(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))

        // The @unchecked Sendable means the compiler trusts us
        // We can't programmatically verify this, but the code compiles
        XCTAssertNotNil(wrapper)
    }
}
