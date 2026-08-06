import AppKit
import Foundation
@testable import MacosUseSDK
import Testing

/// Performance benchmarks for traverseAccessibilityTree.
///
/// These tests measure traversal performance with real applications:
/// - Calculator: Small UI tree (~50-100 elements)
/// - TextEdit: An owned document window with known visible controls
///
/// **Requirements**: Accessibility permissions must be granted.
/// Run with: `swift test --filter TraversalPerformanceTests`
@Suite(.serialized)
struct TraversalPerformanceTests {
    /// Minimum number of iterations for stable timing
    private let iterations = 5

    /// Opens Calculator and measures traversal time.
    ///
    /// Expected: Small tree, fast traversal (<500ms)
    @Test(.enabled(if: AXIsProcessTrusted(), "Requires Accessibility permissions"))
    @MainActor
    func `Calculator traversal baseline`() async throws {
        let openResult = try await openApplication(
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            background: true,
        )
        let pid = openResult.pid
        defer {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            }
        }

        // Wait for Calculator to be ready with actual UI elements
        var warmupElements = 0
        for _ in 0 ..< 50 {
            if let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
                let warmup = try? traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
                warmupElements = warmup?.elements.count ?? 0
                if warmupElements > 10 {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        // If Calculator didn't fully render, record an issue — AX is available so this is unexpected
        guard warmupElements > 10 else {
            Issue.record("Calculator UI not fully rendered (\(warmupElements) elements) — cannot benchmark")
            return
        }

        // Perform traversals and collect timing
        var durations: [TimeInterval] = []
        var elementCounts: [Int] = []

        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            elementCounts.append(result.elements.count)
        }

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

        #expect(avgElements > 10, "Calculator should have at least 10 visible elements")
        #expect(avgDuration < 2.0, "Calculator traversal should complete under 2 seconds")
    }

    /// Opens an exact-PID TextEdit instance and measures repeated traversal of
    /// a known visible document window.
    ///
    /// Finder is intentionally not used here: it is a shared singleton and its
    /// process-wide AX tree depends on unrelated user windows. A menu-only Finder
    /// tree can contain fewer than 20 collected elements, while a busy Finder can
    /// expose an arbitrarily large tree. Neither state is a valid benchmark fixture.
    @Test(.enabled(if: AXIsProcessTrusted(), "Requires Accessibility permissions"))
    @MainActor
    func `Owned TextEdit traversal baseline`() async throws {
        guard let textEditURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.TextEdit",
        ) else {
            Issue.record("TextEdit application could not be resolved")
            return
        }

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacosUseSDK-Traversal-\(UUID().uuidString).txt")
        try "MacosUseSDK owned traversal fixture".write(
            to: fixtureURL,
            atomically: true,
            encoding: .utf8,
        )
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        let app = try await NSWorkspace.shared.open(
            [fixtureURL],
            withApplicationAt: textEditURL,
            configuration: configuration,
        )
        let pid = app.processIdentifier
        defer { app.forceTerminate() }

        let warmup = try await pollUntilTraversal(pid: pid) { result in
            result.elements.contains { hasRole($0, "AXWindow") }
                && result.elements.contains { hasRole($0, "AXTextArea") }
        }

        // Perform traversals and collect timing
        var durations: [TimeInterval] = []
        var elementCounts: [Int] = []

        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            elementCounts.append(result.elements.count)

            #expect(
                result.elements.contains { hasRole($0, "AXWindow") },
                "The owned TextEdit document window must remain visible during traversal",
            )
            #expect(
                result.elements.contains { hasRole($0, "AXTextArea") },
                "The owned TextEdit text area must remain visible during traversal",
            )
        }

        let avgDuration = durations.reduce(0, +) / Double(iterations)
        let avgElements = elementCounts.reduce(0, +) / iterations
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        print("""
        ===== Owned TextEdit Traversal Benchmark =====
        Iterations: \(iterations)
        Warmup Elements: \(warmup.elements.count)
        Avg Elements: \(avgElements)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        ==============================================
        """)

        #expect(avgElements > 0, "The owned TextEdit fixture must expose visible elements")
        #expect(maxDuration < 10.0, "Every owned TextEdit traversal should complete under 10 seconds")
    }

    /// Measures traversal with all elements (not just visible) for comparison.
    @Test(.enabled(if: AXIsProcessTrusted(), "Requires Accessibility permissions"))
    @MainActor
    func `Calculator traversal all elements`() async throws {
        let openResult = try await openApplication(
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            background: true,
        )
        let pid = openResult.pid
        defer {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            }
        }

        // Wait for Calculator to be fully launched AND have UI elements rendered
        var warmupElements = 0
        for _ in 0 ..< 50 {
            if let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
                let warmup = try? traverseAccessibilityTree(pid: pid, onlyVisibleElements: true, shouldActivate: false)
                warmupElements = warmup?.elements.count ?? 0
                if warmupElements > 10 {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        // If Calculator didn't fully render, record an issue — AX is available so this is unexpected
        guard warmupElements > 10 else {
            Issue.record("Calculator UI not fully rendered (\(warmupElements) elements) — cannot compare")
            return
        }

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

        #expect(
            allResult.elements.count >= visibleResult.elements.count,
            "All elements should include visible elements",
        )
    }
}

private struct TraversalReadinessTimeout: LocalizedError {
    let pid: pid_t
    let lastElementCount: Int
    let lastError: Error?

    var errorDescription: String? {
        var description = "Timed out waiting for visible AX controls in PID \(pid); last element count was \(lastElementCount)"
        if let lastError {
            description += "; last traversal error: \(lastError.localizedDescription)"
        }
        return description
    }
}

/// Polls the real AX tree until the owned fixture reaches the required state.
/// The bounded retry interval is part of a state-based PollUntil, not a fixed
/// readiness delay.
@MainActor
private func pollUntilTraversal(
    pid: pid_t,
    timeout: Duration = .seconds(10),
    predicate: (ResponseData) -> Bool,
) async throws -> ResponseData {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastElementCount = 0
    var lastError: Error?

    while clock.now < deadline {
        try Task.checkCancellation()
        do {
            let result = try traverseAccessibilityTree(
                pid: pid,
                onlyVisibleElements: true,
                shouldActivate: false,
            )
            lastElementCount = result.elements.count
            if predicate(result) {
                return result
            }
        } catch {
            lastError = error
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    throw TraversalReadinessTimeout(
        pid: pid,
        lastElementCount: lastElementCount,
        lastError: lastError,
    )
}

private func hasRole(_ element: ElementData, _ role: String) -> Bool {
    element.role == role || element.role.hasPrefix("\(role) (")
}
