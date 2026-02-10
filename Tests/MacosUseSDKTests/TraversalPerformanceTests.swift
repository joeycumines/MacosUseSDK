import Foundation
import Testing

@testable import MacosUseSDK

/// Performance benchmarks for traverseAccessibilityTree.
///
/// These tests measure traversal performance with real applications:
/// - Calculator: Small UI tree (~50-100 elements)
/// - Finder: Large UI tree (~500-2000+ elements depending on window state)
///
/// **Requirements**: Accessibility permissions must be granted.
/// Run with: `swift test --filter TraversalPerformanceTests`
@Suite("Traversal Performance Benchmarks")
struct TraversalPerformanceTests {
    /// Minimum number of iterations for stable timing
    private let iterations = 5

    /// Opens Calculator and measures traversal time.
    ///
    /// Expected: Small tree, fast traversal (<500ms)
    @Test("Calculator traversal baseline")
    @MainActor
    func testCalculatorTraversalPerformance() async throws {
        // Open Calculator in background mode
        let openResult = try await openApplication(identifier: "Calculator", background: true)
        let pid = openResult.pid
        defer {
            // Cleanup: terminate Calculator
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            }
        }

        // Wait for Calculator to be ready (has a window)
        var attempts = 0
        while attempts < 20 {
            if let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }

        // Perform traversals and collect timing
        var durations: [TimeInterval] = []
        var elementCounts: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            elementCounts.append(result.elements.count)
        }

        // Log results
        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgElements = elementCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== Calculator Traversal Benchmark =====
        Iterations: \(iterations)
        Avg Elements: \(avgElements)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        ==========================================
        """)

        // Assertions
        #expect(avgElements > 10, "Calculator should have at least 10 visible elements")
        #expect(avgDuration < 2.0, "Calculator traversal should complete under 2 seconds")
    }

    /// Opens Finder and measures traversal time for a large tree.
    ///
    /// Expected: Large tree, longer traversal (<3s)
    @Test("Finder traversal baseline")
    @MainActor
    func testFinderTraversalPerformance() async throws {
        // Open Finder (creates new window or uses existing)
        let openResult = try await openApplication(identifier: "Finder", background: true)
        let pid = openResult.pid
        // Note: We don't terminate Finder as it's a system app

        // Wait for Finder to be ready
        var attempts = 0
        while attempts < 30 {
            if let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }

        // Give Finder time to render its UI
        try await Task.sleep(for: .milliseconds(500))

        // Perform traversals and collect timing
        var durations: [TimeInterval] = []
        var elementCounts: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            elementCounts.append(result.elements.count)
        }

        // Log results
        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgElements = elementCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== Finder Traversal Benchmark =====
        Iterations: \(iterations)
        Avg Elements: \(avgElements)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        ======================================
        """)

        // Assertions
        #expect(avgElements > 50, "Finder should have at least 50 visible elements")
        #expect(avgDuration < 10.0, "Finder traversal should complete under 10 seconds")
    }

    /// Measures traversal with all elements (not just visible) for comparison.
    @Test("Calculator traversal all elements")
    @MainActor
    func testCalculatorTraversalAllElements() async throws {
        let openResult = try await openApplication(identifier: "Calculator", background: true)
        let pid = openResult.pid
        defer {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            }
        }

        // Wait for Calculator
        try await Task.sleep(for: .milliseconds(500))

        // Single traversal for all elements
        let start = CFAbsoluteTimeGetCurrent()
        let visibleResult = try traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
        let visibleDuration = CFAbsoluteTimeGetCurrent() - start

        let allStart = CFAbsoluteTimeGetCurrent()
        let allResult = try traverseAccessibilityTree(pid: pid, onlyVisibleElements: false, shouldActivate: false)
        let allDuration = CFAbsoluteTimeGetCurrent() - allStart

        print("""
        ===== Calculator Element Comparison =====
        Visible Only: \(visibleResult.elements.count) elements in \(String(format: "%.3f", visibleDuration * 1000))ms
        All Elements: \(allResult.elements.count) elements in \(String(format: "%.3f", allDuration * 1000))ms
        Ratio: \(String(format: "%.1f", Double(allResult.elements.count) / Double(max(1, visibleResult.elements.count))))x more elements
        =========================================
        """)

        #expect(allResult.elements.count >= visibleResult.elements.count, "All elements should include visible elements")
    }
}
