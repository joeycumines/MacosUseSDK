import Foundation
@testable import MacosUseServer
import XCTest

final class FileDialogAutomationTests: XCTestCase {
    func testProductionFileDialogSourcesContainNoServerOwnedMutationSink() throws {
        let serverRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacosUseServer")
        let sources = [
            serverRoot.appendingPathComponent("FileDialogAutomation.swift"),
            serverRoot.appendingPathComponent("FileDialogMethods.swift"),
        ]
        let forbiddenTokens = [
            "FileDialogAutomation.shared",
            "NSOpenPanel",
            "NSSavePanel",
            "CGEvent(",
            ".post(tap:",
            "NSWorkspace.shared.activateFileViewerSelecting",
            "FileManager.default.createDirectory",
        ]

        for sourceURL in sources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(
                    source.contains(token),
                    "\(sourceURL.lastPathComponent) must not contain \(token)",
                )
            }
        }
    }

    func testFileDialogErrorsHaveStableNonEmptyDescriptions() {
        let errors: [FileDialogError] = [
            .invalidPath("/invalid/path"),
            .dialogCancelled,
            .dialogTimeout,
            .fileNotFound("/missing/file"),
            .directoryNotFound("/missing/directory"),
            .permissionDenied("/protected/file"),
            .invalidFileType,
            .creationFailed("reason"),
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
    }
}
