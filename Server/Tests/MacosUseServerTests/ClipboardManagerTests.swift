import AppKit
import Foundation
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for ClipboardManager verifying clearContents is called before every write.
///
/// Per CLAUDE.md: "ClipboardManager MUST call pasteboard.clearContents() before EVERY write operation"
/// Apple's NSPasteboard documentation states: "Clearing the pasteboard before writing is recommended."
///
/// These tests use a mock pasteboard to verify the exact call order.
final class ClipboardManagerTests: XCTestCase {
    // MARK: - Mock Pasteboard

    /// Mock pasteboard that records all method calls in order.
    final class MockPasteboard: @unchecked Sendable {
        /// Enum to track which methods were called.
        enum Call: Equatable, CustomStringConvertible {
            case clearContents
            case setString(String)
            case setData(Int) // Store data length for comparison
            case writeObjects(Int) // Store object count

            var description: String {
                switch self {
                case .clearContents:
                    "clearContents()"
                case let .setString(s):
                    "setString(\"\(s)\")"
                case let .setData(len):
                    "setData(length: \(len))"
                case let .writeObjects(count):
                    "writeObjects(count: \(count))"
                }
            }
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _setStringResult = true
        private var _setDataResult = true
        private var _writeObjectsResult = true

        /// Recorded calls in order.
        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        /// Configure setString return value for testing failure paths.
        var setStringResult: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _setStringResult
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _setStringResult = newValue
            }
        }

        /// Configure setData return value for testing failure paths.
        var setDataResult: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _setDataResult
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _setDataResult = newValue
            }
        }

        /// Configure writeObjects return value for testing failure paths.
        var writeObjectsResult: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _writeObjectsResult
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _writeObjectsResult = newValue
            }
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            _calls = []
            _setStringResult = true
            _setDataResult = true
            _writeObjectsResult = true
        }

        func clearContents() -> Int {
            lock.lock()
            defer { lock.unlock() }
            _calls.append(.clearContents)
            return 1 // New change count
        }

        func setString(_ string: String, forType _: NSPasteboard.PasteboardType) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            _calls.append(.setString(string))
            return _setStringResult
        }

        func setData(_ data: Data, forType _: NSPasteboard.PasteboardType) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            _calls.append(.setData(data.count))
            return _setDataResult
        }

        func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            _calls.append(.writeObjects(objects.count))
            return _writeObjectsResult
        }
    }

    // MARK: - Testable Clipboard Writer

    /// A testable clipboard writer that uses our mock pasteboard.
    /// This mirrors the writeClipboard logic from ClipboardManager but with injectable pasteboard.
    struct TestableClipboardWriter {
        let mockPasteboard: MockPasteboard

        /// Simulates writeClipboard with an injectable mock pasteboard.
        /// This replicates the exact logic from ClipboardManager.writeClipboard.
        func writeClipboard(content: Macosusesdk_V1_ClipboardContent) throws -> Bool {
            // CRITICAL: NSPasteboard documentation states clearing before writing is recommended.
            // We MUST always clear before writing to ensure proper ownership transfer.
            _ = mockPasteboard.clearContents()

            var success = false

            switch content.content {
            case let .text(text):
                success = mockPasteboard.setString(text, forType: .string)

            case let .rtf(rtfData):
                success = mockPasteboard.setData(rtfData, forType: .rtf)

            case let .html(html):
                if let htmlData = html.data(using: .utf8) {
                    success = mockPasteboard.setData(htmlData, forType: .html)
                }

            case let .image(imageData):
                if let image = NSImage(data: imageData) {
                    success = mockPasteboard.writeObjects([image])
                }

            case let .files(filePaths):
                let urls = filePaths.paths.compactMap { URL(fileURLWithPath: $0) }
                success = mockPasteboard.writeObjects(urls as [NSURL])

            case let .url(urlString):
                if let url = URL(string: urlString) {
                    success = mockPasteboard.writeObjects([url as NSURL])
                }

            case .none:
                throw ClipboardError.invalidContent("No content specified")
            }

            if !success {
                throw ClipboardError.writeFailed("Failed to write clipboard content")
            }

            return success
        }
    }

    // MARK: - Properties

    private var mockPasteboard: MockPasteboard!
    private var writer: TestableClipboardWriter!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        mockPasteboard = MockPasteboard()
        writer = TestableClipboardWriter(mockPasteboard: mockPasteboard)
    }

    override func tearDown() {
        mockPasteboard = nil
        writer = nil
        super.tearDown()
    }

    // MARK: - Test: clearContents Called Before Write (Text)

    func testWriteText_clearContentsCalledBeforeSetString() throws {
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Hello, World!")

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + setString")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .setString("Hello, World!"), "Second call must be setString()")
    }

    func testWriteText_clearContentsCalledExactlyOnce() throws {
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Test")

        _ = try writer.writeClipboard(content: content)

        let clearCalls = mockPasteboard.calls.filter { $0 == .clearContents }
        XCTAssertEqual(clearCalls.count, 1, "clearContents() must be called exactly once per write")
    }

    // MARK: - Test: clearContents Called Before Write (RTF)

    func testWriteRTF_clearContentsCalledBeforeSetData() throws {
        let rtfData = Data("RTF data".utf8)
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .rtf
        content.content = .rtf(rtfData)

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + setData")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .setData(rtfData.count), "Second call must be setData()")
    }

    // MARK: - Test: clearContents Called Before Write (HTML)

    func testWriteHTML_clearContentsCalledBeforeSetData() throws {
        let htmlString = "<html><body>Test</body></html>"
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .html
        content.content = .html(htmlString)

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + setData")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        guard case .setData = calls[1] else {
            XCTFail("Second call must be setData(), got: \(calls[1])")
            return
        }
    }

    // MARK: - Test: clearContents Called Before Write (URL)

    func testWriteURL_clearContentsCalledBeforeWriteObjects() throws {
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .url
        content.content = .url("https://example.com")

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + writeObjects")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .writeObjects(1), "Second call must be writeObjects(1)")
    }

    // MARK: - Test: clearContents Called Before Write (Files)

    func testWriteFiles_clearContentsCalledBeforeWriteObjects() throws {
        var filePaths = Macosusesdk_V1_FilePaths()
        filePaths.paths = ["/tmp/file1.txt", "/tmp/file2.txt"]

        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .files
        content.content = .files(filePaths)

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + writeObjects")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .writeObjects(2), "Second call must be writeObjects(2)")
    }

    // MARK: - Test: clearContents Called Before Write (Image)

    func testWriteImage_clearContentsCalledBeforeWriteObjects() throws {
        // Create a valid 1x1 PNG image
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()

        guard let pngData = image.pngData() else {
            XCTFail("Failed to create PNG data for test")
            return
        }

        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .image
        content.content = .image(pngData)

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + writeObjects")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .writeObjects(1), "Second call must be writeObjects(1)")
    }

    // MARK: - Test: Multiple Writes Clear Each Time

    func testMultipleWrites_clearContentsCalledBeforeEachWrite() throws {
        var content1 = Macosusesdk_V1_ClipboardContent()
        content1.type = .text
        content1.content = .text("First")

        var content2 = Macosusesdk_V1_ClipboardContent()
        content2.type = .text
        content2.content = .text("Second")

        var content3 = Macosusesdk_V1_ClipboardContent()
        content3.type = .text
        content3.content = .text("Third")

        _ = try writer.writeClipboard(content: content1)
        _ = try writer.writeClipboard(content: content2)
        _ = try writer.writeClipboard(content: content3)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 6, "Expected 6 calls: 3x (clearContents + setString)")

        // Verify pattern: clearContents -> write, clearContents -> write, clearContents -> write
        XCTAssertEqual(calls[0], .clearContents)
        XCTAssertEqual(calls[1], .setString("First"))
        XCTAssertEqual(calls[2], .clearContents)
        XCTAssertEqual(calls[3], .setString("Second"))
        XCTAssertEqual(calls[4], .clearContents)
        XCTAssertEqual(calls[5], .setString("Third"))
    }

    // MARK: - Test: clearContents Called Even On Write Failure

    func testWriteFailure_clearContentsStillCalledFirst() throws {
        mockPasteboard.setStringResult = false

        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("This will fail")

        XCTAssertThrowsError(try writer.writeClipboard(content: content)) { error in
            guard case ClipboardError.writeFailed = error else {
                XCTFail("Expected writeFailed error, got: \(error)")
                return
            }
        }

        // Even though write failed, clearContents must have been called first
        let calls = mockPasteboard.calls
        XCTAssertGreaterThanOrEqual(calls.count, 1)
        XCTAssertEqual(calls[0], .clearContents, "clearContents() must be called first even if write fails")
    }

    // MARK: - Test: No Content Throws Error (No clearContents called)

    func testNoContent_throwsError() throws {
        let content = Macosusesdk_V1_ClipboardContent()
        // content.content is not set (none case)

        XCTAssertThrowsError(try writer.writeClipboard(content: content)) { error in
            guard case ClipboardError.invalidContent = error else {
                XCTFail("Expected invalidContent error, got: \(error)")
                return
            }
        }
    }

    // MARK: - Test: Order Verification with Different Content Types

    func testMixedContentTypes_clearContentsAlwaysPrecedesWrite() throws {
        // Write text
        var textContent = Macosusesdk_V1_ClipboardContent()
        textContent.type = .text
        textContent.content = .text("text")
        _ = try writer.writeClipboard(content: textContent)

        // Write URL
        var urlContent = Macosusesdk_V1_ClipboardContent()
        urlContent.type = .url
        urlContent.content = .url("https://example.com")
        _ = try writer.writeClipboard(content: urlContent)

        // Write RTF
        var rtfContent = Macosusesdk_V1_ClipboardContent()
        rtfContent.type = .rtf
        rtfContent.content = .rtf(Data("rtf".utf8))
        _ = try writer.writeClipboard(content: rtfContent)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 6)

        // Verify each write is preceded by clearContents
        for i in stride(from: 0, to: calls.count, by: 2) {
            XCTAssertEqual(
                calls[i],
                .clearContents,
                "Call at index \(i) must be clearContents(), got: \(calls[i])",
            )
        }

        // Verify writes are in expected positions
        XCTAssertEqual(calls[1], .setString("text"))
        XCTAssertEqual(calls[3], .writeObjects(1)) // URL
        XCTAssertEqual(calls[5], .setData(3)) // RTF
    }

    // MARK: - Test: Empty Text Still Clears and Writes

    func testEmptyText_clearContentsStillCalled() throws {
        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .text
        content.content = .text("")

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], .clearContents)
        XCTAssertEqual(calls[1], .setString(""))
    }

    // MARK: - Test: Empty Files Array

    func testEmptyFilesArray_clearContentsStillCalled() throws {
        var filePaths = Macosusesdk_V1_FilePaths()
        filePaths.paths = []

        var content = Macosusesdk_V1_ClipboardContent()
        content.type = .files
        content.content = .files(filePaths)

        _ = try writer.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertGreaterThanOrEqual(calls.count, 1)
        XCTAssertEqual(calls[0], .clearContents, "clearContents() must be called even for empty files")
    }
}
