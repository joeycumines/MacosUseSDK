import CoreGraphics
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for FileDialogMethods (automateOpenFileDialog, automateSaveFileDialog,
/// selectFile, selectDirectory, dragFiles).
///
/// These tests verify proto structure construction, validation error handling,
/// and response structures. Actual file system operations are tested in
/// FileDialogAutomationTests.swift.
final class FileDialogMethodsTests: XCTestCase {
    var service: MacosUseService!

    override func setUp() async throws {
        let registry = WindowRegistry(system: ProductionSystemOperations.shared)
        service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: ProductionSystemOperations.shared,
        )
    }

    override func tearDown() async throws {
        service = nil
    }

    // MARK: - Helpers

    private func makeAutomateOpenFileDialogRequest(
        _ msg: Macosusesdk_V1_AutomateOpenFileDialogRequest = Macosusesdk_V1_AutomateOpenFileDialogRequest(),
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_AutomateOpenFileDialogRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeAutomateSaveFileDialogRequest(
        _ msg: Macosusesdk_V1_AutomateSaveFileDialogRequest = Macosusesdk_V1_AutomateSaveFileDialogRequest(),
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_AutomateSaveFileDialogRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeSelectFileRequest(
        _ msg: Macosusesdk_V1_SelectFileRequest = Macosusesdk_V1_SelectFileRequest(),
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_SelectFileRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeSelectDirectoryRequest(
        _ msg: Macosusesdk_V1_SelectDirectoryRequest = Macosusesdk_V1_SelectDirectoryRequest(),
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_SelectDirectoryRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeDragFilesRequest(
        _ msg: Macosusesdk_V1_DragFilesRequest = Macosusesdk_V1_DragFilesRequest(),
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_DragFilesRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeContext(descriptor: MethodDescriptor) -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeAutomateOpenFileDialogContext() -> GRPCCore.ServerContext {
        makeContext(descriptor: Macosusesdk_V1_MacosUse.Method.AutomateOpenFileDialog.descriptor)
    }

    private func makeAutomateSaveFileDialogContext() -> GRPCCore.ServerContext {
        makeContext(descriptor: Macosusesdk_V1_MacosUse.Method.AutomateSaveFileDialog.descriptor)
    }

    private func makeSelectFileContext() -> GRPCCore.ServerContext {
        makeContext(descriptor: Macosusesdk_V1_MacosUse.Method.SelectFile.descriptor)
    }

    private func makeSelectDirectoryContext() -> GRPCCore.ServerContext {
        makeContext(descriptor: Macosusesdk_V1_MacosUse.Method.SelectDirectory.descriptor)
    }

    private func makeDragFilesContext() -> GRPCCore.ServerContext {
        makeContext(descriptor: Macosusesdk_V1_MacosUse.Method.DragFiles.descriptor)
    }

    // MARK: - Proto Request/Response Structure Tests

    func testAutomateOpenFileDialogRequestConstruction() {
        var request = Macosusesdk_V1_AutomateOpenFileDialogRequest()
        request.filePath = "/path/to/file.txt"
        request.defaultDirectory = "/Users"
        request.fileFilters = ["*.txt", "*.pdf"]
        request.allowMultiple = true

        XCTAssertEqual(request.filePath, "/path/to/file.txt")
        XCTAssertEqual(request.defaultDirectory, "/Users")
        XCTAssertEqual(request.fileFilters, ["*.txt", "*.pdf"])
        XCTAssertTrue(request.allowMultiple)
    }

    func testAutomateOpenFileDialogRequestDefaultValues() {
        let request = Macosusesdk_V1_AutomateOpenFileDialogRequest()

        XCTAssertTrue(request.filePath.isEmpty)
        XCTAssertTrue(request.defaultDirectory.isEmpty)
        XCTAssertTrue(request.fileFilters.isEmpty)
        XCTAssertFalse(request.allowMultiple)
    }

    func testAutomateOpenFileDialogResponseConstruction() {
        var response = Macosusesdk_V1_AutomateOpenFileDialogResponse()
        response.success = true
        response.selectedPaths = ["/path/to/file1.txt", "/path/to/file2.txt"]
        response.error = ""

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.selectedPaths.count, 2)
        XCTAssertTrue(response.error.isEmpty)
    }

    func testAutomateOpenFileDialogResponseErrorCase() {
        var response = Macosusesdk_V1_AutomateOpenFileDialogResponse()
        response.success = false
        response.selectedPaths = []
        response.error = "Dialog was cancelled"

        XCTAssertFalse(response.success)
        XCTAssertTrue(response.selectedPaths.isEmpty)
        XCTAssertFalse(response.error.isEmpty)
    }

    func testAutomateSaveFileDialogRequestConstruction() {
        var request = Macosusesdk_V1_AutomateSaveFileDialogRequest()
        request.filePath = "/path/to/save.txt"
        request.defaultDirectory = "/Documents"
        request.defaultFilename = "document.txt"
        request.confirmOverwrite = true

        XCTAssertEqual(request.filePath, "/path/to/save.txt")
        XCTAssertEqual(request.defaultDirectory, "/Documents")
        XCTAssertEqual(request.defaultFilename, "document.txt")
        XCTAssertTrue(request.confirmOverwrite)
    }

    func testAutomateSaveFileDialogRequestDefaultValues() {
        let request = Macosusesdk_V1_AutomateSaveFileDialogRequest()

        XCTAssertTrue(request.filePath.isEmpty)
        XCTAssertTrue(request.defaultDirectory.isEmpty)
        XCTAssertTrue(request.defaultFilename.isEmpty)
        XCTAssertFalse(request.confirmOverwrite)
    }

    func testAutomateSaveFileDialogResponseConstruction() {
        var response = Macosusesdk_V1_AutomateSaveFileDialogResponse()
        response.success = true
        response.savedPath = "/path/to/saved.txt"

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.savedPath, "/path/to/saved.txt")
        XCTAssertTrue(response.error.isEmpty)
    }

    func testSelectFileRequestConstruction() {
        var request = Macosusesdk_V1_SelectFileRequest()
        request.filePath = "/path/to/select.txt"
        request.revealFinder = true

        XCTAssertEqual(request.filePath, "/path/to/select.txt")
        XCTAssertTrue(request.revealFinder)
    }

    func testSelectFileRequestDefaultValues() {
        let request = Macosusesdk_V1_SelectFileRequest()

        XCTAssertTrue(request.filePath.isEmpty)
        XCTAssertFalse(request.revealFinder)
    }

    func testSelectFileResponseConstruction() {
        var response = Macosusesdk_V1_SelectFileResponse()
        response.success = true
        response.selectedPath = "/path/to/selected.txt"

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.selectedPath, "/path/to/selected.txt")
        XCTAssertTrue(response.error.isEmpty)
    }

    func testSelectDirectoryRequestConstruction() {
        var request = Macosusesdk_V1_SelectDirectoryRequest()
        request.directoryPath = "/path/to/directory"
        request.createMissing = true

        XCTAssertEqual(request.directoryPath, "/path/to/directory")
        XCTAssertTrue(request.createMissing)
    }

    func testSelectDirectoryRequestDefaultValues() {
        let request = Macosusesdk_V1_SelectDirectoryRequest()

        XCTAssertTrue(request.directoryPath.isEmpty)
        XCTAssertFalse(request.createMissing)
    }

    func testSelectDirectoryResponseConstruction() {
        var response = Macosusesdk_V1_SelectDirectoryResponse()
        response.success = true
        response.selectedPath = "/path/to/dir"
        response.created = true

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.selectedPath, "/path/to/dir")
        XCTAssertTrue(response.created)
        XCTAssertTrue(response.error.isEmpty)
    }

    func testDragFilesRequestConstruction() {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/file1.txt", "/path/file2.txt"]
        request.targetElementID = "elem_12345_67890"
        request.duration = 0.5

        XCTAssertEqual(request.filePaths.count, 2)
        XCTAssertEqual(request.targetElementID, "elem_12345_67890")
        XCTAssertEqual(request.duration, 0.5)
    }

    func testDragFilesRequestDefaultValues() {
        let request = Macosusesdk_V1_DragFilesRequest()

        XCTAssertTrue(request.filePaths.isEmpty)
        XCTAssertTrue(request.targetElementID.isEmpty)
        XCTAssertEqual(request.duration, 0.0)
    }

    func testDragFilesResponseConstruction() {
        var response = Macosusesdk_V1_DragFilesResponse()
        response.success = true
        response.filesDropped = 3

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.filesDropped, 3)
        XCTAssertTrue(response.error.isEmpty)
    }

    func testDragFilesResponseErrorCase() {
        var response = Macosusesdk_V1_DragFilesResponse()
        response.success = false
        response.filesDropped = 0
        response.error = "Target element not found"

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.filesDropped, 0)
        XCTAssertEqual(response.error, "Target element not found")
    }

    // MARK: - Validation Error Tests

    func testAutomateSaveFileDialogEmptyPathReturnsValidationError() async throws {
        let request = Macosusesdk_V1_AutomateSaveFileDialogRequest()

        do {
            _ = try await service.automateSaveFileDialog(
                request: makeAutomateSaveFileDialogRequest(request),
                context: makeAutomateSaveFileDialogContext(),
            )
            XCTFail("Expected validation error for empty file_path")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("file_path"),
                "Error message should mention file_path: \(error.message)",
            )
        }
    }

    func testSelectFileEmptyPathReturnsValidationError() async throws {
        let request = Macosusesdk_V1_SelectFileRequest()

        do {
            _ = try await service.selectFile(
                request: makeSelectFileRequest(request),
                context: makeSelectFileContext(),
            )
            XCTFail("Expected validation error for empty file_path")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("file_path"),
                "Error message should mention file_path: \(error.message)",
            )
        }
    }

    func testSelectDirectoryEmptyPathReturnsValidationError() async throws {
        let request = Macosusesdk_V1_SelectDirectoryRequest()

        do {
            _ = try await service.selectDirectory(
                request: makeSelectDirectoryRequest(request),
                context: makeSelectDirectoryContext(),
            )
            XCTFail("Expected validation error for empty directory_path")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("directory_path"),
                "Error message should mention directory_path: \(error.message)",
            )
        }
    }

    func testDragFilesEmptyFilePathsReturnsValidationError() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.targetElementID = "elem_valid_id"
        // filePaths is empty

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(request),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for empty file_paths")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("file_paths"),
                "Error message should mention file_paths: \(error.message)",
            )
        }
    }

    func testDragFilesEmptyTargetElementIDReturnsValidationError() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        // targetElementID is empty

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(request),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for empty target_element_id")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("target_element_id"),
                "Error message should mention target_element_id: \(error.message)",
            )
        }
    }

    func testDragFilesNegativeDurationReturnsValidationError() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        request.targetElementID = "elem_valid_id"
        request.duration = -1.0

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(request),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for negative duration")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("duration"),
                "Error message should mention duration: \(error.message)",
            )
        }
    }

    func testDragFilesInfiniteDurationReturnsValidationError() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        request.targetElementID = "elem_valid_id"
        request.duration = .infinity

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(request),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for infinite duration")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("duration"),
                "Error message should mention duration: \(error.message)",
            )
        }
    }

    func testDragFilesNaNDurationReturnsValidationError() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        request.targetElementID = "elem_valid_id"
        request.duration = .nan

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(request),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for NaN duration")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(
                error.message.contains("duration"),
                "Error message should mention duration: \(error.message)",
            )
        }
    }

    // MARK: - RPC Handler Response Tests

    func testDragFilesWithNonexistentElementReturnsErrorInResponse() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        request.targetElementID = "elem_nonexistent_12345"
        request.duration = 0.5

        let response = try await service.dragFiles(
            request: makeDragFilesRequest(request),
            context: makeDragFilesContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(
            msg.error.contains("not found"),
            "Error should mention element not found: \(msg.error)",
        )
    }

    func testDragFilesMultipleFilesValidation() {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = [
            "/path/to/file1.txt",
            "/path/to/file2.txt",
            "/path/to/file3.txt",
        ]
        request.targetElementID = "elem_test_123"
        request.duration = 1.0

        XCTAssertEqual(request.filePaths.count, 3)
        XCTAssertEqual(request.duration, 1.0)
    }

    // MARK: - SelectFile Response Tests

    func testSelectFileWithValidPathReturnsSuccess() async throws {
        // Create a temporary file for testing
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_select_file_\(UUID().uuidString).txt")
        try "test content".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var request = Macosusesdk_V1_SelectFileRequest()
        request.filePath = tempFile.path
        request.revealFinder = false

        let response = try await service.selectFile(
            request: makeSelectFileRequest(request),
            context: makeSelectFileContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.selectedPath, tempFile.path)
        XCTAssertTrue(msg.error.isEmpty)
    }

    func testSelectFileWithInvalidPathReturnsError() async throws {
        var request = Macosusesdk_V1_SelectFileRequest()
        request.filePath = "/nonexistent/path/to/file.txt"
        request.revealFinder = false

        let response = try await service.selectFile(
            request: makeSelectFileRequest(request),
            context: makeSelectFileContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertFalse(msg.error.isEmpty, "Error message should be populated")
    }

    func testSelectFileWithDirectoryPathReturnsError() async throws {
        var request = Macosusesdk_V1_SelectFileRequest()
        request.filePath = FileManager.default.temporaryDirectory.path
        request.revealFinder = false

        let response = try await service.selectFile(
            request: makeSelectFileRequest(request),
            context: makeSelectFileContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(
            msg.error.contains("Invalid file type"),
            "Error should mention invalid file type: \(msg.error)",
        )
    }

    // MARK: - SelectDirectory Response Tests

    func testSelectDirectoryWithValidPathReturnsSuccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("test_dir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        var request = Macosusesdk_V1_SelectDirectoryRequest()
        request.directoryPath = testDir.path
        request.createMissing = false

        let response = try await service.selectDirectory(
            request: makeSelectDirectoryRequest(request),
            context: makeSelectDirectoryContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.selectedPath, testDir.path)
        XCTAssertFalse(msg.created)
        XCTAssertTrue(msg.error.isEmpty)
    }

    func testSelectDirectoryWithInvalidPathReturnsError() async throws {
        var request = Macosusesdk_V1_SelectDirectoryRequest()
        request.directoryPath = "/nonexistent/path/to/directory"
        request.createMissing = false

        let response = try await service.selectDirectory(
            request: makeSelectDirectoryRequest(request),
            context: makeSelectDirectoryContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertFalse(msg.error.isEmpty, "Error message should be populated")
    }

    func testSelectDirectoryWithCreateMissingCreatesDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let newDir = tempDir.appendingPathComponent("test_create_dir_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: newDir) }

        // Ensure directory doesn't exist
        try? FileManager.default.removeItem(at: newDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDir.path))

        var request = Macosusesdk_V1_SelectDirectoryRequest()
        request.directoryPath = newDir.path
        request.createMissing = true

        let response = try await service.selectDirectory(
            request: makeSelectDirectoryRequest(request),
            context: makeSelectDirectoryContext(),
        )
        let msg = try response.message

        XCTAssertTrue(msg.success)
        XCTAssertEqual(msg.selectedPath, newDir.path)
        XCTAssertTrue(msg.created, "created flag should be true for newly created directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path))
    }

    func testSelectDirectoryWithFilePathReturnsError() async throws {
        // Create a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_file_\(UUID().uuidString).txt")
        try "test content".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var request = Macosusesdk_V1_SelectDirectoryRequest()
        request.directoryPath = tempFile.path
        request.createMissing = false

        let response = try await service.selectDirectory(
            request: makeSelectDirectoryRequest(request),
            context: makeSelectDirectoryContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(
            msg.error.contains("Invalid file type"),
            "Error should mention invalid file type: \(msg.error)",
        )
    }

    // MARK: - AutomateOpenFileDialog Proto Tests

    // NOTE: Tests that call automateOpenFileDialog/automateSaveFileDialog RPC methods
    // are NOT included here because they present actual NSOpenPanel/NSSavePanel dialogs
    // that require user interaction. Such tests belong in integration test suites.
    // Below we test proto construction, defaults, and validation only.

    func testAutomateOpenFileDialogWithMultipleFiltersConstruction() {
        var request = Macosusesdk_V1_AutomateOpenFileDialogRequest()
        request.fileFilters = ["*.txt", "*.md", "*.json"]
        request.allowMultiple = true

        XCTAssertEqual(request.fileFilters.count, 3)
        XCTAssertTrue(request.allowMultiple)
    }

    // NOTE: Response success/error cases are already tested above in
    // testAutomateOpenFileDialogResponseConstruction/testAutomateOpenFileDialogResponseErrorCase.
    // Tests that call automateOpenFileDialog/automateSaveFileDialog RPC methods
    // are NOT included as unit tests because they present actual NSOpenPanel/NSSavePanel
    // dialogs requiring user interaction. Such tests belong in integration test suites.

    // MARK: - Validation Error Reason Tests

    func testSelectFileValidationErrorContainsRequiredFieldReason() async throws {
        let request = Macosusesdk_V1_SelectFileRequest()

        do {
            _ = try await service.selectFile(
                request: makeSelectFileRequest(request),
                context: makeSelectFileContext(),
            )
            XCTFail("Expected validation error")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("required"))
        }
    }

    func testSelectDirectoryValidationErrorContainsRequiredFieldReason() async throws {
        let request = Macosusesdk_V1_SelectDirectoryRequest()

        do {
            _ = try await service.selectDirectory(
                request: makeSelectDirectoryRequest(request),
                context: makeSelectDirectoryContext(),
            )
            XCTFail("Expected validation error")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("required"))
        }
    }

    func testDragFilesValidationErrorsAreDistinct() async throws {
        // Test that different validation errors are distinguishable
        var emptyFilesRequest = Macosusesdk_V1_DragFilesRequest()
        emptyFilesRequest.targetElementID = "elem_test"

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(emptyFilesRequest),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for empty file_paths")
        } catch let error as RPCError {
            XCTAssertTrue(error.message.contains("file_paths"))
        }

        var emptyTargetRequest = Macosusesdk_V1_DragFilesRequest()
        emptyTargetRequest.filePaths = ["/some/file.txt"]

        do {
            _ = try await service.dragFiles(
                request: makeDragFilesRequest(emptyTargetRequest),
                context: makeDragFilesContext(),
            )
            XCTFail("Expected validation error for empty target_element_id")
        } catch let error as RPCError {
            XCTAssertTrue(error.message.contains("target_element_id"))
        }
    }

    // MARK: - Edge Case Tests

    func testSelectFileWithWhitespaceOnlyPathPassesValidation() async throws {
        // Whitespace-only path should pass validation but fail file lookup
        var request = Macosusesdk_V1_SelectFileRequest()
        request.filePath = "   "

        let response = try await service.selectFile(
            request: makeSelectFileRequest(request),
            context: makeSelectFileContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertFalse(msg.error.isEmpty)
    }

    func testSelectDirectoryWithWhitespaceOnlyPathPassesValidation() async throws {
        var request = Macosusesdk_V1_SelectDirectoryRequest()
        request.directoryPath = "   "

        let response = try await service.selectDirectory(
            request: makeSelectDirectoryRequest(request),
            context: makeSelectDirectoryContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertFalse(msg.error.isEmpty)
    }

    func testDragFilesZeroDurationIsValid() async throws {
        // Zero duration should be valid (uses default)
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        request.targetElementID = "elem_test_123"
        request.duration = 0.0

        // Should not throw validation error for duration
        // Will fail on element lookup instead
        let response = try await service.dragFiles(
            request: makeDragFilesRequest(request),
            context: makeDragFilesContext(),
        )
        let msg = try response.message

        XCTAssertFalse(msg.success)
        XCTAssertTrue(
            msg.error.contains("not found"),
            "Should fail on element lookup, not duration validation",
        )
    }

    func testDragFilesLargeDurationIsValid() async throws {
        var request = Macosusesdk_V1_DragFilesRequest()
        request.filePaths = ["/path/to/file.txt"]
        request.targetElementID = "elem_test_123"
        request.duration = 999.0

        // Large but finite duration should pass validation
        let response = try await service.dragFiles(
            request: makeDragFilesRequest(request),
            context: makeDragFilesContext(),
        )
        let msg = try response.message

        // Should fail on element lookup, not duration
        XCTAssertFalse(msg.success)
        XCTAssertTrue(msg.error.contains("not found"))
    }
}
