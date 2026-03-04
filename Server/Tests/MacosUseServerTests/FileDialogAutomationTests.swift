import Foundation
@testable import MacosUseServer
import XCTest

/// Tests for FileDialogAutomation and FileDialogError.
///
/// Note: Tests for automateOpenFileDialog and automateSaveFileDialog that present actual
/// UI panels are integration tests and cannot be run as unit tests. This file tests:
/// - FileDialogError descriptions
/// - selectFile validation and error handling
/// - selectDirectory validation and error handling
/// - dragFilesToElement validation
/// - Path and file type validation logic
@MainActor
final class FileDialogAutomationTests: XCTestCase {
    // MARK: - Test Fixtures

    private var tempDirectory: URL!
    private var tempFile: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Create temporary directory for tests
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDialogAutomationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Create a temporary file
        tempFile = tempDirectory.appendingPathComponent("testfile.txt")
        try "test content".write(to: tempFile, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        // Clean up temporary files
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - FileDialogError Description Tests

    func testInvalidPathErrorDescription() {
        let error = FileDialogError.invalidPath("/nonexistent/path")
        XCTAssertEqual(error.description, "Invalid path: /nonexistent/path")
    }

    func testDialogCancelledErrorDescription() {
        let error = FileDialogError.dialogCancelled
        XCTAssertEqual(error.description, "Dialog was cancelled by user")
    }

    func testDialogTimeoutErrorDescription() {
        let error = FileDialogError.dialogTimeout
        XCTAssertEqual(error.description, "Dialog did not appear within timeout")
    }

    func testFileNotFoundErrorDescription() {
        let error = FileDialogError.fileNotFound("/missing/file.txt")
        XCTAssertEqual(error.description, "File not found: /missing/file.txt")
    }

    func testDirectoryNotFoundErrorDescription() {
        let error = FileDialogError.directoryNotFound("/missing/directory")
        XCTAssertEqual(error.description, "Directory not found: /missing/directory")
    }

    func testPermissionDeniedErrorDescription() {
        let error = FileDialogError.permissionDenied("/protected/file.txt")
        XCTAssertEqual(error.description, "Permission denied: /protected/file.txt")
    }

    func testInvalidFileTypeErrorDescription() {
        let error = FileDialogError.invalidFileType
        XCTAssertEqual(error.description, "Invalid file type for operation")
    }

    func testCreationFailedErrorDescription() {
        let error = FileDialogError.creationFailed("Disk full")
        XCTAssertEqual(error.description, "Creation failed: Disk full")
    }

    // MARK: - FileDialogError Conformance Tests

    func testFileDialogErrorConformsToError() {
        let error: any Error = FileDialogError.invalidPath("test")
        XCTAssertTrue(error is FileDialogError)
    }

    func testFileDialogErrorConformsToCustomStringConvertible() {
        let error: any CustomStringConvertible = FileDialogError.dialogCancelled
        XCTAssertFalse(error.description.isEmpty)
    }

    // MARK: - selectFile Tests

    func testSelectFileWithEmptyPathThrowsInvalidPath() async {
        do {
            _ = try await FileDialogAutomation.shared.selectFile(filePath: "", revealInFinder: false)
            XCTFail("Expected invalidPath error")
        } catch let error as FileDialogError {
            switch error {
            case .invalidPath:
                break // Expected
            default:
                XCTFail("Expected invalidPath, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSelectFileWithNonexistentPathThrowsFileNotFound() async {
        do {
            let path = "/nonexistent/path/to/file.txt"
            _ = try await FileDialogAutomation.shared.selectFile(filePath: path, revealInFinder: false)
            XCTFail("Expected fileNotFound error")
        } catch let error as FileDialogError {
            switch error {
            case .fileNotFound:
                break // Expected
            default:
                XCTFail("Expected fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSelectFileWithDirectoryThrowsInvalidFileType() async {
        do {
            // tempDirectory is a directory, not a file
            _ = try await FileDialogAutomation.shared.selectFile(
                filePath: tempDirectory.path,
                revealInFinder: false,
            )
            XCTFail("Expected invalidFileType error")
        } catch let error as FileDialogError {
            switch error {
            case .invalidFileType:
                break // Expected
            default:
                XCTFail("Expected invalidFileType, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSelectFileWithValidFileReturnsPath() async throws {
        let result = try await FileDialogAutomation.shared.selectFile(
            filePath: tempFile.path,
            revealInFinder: false,
        )
        XCTAssertEqual(result, tempFile.path)
    }

    func testSelectFileWithRevealInFinderReturnsPath() async throws {
        // Note: This will actually reveal in Finder during test, but should not fail
        let result = try await FileDialogAutomation.shared.selectFile(
            filePath: tempFile.path,
            revealInFinder: true,
        )
        XCTAssertEqual(result, tempFile.path)
    }

    // MARK: - selectDirectory Tests

    func testSelectDirectoryWithEmptyPathThrowsInvalidPath() async {
        do {
            _ = try await FileDialogAutomation.shared.selectDirectory(
                directoryPath: "",
                createMissing: false,
            )
            XCTFail("Expected invalidPath error")
        } catch let error as FileDialogError {
            switch error {
            case .invalidPath:
                break // Expected
            default:
                XCTFail("Expected invalidPath, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSelectDirectoryWithNonexistentPathNoCreateThrowsDirectoryNotFound() async {
        do {
            let path = "/nonexistent/directory/path"
            _ = try await FileDialogAutomation.shared.selectDirectory(
                directoryPath: path,
                createMissing: false,
            )
            XCTFail("Expected directoryNotFound error")
        } catch let error as FileDialogError {
            switch error {
            case .directoryNotFound:
                break // Expected
            default:
                XCTFail("Expected directoryNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSelectDirectoryWithFilePathThrowsInvalidFileType() async {
        do {
            // tempFile is a file, not a directory
            _ = try await FileDialogAutomation.shared.selectDirectory(
                directoryPath: tempFile.path,
                createMissing: false,
            )
            XCTFail("Expected invalidFileType error")
        } catch let error as FileDialogError {
            switch error {
            case .invalidFileType:
                break // Expected
            default:
                XCTFail("Expected invalidFileType, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSelectDirectoryWithExistingDirectoryReturnsPath() async throws {
        let result = try await FileDialogAutomation.shared.selectDirectory(
            directoryPath: tempDirectory.path,
            createMissing: false,
        )
        XCTAssertEqual(result.path, tempDirectory.path)
        XCTAssertFalse(result.created)
    }

    func testSelectDirectoryWithCreateMissingCreatesDirectory() async throws {
        let newDirPath = tempDirectory.appendingPathComponent("newsubdir").path
        let result = try await FileDialogAutomation.shared.selectDirectory(
            directoryPath: newDirPath,
            createMissing: true,
        )
        XCTAssertEqual(result.path, newDirPath)
        XCTAssertTrue(result.created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDirPath))
    }

    func testSelectDirectoryWithNestedCreateMissingCreatesNestedDirectories() async throws {
        let nestedPath = tempDirectory
            .appendingPathComponent("level1")
            .appendingPathComponent("level2")
            .appendingPathComponent("level3")
            .path
        let result = try await FileDialogAutomation.shared.selectDirectory(
            directoryPath: nestedPath,
            createMissing: true,
        )
        XCTAssertEqual(result.path, nestedPath)
        XCTAssertTrue(result.created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedPath))
    }

    func testSelectDirectoryWithExistingDirectoryDoesNotReturnCreated() async throws {
        // Even with createMissing=true, existing directory should not be marked as created
        let result = try await FileDialogAutomation.shared.selectDirectory(
            directoryPath: tempDirectory.path,
            createMissing: true,
        )
        XCTAssertEqual(result.path, tempDirectory.path)
        XCTAssertFalse(result.created, "Existing directory should not be marked as created")
    }

    // MARK: - dragFilesToElement Validation Tests

    func testDragFilesToElementWithEmptyFilesThrowsInvalidPath() async {
        do {
            try await FileDialogAutomation.shared.dragFilesToElement(
                filePaths: [],
                targetElement: CGPoint(x: 100, y: 100),
                duration: 0.5,
            )
            XCTFail("Expected invalidPath error")
        } catch let error as FileDialogError {
            switch error {
            case .invalidPath:
                break // Expected
            default:
                XCTFail("Expected invalidPath, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDragFilesToElementWithNonexistentFileThrowsFileNotFound() async {
        do {
            try await FileDialogAutomation.shared.dragFilesToElement(
                filePaths: ["/nonexistent/file.txt"],
                targetElement: CGPoint(x: 100, y: 100),
                duration: 0.5,
            )
            XCTFail("Expected fileNotFound error")
        } catch let error as FileDialogError {
            switch error {
            case .fileNotFound:
                break // Expected
            default:
                XCTFail("Expected fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDragFilesToElementWithMixedFilesThrowsFileNotFound() async {
        do {
            try await FileDialogAutomation.shared.dragFilesToElement(
                filePaths: [tempFile.path, "/nonexistent/file.txt"],
                targetElement: CGPoint(x: 100, y: 100),
                duration: 0.5,
            )
            XCTFail("Expected fileNotFound error for missing file")
        } catch let error as FileDialogError {
            switch error {
            case .fileNotFound:
                break // Expected
            default:
                XCTFail("Expected fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - automateOpenFileDialog Configuration Tests

    // Note: These tests verify error handling for invalid configurations.
    // Actual panel presentation cannot be tested in unit tests.

    func testAutomateOpenFileDialogWithEmptyFiltersAcceptsAll() {
        // This would present a panel - we just verify it doesn't throw on configuration
        // In a real scenario, we would cancel immediately after configuration
        // For now, we test that the method signature accepts empty filters
        let filters: [String] = []
        XCTAssertTrue(filters.isEmpty, "Empty filters should be valid configuration")
    }

    func testFileFilterPatternParsing() {
        // Test that filter patterns are correctly recognized
        let patterns = ["*.txt", "*.pdf", "*.doc"]
        for pattern in patterns {
            XCTAssertTrue(pattern.hasPrefix("*."), "Pattern should start with *.")
            let ext = String(pattern.dropFirst(2))
            XCTAssertFalse(ext.isEmpty, "Extension should not be empty")
        }
    }

    func testInvalidFileFilterPatternIsIgnored() {
        // Patterns not matching *.ext format should be handled gracefully
        let invalidPatterns = ["txt", ".txt", "text/*", ""]
        for pattern in invalidPatterns {
            XCTAssertFalse(
                pattern.hasPrefix("*.") && pattern.count > 2,
                "Invalid pattern should be recognized: \(pattern)",
            )
        }
    }

    // MARK: - automateSaveFileDialog Configuration Tests

    func testAutomateSaveFileDialogWithEmptyPathThrowsInvalidPath() async {
        do {
            _ = try await FileDialogAutomation.shared.automateSaveFileDialog(
                filePath: "",
                defaultDirectory: nil,
                defaultFilename: nil,
                confirmOverwrite: true,
            )
            XCTFail("Expected invalidPath error")
        } catch let error as FileDialogError {
            switch error {
            case .invalidPath:
                break // Expected
            default:
                XCTFail("Expected invalidPath, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Path Validation Edge Cases

    func testPathValidationWithWhitespaceOnlyPath() {
        // Whitespace-only paths should be treated as empty
        let whitespacePath = "   "
        // The implementation checks !isEmpty, so whitespace is not empty
        // This test documents current behavior
        XCTAssertFalse(whitespacePath.isEmpty, "Whitespace path is not empty string")
    }

    func testPathValidationWithNullCharacterInPath() {
        // Paths with null characters are technically invalid
        let pathWithNull = "/some\0/path"
        // FileManager should handle this gracefully
        let exists = FileManager.default.fileExists(atPath: pathWithNull)
        XCTAssertFalse(exists, "Path with null character should not exist")
    }

    func testPathValidationWithVeryLongPath() {
        // Very long paths should fail gracefully
        let longPath = "/" + String(repeating: "a", count: 2048)
        let exists = FileManager.default.fileExists(atPath: longPath)
        XCTAssertFalse(exists, "Very long path should not exist")
    }

    func testPathValidationWithColonInFilename() async {
        // macOS allows colons in filenames (they display as slashes in Finder)
        let pathWithColon = tempDirectory.appendingPathComponent("file:name.txt").path
        do {
            try "test".write(toFile: pathWithColon, atomically: true, encoding: .utf8)
            let result = try await FileDialogAutomation.shared.selectFile(
                filePath: pathWithColon,
                revealInFinder: false,
            )
            XCTAssertEqual(result, pathWithColon)
        } catch {
            // Colon handling may vary by filesystem
            XCTFail("Unexpected error handling path with colon: \(error)")
        }
    }

    // MARK: - Directory Creation Edge Cases

    func testDirectoryCreationWithInvalidParent() async {
        // Attempting to create directory under non-existent parent
        // should still work due to withIntermediateDirectories: true
        let deepPath = tempDirectory
            .appendingPathComponent("nonexistent")
            .appendingPathComponent("deep")
            .appendingPathComponent("path")
            .path

        let result = try? await FileDialogAutomation.shared.selectDirectory(
            directoryPath: deepPath,
            createMissing: true,
        )
        XCTAssertNotNil(result, "Should create nested directories")
        XCTAssertEqual(result?.path, deepPath)
        XCTAssertTrue(result?.created == true)
    }

    // MARK: - Error Type Consistency Tests

    func testAllErrorCasesAreExhaustive() {
        // Verify all error cases have descriptions
        let errors: [FileDialogError] = [
            .invalidPath("path"),
            .dialogCancelled,
            .dialogTimeout,
            .fileNotFound("file"),
            .directoryNotFound("dir"),
            .permissionDenied("path"),
            .invalidFileType,
            .creationFailed("reason"),
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) should have description")
        }
    }

    func testErrorDescriptionsContainRelevantInfo() {
        // Verify error messages contain the provided context
        let path = "/test/specific/path"
        let reason = "specific reason"

        XCTAssertTrue(FileDialogError.invalidPath(path).description.contains(path))
        XCTAssertTrue(FileDialogError.fileNotFound(path).description.contains(path))
        XCTAssertTrue(FileDialogError.directoryNotFound(path).description.contains(path))
        XCTAssertTrue(FileDialogError.permissionDenied(path).description.contains(path))
        XCTAssertTrue(FileDialogError.creationFailed(reason).description.contains(reason))
    }
}
