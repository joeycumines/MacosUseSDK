import AppKit
import Foundation
import MacosUseProto
import SwiftProtobuf
import UniformTypeIdentifiers

/// Manages clipboard operations using NSPasteboard.
actor ClipboardManager {
    static let shared = ClipboardManager()

    private init() {}

    /// Read current clipboard contents.
    func readClipboard() -> Macosusesdk_V1_Clipboard {
        let pasteboard = NSPasteboard.general

        // Detect available types
        var availableTypes: [Macosusesdk_V1_ContentType] = []
        var content = Macosusesdk_V1_ClipboardContent()
        var hasSetContent = false

        // Check for text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            availableTypes.append(.text)
            if !hasSetContent {
                content.type = .text
                content.content = .text(text)
                hasSetContent = true
            }
        }

        // Check for RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            availableTypes.append(.rtf)
            if !hasSetContent {
                content.type = .rtf
                content.content = .rtf(rtfData)
                hasSetContent = true
            }
        }

        // Check for HTML
        if let htmlData = pasteboard.data(forType: .html),
           let htmlString = String(data: htmlData, encoding: .utf8)
        {
            availableTypes.append(.html)
            if !hasSetContent {
                content.type = .html
                content.content = .html(htmlString)
                hasSetContent = true
            }
        }

        // Check for image (PNG, TIFF)
        if let image = NSImage(pasteboard: pasteboard) {
            availableTypes.append(.image)
            if !hasSetContent, let pngData = image.pngData() {
                content.type = .image
                content.content = .image(pngData)
                hasSetContent = true
            }
        }

        // Check for file URLs
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !fileURLs.isEmpty
        {
            availableTypes.append(.files)
            if !hasSetContent {
                let filePaths = Macosusesdk_V1_FilePaths.with {
                    $0.paths = fileURLs.map(\.path)
                }
                content.type = .files
                content.content = .files(filePaths)
                hasSetContent = true
            }
        }

        // Check for URL
        if let urlString = pasteboard.string(forType: .URL), !urlString.isEmpty {
            availableTypes.append(.url)
            if !hasSetContent {
                content.type = .url
                content.content = .url(urlString)
                hasSetContent = true
            }
        }

        return Macosusesdk_V1_Clipboard.with {
            $0.name = "clipboard"
            $0.content = content
            $0.availableTypes = availableTypes
        }
    }

    /// Write content to clipboard.
    func writeClipboard(content: Macosusesdk_V1_ClipboardContent, _: Bool) async throws
        -> Macosusesdk_V1_Clipboard
    {
        let pasteboard = NSPasteboard.general

        // CRITICAL: NSPasteboard documentation states clearing before writing is recommended.
        // We MUST always clear before writing to ensure proper ownership transfer.
        pasteboard.clearContents()

        var success = false

        switch content.content {
        case let .text(text):
            success = pasteboard.setString(text, forType: .string)

        case let .rtf(rtfData):
            success = pasteboard.setData(rtfData, forType: .rtf)

        case let .html(html):
            if let htmlData = html.data(using: .utf8) {
                success = pasteboard.setData(htmlData, forType: .html)
            }

        case let .image(imageData):
            if let image = NSImage(data: imageData) {
                success = pasteboard.writeObjects([image])
            }

        case let .files(filePaths):
            let urls = filePaths.paths.compactMap { URL(fileURLWithPath: $0) }
            success = pasteboard.writeObjects(urls as [NSURL])

        case let .url(urlString):
            if let url = URL(string: urlString) {
                success = pasteboard.writeObjects([url as NSURL])
            }

        case .none:
            throw ClipboardError.invalidContent("No content specified")
        }

        if !success {
            throw ClipboardError.writeFailed("Failed to write clipboard content")
        }

        // Track in history
        await ClipboardHistoryManager.shared.addEntry(content: content)

        return readClipboard()
    }

    /// Clear clipboard contents.
    func clearClipboard() {
        NSPasteboard.general.clearContents()
    }
}

/// Manages clipboard history.
actor ClipboardHistoryManager {
    static let shared = ClipboardHistoryManager()

    private var history: [Macosusesdk_V1_ClipboardHistoryEntry] = []
    private let maxEntries = 100

    private init() {}

    /// Add an entry to clipboard history.
    func addEntry(content: Macosusesdk_V1_ClipboardContent) {
        let entry = Macosusesdk_V1_ClipboardHistoryEntry.with {
            $0.copiedTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.content = content
            $0.sourceApplication = getActiveApplicationName()
        }

        // Add to beginning (most recent first)
        history.insert(entry, at: 0)

        // Limit history size
        if history.count > maxEntries {
            history = Array(history.prefix(maxEntries))
        }
    }

    /// Get clipboard history.
    func getHistory() -> Macosusesdk_V1_ClipboardHistory {
        Macosusesdk_V1_ClipboardHistory.with {
            $0.entries = history
        }
    }

    /// Get the name of the active application.
    private func getActiveApplicationName() -> String {
        if let activeApp = NSWorkspace.shared.frontmostApplication {
            return activeApp.localizedName ?? activeApp.bundleIdentifier ?? "Unknown"
        }
        return "Unknown"
    }
}

/// Clipboard-related errors.
enum ClipboardError: Error, CustomStringConvertible {
    case invalidContent(String)
    case writeFailed(String)
    case readFailed(String)

    var description: String {
        switch self {
        case let .invalidContent(msg):
            "Invalid clipboard content: \(msg)"
        case let .writeFailed(msg):
            "Clipboard write failed: \(msg)"
        case let .readFailed(msg):
            "Clipboard read failed: \(msg)"
        }
    }
}

extension NSImage {
    /// Convert NSImage to PNG data.
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}
