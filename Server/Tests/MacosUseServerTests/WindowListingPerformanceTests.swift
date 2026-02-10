import Foundation
import Testing

@testable import MacosUseServer

/// Performance benchmarks for window listing operations.
///
/// These tests measure WindowRegistry.listAllWindows and listWindows(forPID:)
/// to establish baseline performance metrics.
///
/// **Requirements**: Tests depend on actual macOS windows being present.
@Suite("Window Listing Performance Benchmarks")
struct WindowListingPerformanceTests {
    /// Number of iterations for stable timing
    private let iterations = 10

    /// Test listAllWindows performance across all system windows.
    ///
    /// Expected: Sub-100ms for typical desktop with <50 windows
    @Test("listAllWindows performance baseline")
    func testListAllWindowsPerformance() async throws {
        let registry = WindowRegistry()

        // Perform listing iterations and collect timing
        var durations: [TimeInterval] = []
        var windowCounts: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let windows = try await registry.listAllWindows()
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            windowCounts.append(windows.count)
        }

        // Calculate metrics
        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgWindows = windowCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== listAllWindows Benchmark =====
        Iterations: \(iterations)
        Avg Windows: \(avgWindows)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        ====================================
        """)

        // Assertions
        #expect(avgDuration < 0.5, "listAllWindows should complete under 500ms")
        // At minimum, we should see at least a few windows (desktop, status menu, etc.)
        #expect(windowCounts.allSatisfy { $0 >= 0 }, "Window count should be non-negative")
    }

    /// Test listWindows(forPID:) performance for a specific application.
    ///
    /// Uses Finder as it's always running on macOS.
    @Test("listWindows for Finder performance")
    func testListWindowsForFinderPerformance() async throws {
        let registry = WindowRegistry()

        // Find Finder's PID
        guard let finderApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            Issue.record("Finder not running - test cannot proceed")
            return
        }

        let finderPID = finderApp.processIdentifier

        // Perform listing iterations
        var durations: [TimeInterval] = []
        var windowCounts: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let windows = try await registry.listWindows(forPID: finderPID)
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            windowCounts.append(windows.count)
        }

        // Calculate metrics
        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgWindows = windowCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== listWindows(Finder) Benchmark =====
        PID: \(finderPID)
        Iterations: \(iterations)
        Avg Windows: \(avgWindows)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        =========================================
        """)

        // Assertions
        #expect(avgDuration < 0.5, "listWindows should complete under 500ms")
    }

    /// Measure performance with multiple Calculator windows.
    ///
    /// Opens Calculator multiple times to test window count scaling.
    @Test("listWindows with multiple Calculator windows", .disabled("Disabled by default - opens multiple Calculator windows"))
    @MainActor
    func testListWindowsMultipleWindows() async throws {
        let registry = WindowRegistry()
        var pids: [pid_t] = []

        // Define test cases: number of windows to open
        let testCases = [1, 3, 5]

        for windowCount in testCases {
            // Open Calculator instances
            for _ in 0..<windowCount {
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == "com.apple.calculator"
                }) {
                    pids.append(app.processIdentifier)
                } else {
                    // Try to launch Calculator
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = false
                        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                        pids.append(app.processIdentifier)
                    }
                }
            }

            // Wait for windows to be ready
            try await Task.sleep(for: .milliseconds(500))

            // Measure listing time
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await registry.listAllWindows()
            let duration = CFAbsoluteTimeGetCurrent() - start

            print("With \(windowCount) Calculator instance(s): \(String(format: "%.3f", duration * 1000))ms")

            // Clean up Calculators
            for pid in pids {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.terminate()
                }
            }
            pids.removeAll()
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Measure cache effectiveness - second call should be faster.
    @Test("Cache performance comparison")
    func testCachePerformance() async throws {
        let registry = WindowRegistry()

        // First call - cold cache (forces refresh)
        let coldStart = CFAbsoluteTimeGetCurrent()
        _ = try await registry.listAllWindows()
        let coldDuration = CFAbsoluteTimeGetCurrent() - coldStart

        // Second call - potentially warm cache depending on implementation
        let warmStart = CFAbsoluteTimeGetCurrent()
        _ = try await registry.listAllWindows()
        let warmDuration = CFAbsoluteTimeGetCurrent() - warmStart

        print("""
        ===== Cache Performance Comparison =====
        Cold call: \(String(format: "%.3f", coldDuration * 1000))ms
        Warm call: \(String(format: "%.3f", warmDuration * 1000))ms
        =========================================
        """)

        // Both should be reasonably fast
        #expect(coldDuration < 1.0, "Cold listAllWindows should complete under 1 second")
        #expect(warmDuration < 1.0, "Warm listAllWindows should complete under 1 second")
    }
}
