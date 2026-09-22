import AppKit
import ExactMacProto
import Foundation
import SwiftProtobuf
import UniformTypeIdentifiers

struct ClipboardPasteboardItemSnapshot: Equatable, Sendable {
    let representations: [String: Data]
}

enum ClipboardPasteboardSnapshot: Equatable, Sendable {
    case native([ClipboardPasteboardItemSnapshot])
    case canonical(Exactmac_V1_ClipboardContent?)
}

protocol ClipboardPasteboard: Sendable {
    func read() async -> Exactmac_V1_Clipboard
    /// Monotonic ownership revision for detecting writes by another process.
    func changeCount() async -> Int
    func clear() async
    func write(_ content: Exactmac_V1_ClipboardContent) async -> Bool
    func snapshot() async throws -> ClipboardPasteboardSnapshot
    func restore(_ snapshot: ClipboardPasteboardSnapshot) async throws
}

extension ClipboardPasteboard {
    func snapshot() async throws -> ClipboardPasteboardSnapshot {
        let observed = await read()
        return .canonical(observed.hasContent ? observed.content : nil)
    }

    func restore(_ snapshot: ClipboardPasteboardSnapshot) async throws {
        guard case let .canonical(content) = snapshot else {
            throw ClipboardError.writeFailed(
                "Pasteboard does not support restoring a native snapshot",
            )
        }
        await clear()
        if let content {
            guard await write(content) else {
                throw ClipboardError.writeFailed(
                    "Pasteboard rejected the restored clipboard content",
                )
            }
        }
        let observed = await read()
        guard observed.hasContent == (content != nil),
              content == nil || observed.content == content
        else {
            throw ClipboardError.writeFailed(
                "Restored clipboard content did not match its snapshot",
            )
        }
    }
}

enum ClipboardAccessError: Error, Equatable, LocalizedError {
    case queueFull

    var errorDescription: String? {
        switch self {
        case .queueFull:
            "Clipboard access queue is full"
        }
    }
}

/// Serializes process-global pasteboard access across suspension points.
/// ClipboardManager actor isolation alone is insufficient because an async
/// pasteboard implementation permits actor reentrancy while AppKit mutates its
/// internal type cache.
actor ClipboardAccessGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let capacity: Int
    private var isHeld = false
    private var waiters: [Waiter] = []

    init(capacity: Int = 64) {
        self.capacity = max(0, capacity)
    }

    func withExclusiveAccess<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result,
    ) async throws -> Result {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func pendingCount() -> Int {
        waiters.count
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isHeld {
            isHeld = true
            return
        }
        guard waiters.count < capacity else {
            throw ClipboardAccessError.queueFull
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            // Promotion transfers ownership of the gate to this waiter. If
            // cancellation wins immediately afterward, release that ownership
            // before propagating so the next access cannot deadlock.
            release()
            throw error
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard isHeld else {
            return
        }
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }
}

struct SystemClipboardPasteboard: @unchecked Sendable, ClipboardPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func read() async -> Exactmac_V1_Clipboard {
        var availableTypes: [Exactmac_V1_ContentType] = []

        let text = pasteboard.string(forType: .string)
        if text != nil {
            availableTypes.append(.text)
        }
        let rtfData = pasteboard.data(forType: .rtf)
        if rtfData != nil {
            availableTypes.append(.rtf)
        }
        let html = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        if html != nil {
            availableTypes.append(.html)
        }
        let image = NSImage(pasteboard: pasteboard)?.pngData()
        if image != nil {
            availableTypes.append(.image)
        }
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
            .filter(\.isFileURL)
        if let files, !files.isEmpty {
            availableTypes.append(.files)
        }
        let url = pasteboard.string(forType: .URL)
        if let url, !url.isEmpty {
            availableTypes.append(.url)
        }

        let content: Exactmac_V1_ClipboardContent? = if let files, !files.isEmpty {
            Exactmac_V1_ClipboardContent.with {
                $0.type = .files
                $0.content = .files(
                    Exactmac_V1_FilePaths.with { $0.paths = files.map(\.path) },
                )
            }
        } else if let image {
            Exactmac_V1_ClipboardContent.with {
                $0.type = .image
                $0.content = .image(image)
            }
        } else if let rtfData {
            Exactmac_V1_ClipboardContent.with {
                $0.type = .rtf
                $0.content = .rtf(rtfData)
            }
        } else if let html {
            Exactmac_V1_ClipboardContent.with {
                $0.type = .html
                $0.content = .html(html)
            }
        } else if let url, !url.isEmpty {
            Exactmac_V1_ClipboardContent.with {
                $0.type = .url
                $0.content = .url(url)
            }
        } else if let text {
            Exactmac_V1_ClipboardContent.with {
                $0.type = .text
                $0.content = .text(text)
            }
        } else {
            nil
        }

        return Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            if let content {
                $0.content = content
            }
            $0.availableTypes = availableTypes
        }
    }

    func changeCount() async -> Int {
        pasteboard.changeCount
    }

    func clear() async {
        pasteboard.clearContents()
    }

    func write(_ content: Exactmac_V1_ClipboardContent) async -> Bool {
        switch content.content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .rtf(rtfData):
            pasteboard.setData(rtfData, forType: .rtf)
        case let .html(html):
            if let htmlData = html.data(using: .utf8) {
                pasteboard.setData(htmlData, forType: .html)
            } else {
                false
            }
        case let .image(imageData):
            if let image = NSImage(data: imageData) {
                pasteboard.writeObjects([image])
            } else {
                false
            }
        case let .files(filePaths):
            pasteboard.writeObjects(filePaths.paths.map { URL(fileURLWithPath: $0) } as [NSURL])
        case let .url(urlString):
            if let url = URL(string: urlString) {
                pasteboard.writeObjects([url as NSURL])
            } else {
                false
            }
        case .none:
            false
        }
    }

    func snapshot() async throws -> ClipboardPasteboardSnapshot {
        let snapshots = try (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw ClipboardError.readFailed(
                        "Pasteboard type \(type.rawValue) could not be snapshotted",
                    )
                }
                representations[type.rawValue] = data
            }
            return ClipboardPasteboardItemSnapshot(
                representations: representations,
            )
        }
        return .native(snapshots)
    }

    func restore(_ snapshot: ClipboardPasteboardSnapshot) async throws {
        switch snapshot {
        case let .canonical(content):
            pasteboard.clearContents()
            if let content {
                guard await write(content) else {
                    throw ClipboardError.writeFailed(
                        "Pasteboard rejected the restored clipboard content",
                    )
                }
            }
            let observed = await read()
            guard observed.hasContent == (content != nil),
                  content == nil || observed.content == content
            else {
                throw ClipboardError.writeFailed(
                    "Restored clipboard content did not match its snapshot",
                )
            }
        case let .native(snapshots):
            pasteboard.clearContents()
            guard !snapshots.isEmpty else {
                return
            }
            let items = try snapshots.map { snapshot in
                let item = NSPasteboardItem()
                for (rawType, data) in snapshot.representations {
                    guard item.setData(data, forType: NSPasteboard.PasteboardType(rawType)) else {
                        throw ClipboardError.writeFailed(
                            "Pasteboard rejected restored type \(rawType)",
                        )
                    }
                }
                return item
            }
            guard pasteboard.writeObjects(items) else {
                throw ClipboardError.writeFailed(
                    "Pasteboard rejected its exact restored item snapshot",
                )
            }
            guard try await self.snapshot() == snapshot else {
                throw ClipboardError.writeFailed(
                    "Pasteboard did not reproduce its exact restored item snapshot",
                )
            }
        }
    }
}

enum TemporaryClipboardOwnershipError: Error, Equatable, LocalizedError {
    case unstableSnapshot(before: Int, after: Int)
    case ownershipLost(expected: Int, observed: Int)

    var errorDescription: String? {
        switch self {
        case let .unstableSnapshot(before, after):
            "Clipboard ownership changed while snapshotting (\(before) -> \(after))"
        case let .ownershipLost(expected, observed):
            "Temporary clipboard ownership was lost (expected \(expected), observed \(observed))"
        }
    }
}

private actor TemporaryClipboardLease {
    private let pasteboard: any ClipboardPasteboard
    private let originalSnapshot: ClipboardPasteboardSnapshot
    private var ownedChangeCount: Int
    private var isRestored = false

    private init(
        pasteboard: any ClipboardPasteboard,
        originalSnapshot: ClipboardPasteboardSnapshot,
        ownedChangeCount: Int,
    ) {
        self.pasteboard = pasteboard
        self.originalSnapshot = originalSnapshot
        self.ownedChangeCount = ownedChangeCount
    }

    static func acquire(
        pasteboard: any ClipboardPasteboard,
    ) async throws -> TemporaryClipboardLease {
        let before = await pasteboard.changeCount()
        let snapshot = try await pasteboard.snapshot()
        let after = await pasteboard.changeCount()
        guard before == after else {
            throw TemporaryClipboardOwnershipError.unstableSnapshot(
                before: before,
                after: after,
            )
        }
        return TemporaryClipboardLease(
            pasteboard: pasteboard,
            originalSnapshot: snapshot,
            ownedChangeCount: after,
        )
    }

    func replaceText(_ text: String) async throws {
        try await validateOwnership()
        let content = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text(text)
        }
        await pasteboard.clear()
        guard await pasteboard.write(content) else {
            throw ClipboardError.writeFailed(
                "Failed to stage temporary text for physical paste",
            )
        }
        let stagedChangeCount = await pasteboard.changeCount()
        let observed = await pasteboard.read()
        let verifiedChangeCount = await pasteboard.changeCount()
        guard stagedChangeCount == verifiedChangeCount else {
            throw TemporaryClipboardOwnershipError.ownershipLost(
                expected: stagedChangeCount,
                observed: verifiedChangeCount,
            )
        }
        guard observed.hasContent,
              observed.content.type == .text,
              observed.content.content == .text(text)
        else {
            throw ClipboardError.writeFailed(
                "Temporary physical-paste text did not converge",
            )
        }
        ownedChangeCount = verifiedChangeCount
    }

    func restore() async throws {
        guard !isRestored else {
            return
        }
        try await validateOwnership()
        try await pasteboard.restore(originalSnapshot)
        isRestored = true
    }

    private func validateOwnership() async throws {
        let observed = await pasteboard.changeCount()
        guard observed == ownedChangeCount else {
            throw TemporaryClipboardOwnershipError.ownershipLost(
                expected: ownedChangeCount,
                observed: observed,
            )
        }
    }
}

/// Manages clipboard operations using NSPasteboard.
actor ClipboardManager {
    nonisolated let mutationGate: PhysicalDesktopMutationGate
    nonisolated let historyManager: ClipboardHistoryManager
    nonisolated let accessGate: ClipboardAccessGate
    private let pasteboard: any ClipboardPasteboard

    init(
        mutationGate: PhysicalDesktopMutationGate,
        historyManager: ClipboardHistoryManager,
        pasteboard: any ClipboardPasteboard = SystemClipboardPasteboard(),
        accessGate: ClipboardAccessGate = ClipboardAccessGate(),
    ) {
        self.mutationGate = mutationGate
        self.historyManager = historyManager
        self.pasteboard = pasteboard
        self.accessGate = accessGate
    }

    /// Read current clipboard contents.
    func readClipboard() async throws -> Exactmac_V1_Clipboard {
        let pasteboard = self.pasteboard
        return try await accessGate.withExclusiveAccess {
            let observed = await pasteboard.read()
            do {
                return try Self.canonicalizeObservation(observed, requireContent: false)
            } catch {
                throw ClipboardError.readFailed("Clipboard observation is invalid: \(error)")
            }
        }
    }

    func pendingClipboardAccessCount() async -> Int {
        await accessGate.pendingCount()
    }

    func withTemporaryText<Result: Sendable>(
        _ operation: @escaping @Sendable (
            _ replaceText: @escaping @Sendable (String) async throws -> Void,
        ) async throws -> Result,
    ) async throws -> Result {
        let pasteboard = self.pasteboard
        return try await accessGate.withExclusiveAccess {
            let lease = try await TemporaryClipboardLease.acquire(
                pasteboard: pasteboard,
            )
            let replaceText: @Sendable (String) async throws -> Void = { text in
                try await lease.replaceText(text)
            }

            do {
                let result = try await operation(replaceText)
                try await Self.restoreClipboard(
                    lease,
                )
                return result
            } catch {
                do {
                    try await Self.restoreClipboard(
                        lease,
                    )
                } catch let restorationError {
                    throw TemporaryClipboardRestorationError(
                        operationError: error,
                        restorationError: restorationError,
                    )
                }
                throw error
            }
        }
    }

    /// Write content to clipboard.
    func writeClipboard(content: Exactmac_V1_ClipboardContent) async throws
        -> Exactmac_V1_Clipboard
    {
        let expected = try Self.canonicalize(content: content)
        let pasteboard = self.pasteboard
        let historyManager = self.historyManager
        return try await mutationGate.withExclusiveOperation {
            try await self.accessGate.withExclusiveAccess {
                // NSPasteboard requires a fresh ownership declaration for every write.
                await pasteboard.clear()
                guard await pasteboard.write(expected) else {
                    throw ClipboardError.writeFailed("Failed to write clipboard content")
                }

                let rawObserved = await pasteboard.read()
                let observed: Exactmac_V1_Clipboard
                do {
                    observed = try Self.canonicalizeObservation(
                        rawObserved,
                        requireContent: true,
                    )
                } catch {
                    throw ClipboardError.writeFailed(
                        "Written clipboard content was not observed: \(error)",
                    )
                }
                guard Self.semanticallyEqual(observed.content, expected) else {
                    throw ClipboardError.writeFailed(
                        "Written clipboard content did not match the observed content",
                    )
                }
                await historyManager.addEntry(content: observed.content)
                return observed
            }
        }
    }

    /// Clear clipboard contents.
    func clearClipboard() async throws -> Exactmac_V1_Clipboard {
        let pasteboard = self.pasteboard
        return try await mutationGate.withExclusiveOperation {
            try await self.accessGate.withExclusiveAccess {
                await pasteboard.clear()
                let rawObserved = await pasteboard.read()
                let observed: Exactmac_V1_Clipboard
                do {
                    observed = try Self.canonicalizeObservation(
                        rawObserved,
                        requireContent: false,
                    )
                } catch {
                    throw ClipboardError.writeFailed(
                        "Cleared clipboard observation is invalid: \(error)",
                    )
                }
                guard !observed.hasContent, observed.availableTypes.isEmpty else {
                    throw ClipboardError.writeFailed("Cleared clipboard still exposes content")
                }
                return observed
            }
        }
    }

    private nonisolated static func canonicalize(
        content: Exactmac_V1_ClipboardContent,
    ) throws -> Exactmac_V1_ClipboardContent {
        guard content.hasType else {
            throw ClipboardError.invalidContent("Content type is required")
        }
        let representedType: Exactmac_V1_ContentType
        let payload: Exactmac_V1_ClipboardContent.OneOf_Content
        switch content.content {
        case let .text(value):
            representedType = .text
            payload = .text(value)
        case let .rtf(data):
            representedType = .rtf
            guard !data.isEmpty else {
                throw ClipboardError.invalidContent("RTF content is empty")
            }
            do {
                _ = try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil,
                )
            } catch {
                throw ClipboardError.invalidContent("RTF content is invalid")
            }
            payload = .rtf(data)
        case let .html(value):
            representedType = .html
            guard value.data(using: .utf8) != nil else {
                throw ClipboardError.invalidContent("HTML content is not valid UTF-8")
            }
            payload = .html(value)
        case let .image(data):
            guard canonicalImageData(data) != nil else {
                throw ClipboardError.invalidContent("Image content is not a valid image")
            }
            representedType = .image
            payload = .image(data)
        case let .files(filePaths):
            representedType = .files
            guard !filePaths.paths.isEmpty else {
                throw ClipboardError.invalidContent("At least one file path is required")
            }
            let canonicalPaths = try filePaths.paths.map { path in
                guard !path.isEmpty, (path as NSString).isAbsolutePath else {
                    throw ClipboardError.invalidContent("File paths must be absolute")
                }
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
            payload = .files(
                Exactmac_V1_FilePaths.with {
                    $0.paths = canonicalPaths
                },
            )
        case let .url(value):
            guard let url = URL(string: value),
                  url.scheme != nil,
                  url.baseURL == nil
            else {
                throw ClipboardError.invalidContent("URL content must be absolute")
            }
            representedType = .url
            payload = .url(url.standardized.absoluteString)
        case .none:
            throw ClipboardError.invalidContent("No content specified")
        }
        guard content.type == representedType else {
            throw ClipboardError.invalidContent("Content type does not match its payload")
        }
        return Exactmac_V1_ClipboardContent.with {
            $0.type = representedType
            $0.content = payload
        }
    }

    private nonisolated static func canonicalizeObservation(
        _ observed: Exactmac_V1_Clipboard,
        requireContent: Bool,
    ) throws -> Exactmac_V1_Clipboard {
        guard observed.name == "clipboard" else {
            throw ClipboardError.readFailed("Clipboard resource name is invalid")
        }
        guard observed.hasContent else {
            guard !requireContent, observed.availableTypes.isEmpty else {
                throw ClipboardError.readFailed("Clipboard content is absent")
            }
            return Exactmac_V1_Clipboard.with {
                $0.name = "clipboard"
            }
        }

        let content = try canonicalize(content: observed.content)
        guard observed.availableTypes.contains(content.type) else {
            throw ClipboardError.readFailed("Clipboard content type is unavailable")
        }
        guard observed.availableTypes.allSatisfy({ $0 != .unspecified }) else {
            throw ClipboardError.readFailed("Clipboard exposes an unspecified content type")
        }
        return Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            $0.content = content
            $0.availableTypes = observed.availableTypes
        }
    }

    private nonisolated static func semanticallyEqual(
        _ lhs: Exactmac_V1_ClipboardContent,
        _ rhs: Exactmac_V1_ClipboardContent,
    ) -> Bool {
        guard lhs.type == rhs.type else {
            return false
        }
        switch (lhs.content, rhs.content) {
        case let (.image(lhsData), .image(rhsData)):
            guard let lhsImage = canonicalImageData(lhsData),
                  let rhsImage = canonicalImageData(rhsData)
            else {
                return false
            }
            return lhsImage == rhsImage
        default:
            return lhs == rhs
        }
    }

    private nonisolated static func canonicalImageData(_ data: Data) -> Data? {
        guard let representation = NSBitmapImageRep(data: data),
              representation.pixelsWide > 0,
              representation.pixelsHigh > 0
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }

    private nonisolated static func restoreClipboard(
        _ lease: TemporaryClipboardLease,
    ) async throws {
        let restoration = Task.detached {
            try await lease.restore()
        }
        try await restoration.value
    }
}

/// Manages clipboard history.
actor ClipboardHistoryManager {
    private var history: [Exactmac_V1_ClipboardHistoryEntry] = []
    private let maxEntries = 100
    private let sourceApplication: @Sendable () -> String

    init(
        sourceApplication: @escaping @Sendable () -> String = ClipboardHistoryManager
            .getActiveApplicationName,
    ) {
        self.sourceApplication = sourceApplication
    }

    /// Add an entry to clipboard history.
    func addEntry(content: Exactmac_V1_ClipboardContent) {
        let entry = Exactmac_V1_ClipboardHistoryEntry.with {
            $0.copiedTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.content = content
            $0.sourceApplication = sourceApplication()
        }

        // Add to beginning (most recent first)
        history.insert(entry, at: 0)

        // Limit history size
        if history.count > maxEntries {
            history = Array(history.prefix(maxEntries))
        }
    }

    /// Get clipboard history.
    func getHistory() -> Exactmac_V1_ClipboardHistory {
        Exactmac_V1_ClipboardHistory.with {
            $0.entries = history
        }
    }

    func entryLimit() -> Int {
        maxEntries
    }

    /// Get the name of the active application.
    private nonisolated static func getActiveApplicationName() -> String {
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

struct TemporaryClipboardRestorationError: Error, @unchecked Sendable {
    let operationError: any Error
    let restorationError: any Error
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
