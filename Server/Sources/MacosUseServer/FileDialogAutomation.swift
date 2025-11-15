import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Errors that can occur during file dialog automation
enum FileDialogError: Error, CustomStringConvertible {
    case invalidPath(String)
    case dialogCancelled
    case dialogTimeout
    case fileNotFound(String)
    case directoryNotFound(String)
    case permissionDenied(String)
    case invalidFileType
    case creationFailed(String)

    var description: String {
        switch self {
        case let .invalidPath(path):
            "Invalid path: \(path)"
        case .dialogCancelled:
            "Dialog was cancelled by user"
        case .dialogTimeout:
            "Dialog did not appear within timeout"
        case let .fileNotFound(path):
            "File not found: \(path)"
        case let .directoryNotFound(path):
            "Directory not found: \(path)"
        case let .permissionDenied(path):
            "Permission denied: \(path)"
        case .invalidFileType:
            "Invalid file type for operation"
        case let .creationFailed(reason):
            "Creation failed: \(reason)"
        }
    }
}

/// Utility class for file dialog automation and file operations
@MainActor
final class FileDialogAutomation {
    /// Shared singleton instance
    static let shared = FileDialogAutomation()

    private init() {}

    // MARK: - File Dialog Automation

    /// Automate an open file dialog by presenting NSOpenPanel
    /// - Parameters:
    ///   - filePath: Optional specific file to select
    ///   - defaultDirectory: Default directory to navigate to
    ///   - fileFilters: Array of file type patterns (e.g., ["*.txt", "*.pdf"])
    ///   - allowMultiple: Whether to allow multiple file selection
    /// - Returns: Array of selected file paths
    func automateOpenFileDialog(
        filePath: String?,
        defaultDirectory: String?,
        fileFilters: [String],
        allowMultiple: Bool,
    ) async throws -> [String] {
        let panel = NSOpenPanel()

        // Configure panel
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowMultiple
        panel.canCreateDirectories = false

        // Set default directory
        if let directory = defaultDirectory, !directory.isEmpty {
            let url = URL(fileURLWithPath: directory)
            if FileManager.default.fileExists(atPath: directory) {
                panel.directoryURL = url
            }
        }

        // Set file type filters
        if !fileFilters.isEmpty {
            let utTypes = fileFilters.compactMap { pattern -> UTType? in
                // Convert patterns like "*.txt" to UTTypes
                if pattern.hasPrefix("*.") {
                    let ext = String(pattern.dropFirst(2))
                    return UTType(filenameExtension: ext)
                }
                return nil
            }
            if !utTypes.isEmpty {
                panel.allowedContentTypes = utTypes
            }
        }

        // If specific file path provided, try to select it
        if let path = filePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                panel.directoryURL = url.deletingLastPathComponent()
                panel.nameFieldStringValue = url.lastPathComponent
            }
        }

        // Present panel and await result
        let response = await panel.begin()

        guard response == .OK else {
            throw FileDialogError.dialogCancelled
        }

        return panel.urls.map(\.path)
    }

    /// Automate a save file dialog by presenting NSSavePanel
    /// - Parameters:
    ///   - filePath: Required save path
    ///   - defaultDirectory: Default directory to navigate to
    ///   - defaultFilename: Default filename
    ///   - confirmOverwrite: Whether to show overwrite confirmation
    /// - Returns: Selected save path
    func automateSaveFileDialog(
        filePath: String,
        defaultDirectory: String?,
        defaultFilename: String?,
        confirmOverwrite _: Bool,
    ) async throws -> String {
        guard !filePath.isEmpty else {
            throw FileDialogError.invalidPath("File path is required")
        }

        let panel = NSSavePanel()

        // Configure panel
        panel.canCreateDirectories = true

        // Set default directory
        if let directory = defaultDirectory, !directory.isEmpty {
            let url = URL(fileURLWithPath: directory)
            if FileManager.default.fileExists(atPath: directory) {
                panel.directoryURL = url
            }
        }

        // Set default filename
        if let filename = defaultFilename, !filename.isEmpty {
            panel.nameFieldStringValue = filename
        } else {
            // Extract filename from filePath
            let url = URL(fileURLWithPath: filePath)
            panel.nameFieldStringValue = url.lastPathComponent

            // Set directory if not already set
            if panel.directoryURL == nil {
                let dir = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: dir.path) {
                    panel.directoryURL = dir
                }
            }
        }

        // Present panel and await result
        let response = await panel.begin()

        guard response == .OK else {
            throw FileDialogError.dialogCancelled
        }

        guard let selectedURL = panel.url else {
            throw FileDialogError.invalidPath("No path selected")
        }

        return selectedURL.path
    }

    // MARK: - Programmatic File Selection

    /// Select a file programmatically (without showing dialog)
    /// - Parameters:
    ///   - filePath: Path to file to select
    ///   - revealInFinder: Whether to reveal the file in Finder
    /// - Returns: Selected file path
    func selectFile(filePath: String, revealInFinder: Bool) async throws -> String {
        guard !filePath.isEmpty else {
            throw FileDialogError.invalidPath("File path is required")
        }

        let fileManager = FileManager.default

        // Check if file exists
        guard fileManager.fileExists(atPath: filePath) else {
            throw FileDialogError.fileNotFound(filePath)
        }

        // Check if it's actually a file (not a directory)
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw FileDialogError.invalidFileType
        }

        // Check read permissions
        guard fileManager.isReadableFile(atPath: filePath) else {
            throw FileDialogError.permissionDenied(filePath)
        }

        // Reveal in Finder if requested
        if revealInFinder {
            let url = URL(fileURLWithPath: filePath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        return filePath
    }

    /// Select a directory programmatically (without showing dialog)
    /// - Parameters:
    ///   - directoryPath: Path to directory to select
    ///   - createMissing: Whether to create directory if it doesn't exist
    /// - Returns: Tuple of (selected path, whether directory was created)
    func selectDirectory(directoryPath: String, createMissing: Bool) async throws -> (
        path: String, created: Bool,
    ) {
        guard !directoryPath.isEmpty else {
            throw FileDialogError.invalidPath("Directory path is required")
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory)

        if exists {
            // Check if it's actually a directory
            guard isDirectory.boolValue else {
                throw FileDialogError.invalidFileType
            }

            // Check read permissions
            guard fileManager.isReadableFile(atPath: directoryPath) else {
                throw FileDialogError.permissionDenied(directoryPath)
            }

            return (directoryPath, false)
        } else {
            // Directory doesn't exist
            guard createMissing else {
                throw FileDialogError.directoryNotFound(directoryPath)
            }

            // Try to create directory
            do {
                try fileManager.createDirectory(
                    atPath: directoryPath,
                    withIntermediateDirectories: true,
                    attributes: nil,
                )
                return (directoryPath, true)
            } catch {
                throw FileDialogError.creationFailed(
                    "Failed to create directory: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File Drag and Drop

    /// Simulate dragging files to a target element
    /// - Parameters:
    ///   - filePaths: Array of file paths to drag
    ///   - targetElement: Target element to drop on
    ///   - duration: Duration of drag operation in seconds
    func dragFilesToElement(
        filePaths: [String],
        targetElement: CGPoint,
        duration: Double,
    ) async throws {
        guard !filePaths.isEmpty else {
            throw FileDialogError.invalidPath("At least one file path is required")
        }

        let fileManager = FileManager.default

        // Validate all file paths exist
        for path in filePaths {
            guard fileManager.fileExists(atPath: path) else {
                throw FileDialogError.fileNotFound(path)
            }
        }

        // Calculate drag parameters
        let dragDuration = duration > 0 ? duration : 0.5
        let steps = max(10, Int(dragDuration * 60)) // 60 FPS

        // Start position (slightly offset from target)
        let startX = targetElement.x - 50
        let startY = targetElement.y - 50

        // Create drag event sequence
        guard
            let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: startX, y: startY),
                mouseButton: .left,
            )
        else {
            throw FileDialogError.creationFailed("Failed to create mouse down event")
        }

        // Post mouse down
        mouseDown.post(tap: .cghidEventTap)

        // Simulate drag movement
        let deltaX = (targetElement.x - startX) / Double(steps)
        let deltaY = (targetElement.y - startY) / Double(steps)

        for step in 0 ..< steps {
            let x = startX + (deltaX * Double(step))
            let y = startY + (deltaY * Double(step))

            guard
                let mouseDrag = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseDragged,
                    mouseCursorPosition: CGPoint(x: x, y: y),
                    mouseButton: .left,
                )
            else {
                continue
            }

            mouseDrag.post(tap: .cghidEventTap)

            // Small delay between steps
            try await Task.sleep(nanoseconds: UInt64((dragDuration / Double(steps)) * 1_000_000_000))
        }

        // Post mouse up at target
        guard
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: targetElement,
                mouseButton: .left,
            )
        else {
            throw FileDialogError.creationFailed("Failed to create mouse up event")
        }

        mouseUp.post(tap: .cghidEventTap)
    }
}
