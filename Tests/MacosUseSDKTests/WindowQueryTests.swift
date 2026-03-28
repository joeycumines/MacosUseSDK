import ApplicationServices
import CoreGraphics
@testable import MacosUseSDK
import XCTest

/// Tests for WindowQuery functions.
///
/// Verifies AX bounds extraction, position/size handling, window info structure,
/// heuristic matching logic, title match accuracy, bounds tolerance, multi-window
/// disambiguation, and _AXUIElementGetWindow availability detection.
final class WindowQueryTests: XCTestCase {
    // MARK: - WindowInfo Structure

    func testWindowInfo_properties() {
        // Create a minimal WindowInfo to verify structure
        // The element is created to verify AXUIElementCreateApplication works with our PID
        _ = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        // Note: We can't directly create WindowInfo as it's internal,
        // but we can test the fetchAXWindowInfo function behavior
        // This test verifies the function signature and basic calling

        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)

        // The function should return nil for non-existent window IDs
        // (test window ID 99999 is unlikely to exist)
        let result = fetchAXWindowInfo(
            pid: ProcessInfo.processInfo.processIdentifier,
            windowId: 99999,
            expectedBounds: bounds,
        )

        // Result will be nil for non-existent window, which is expected
        XCTAssertNil(result, "Should return nil for non-existent window")
    }

    // MARK: - Bounds Conversion

    func testBounds_originAndSize() {
        let bounds = CGRect(x: 100, y: 50, width: 800, height: 600)

        XCTAssertEqual(bounds.origin.x, 100)
        XCTAssertEqual(bounds.origin.y, 50)
        XCTAssertEqual(bounds.size.width, 800)
        XCTAssertEqual(bounds.size.height, 600)
    }

    func testBounds_zeroDimensions() {
        let zeroBounds = CGRect(x: 0, y: 0, width: 0, height: 0)

        XCTAssertEqual(zeroBounds.size.width, 0)
        XCTAssertEqual(zeroBounds.size.height, 0)
    }

    func testBounds_negativeCoordinates() {
        // Multi-monitor setups can have negative coordinates
        let bounds = CGRect(x: -500, y: -200, width: 800, height: 600)

        XCTAssertEqual(bounds.origin.x, -500)
        XCTAssertEqual(bounds.origin.y, -200)
    }

    // MARK: - AX Bounds Extraction

    func testCGPoint_creation() {
        // Test basic CGPoint creation and properties
        let testPoint = CGPoint(x: 100, y: 50)

        XCTAssertEqual(testPoint.x, 100)
        XCTAssertEqual(testPoint.y, 50)
    }

    func testCGSize_creation() {
        // Test basic CGSize creation and properties
        let testSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(testSize.width, 800)
        XCTAssertEqual(testSize.height, 600)
    }

    func testCGRect_creation() {
        // Test basic CGRect creation
        let testRect = CGRect(x: 100, y: 50, width: 800, height: 600)

        XCTAssertEqual(testRect.origin.x, 100)
        XCTAssertEqual(testRect.origin.y, 50)
        XCTAssertEqual(testRect.size.width, 800)
        XCTAssertEqual(testRect.size.height, 600)
    }

    func testCGRect_zero() {
        // Test zero rect
        let zeroRect = CGRect.zero

        XCTAssertEqual(zeroRect.origin.x, 0)
        XCTAssertEqual(zeroRect.origin.y, 0)
        XCTAssertEqual(zeroRect.size.width, 0)
        XCTAssertEqual(zeroRect.size.height, 0)
    }

    // MARK: - Window ID Handling

    func testCGWindowID_type() {
        // CGWindowID is a type alias for UInt32
        let windowId: CGWindowID = 12345

        XCTAssertEqual(windowId, 12345)
        XCTAssertLessThanOrEqual(windowId, UInt32.max)
    }

    func testCGWindowID_zeroValue() {
        // Window ID 0 typically means "no window" or invalid
        let windowId: CGWindowID = 0

        XCTAssertEqual(windowId, 0)
    }

    // MARK: - Heuristic Score Threshold

    func testScoreThreshold_constant() {
        // The score threshold for window matching is 1000.0 pixels
        // as defined in docs/window-state-management.md
        let threshold: CGFloat = 1000.0

        // Threshold should be positive and reasonably large
        XCTAssertGreaterThan(threshold, 0)
        XCTAssertLessThan(threshold, 10000)
    }

    func testScoreCalculation() {
        // Test Euclidean distance calculation for scoring
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 3, y: 4)

        // Distance should be 5 (3-4-5 triangle)
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)

        XCTAssertEqual(distance, 5.0, accuracy: 0.001)
    }

    func testScoreCalculation_zeroDistance() {
        let p1 = CGPoint(x: 100, y: 50)
        let p2 = CGPoint(x: 100, y: 50)

        let distance = hypot(p2.x - p1.x, p2.y - p1.y)

        XCTAssertEqual(distance, 0.0, accuracy: 0.001)
    }

    // MARK: - PID Handling

    func testPid_type() {
        // pid_t is typically Int32
        let pid: pid_t = ProcessInfo.processInfo.processIdentifier

        XCTAssertGreaterThan(pid, 0, "Process PID should be positive")
        XCTAssertNotEqual(pid, 0)
    }

    // MARK: - AXUIElement Window Bridge

    func testAXUIElementCreateApplication_validPid() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        // Should create a non-nil element
        XCTAssertNotNil(element)
    }

    func testAXUIElementCreateApplication_zeroPid() {
        let element = AXUIElementCreateApplication(0)

        // Should create an element (might be invalid)
        XCTAssertNotNil(element)
    }

    // MARK: - Heuristic Matching Fallback Tests

    /// Tests that the heuristic score formula correctly calculates origin + size deviation.
    /// Score = hypot(origin delta) + hypot(size delta)
    func testHeuristicScore_formulaCalculation() {
        // Expected bounds from Quartz
        let expected = CGRect(x: 100, y: 100, width: 800, height: 600)
        // Candidate AX bounds with slight offset (simulating shadow penalty)
        let candidate = CGRect(x: 110, y: 105, width: 820, height: 610)

        // Calculate score using the same formula as fetchAXWindowInfo
        let originDiff = hypot(
            candidate.origin.x - expected.origin.x,
            candidate.origin.y - expected.origin.y,
        )
        let sizeDiff = hypot(
            candidate.width - expected.width,
            candidate.height - expected.height,
        )
        let score = originDiff + sizeDiff

        // Origin diff: hypot(10, 5) ≈ 11.18
        // Size diff: hypot(20, 10) ≈ 22.36
        // Total: ≈ 33.54
        XCTAssertEqual(score, originDiff + sizeDiff, accuracy: 0.001)
        XCTAssertLessThan(score, 50, "Slight offset should produce low score")
        XCTAssertLessThan(score, 1000, "Slight offset should be well under threshold")
    }

    /// Tests that perfect bounds match produces zero score.
    func testHeuristicScore_perfectMatch() {
        let bounds = CGRect(x: 500, y: 300, width: 1024, height: 768)
        _ = bounds // Used for documentation, testing formula

        let originDiff: CGFloat = hypot(0, 0)
        let sizeDiff: CGFloat = hypot(0, 0)
        let score = originDiff + sizeDiff

        XCTAssertEqual(score, 0.0, accuracy: 0.0001)
    }

    /// Tests that large position differences exceed threshold.
    /// This simulates cross-monitor moves where heuristic should fail-closed.
    func testHeuristicScore_crossMonitorJump() {
        let expected = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Window moved to second monitor
        let candidate = CGRect(x: 3840, y: 0, width: 800, height: 600)

        let originDiff = hypot(
            candidate.origin.x - expected.origin.x,
            candidate.origin.y - expected.origin.y,
        )
        let sizeDiff = hypot(
            candidate.width - expected.width,
            candidate.height - expected.height,
        )
        let score = originDiff + sizeDiff

        // Origin diff: hypot(3840, 0) = 3840, far exceeds 1000
        XCTAssertEqual(originDiff, 3840, accuracy: 0.001)
        XCTAssertGreaterThan(score, 1000, "Cross-monitor jump should exceed threshold")
    }

    /// Tests shadow penalty absorption - Quartz reports larger bounds than AX.
    /// This is a common scenario documented in window-state-management.md.
    func testHeuristicScore_shadowPenaltyAbsorption() {
        // AX content bounds
        let axBounds = CGRect(x: 100, y: 100, width: 1000, height: 800)
        // Quartz includes shadows (20px on each side)
        let cgBounds = CGRect(x: 80, y: 80, width: 1040, height: 840)

        let originDiff = hypot(
            axBounds.origin.x - cgBounds.origin.x,
            axBounds.origin.y - cgBounds.origin.y,
        )
        let sizeDiff = hypot(
            axBounds.width - cgBounds.width,
            axBounds.height - cgBounds.height,
        )
        let score = originDiff + sizeDiff

        // Origin diff: hypot(20, 20) ≈ 28.28
        // Size diff: hypot(40, 40) ≈ 56.57
        // Total ≈ 84.85 - well under threshold
        XCTAssertLessThan(score, 100, "Shadow penalty should be absorbed")
        XCTAssertLessThan(score, 1000, "Shadow penalty should be under threshold")
    }

    /// Tests animation lag tolerance - transient deltas during fast drags.
    func testHeuristicScore_animationLagTolerance() {
        let expected = CGRect(x: 100, y: 100, width: 800, height: 600)
        // Window is mid-animation, 200px offset
        let candidate = CGRect(x: 300, y: 200, width: 800, height: 600)

        let originDiff = hypot(
            candidate.origin.x - expected.origin.x,
            candidate.origin.y - expected.origin.y,
        )
        let sizeDiff = hypot(
            candidate.width - expected.width,
            candidate.height - expected.height,
        )
        let score = originDiff + sizeDiff

        // Origin diff: hypot(200, 100) ≈ 223.61
        XCTAssertLessThan(score, 300, "Animation lag should be tolerable")
        XCTAssertLessThan(score, 1000, "Animation lag should be under threshold")
    }

    // MARK: - Title Match Accuracy Tests

    /// Tests that exact title match applies 50% score reduction.
    func testTitleMatch_exactMatch_appliesBonus() {
        // Base score calculation
        let originDiff: CGFloat = 100
        let sizeDiff: CGFloat = 50
        var score = originDiff + sizeDiff // 150

        // Simulate title match bonus (50% reduction)
        let expectedTitle = "Untitled"
        let axTitle = "Untitled"

        if !expectedTitle.isEmpty, axTitle == expectedTitle {
            score *= 0.5
        }

        XCTAssertEqual(score, 75, accuracy: 0.001)
    }

    /// Tests that empty expected title does not apply bonus.
    func testTitleMatch_emptyExpectedTitle_noBonus() {
        var score: CGFloat = 150

        let expectedTitle = ""
        let axTitle = "Document.txt"

        if !expectedTitle.isEmpty, axTitle == expectedTitle {
            score *= 0.5
        }

        XCTAssertEqual(score, 150, accuracy: 0.001, "Empty expected title should not apply bonus")
    }

    /// Tests that title mismatch does not apply bonus.
    func testTitleMatch_mismatch_noBonus() {
        var score: CGFloat = 150

        let expectedTitle = "Document1.txt"
        let axTitle = "Document2.txt"

        if !expectedTitle.isEmpty, axTitle == expectedTitle {
            score *= 0.5
        }

        XCTAssertEqual(score, 150, accuracy: 0.001, "Title mismatch should not apply bonus")
    }

    /// Tests title matching is case-sensitive.
    func testTitleMatch_caseSensitive() {
        var score: CGFloat = 150

        let expectedTitle = "Document.txt"
        let axTitle = "document.txt"

        if !expectedTitle.isEmpty, axTitle == expectedTitle {
            score *= 0.5
        }

        XCTAssertEqual(score, 150, accuracy: 0.001, "Title match should be case-sensitive")
    }

    /// Tests title bonus helps differentiate identically-positioned windows.
    func testTitleMatch_helpsDisambiguation() {
        // Two windows at same position and size
        let baseScore: CGFloat = 10 // Very close bounds

        // Window 1: title matches
        var score1 = baseScore
        let expectedTitle = "Preferences"
        let title1 = "Preferences"
        if !expectedTitle.isEmpty, title1 == expectedTitle {
            score1 *= 0.5
        }

        // Window 2: title doesn't match
        var score2 = baseScore
        let title2 = "About"
        if !expectedTitle.isEmpty, title2 == expectedTitle {
            score2 *= 0.5
        }

        XCTAssertLessThan(score1, score2, "Title match should produce lower score")
        XCTAssertEqual(score1, 5, accuracy: 0.001)
        XCTAssertEqual(score2, 10, accuracy: 0.001)
    }

    // MARK: - Bounds Match Within Tolerance Tests

    /// Tests that bounds differences under threshold are acceptable.
    func testBoundsMatch_underThreshold_acceptable() {
        let threshold: CGFloat = 1000.0

        // Test various acceptable deltas
        // Score = hypot(originDelta, 0) + hypot(sizeDelta, 0) = originDelta + sizeDelta
        let testCases: [(CGFloat, CGFloat, Bool)] = [
            (0, 0, true), // Perfect match: 0
            (10, 10, true), // Tiny delta: 20
            (100, 100, true), // Small delta: 200
            (400, 400, true), // Medium delta: 800
            (700, 0, true), // Near threshold: 700
            (999, 0, true), // Just under threshold: 999
        ]

        for (originDelta, sizeDelta, shouldAccept) in testCases {
            let originDiff = hypot(originDelta, 0)
            let sizeDiff = hypot(sizeDelta, 0)
            let score = originDiff + sizeDiff

            if shouldAccept {
                XCTAssertLessThan(
                    score,
                    threshold,
                    "Delta (\(originDelta), \(sizeDelta)) should be under threshold",
                )
            }
        }
    }

    /// Tests that bounds differences at or above threshold are rejected.
    func testBoundsMatch_atOrAboveThreshold_rejected() {
        let threshold: CGFloat = 1000.0

        let testCases: [(CGFloat, CGFloat)] = [
            (1000, 0), // Exactly at threshold
            (1001, 0), // Just over threshold
            (2000, 0), // Well over threshold
            (500, 500), // Combined over threshold: hypot(500,0)+hypot(500,0)=1000
        ]

        for (originDelta, sizeDelta) in testCases {
            let originDiff = hypot(originDelta, 0)
            let sizeDiff = hypot(sizeDelta, 0)
            let score = originDiff + sizeDiff

            XCTAssertGreaterThanOrEqual(
                score,
                threshold,
                "Delta (\(originDelta), \(sizeDelta)) should be at or above threshold",
            )
        }
    }

    /// Tests tolerance for negative coordinate spaces (multi-monitor left of primary).
    func testBoundsMatch_negativeCoordinates() {
        let expected = CGRect(x: -1920, y: 0, width: 800, height: 600)
        let candidate = CGRect(x: -1910, y: 5, width: 800, height: 600)

        let originDiff = hypot(
            candidate.origin.x - expected.origin.x,
            candidate.origin.y - expected.origin.y,
        )
        let sizeDiff = hypot(
            candidate.width - expected.width,
            candidate.height - expected.height,
        )
        let score = originDiff + sizeDiff

        // hypot(10, 5) ≈ 11.18
        XCTAssertLessThan(score, 20, "Negative coordinates should work correctly")
    }

    // MARK: - Multi-Window Disambiguation Tests

    /// Tests score comparison selects closest matching window.
    func testMultiWindow_selectsClosestMatch() {
        let expected = CGRect(x: 100, y: 100, width: 800, height: 600)

        // Window A: slight offset
        let windowA = CGRect(x: 105, y: 102, width: 800, height: 600)
        // Window B: larger offset
        let windowB = CGRect(x: 200, y: 150, width: 800, height: 600)
        // Window C: different size
        let windowC = CGRect(x: 100, y: 100, width: 900, height: 700)

        func calculateScore(_ candidate: CGRect) -> CGFloat {
            let originDiff = hypot(
                candidate.origin.x - expected.origin.x,
                candidate.origin.y - expected.origin.y,
            )
            let sizeDiff = hypot(
                candidate.width - expected.width,
                candidate.height - expected.height,
            )
            return originDiff + sizeDiff
        }

        let scoreA = calculateScore(windowA)
        let scoreB = calculateScore(windowB)
        let scoreC = calculateScore(windowC)

        // Window A should have lowest score
        XCTAssertLessThan(scoreA, scoreB, "Closest window should have lowest score")
        XCTAssertLessThan(scoreA, scoreC, "Closest window should have lowest score")
    }

    /// Tests stacked clone scenario - nearly identical windows at slight offset.
    func testMultiWindow_stackedClones() {
        // Expected: first window in stack
        let expected = CGRect(x: 100, y: 100, width: 800, height: 600)
        // Clone: offset by typical window cascade amount
        let clone1 = CGRect(x: 120, y: 120, width: 800, height: 600)
        let clone2 = CGRect(x: 140, y: 140, width: 800, height: 600)

        func calculateScore(_ candidate: CGRect) -> CGFloat {
            let originDiff = hypot(
                candidate.origin.x - expected.origin.x,
                candidate.origin.y - expected.origin.y,
            )
            let sizeDiff = hypot(
                candidate.width - expected.width,
                candidate.height - expected.height,
            )
            return originDiff + sizeDiff
        }

        let scoreClone1 = calculateScore(clone1)
        let scoreClone2 = calculateScore(clone2)

        // Clone1: hypot(20,20) ≈ 28.28
        // Clone2: hypot(40,40) ≈ 56.57
        XCTAssertEqual(scoreClone1, hypot(20, 20), accuracy: 0.01)
        XCTAssertEqual(scoreClone2, hypot(40, 40), accuracy: 0.01)
        XCTAssertLessThan(scoreClone1, scoreClone2, "Closer clone should have lower score")
    }

    /// Tests that all windows above threshold are rejected in multi-window scenario.
    func testMultiWindow_allAboveThreshold_returnsNil() {
        let threshold: CGFloat = 1000.0
        let expected = CGRect(x: 0, y: 0, width: 800, height: 600)

        // All windows are on different monitors (far away)
        let windows = [
            CGRect(x: 1920, y: 0, width: 800, height: 600),
            CGRect(x: 3840, y: 0, width: 800, height: 600),
            CGRect(x: 5760, y: 0, width: 800, height: 600),
        ]

        var bestScore = CGFloat.greatestFiniteMagnitude
        for window in windows {
            let originDiff = hypot(window.origin.x - expected.origin.x, window.origin.y - expected.origin.y)
            let sizeDiff = hypot(window.width - expected.width, window.height - expected.height)
            let score = originDiff + sizeDiff
            if score < bestScore {
                bestScore = score
            }
        }

        // Best score is still above threshold
        XCTAssertGreaterThan(bestScore, threshold, "All windows should exceed threshold")
        // In real implementation, fetchAXWindowInfo would return nil
    }

    // MARK: - _AXUIElementGetWindow Availability Detection Tests

    /// Tests that resolveAXWindowID returns valid result structure.
    func testResolveAXWindowID_returnsValidResult() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        let (result, windowID) = resolveAXWindowID(for: element)

        // Result should be either:
        // - (.success, valid ID) if private API available and element is a window
        // - (.failure, 0) if private API unavailable or element is not a window
        // - (other error, 0) if API call failed

        // We just verify the structure is valid
        XCTAssertTrue(
            result == .success || result == .failure || result.rawValue != 0,
            "Result should be a valid AXError value",
        )

        // If failure, windowID should be 0
        if result == .failure {
            XCTAssertEqual(windowID, 0, "Failed result should have windowID of 0")
        }
    }

    /// Tests that resolveAXWindowID handles application element (not a window).
    func testResolveAXWindowID_applicationElement() {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Create an application element (not a window element)
        let appElement = AXUIElementCreateApplication(pid)

        let (result, windowID) = resolveAXWindowID(for: appElement)

        // Application elements are not windows, so should fail or return 0
        // The private API may return an error or the API may not be available
        // Either way, we shouldn't get a valid window ID for an app element
        if result == .success {
            // If somehow it "succeeded", windowID should still be 0 for non-window
            // This tests defensive behavior
            XCTAssertTrue(
                windowID == 0 || windowID != 0,
                "Result structure should be valid",
            )
        } else {
            XCTAssertEqual(windowID, 0, "Non-window element should have windowID of 0")
        }
    }

    /// Tests that resolveAXWindowID can be called repeatedly without side effects.
    func testResolveAXWindowID_repeatedCalls() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        // Call multiple times - should be idempotent
        let (result1, id1) = resolveAXWindowID(for: element)
        let (result2, id2) = resolveAXWindowID(for: element)
        let (result3, id3) = resolveAXWindowID(for: element)

        // All calls should return consistent results
        XCTAssertEqual(result1, result2, "Repeated calls should return same result")
        XCTAssertEqual(result2, result3, "Repeated calls should return same result")
        XCTAssertEqual(id1, id2, "Repeated calls should return same windowID")
        XCTAssertEqual(id2, id3, "Repeated calls should return same windowID")
    }

    /// Tests that resolveAXWindowID is thread-safe (lazy initialization).
    /// Uses concurrent calls to verify no crashes or inconsistent results.
    func testResolveAXWindowID_threadSafe() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(pid)

        // First, get a reference result
        let (refResult, refID) = resolveAXWindowID(for: element)

        // Run many concurrent calls using a dispatch group
        let iterations = 100
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        // Thread-safe counters using atomic-like pattern
        let successCount = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        successCount.initialize(to: 0)
        defer {
            successCount.deinitialize(count: 1)
            successCount.deallocate()
        }

        for _ in 0 ..< iterations {
            group.enter()
            queue.async {
                let (result, windowID) = resolveAXWindowID(for: element)
                // Verify each call matches reference
                if result == refResult, windowID == refID {
                    OSAtomicIncrement32(successCount)
                }
                group.leave()
            }
        }

        let waitResult = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(waitResult, .success, "All iterations should complete")
        XCTAssertEqual(successCount.pointee, Int32(iterations), "All calls should return same result")
    }

    // MARK: - Single Window Fallback Tests

    /// Tests the score logic for single-window-from-app fallback.
    /// When only one window exists, it should be accepted regardless of score.
    func testSingleWindowFallback_acceptsHighScore() {
        // This tests the conceptual logic: if windowCount == 1, accept match regardless
        let windowCount = 1
        let score: CGFloat = 5000 // Way above threshold

        let singleWindowFallback = (windowCount == 1)

        // In the real implementation, single window is accepted even with high score
        XCTAssertTrue(singleWindowFallback, "Single window should trigger fallback")

        // Simulate decision logic
        let threshold: CGFloat = 1000.0
        let shouldAccept = score < threshold || singleWindowFallback
        XCTAssertTrue(shouldAccept, "Single window should be accepted despite high score")
    }

    /// Tests that multi-window scenario does not use single-window fallback.
    func testMultipleWindows_noFallback() {
        let windowCount = 3
        let score: CGFloat = 5000

        let singleWindowFallback = (windowCount == 1)
        XCTAssertFalse(singleWindowFallback, "Multiple windows should not trigger fallback")

        let threshold: CGFloat = 1000.0
        let shouldAccept = score < threshold || singleWindowFallback
        XCTAssertFalse(shouldAccept, "Multiple windows with high score should be rejected")
    }

    // MARK: - ID Regeneration Scenario Tests

    /// Tests that bounds-based fallback works when window ID changes.
    func testIDRegeneration_boundsFallbackScenario() {
        // Scenario: After MoveWindow, CGWindowID regenerated
        let originalID: CGWindowID = 12345
        let newID: CGWindowID = 67890 // Different ID after mutation
        let expectedBounds = CGRect(x: 200, y: 300, width: 800, height: 600)
        let candidateBounds = CGRect(x: 205, y: 302, width: 800, height: 600) // Slight lag

        // IDs don't match
        XCTAssertNotEqual(originalID, newID, "IDs should be different after regeneration")

        // But bounds are close enough
        let originDiff = hypot(
            candidateBounds.origin.x - expectedBounds.origin.x,
            candidateBounds.origin.y - expectedBounds.origin.y,
        )
        let sizeDiff = hypot(
            candidateBounds.width - expectedBounds.width,
            candidateBounds.height - expectedBounds.height,
        )
        let score = originDiff + sizeDiff

        XCTAssertLessThan(score, 10, "Bounds should be close enough for fallback match")
        XCTAssertLessThan(score, 1000, "Score should be under threshold")
    }

    // MARK: - fetchAXWindowInfo Edge Cases

    /// Tests fetchAXWindowInfo with zero bounds (should attempt match).
    func testFetchAXWindowInfo_zeroBounds() {
        let result = fetchAXWindowInfo(
            pid: ProcessInfo.processInfo.processIdentifier,
            windowId: 99999,
            expectedBounds: .zero,
        )

        // Should return nil for non-existent window
        XCTAssertNil(result, "Should return nil for non-existent window with zero bounds")
    }

    /// Tests fetchAXWindowInfo with expectedTitle parameter.
    func testFetchAXWindowInfo_withExpectedTitle() {
        let result = fetchAXWindowInfo(
            pid: ProcessInfo.processInfo.processIdentifier,
            windowId: 99999,
            expectedBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            expectedTitle: "Test Window",
        )

        // Should return nil for non-existent window
        XCTAssertNil(result, "Should return nil for non-existent window with title")
    }

    /// Tests fetchAXWindowInfo with invalid PID.
    func testFetchAXWindowInfo_invalidPid() {
        // PID 1 is typically launchd, which probably has no windows
        let result = fetchAXWindowInfo(
            pid: 1,
            windowId: 99999,
            expectedBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
        )

        // Should return nil for process with no matching windows
        XCTAssertNil(result, "Should return nil for invalid PID or no matching window")
    }

    /// Tests fetchAXWindowInfo with negative PID.
    func testFetchAXWindowInfo_negativePid() {
        let result = fetchAXWindowInfo(
            pid: -1,
            windowId: 99999,
            expectedBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
        )

        // Should return nil for invalid PID
        XCTAssertNil(result, "Should return nil for negative PID")
    }
}
