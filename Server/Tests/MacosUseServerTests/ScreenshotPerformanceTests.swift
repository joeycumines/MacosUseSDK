import Foundation
import Testing

@testable import MacosUseProto
@testable import MacosUseServer

/// Performance benchmarks for screenshot capture operations.
///
/// These tests measure ScreenshotCapture latency across different scenarios:
/// - Image formats: PNG, JPEG, TIFF
/// - OCR: with and without text extraction
/// - Capture types: full screen, window, region
@Suite("Screenshot Capture Performance Benchmarks")
struct ScreenshotPerformanceTests {
    /// Number of iterations for stable timing
    private let iterations = 5

    // MARK: - Format Comparison Tests

    /// Benchmark full screen capture with PNG format.
    @Test("Full screen PNG capture latency")
    @MainActor
    func testFullScreenPNGCapture() async throws {
        var durations: [TimeInterval] = []
        var dataSizes: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureScreen(
                format: .png,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            dataSizes.append(result.data.count)
        }

        printMetrics(name: "Full Screen PNG", durations: durations, dataSizes: dataSizes)
        #expect(durations.min()! < 2.0, "PNG capture should complete under 2 seconds")
    }

    /// Benchmark full screen capture with JPEG format.
    @Test("Full screen JPEG capture latency")
    @MainActor
    func testFullScreenJPEGCapture() async throws {
        var durations: [TimeInterval] = []
        var dataSizes: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureScreen(
                format: .jpeg,
                quality: 85,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            dataSizes.append(result.data.count)
        }

        printMetrics(name: "Full Screen JPEG (q=85)", durations: durations, dataSizes: dataSizes)
        #expect(durations.min()! < 2.0, "JPEG capture should complete under 2 seconds")
    }

    /// Benchmark full screen capture with TIFF format.
    @Test("Full screen TIFF capture latency")
    @MainActor
    func testFullScreenTIFFCapture() async throws {
        var durations: [TimeInterval] = []
        var dataSizes: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureScreen(
                format: .tiff,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            dataSizes.append(result.data.count)
        }

        printMetrics(name: "Full Screen TIFF", durations: durations, dataSizes: dataSizes)
        #expect(durations.min()! < 3.0, "TIFF capture should complete under 3 seconds")
    }

    // MARK: - OCR Comparison Tests

    /// Benchmark full screen capture with OCR enabled.
    @Test("Full screen with OCR latency")
    @MainActor
    func testFullScreenWithOCR() async throws {
        var durations: [TimeInterval] = []
        var ocrLengths: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureScreen(
                format: .png,
                includeOCR: true
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            ocrLengths.append(result.ocrText?.count ?? 0)
        }

        let avgOCRLength = ocrLengths.reduce(0, +) / iterations
        printMetrics(name: "Full Screen + OCR", durations: durations, dataSizes: nil)
        print("  Avg OCR text length: \(avgOCRLength) chars")

        // OCR adds latency but should still be reasonable
        #expect(durations.min()! < 5.0, "OCR capture should complete under 5 seconds")
    }

    /// Compare OCR vs no-OCR latency
    @Test("OCR overhead comparison")
    @MainActor
    func testOCROverhead() async throws {
        // Without OCR
        let noOCRStart = CFAbsoluteTimeGetCurrent()
        _ = try await ScreenshotCapture.captureScreen(format: .png, includeOCR: false)
        let noOCRDuration = CFAbsoluteTimeGetCurrent() - noOCRStart

        // With OCR
        let withOCRStart = CFAbsoluteTimeGetCurrent()
        _ = try await ScreenshotCapture.captureScreen(format: .png, includeOCR: true)
        let withOCRDuration = CFAbsoluteTimeGetCurrent() - withOCRStart

        let overhead = withOCRDuration - noOCRDuration

        print("""
        ===== OCR Overhead Comparison =====
        Without OCR: \(String(format: "%.3f", noOCRDuration * 1000))ms
        With OCR: \(String(format: "%.3f", withOCRDuration * 1000))ms
        OCR Overhead: \(String(format: "%.3f", overhead * 1000))ms
        ===================================
        """)
    }

    // MARK: - Window Capture Tests

    /// Benchmark window capture for Finder.
    ///
    /// Uses Finder as it's always available on macOS.
    @Test("Window capture latency (Finder)")
    @MainActor
    func testWindowCapture() async throws {
        // Find a Finder window
        guard let finderApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            Issue.record("Finder not running - test cannot proceed")
            return
        }

        // Get window list from CGWindowList for Finder
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let finderWindows = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  let layer = info[kCGWindowLayer] as? Int32,
                  layer == 0  // Normal windows
            else { return false }
            return ownerPID == finderApp.processIdentifier
        }

        guard let windowInfo = finderWindows.first,
              let windowID = windowInfo[kCGWindowNumber] as? CGWindowID
        else {
            Issue.record("No Finder window found - test cannot proceed")
            return
        }

        var durations: [TimeInterval] = []
        var dataSizes: [Int] = []

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureWindow(
                windowID: windowID,
                format: .png,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            dataSizes.append(result.data.count)
        }

        printMetrics(name: "Window Capture (Finder)", durations: durations, dataSizes: dataSizes)
        #expect(durations.min()! < 2.0, "Window capture should complete under 2 seconds")
    }

    // MARK: - Region Capture Tests

    /// Benchmark region capture for a small area.
    @Test("Small region capture latency")
    @MainActor
    func testSmallRegionCapture() async throws {
        var durations: [TimeInterval] = []

        // Small 200x200 region
        let region = CGRect(x: 100, y: 100, width: 200, height: 200)

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureRegion(
                bounds: region,
                format: .png,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            _ = result  // Suppress unused warning
        }

        printMetrics(name: "Small Region (200x200)", durations: durations, dataSizes: nil)
        #expect(durations.min()! < 1.0, "Small region capture should complete under 1 second")
    }

    /// Benchmark region capture for a larger area.
    @Test("Large region capture latency")
    @MainActor
    func testLargeRegionCapture() async throws {
        var durations: [TimeInterval] = []

        // Large 1000x800 region
        let region = CGRect(x: 0, y: 0, width: 1000, height: 800)

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureRegion(
                bounds: region,
                format: .png,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            durations.append(duration)
            _ = result
        }

        printMetrics(name: "Large Region (1000x800)", durations: durations, dataSizes: nil)
        #expect(durations.min()! < 2.0, "Large region capture should complete under 2 seconds")
    }

    // MARK: - JPEG Quality Comparison

    /// Compare JPEG quality settings impact on size and latency.
    @Test("JPEG quality comparison")
    @MainActor
    func testJPEGQualityComparison() async throws {
        let qualities: [Int32] = [50, 75, 90, 100]
        var results: [(quality: Int32, duration: TimeInterval, size: Int)] = []

        for quality in qualities {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await ScreenshotCapture.captureScreen(
                format: .jpeg,
                quality: quality,
                includeOCR: false
            )
            let duration = CFAbsoluteTimeGetCurrent() - start

            results.append((quality, duration, result.data.count))
        }

        print("===== JPEG Quality Comparison =====")
        for r in results {
            let sizeKB = Double(r.size) / 1024.0
            print("Quality \(r.quality): \(String(format: "%.3f", r.duration * 1000))ms, \(String(format: "%.1f", sizeKB))KB")
        }
        print("===================================")
    }

    // MARK: - Helpers

    private func printMetrics(name: String, durations: [TimeInterval], dataSizes: [Int]?) {
        let avgDuration = durations.reduce(0, +) / Double(durations.count)
        let minDuration = durations.min() ?? 0
        let maxDuration = durations.max() ?? 0

        var output = """
        ===== \(name) Benchmark =====
        Iterations: \(durations.count)
        Avg Duration: \(String(format: "%.3f", avgDuration * 1000))ms
        Min Duration: \(String(format: "%.3f", minDuration * 1000))ms
        Max Duration: \(String(format: "%.3f", maxDuration * 1000))ms
        """

        if let sizes = dataSizes, !sizes.isEmpty {
            let avgSize = sizes.reduce(0, +) / sizes.count
            let sizeKB = Double(avgSize) / 1024.0
            output += "\n  Avg Size: \(String(format: "%.1f", sizeKB))KB"
        }

        output += "\n" + String(repeating: "=", count: name.count + 18)
        print(output)
    }
}
