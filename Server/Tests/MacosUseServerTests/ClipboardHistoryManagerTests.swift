import AppKit
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for ClipboardHistoryManager and NSImage.pngData extension.
///
/// ClipboardHistoryManager is an actor that manages clipboard history entries.
/// These tests verify the history management logic without touching NSPasteboard.
final class ClipboardHistoryManagerTests: XCTestCase {
    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        // Reset history before each test to ensure isolation
        await ClipboardHistoryManager.shared._resetForTesting()
    }

    override func tearDown() async throws {
        // Clean up after test
        await ClipboardHistoryManager.shared._resetForTesting()
        try await super.tearDown()
    }

    // MARK: - ClipboardHistoryManager Tests

    func testAddEntry_addsToHistory() async {
        let manager = ClipboardHistoryManager.shared

        // Create content and add entry
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Test content")

        await manager.addEntry(content: content)

        let history = await manager.getHistory()
        XCTAssertEqual(history.entries.count, 1)
    }

    func testAddEntry_mostRecentFirst() async {
        let manager = ClipboardHistoryManager.shared

        // Add first entry
        var content1 = Macosusesdk_V1_ClipboardContent()
        content1.type = .text
        content1.content = .text("First")
        await manager.addEntry(content: content1)

        // Add second entry
        var content2 = Macosusesdk_V1_ClipboardContent()
        content2.type = .text
        content2.content = .text("Second")
        await manager.addEntry(content: content2)

        let history = await manager.getHistory()
        XCTAssertEqual(history.entries.count, 2)
        guard case let .text(latestText) = history.entries.first?.content.content else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertEqual(latestText, "Second")
    }

    func testAddEntry_setCopiedTime() async {
        let manager = ClipboardHistoryManager.shared

        let beforeAdd = Date()

        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Time test")
        await manager.addEntry(content: content)

        let afterAdd = Date()

        let history = await manager.getHistory()
        XCTAssertEqual(history.entries.count, 1)
        let firstEntry = history.entries[0]

        let copiedTime = firstEntry.copiedTime.date
        XCTAssertGreaterThanOrEqual(copiedTime, beforeAdd)
        XCTAssertLessThanOrEqual(copiedTime, afterAdd)
    }

    func testAddEntry_setsSourceApplication() async {
        let manager = ClipboardHistoryManager.shared

        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Source app test")
        await manager.addEntry(content: content)

        let history = await manager.getHistory()
        XCTAssertEqual(history.entries.count, 1)
        let firstEntry = history.entries[0]

        // Source application should be set to something (even "Unknown")
        XCTAssertFalse(firstEntry.sourceApplication.isEmpty)
    }

    func testGetHistory_emptyByDefault() async {
        let manager = ClipboardHistoryManager.shared

        let history = await manager.getHistory()

        // After reset, history should be empty
        XCTAssertEqual(history.entries.count, 0)
    }

    func testAddEntry_limitEnforcedAtMaxEntries() async {
        let manager = ClipboardHistoryManager.shared
        let maxEntries = await manager._maxEntries

        // Add entries up to max + 10
        for i in 0 ..< (maxEntries + 10) {
            var content = Macosusesdk_V1_ClipboardContent()
            content.type = .text
            content.content = .text("Entry \(i)")
            await manager.addEntry(content: content)
        }

        let history = await manager.getHistory()

        // Should be capped at maxEntries
        XCTAssertEqual(history.entries.count, maxEntries)

        // Most recent should be the last added entry
        guard case let .text(latestText) = history.entries.first?.content.content else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertEqual(latestText, "Entry \(maxEntries + 9)")
    }

    func testAddEntry_differentContentTypes() async {
        let manager = ClipboardHistoryManager.shared

        // Add text
        var textContent = Macosusesdk_V1_ClipboardContent()
        textContent.type = .text
        textContent.content = .text("Plain text")
        await manager.addEntry(content: textContent)

        // Add URL
        var urlContent = Macosusesdk_V1_ClipboardContent()
        urlContent.type = .url
        urlContent.content = .url("https://example.com")
        await manager.addEntry(content: urlContent)

        let history = await manager.getHistory()
        XCTAssertEqual(history.entries.count, 2)

        // URL is most recent
        XCTAssertEqual(history.entries[0].content.type, .url)
        XCTAssertEqual(history.entries[1].content.type, .text)
    }

    // MARK: - NSImage.pngData Extension Tests

    func testPngData_validImageReturnsPngData() {
        // Create a simple 1x1 red image
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()

        let pngData = image.pngData()

        XCTAssertNotNil(pngData)
        guard let data = pngData else { return }

        // Check PNG signature bytes
        let signature = Array(data.prefix(8))
        let expectedSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(signature, expectedSignature, "Data should have PNG signature")
    }

    func testPngData_canBeReconstructedAsNSImage() {
        // Create a simple test image
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.blue.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()

        guard let pngData = image.pngData() else {
            XCTFail("Expected pngData to succeed")
            return
        }

        let reconstructedImage = NSImage(data: pngData)
        XCTAssertNotNil(reconstructedImage)
    }

    func testPngData_largerImageWorks() {
        // Create a larger image
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.green.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 100, height: 100))
        image.unlockFocus()

        let pngData = image.pngData()

        XCTAssertNotNil(pngData)
        XCTAssertGreaterThan(pngData?.count ?? 0, 0)
    }

    // MARK: - ClipboardError Tests (Supplementary)

    func testClipboardError_localizedErrorConformance() {
        let errors: [ClipboardError] = [
            .invalidContent("test"),
            .writeFailed("test"),
            .readFailed("test"),
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
    }
}
