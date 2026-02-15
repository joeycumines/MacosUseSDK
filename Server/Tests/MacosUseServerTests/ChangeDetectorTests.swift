import Foundation
@testable import MacosUseServer
import XCTest

/// Tests for ChangeDetector circuit breaker and SDK activation tracking.
/// These tests verify:
/// - Circuit breaker trips after threshold is exceeded within the rolling window
/// - Circuit breaker resets after the window expires
/// - SDK activation tracking correctly suppresses self-triggered events
@MainActor
final class ChangeDetectorTests: XCTestCase {
    var detector: ChangeDetector!

    override func setUp() async throws {
        try await super.setUp()
        detector = ChangeDetector.shared
        // Reset state before each test for isolation
        detector.resetActivationState()
    }

    override func tearDown() async throws {
        // Clean up state after each test
        detector.resetActivationState()
        try await super.tearDown()
    }

    // MARK: - Circuit Breaker Tests

    /// Test that events below threshold pass through (circuit breaker does not trip).
    func testCircuitBreakerNormalEventsPassThrough() {
        let pid: pid_t = 99999

        // Call up to threshold - all should pass
        for i in 1 ... detector.testCircuitBreakerThreshold {
            let shouldBreak = detector.shouldCircuitBreak(pid: pid)
            XCTAssertFalse(
                shouldBreak,
                "Event \(i) of \(detector.testCircuitBreakerThreshold) should NOT trigger circuit breaker",
            )
        }

        // Verify count
        XCTAssertEqual(
            detector.testGetActivationCount(pid: pid),
            detector.testCircuitBreakerThreshold,
            "Activation count should equal threshold",
        )
    }

    /// Test that rapid activation events (exceeding threshold) trigger the circuit breaker.
    func testCircuitBreakerTripsAtThreshold() {
        let pid: pid_t = 99998

        // First 5 events should pass
        for _ in 1 ... detector.testCircuitBreakerThreshold {
            _ = detector.shouldCircuitBreak(pid: pid)
        }

        // The next event should trip the breaker
        let shouldBreak = detector.shouldCircuitBreak(pid: pid)
        XCTAssertTrue(
            shouldBreak,
            "Event exceeding threshold (\(detector.testCircuitBreakerThreshold)) should trigger circuit breaker",
        )

        // Continued events should also be suppressed
        let shouldBreak2 = detector.shouldCircuitBreak(pid: pid)
        XCTAssertTrue(shouldBreak2, "Subsequent events should also be suppressed")
    }

    /// Test that the circuit breaker resets after the window expires.
    func testCircuitBreakerResetsAfterWindowExpires() async throws {
        let pid: pid_t = 99997

        // Trigger nearly to threshold
        for _ in 1 ... detector.testCircuitBreakerThreshold {
            _ = detector.shouldCircuitBreak(pid: pid)
        }

        // Verify we're at threshold
        XCTAssertEqual(
            detector.testGetActivationCount(pid: pid),
            detector.testCircuitBreakerThreshold,
        )

        // Wait for window to expire (add small buffer for timing)
        // Using a short sleep since window is 1.0 second
        try await Task.sleep(nanoseconds: UInt64((detector.testCircuitBreakerWindow + 0.1) * 1_000_000_000))

        // Next event should reset the counter (window expired)
        let shouldBreak = detector.shouldCircuitBreak(pid: pid)
        XCTAssertFalse(
            shouldBreak,
            "After window expiry, circuit breaker should reset and allow events",
        )

        // Counter should be reset to 1
        XCTAssertEqual(
            detector.testGetActivationCount(pid: pid),
            1,
            "Counter should reset to 1 after window expires",
        )
    }

    /// Test that different PIDs have independent circuit breakers.
    func testCircuitBreakerIndependentPerPID() {
        let pid1: pid_t = 99996
        let pid2: pid_t = 99995

        // Max out pid1
        for _ in 1 ... detector.testCircuitBreakerThreshold + 1 {
            _ = detector.shouldCircuitBreak(pid: pid1)
        }

        // pid1 should be tripped
        XCTAssertTrue(detector.shouldCircuitBreak(pid: pid1))

        // pid2 should be unaffected
        let shouldBreak = detector.shouldCircuitBreak(pid: pid2)
        XCTAssertFalse(
            shouldBreak,
            "Different PID should have independent circuit breaker",
        )

        XCTAssertEqual(detector.testGetActivationCount(pid: pid2), 1)
    }

    // MARK: - SDK Activation Tracking Tests

    /// Test that markSDKActivation + isSDKActivation returns true within the window.
    func testSDKActivationWithinWindow() {
        let pid: pid_t = 88888

        // Initially not marked
        XCTAssertFalse(detector.isSDKActivation(pid: pid))

        // Mark SDK activation
        detector.markSDKActivation(pid: pid)

        // Should return true immediately
        XCTAssertTrue(
            detector.isSDKActivation(pid: pid),
            "isSDKActivation should return true immediately after marking",
        )
    }

    /// Test that isSDKActivation returns false after the window expires.
    func testSDKActivationExpiresAfterWindow() async throws {
        let pid: pid_t = 88887

        // Mark SDK activation
        detector.markSDKActivation(pid: pid)
        XCTAssertTrue(detector.isSDKActivation(pid: pid))

        // Wait for window to expire (500ms + buffer)
        try await Task.sleep(nanoseconds: UInt64((detector.testSDKActivationWindow + 0.1) * 1_000_000_000))

        // Should now return false
        XCTAssertFalse(
            detector.isSDKActivation(pid: pid),
            "isSDKActivation should return false after window expires",
        )
    }

    /// Test hasRecentSDKActivation returns true if any PID was marked recently.
    func testHasRecentSDKActivationAnyPID() {
        // Initially false
        XCTAssertFalse(detector.hasRecentSDKActivation())

        // Mark one PID
        detector.markSDKActivation(pid: 77777)

        // Should return true
        XCTAssertTrue(
            detector.hasRecentSDKActivation(),
            "hasRecentSDKActivation should return true after marking any PID",
        )
    }

    /// Test hasRecentSDKActivation returns false after all marked PIDs expire.
    func testHasRecentSDKActivationExpiresAfterWindow() async throws {
        // Mark a PID
        detector.markSDKActivation(pid: 77776)
        XCTAssertTrue(detector.hasRecentSDKActivation())

        // Wait for window to expire
        try await Task.sleep(nanoseconds: UInt64((detector.testSDKActivationWindow + 0.1) * 1_000_000_000))

        // Should now return false
        XCTAssertFalse(
            detector.hasRecentSDKActivation(),
            "hasRecentSDKActivation should return false after all marked PIDs expire",
        )
    }

    /// Test that multiple PIDs can be tracked independently for SDK activation.
    func testSDKActivationMultiplePIDs() {
        let pid1: pid_t = 66666
        let pid2: pid_t = 66665

        // Mark both
        detector.markSDKActivation(pid: pid1)
        detector.markSDKActivation(pid: pid2)

        XCTAssertTrue(detector.isSDKActivation(pid: pid1))
        XCTAssertTrue(detector.isSDKActivation(pid: pid2))
        XCTAssertTrue(detector.hasRecentSDKActivation())

        // Unknown PID should be false
        XCTAssertFalse(detector.isSDKActivation(pid: 11111))
    }

    /// Test that resetActivationState clears all tracking state.
    func testResetActivationStateClearsAll() {
        let pid: pid_t = 55555

        // Set up some state
        detector.markSDKActivation(pid: pid)
        for _ in 1 ... 3 {
            _ = detector.shouldCircuitBreak(pid: pid)
        }

        XCTAssertTrue(detector.isSDKActivation(pid: pid))
        XCTAssertEqual(detector.testGetActivationCount(pid: pid), 3)

        // Reset
        detector.resetActivationState()

        // All state should be cleared
        XCTAssertFalse(detector.isSDKActivation(pid: pid))
        XCTAssertNil(detector.testGetActivationCount(pid: pid))
        XCTAssertFalse(detector.hasRecentSDKActivation())
    }
}
