import AppKit
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import XCTest

enum MockPasteboardCall: Equatable, CustomStringConvertible {
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

/// Unit tests for ClipboardManager verifying clearContents is called before every write.
///
/// Per AGENTS.md: "ClipboardManager MUST call pasteboard.clearContents() before EVERY write operation"
/// Apple's NSPasteboard documentation states: "Clearing the pasteboard before writing is recommended."
///
/// These tests use a mock pasteboard to verify the exact call order.
final class ClipboardManagerTests: XCTestCase {
    // MARK: - Mock Pasteboard

    /// Mock pasteboard that records all method calls in order.
    final class MockPasteboard: @unchecked Sendable, ClipboardPasteboard {
        private let lock = NSLock()
        private var _calls: [MockPasteboardCall] = []
        private var _setStringResult = true
        private var _setDataResult = true
        private var _writeObjectsResult = true
        private var _content = Exactmac_V1_ClipboardContent()
        private var _changeCount = 0

        /// Recorded calls in order.
        var calls: [MockPasteboardCall] {
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
            _content = Exactmac_V1_ClipboardContent()
            _changeCount = 0
        }

        func installCurrentContent(_ content: Exactmac_V1_ClipboardContent) {
            setCurrentContent(content)
        }

        func installExternalContent(_ content: Exactmac_V1_ClipboardContent) {
            lock.lock()
            defer { lock.unlock() }
            _changeCount += 1
            _content = content
        }

        func changeCount() async -> Int {
            lock.withLock { _changeCount }
        }

        func clearContents() -> Int {
            lock.lock()
            defer { lock.unlock() }
            _calls.append(.clearContents)
            _changeCount += 1
            _content = Exactmac_V1_ClipboardContent()
            return _changeCount
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

        func read() async -> Exactmac_V1_Clipboard {
            snapshot()
        }

        func clear() async {
            _ = clearContents()
        }

        func write(_ content: Exactmac_V1_ClipboardContent) async -> Bool {
            let success: Bool = switch content.content {
            case let .text(text):
                setString(text, forType: .string)
            case let .rtf(data):
                setData(data, forType: .rtf)
            case let .html(html):
                html.data(using: .utf8).map { setData($0, forType: .html) } ?? false
            case let .image(data):
                NSImage(data: data).map { writeObjects([$0]) } ?? false
            case let .files(paths):
                writeObjects(paths.paths.map { URL(fileURLWithPath: $0) } as [NSURL])
            case let .url(value):
                URL(string: value).map { writeObjects([$0 as NSURL]) } ?? false
            case .none:
                false
            }
            if success {
                setCurrentContent(content)
            }
            return success
        }

        private func snapshot() -> Exactmac_V1_Clipboard {
            lock.lock()
            defer { lock.unlock() }
            let content = _content
            return Exactmac_V1_Clipboard.with {
                $0.name = "clipboard"
                $0.content = content
                if content.content != nil {
                    $0.availableTypes = [content.type]
                }
            }
        }

        private func setCurrentContent(_ content: Exactmac_V1_ClipboardContent) {
            lock.lock()
            defer { lock.unlock() }
            _content = content
        }
    }

    // MARK: - Properties

    private var mockPasteboard: MockPasteboard!
    private var manager: ClipboardManager!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        mockPasteboard = MockPasteboard()
        manager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: ClipboardHistoryManager(sourceApplication: { "Test source" }),
            pasteboard: mockPasteboard,
        )
    }

    override func tearDown() {
        mockPasteboard = nil
        manager = nil
        super.tearDown()
    }

    func testTemporaryTextRestoresOriginalClipboardAfterSuccess() async throws {
        let original = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("original")
        }
        mockPasteboard.installCurrentContent(original)
        let pasteboard = try XCTUnwrap(mockPasteboard)

        let staged = try await manager.withTemporaryText { replaceText in
            try await replaceText("λ")
            return await pasteboard.read()
        }

        XCTAssertEqual(staged.content.content, .text("λ"))
        let restored = await mockPasteboard.read()
        let pendingAccessCount = await manager.pendingClipboardAccessCount()
        XCTAssertEqual(restored.content, original)
        XCTAssertEqual(pendingAccessCount, 0)
    }

    func testTemporaryTextRestoresOriginalClipboardAfterOperationFailure() async throws {
        enum ExpectedFailure: Error {
            case operation
        }

        let original = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("original")
        }
        mockPasteboard.installCurrentContent(original)

        do {
            _ = try await manager.withTemporaryText { replaceText in
                try await replaceText("🙂")
                throw ExpectedFailure.operation
            }
            XCTFail("Expected the physical paste operation to fail")
        } catch ExpectedFailure.operation {
            // Expected.
        }

        let restored = await mockPasteboard.read()
        let pendingAccessCount = await manager.pendingClipboardAccessCount()
        XCTAssertEqual(restored.content, original)
        XCTAssertEqual(pendingAccessCount, 0)
    }

    func testTemporaryTextDoesNotOverwriteExternalClipboardMutation() async throws {
        let original = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("original")
        }
        let external = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("external")
        }
        mockPasteboard.installCurrentContent(original)
        let pasteboard = try XCTUnwrap(mockPasteboard)

        do {
            _ = try await manager.withTemporaryText { replaceText in
                try await replaceText("temporary")
                pasteboard.installExternalContent(external)
                return ()
            }
            XCTFail("Expected external clipboard ownership loss to fail closed")
        } catch {
            // The exact ownership error is asserted by the preserved bytes:
            // restoration must not overwrite the external owner's content.
        }

        let observed = await mockPasteboard.read()
        let pendingAccessCount = await manager.pendingClipboardAccessCount()
        XCTAssertEqual(observed.content, external)
        XCTAssertEqual(pendingAccessCount, 0)
    }

    func testTemporaryTextPreservesOperationAndExternalOwnershipFailures() async throws {
        enum ExpectedFailure: Error {
            case operation
        }

        let original = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("original")
        }
        let external = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text("external")
        }
        mockPasteboard.installCurrentContent(original)
        let pasteboard = try XCTUnwrap(mockPasteboard)

        do {
            _ = try await manager.withTemporaryText { replaceText in
                try await replaceText("temporary")
                pasteboard.installExternalContent(external)
                throw ExpectedFailure.operation
            }
            XCTFail("Expected operation and restoration failures")
        } catch let error as TemporaryClipboardRestorationError {
            XCTAssertTrue(error.operationError is ExpectedFailure)
        }

        let observed = await mockPasteboard.read()
        let pendingAccessCount = await manager.pendingClipboardAccessCount()
        XCTAssertEqual(observed.content, external)
        XCTAssertEqual(pendingAccessCount, 0)
    }

    // MARK: - Test: clearContents Called Before Write (Text)

    func testWriteText_clearContentsCalledBeforeSetString() async throws {
        var content = Exactmac_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Hello, World!")

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + setString")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .setString("Hello, World!"), "Second call must be setString()")
    }

    func testWriteText_clearContentsCalledExactlyOnce() async throws {
        var content = Exactmac_V1_ClipboardContent()
        content.type = .text
        content.content = .text("Test")

        _ = try await manager.writeClipboard(content: content)

        let clearCalls = mockPasteboard.calls.filter { $0 == .clearContents }
        XCTAssertEqual(clearCalls.count, 1, "clearContents() must be called exactly once per write")
    }

    // MARK: - Test: clearContents Called Before Write (RTF)

    func testWriteRTF_clearContentsCalledBeforeSetData() async throws {
        let rtfData = Data(#"{\rtf1\ansi RTF data}"#.utf8)
        var content = Exactmac_V1_ClipboardContent()
        content.type = .rtf
        content.content = .rtf(rtfData)

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + setData")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .setData(rtfData.count), "Second call must be setData()")
    }

    // MARK: - Test: clearContents Called Before Write (HTML)

    func testWriteHTML_clearContentsCalledBeforeSetData() async throws {
        let htmlString = "<html><body>Test</body></html>"
        var content = Exactmac_V1_ClipboardContent()
        content.type = .html
        content.content = .html(htmlString)

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + setData")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        guard case .setData = calls[1] else {
            XCTFail("Second call must be setData(), got: \(calls[1])")
            return
        }
    }

    // MARK: - Test: clearContents Called Before Write (URL)

    func testWriteURL_clearContentsCalledBeforeWriteObjects() async throws {
        var content = Exactmac_V1_ClipboardContent()
        content.type = .url
        content.content = .url("https://example.com")

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + writeObjects")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .writeObjects(1), "Second call must be writeObjects(1)")
    }

    // MARK: - Test: clearContents Called Before Write (Files)

    func testWriteFiles_clearContentsCalledBeforeWriteObjects() async throws {
        var filePaths = Exactmac_V1_FilePaths()
        filePaths.paths = ["/tmp/file1.txt", "/tmp/file2.txt"]

        var content = Exactmac_V1_ClipboardContent()
        content.type = .files
        content.content = .files(filePaths)

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + writeObjects")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .writeObjects(2), "Second call must be writeObjects(2)")
    }

    // MARK: - Test: clearContents Called Before Write (Image)

    func testWriteImage_clearContentsCalledBeforeWriteObjects() async throws {
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

        var content = Exactmac_V1_ClipboardContent()
        content.type = .image
        content.content = .image(pngData)

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2, "Expected exactly 2 calls: clearContents + writeObjects")
        XCTAssertEqual(calls[0], .clearContents, "First call must be clearContents()")
        XCTAssertEqual(calls[1], .writeObjects(1), "Second call must be writeObjects(1)")
    }

    // MARK: - Test: Multiple Writes Clear Each Time

    func testMultipleWrites_clearContentsCalledBeforeEachWrite() async throws {
        var content1 = Exactmac_V1_ClipboardContent()
        content1.type = .text
        content1.content = .text("First")

        var content2 = Exactmac_V1_ClipboardContent()
        content2.type = .text
        content2.content = .text("Second")

        var content3 = Exactmac_V1_ClipboardContent()
        content3.type = .text
        content3.content = .text("Third")

        _ = try await manager.writeClipboard(content: content1)
        _ = try await manager.writeClipboard(content: content2)
        _ = try await manager.writeClipboard(content: content3)

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

    func testWriteFailure_clearContentsStillCalledFirst() async throws {
        mockPasteboard.setStringResult = false

        var content = Exactmac_V1_ClipboardContent()
        content.type = .text
        content.content = .text("This will fail")

        do {
            _ = try await manager.writeClipboard(content: content)
            XCTFail("Expected writeFailed error")
        } catch let error as ClipboardError {
            guard case .writeFailed = error else {
                return XCTFail("Expected writeFailed error, got: \(error)")
            }
        } catch {
            XCTFail("Expected ClipboardError.writeFailed, got: \(error)")
        }

        // Even though write failed, clearContents must have been called first
        let calls = mockPasteboard.calls
        XCTAssertGreaterThanOrEqual(calls.count, 1)
        XCTAssertEqual(calls[0], .clearContents, "clearContents() must be called first even if write fails")
    }

    // MARK: - Test: No Content Throws Error (No clearContents called)

    func testNoContent_throwsError() async throws {
        let content = Exactmac_V1_ClipboardContent()
        // content.content is not set (none case)

        do {
            _ = try await manager.writeClipboard(content: content)
            XCTFail("Expected invalidContent error")
        } catch let error as ClipboardError {
            guard case .invalidContent = error else {
                return XCTFail("Expected invalidContent error, got: \(error)")
            }
        } catch {
            XCTFail("Expected ClipboardError.invalidContent, got: \(error)")
        }
        XCTAssertTrue(mockPasteboard.calls.isEmpty, "Invalid content must fail before clipboard mutation")
    }

    // MARK: - Test: Order Verification with Different Content Types

    func testMixedContentTypes_clearContentsAlwaysPrecedesWrite() async throws {
        // Write text
        var textContent = Exactmac_V1_ClipboardContent()
        textContent.type = .text
        textContent.content = .text("text")
        _ = try await manager.writeClipboard(content: textContent)

        // Write URL
        var urlContent = Exactmac_V1_ClipboardContent()
        urlContent.type = .url
        urlContent.content = .url("https://example.com")
        _ = try await manager.writeClipboard(content: urlContent)

        // Write RTF
        var rtfContent = Exactmac_V1_ClipboardContent()
        rtfContent.type = .rtf
        let rtfData = Data(#"{\rtf1\ansi rtf}"#.utf8)
        rtfContent.content = .rtf(rtfData)
        _ = try await manager.writeClipboard(content: rtfContent)

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
        XCTAssertEqual(calls[5], .setData(rtfData.count)) // RTF
    }

    // MARK: - Test: Empty Text Still Clears and Writes

    func testEmptyText_clearContentsStillCalled() async throws {
        var content = Exactmac_V1_ClipboardContent()
        content.type = .text
        content.content = .text("")

        _ = try await manager.writeClipboard(content: content)

        let calls = mockPasteboard.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], .clearContents)
        XCTAssertEqual(calls[1], .setString(""))
    }

    // MARK: - Test: Empty Files Array

    func testEmptyFilesArray_rejectedBeforeClearContents() async throws {
        var filePaths = Exactmac_V1_FilePaths()
        filePaths.paths = []

        var content = Exactmac_V1_ClipboardContent()
        content.type = .files
        content.content = .files(filePaths)

        do {
            _ = try await manager.writeClipboard(content: content)
            XCTFail("Expected empty file paths to be rejected")
        } catch let error as ClipboardError {
            guard case .invalidContent = error else {
                return XCTFail("Expected invalidContent, got \(error)")
            }
        }

        let calls = mockPasteboard.calls
        XCTAssertTrue(calls.isEmpty, "Invalid file content must fail before clipboard mutation")
    }
}
