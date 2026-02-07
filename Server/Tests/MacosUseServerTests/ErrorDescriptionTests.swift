import CoreGraphics
import Foundation
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Unit tests for ScreenshotError descriptions.
final class ScreenshotErrorTests: XCTestCase {
    // MARK: - Description Tests

    func testCaptureFailedScreen_description() {
        let error = ScreenshotError.captureFailedScreen
        XCTAssertEqual(error.description, "Failed to capture screen")
    }

    func testCaptureFailedWindow_description() {
        let windowID: CGWindowID = 12345
        let error = ScreenshotError.captureFailedWindow(windowID)
        XCTAssertEqual(error.description, "Failed to capture window 12345")
    }

    func testCaptureFailedRegion_description() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 200)
        let error = ScreenshotError.captureFailedRegion(bounds)
        XCTAssertTrue(error.description.contains("Failed to capture region"))
        XCTAssertTrue(error.description.contains("10"))
        XCTAssertTrue(error.description.contains("20"))
    }

    func testCaptureFailedGeneric_description() {
        let error = ScreenshotError.captureFailedGeneric
        XCTAssertEqual(error.description, "Screenshot capture failed for an unknown reason")
    }

    func testInvalidRegion_description() {
        let error = ScreenshotError.invalidRegion
        XCTAssertEqual(error.description, "Invalid region bounds (width/height must be > 0)")
    }

    func testEncodingFailed_png_description() {
        let error = ScreenshotError.encodingFailed(.png)
        XCTAssertTrue(error.description.contains("Failed to encode image"))
        XCTAssertTrue(error.description.lowercased().contains("png"))
    }

    func testEncodingFailed_jpeg_description() {
        let error = ScreenshotError.encodingFailed(.jpeg)
        XCTAssertTrue(error.description.contains("Failed to encode image"))
        XCTAssertTrue(error.description.lowercased().contains("jpeg"))
    }

    func testEncodingFailed_tiff_description() {
        let error = ScreenshotError.encodingFailed(.tiff)
        XCTAssertTrue(error.description.contains("Failed to encode image"))
        XCTAssertTrue(error.description.lowercased().contains("tiff"))
    }

    func testEncodingFailed_unspecified_description() {
        let error = ScreenshotError.encodingFailed(.unspecified)
        XCTAssertTrue(error.description.contains("Failed to encode image"))
    }

    func testWindowNotFound_description() {
        let windowID: CGWindowID = 99999
        let error = ScreenshotError.windowNotFound(windowID)
        XCTAssertEqual(error.description, "Window 99999 not found")
    }

    func testElementNotFound_description() {
        let error = ScreenshotError.elementNotFound("element-abc123")
        XCTAssertEqual(error.description, "Element element-abc123 not found")
    }

    // MARK: - Conformance Tests

    func testScreenshotError_conformsToError() {
        let error: Error = ScreenshotError.invalidRegion
        XCTAssertNotNil(error)
    }

    func testScreenshotError_conformsToCustomStringConvertible() {
        let error: CustomStringConvertible = ScreenshotError.captureFailedScreen
        XCTAssertFalse(String(describing: error).isEmpty)
    }

    func testScreenshotError_allCasesHaveNonEmptyDescription() {
        let errors: [ScreenshotError] = [
            .captureFailedScreen,
            .captureFailedWindow(1),
            .captureFailedRegion(CGRect(x: 0, y: 0, width: 100, height: 100)),
            .captureFailedGeneric,
            .invalidRegion,
            .encodingFailed(.png),
            .encodingFailed(.jpeg),
            .encodingFailed(.tiff),
            .encodingFailed(.unspecified),
            .windowNotFound(1),
            .elementNotFound("test"),
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) has empty description")
        }
    }
}

/// Unit tests for FileDialogError descriptions.
final class FileDialogErrorTests: XCTestCase {
    // MARK: - Description Tests

    func testInvalidPath_description() {
        let error = FileDialogError.invalidPath("/invalid/path")
        XCTAssertTrue(error.description.contains("Invalid path"))
        XCTAssertTrue(error.description.contains("/invalid/path"))
    }

    func testDialogCancelled_description() {
        let error = FileDialogError.dialogCancelled
        XCTAssertTrue(error.description.contains("cancelled") || error.description.contains("cancel"))
    }

    func testDialogTimeout_description() {
        let error = FileDialogError.dialogTimeout
        XCTAssertTrue(error.description.lowercased().contains("timeout"))
    }

    func testFileNotFound_description() {
        let error = FileDialogError.fileNotFound("/path/to/missing.txt")
        XCTAssertTrue(error.description.contains("not found") || error.description.contains("File"))
        XCTAssertTrue(error.description.contains("/path/to/missing.txt"))
    }

    func testDirectoryNotFound_description() {
        let error = FileDialogError.directoryNotFound("/missing/directory")
        XCTAssertTrue(error.description.contains("not found") || error.description.contains("Directory"))
        XCTAssertTrue(error.description.contains("/missing/directory"))
    }

    func testPermissionDenied_description() {
        let error = FileDialogError.permissionDenied("/protected/file")
        XCTAssertTrue(error.description.contains("Permission") || error.description.contains("denied"))
        XCTAssertTrue(error.description.contains("/protected/file"))
    }

    func testInvalidFileType_description() {
        let error = FileDialogError.invalidFileType
        XCTAssertTrue(error.description.contains("file type") || error.description.contains("type"))
    }

    func testCreationFailed_description() {
        let error = FileDialogError.creationFailed("Disk full")
        XCTAssertTrue(error.description.contains("failed") || error.description.contains("Failed"))
        XCTAssertTrue(error.description.contains("Disk full"))
    }

    // MARK: - Conformance Tests

    func testFileDialogError_conformsToError() {
        let error: Error = FileDialogError.dialogTimeout
        XCTAssertNotNil(error)
    }

    func testFileDialogError_conformsToCustomStringConvertible() {
        let error: CustomStringConvertible = FileDialogError.invalidFileType
        XCTAssertFalse(String(describing: error).isEmpty)
    }

    func testFileDialogError_allCasesHaveNonEmptyDescription() {
        let errors: [FileDialogError] = [
            .invalidPath("test"),
            .dialogCancelled,
            .dialogTimeout,
            .fileNotFound("test"),
            .directoryNotFound("test"),
            .permissionDenied("test"),
            .invalidFileType,
            .creationFailed("test"),
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty, "Error \(error) has empty description")
        }
    }

    // MARK: - Edge Case Tests

    func testFileDialogError_emptyPath() {
        let error = FileDialogError.invalidPath("")
        // Should still produce valid description even with empty path
        XCTAssertFalse(error.description.isEmpty)
    }

    func testFileDialogError_unicodePath() {
        let error = FileDialogError.fileNotFound("/ユーザー/ドキュメント/ファイル.txt")
        XCTAssertTrue(error.description.contains("ファイル"))
    }

    func testFileDialogError_pathWithSpaces() {
        let error = FileDialogError.directoryNotFound("/path/with spaces/dir")
        XCTAssertTrue(error.description.contains("with spaces"))
    }
}
