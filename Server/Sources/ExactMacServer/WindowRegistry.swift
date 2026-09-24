// Copyright 2025 Joseph Cumines
//
// WindowRegistry - Thread-safe registry for tracking application windows

import AppKit
import ApplicationServices
import ExactMac
import Foundation
import GRPCCore
import OSLog

private let logger = ExactMac.sdkLogger(category: "WindowRegistry")

/// Thread-safe registry for current Core Graphics windows and their public,
/// generation-scoped resource identities.
actor WindowRegistry {
    final class RetainedWindowElement: @unchecked Sendable {
        let element: AXUIElement

        init(_ element: AXUIElement) {
            self.element = element
        }
    }

    struct WindowInfo: Sendable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let bounds: CGRect
        let title: String
        let layer: Int32
        let isOnScreen: Bool
        let timestamp: Date
        let bundleID: String?

        func replacing(
            windowID replacement: CGWindowID,
            bounds replacementBounds: CGRect? = nil,
        ) -> WindowInfo {
            WindowInfo(
                windowID: replacement,
                ownerPID: ownerPID,
                bounds: replacementBounds ?? bounds,
                title: title,
                layer: layer,
                isOnScreen: isOnScreen,
                timestamp: timestamp,
                bundleID: bundleID,
            )
        }

        func replacingMetadata(from snapshot: WindowInfo) -> WindowInfo {
            WindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                bounds: bounds,
                title: snapshot.title,
                layer: snapshot.layer,
                isOnScreen: snapshot.isOnScreen,
                timestamp: snapshot.timestamp,
                bundleID: snapshot.bundleID,
            )
        }
    }

    /// One server-owned public name for one continuously observed window
    /// generation under one exact application process instance.
    struct WindowBinding: Sendable {
        let resourceID: String
        let applicationName: String
        let processIdentity: ApplicationProcessIdentity?
        let info: WindowInfo
        let retainedElement: RetainedWindowElement?

        var name: String {
            "\(applicationName)/windows/\(resourceID)"
        }

        var windowID: CGWindowID {
            info.windowID
        }

        var ownerPID: pid_t {
            info.ownerPID
        }

        var bounds: CGRect {
            info.bounds
        }

        var title: String {
            info.title
        }

        var layer: Int32 {
            info.layer
        }

        var isOnScreen: Bool {
            info.isOnScreen
        }

        var bundleID: String? {
            info.bundleID
        }
    }

    private struct WindowOwner: Hashable, Sendable {
        let applicationName: String
        let pid: pid_t
        let processIdentity: ApplicationProcessIdentity?
    }

    struct WindowPage: Sendable {
        let bindings: [WindowBinding]
        let nextPageToken: String
    }

    private struct PageCursor: Sendable {
        let snapshotID: String
        let offset: Int
    }

    private struct PageSnapshot: Sendable {
        let owner: WindowOwner
        let queryBinding: String
        let bindings: [WindowBinding]
        let expiresAt: ContinuousClock.Instant
        var tokensByOffset: [Int: String]
    }

    private let system: SystemOperations
    private var windowCache: [CGWindowID: WindowInfo] = [:]
    private var bindingIDsByOwner: [WindowOwner: [CGWindowID: String]] = [:]
    private var bindingsByResourceID: [String: WindowBinding] = [:]
    private var pageSnapshots: [String: PageSnapshot] = [:]
    private var pageCursors: [String: PageCursor] = [:]
    private let maximumPageSnapshots = 256
    private let maximumPageRows = 100_000
    private let maximumPageCursors = 100_000
    private let pageSnapshotLifetime: Duration = .seconds(3 * 24 * 60 * 60)
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    init(
        system: SystemOperations = ProductionSystemOperations.shared,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
    ) {
        self.system = system
        self.monotonicNow = monotonicNow
    }

    /// Replaces the complete current snapshot for one owner (or every owner).
    /// Missing windows are removed immediately; a later reuse of the same CG ID
    /// receives a new public resource name.
    func refreshWindows(
        forPID pid: pid_t? = nil,
        processIdentity: ApplicationProcessIdentity? = nil,
    ) async throws {
        let refreshed = try readWindowSnapshot(
            forPID: pid,
            processIdentity: processIdentity,
        )

        if let pid {
            windowCache = windowCache.filter { $0.value.ownerPID != pid }
            windowCache.merge(refreshed) { _, replacement in replacement }
            retireMissingBindings(forPID: pid, currentWindowIDs: Set(refreshed.keys))
        } else {
            windowCache = refreshed
            let currentIDsByPID = Dictionary(grouping: refreshed.values, by: \.ownerPID)
                .mapValues { Set($0.map(\.windowID)) }
            for owner in Array(bindingIDsByOwner.keys) {
                retireMissingBindings(
                    for: owner,
                    currentWindowIDs: currentIDsByPID[owner.pid] ?? [],
                )
            }
        }
    }

    /// Lists one current raw window snapshot. This method performs exactly one
    /// Core Graphics inventory call.
    func listWindows(
        forPID pid: pid_t,
        processIdentity: ApplicationProcessIdentity? = nil,
    ) async throws -> [WindowInfo] {
        try await refreshWindows(forPID: pid, processIdentity: processIdentity)
        return windowCache.values
            .filter { $0.ownerPID == pid }
            .sorted(by: Self.windowOrder)
    }

    /// Reconciles the current raw snapshot into stable public bindings.
    func listWindowBindings(
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
    ) async throws -> [WindowBinding] {
        let infos = try await listWindows(
            forPID: pid,
            processIdentity: processIdentity,
        )
        let owner = WindowOwner(
            applicationName: applicationName,
            pid: pid,
            processIdentity: processIdentity,
        )
        retireReplacedOwners(current: owner)

        var resourceIDsByWindowID = bindingIDsByOwner[owner] ?? [:]
        let currentWindowIDs = Set(infos.map(\.windowID))
        for windowID in Array(resourceIDsByWindowID.keys) where !currentWindowIDs.contains(windowID) {
            if let resourceID = resourceIDsByWindowID.removeValue(forKey: windowID) {
                bindingsByResourceID.removeValue(forKey: resourceID)
            }
        }

        var bindings: [WindowBinding] = []
        bindings.reserveCapacity(infos.count)
        for info in infos {
            let resourceID = resourceIDsByWindowID[info.windowID] ?? makeResourceID()
            resourceIDsByWindowID[info.windowID] = resourceID
            let retainedElement = bindingsByResourceID[resourceID]?.retainedElement
            let binding = WindowBinding(
                resourceID: resourceID,
                applicationName: applicationName,
                processIdentity: processIdentity,
                info: info,
                retainedElement: retainedElement,
            )
            bindingsByResourceID[resourceID] = binding
            bindings.append(binding)
        }
        bindingIDsByOwner[owner] = resourceIDsByWindowID
        return bindings.sorted { Self.windowOrder($0.info, $1.info) }
    }

    func firstWindowPage(
        bindings: [WindowBinding],
        pageSize: Int,
        skip: Int,
        queryBinding: String,
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
    ) throws -> WindowPage {
        guard pageSize > 0 else {
            throw RPCError(code: .internalError, message: "Window page size must be positive after validation")
        }
        guard skip >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "skip must not be negative",
                reason: "INVALID_SKIP",
                field: "skip",
                value: String(skip),
            )
        }
        let publicBindings = bindings.map(Self.publicSnapshotBinding)
        let start = min(skip, publicBindings.count)
        guard start < publicBindings.count else {
            return WindowPage(bindings: [], nextPageToken: "")
        }
        let (candidateEnd, overflow) = start.addingReportingOverflow(pageSize)
        let upperBound = overflow ? publicBindings.count : min(candidateEnd, publicBindings.count)
        guard upperBound < publicBindings.count else {
            return WindowPage(
                bindings: Array(publicBindings[start ..< upperBound]),
                nextPageToken: "",
            )
        }

        purgeExpiredPageSnapshots()
        guard pageSnapshots.count < maximumPageSnapshots else {
            throw RPCError(
                code: .resourceExhausted,
                message: "Too many active ListWindows snapshots",
            )
        }
        let activeRows = pageSnapshots.values.reduce(0) { $0 + $1.bindings.count }
        guard bindings.count <= maximumPageRows - min(activeRows, maximumPageRows) else {
            throw RPCError(
                code: .resourceExhausted,
                message: "ListWindows snapshot row capacity is exhausted",
            )
        }
        let snapshotID = makeOpaquePageHandle()
        pageSnapshots[snapshotID] = PageSnapshot(
            owner: WindowOwner(
                applicationName: applicationName,
                pid: pid,
                processIdentity: processIdentity,
            ),
            queryBinding: queryBinding,
            bindings: publicBindings,
            expiresAt: monotonicNow().advanced(by: pageSnapshotLifetime),
            tokensByOffset: [:],
        )
        let token = try makePageToken(snapshotID: snapshotID, offset: upperBound)
        return WindowPage(
            bindings: Array(publicBindings[start ..< upperBound]),
            nextPageToken: token,
        )
    }

    func continuationWindowPage(
        token: String,
        pageSize: Int,
        skip: Int,
        queryBinding: String,
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
    ) throws -> WindowPage {
        guard pageSize > 0 else {
            throw RPCError(code: .internalError, message: "Window page size must be positive after validation")
        }
        guard skip >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "skip must not be negative",
                reason: "INVALID_SKIP",
                field: "skip",
                value: String(skip),
            )
        }
        purgeExpiredPageSnapshots()
        guard let cursor = pageCursors[token],
              let snapshot = pageSnapshots[cursor.snapshotID],
              snapshot.owner == WindowOwner(
                  applicationName: applicationName,
                  pid: pid,
                  processIdentity: processIdentity,
              ),
              snapshot.queryBinding == queryBinding,
              cursor.offset >= 0,
              cursor.offset <= snapshot.bindings.count
        else {
            throw invalidPageToken()
        }
        let (start, startOverflow) = cursor.offset.addingReportingOverflow(skip)
        guard !startOverflow else {
            throw RPCErrorHelpers.validationError(
                message: "page_token offset plus skip overflows",
                reason: "INVALID_SKIP",
                field: "skip",
            )
        }
        guard start < snapshot.bindings.count else {
            return WindowPage(bindings: [], nextPageToken: "")
        }
        let (candidateUpperBound, upperOverflow) = start.addingReportingOverflow(pageSize)
        let upperBound = upperOverflow
            ? snapshot.bindings.count
            : min(candidateUpperBound, snapshot.bindings.count)
        let nextToken = upperBound < snapshot.bindings.count
            ? try makePageToken(snapshotID: cursor.snapshotID, offset: upperBound)
            : ""
        return WindowPage(
            bindings: Array(snapshot.bindings[start ..< upperBound]),
            nextPageToken: nextToken,
        )
    }

    func resolveWindowBinding(
        resourceID: String,
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
    ) -> WindowBinding? {
        guard let binding = bindingsByResourceID[resourceID],
              binding.applicationName == applicationName,
              binding.ownerPID == pid,
              binding.processIdentity == processIdentity
        else {
            return nil
        }
        return binding
    }

    /// Atomically admits or revalidates one exact AX object and persists its
    /// observed private ID and frame. Before initial admission the ID must
    /// equal the CG snapshot. After admission, CF identity is authoritative
    /// and the ID may change only for that same retained object.
    func admitExactWindowElement(
        resourceID: String,
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
        expectedWindowID: CGWindowID,
        element: AXUIElement,
        observedWindowID: CGWindowID,
        observedBounds: CGRect,
    ) -> WindowBinding? {
        let owner = WindowOwner(
            applicationName: applicationName,
            pid: pid,
            processIdentity: processIdentity,
        )
        guard let binding = resolveWindowBinding(
            resourceID: resourceID,
            applicationName: applicationName,
            pid: pid,
            processIdentity: processIdentity,
        ) else {
            return nil
        }
        guard EndpointSafeGeometry.containsValidEndpoints(
            observedBounds,
            requiresPositiveSize: false,
        ) else {
            return nil
        }
        if let retained = binding.retainedElement {
            guard CFEqual(retained.element, element) else {
                return nil
            }
        } else {
            guard binding.windowID == expectedWindowID,
                  observedWindowID == expectedWindowID
            else {
                return nil
            }
        }
        var ids = bindingIDsByOwner[owner] ?? [:]
        guard binding.windowID == observedWindowID ||
            ids[observedWindowID] == nil ||
            ids[observedWindowID] == resourceID
        else {
            return nil
        }
        if binding.windowID != observedWindowID {
            ids.removeValue(forKey: binding.windowID)
            ids[observedWindowID] = resourceID
            bindingIDsByOwner[owner] = ids
        }

        let replacementInfo = binding.info.replacing(
            windowID: observedWindowID,
            bounds: observedBounds,
        )
        if binding.windowID != observedWindowID {
            windowCache.removeValue(forKey: binding.windowID)
        }
        windowCache[observedWindowID] = replacementInfo
        let replacement = WindowBinding(
            resourceID: resourceID,
            applicationName: applicationName,
            processIdentity: processIdentity,
            info: replacementInfo,
            retainedElement: binding.retainedElement ?? RetainedWindowElement(element),
        )
        bindingsByResourceID[resourceID] = replacement
        return replacement
    }

    /// Refreshes result-shaping Core Graphics metadata for one already-admitted
    /// exact AX window without replacing its AX-observed geometry or public
    /// identity. A missing current CG record is contradictory evidence, so the
    /// public response fails closed instead of returning stale visibility.
    func refreshExactWindowMetadata(
        resourceID: String,
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
        observedWindowID: CGWindowID,
    ) throws -> WindowBinding {
        guard let binding = resolveWindowBinding(
            resourceID: resourceID,
            applicationName: applicationName,
            pid: pid,
            processIdentity: processIdentity,
        ) else {
            throw RPCError(code: .notFound, message: "Window binding is stale")
        }
        guard binding.windowID == observedWindowID else {
            throw RPCError(code: .failedPrecondition, message: "Window identity changed ambiguously")
        }
        let snapshot = try readWindowSnapshot(
            forPID: pid,
            processIdentity: processIdentity,
        )
        guard let current = snapshot[observedWindowID] else {
            throw RPCError(
                code: .unavailable,
                message: "Current Core Graphics window metadata is unavailable",
            )
        }
        let replacement = WindowBinding(
            resourceID: binding.resourceID,
            applicationName: binding.applicationName,
            processIdentity: binding.processIdentity,
            info: binding.info.replacingMetadata(from: current),
            retainedElement: binding.retainedElement,
        )
        bindingsByResourceID[resourceID] = replacement
        windowCache[observedWindowID] = replacement.info
        return replacement
    }

    func retireWindowBinding(
        resourceID: String,
        applicationName: String,
        pid: pid_t,
        processIdentity: ApplicationProcessIdentity?,
    ) {
        let owner = WindowOwner(
            applicationName: applicationName,
            pid: pid,
            processIdentity: processIdentity,
        )
        guard let binding = resolveWindowBinding(
            resourceID: resourceID,
            applicationName: applicationName,
            pid: pid,
            processIdentity: processIdentity,
        ) else {
            return
        }
        bindingsByResourceID.removeValue(forKey: resourceID)
        bindingIDsByOwner[owner]?.removeValue(forKey: binding.windowID)
        if bindingIDsByOwner[owner]?.isEmpty == true {
            bindingIDsByOwner.removeValue(forKey: owner)
        }
        windowCache.removeValue(forKey: binding.windowID)
    }

    func getWindow(_ windowID: CGWindowID) async throws -> WindowInfo? {
        if let cached = windowCache[windowID] {
            return cached
        }
        try await refreshWindows()
        return windowCache[windowID]
    }

    func listAllWindows() async throws -> [WindowInfo] {
        try await refreshWindows()
        return windowCache.values.sorted(by: Self.windowOrder)
    }

    func invalidate(windowID: CGWindowID) {
        windowCache.removeValue(forKey: windowID)
    }

    func invalidate(forPID pid: pid_t) {
        windowCache = windowCache.filter { $0.value.ownerPID != pid }
        for owner in Array(bindingIDsByOwner.keys) where owner.pid == pid {
            retireOwner(owner)
        }
    }

    func getLastKnownWindow(_ windowID: CGWindowID, ownerPID: pid_t? = nil) -> WindowInfo? {
        guard let info = windowCache[windowID], ownerPID == nil || info.ownerPID == ownerPID else {
            return nil
        }
        return info
    }

    func findWindowByPosition(
        pid: pid_t,
        x: Double,
        y: Double,
        tolerance: Double = 5.0,
    ) -> WindowInfo? {
        let matches = windowCache.values.filter { info in
            info.ownerPID == pid &&
                abs(info.bounds.origin.x - x) <= tolerance &&
                abs(info.bounds.origin.y - y) <= tolerance
        }
        return matches.count == 1 ? matches.first : nil
    }

    func findWindowByBounds(
        pid: pid_t,
        bounds: CGRect,
        tolerance: Double = 5.0,
    ) -> WindowInfo? {
        let matches = windowCache.values.filter { info in
            info.ownerPID == pid &&
                abs(info.bounds.origin.x - bounds.origin.x) <= tolerance &&
                abs(info.bounds.origin.y - bounds.origin.y) <= tolerance &&
                abs(info.bounds.width - bounds.width) <= tolerance &&
                abs(info.bounds.height - bounds.height) <= tolerance
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func validateSnapshotOwner(
        pid: pid_t?,
        processIdentity: ApplicationProcessIdentity?,
    ) throws {
        guard let processIdentity else {
            return
        }
        guard pid == processIdentity.pid,
              system.isApplicationProcessRunning(processIdentity)
        else {
            throw RPCError(code: .notFound, message: "Window owner process identity is stale")
        }
    }

    private func readWindowSnapshot(
        forPID pid: pid_t?,
        processIdentity: ApplicationProcessIdentity?,
    ) throws -> [CGWindowID: WindowInfo] {
        try validateSnapshotOwner(pid: pid, processIdentity: processIdentity)
        let windowList: [[String: Any]]
        do {
            windowList = try system.cgWindowListCopyWindowInfo(
                options: [.optionAll, .excludeDesktopElements],
                relativeToWindow: kCGNullWindowID,
            )
        } catch {
            throw RPCError(code: .unavailable, message: "Core Graphics window snapshot is unavailable")
        }
        let now = Date()
        var refreshed: [CGWindowID: WindowInfo] = [:]
        var skippedMalformed = 0
        for windowDictionary in windowList {
            guard let parsedOwnerPID = Self.int32(
                windowDictionary[kCGWindowOwnerPID as String],
            ), parsedOwnerPID > 0 else {
                // A CG window snapshot is a point-in-time view of a changing
                // population; transient entries (windows mid-creation/teardown,
                // system overlays) routinely carry an absent or non-positive
                // owner PID. Such an entry cannot belong to any specific owner,
                // so skip it rather than aborting the whole snapshot.
                skippedMalformed += 1
                continue
            }
            let ownerPID = pid_t(parsedOwnerPID)
            guard pid == nil || ownerPID == pid else {
                continue
            }
            let info: WindowInfo
            if pid == nil {
                // System-wide enumeration (listAllWindows) is best-effort over a
                // volatile population: a single window with transiently
                // incomplete bounds/layer metadata must not make the entire
                // listing unavailable. Skip malformed entries and continue with
                // the valid windows.
                do {
                    info = try parseWindowInfo(
                        windowDictionary,
                        ownerPID: ownerPID,
                        timestamp: now,
                    )
                } catch {
                    skippedMalformed += 1
                    continue
                }
            } else {
                // Owned enumeration (a specific application's windows) is a
                // fail-closed contract: malformed geometry/type for the owned
                // application signals corruption that must NOT silently replace
                // the last valid snapshot. Throw so the caller sees the failure
                // and the prior valid state is retained.
                info = try parseWindowInfo(
                    windowDictionary,
                    ownerPID: ownerPID,
                    timestamp: now,
                )
            }
            guard refreshed.updateValue(info, forKey: info.windowID) == nil else {
                throw invalidSnapshot("Core Graphics window snapshot contains a duplicate window ID")
            }
        }
        if skippedMalformed > 0 {
            logger.debug("skipped \(skippedMalformed, privacy: .public) malformed CG window entries during snapshot refresh")
        }
        try validateSnapshotOwner(pid: pid, processIdentity: processIdentity)
        return refreshed
    }

    private func parseWindowInfo(
        _ dictionary: [String: Any],
        ownerPID: pid_t,
        timestamp: Date,
    ) throws -> WindowInfo {
        guard let windowID = Self.windowID(dictionary[kCGWindowNumber as String]),
              windowID != kCGNullWindowID,
              let rawBounds = dictionary[kCGWindowBounds as String] as? [String: Any],
              let x = Self.cgFloat(rawBounds["X"]),
              let y = Self.cgFloat(rawBounds["Y"]),
              let width = Self.cgFloat(rawBounds["Width"]),
              let height = Self.cgFloat(rawBounds["Height"]),
              EndpointSafeGeometry.containsValidEndpoints(
                  x: x,
                  y: y,
                  width: width,
                  height: height,
                  requiresPositiveSize: false,
              ),
              let layer = Self.int32(dictionary[kCGWindowLayer as String])
        else {
            throw invalidSnapshot("Core Graphics returned malformed window metadata")
        }
        let isOnScreen: Bool
        if let rawIsOnScreen = dictionary[kCGWindowIsOnscreen as String] {
            guard let boolean = rawIsOnScreen as? Bool else {
                throw invalidSnapshot("Core Graphics returned a malformed onscreen state")
            }
            isOnScreen = boolean
        } else {
            // CoreGraphics/CGWindow.h defines absence of this optional key as
            // "not ordered on screen"; this is source data, not inference.
            isOnScreen = false
        }
        let title: String
        if let rawTitle = dictionary[kCGWindowName as String] {
            guard let string = rawTitle as? String else {
                throw invalidSnapshot("Core Graphics returned a malformed window title")
            }
            title = string
        } else {
            title = ""
        }
        return WindowInfo(
            windowID: windowID,
            ownerPID: ownerPID,
            bounds: CGRect(x: x, y: y, width: width, height: height),
            title: title,
            layer: layer,
            isOnScreen: isOnScreen,
            timestamp: timestamp,
            bundleID: system.getRunningApplicationBundleID(pid: ownerPID),
        )
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return CGFloat(number.doubleValue)
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int32.min),
              double <= Double(Int32.max)
        else {
            return nil
        }
        return Int32(double)
    }

    private static func windowID(_ value: Any?) -> CGWindowID? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= 0,
              double <= Double(CGWindowID.max)
        else {
            return nil
        }
        return CGWindowID(double)
    }

    private func invalidSnapshot(_ message: String) -> RPCError {
        RPCError(code: .unavailable, message: message)
    }

    private func purgeExpiredPageSnapshots() {
        let now = monotonicNow()
        let expired = pageSnapshots.compactMap { key, snapshot in
            snapshot.expiresAt <= now ? key : nil
        }
        for snapshotID in expired {
            removePageSnapshot(snapshotID)
        }
    }

    private func removePageSnapshot(_ snapshotID: String) {
        pageSnapshots.removeValue(forKey: snapshotID)
        pageCursors = pageCursors.filter { $0.value.snapshotID != snapshotID }
    }

    private func makePageToken(snapshotID: String, offset: Int) throws -> String {
        if let token = pageSnapshots[snapshotID]?.tokensByOffset[offset] {
            return token
        }
        guard pageCursors.count < maximumPageCursors else {
            throw RPCError(
                code: .resourceExhausted,
                message: "ListWindows cursor capacity is exhausted",
            )
        }
        let token = ParsingHelpers.encodePageToken(
            offset: offset,
            queryBinding: ParsingHelpers.pageTokenQuery(
                method: "ListWindowsSnapshot",
                parameters: [("snapshot", snapshotID)],
            ),
        )
        pageSnapshots[snapshotID]?.tokensByOffset[offset] = token
        pageCursors[token] = PageCursor(snapshotID: snapshotID, offset: offset)
        return token
    }

    private func makeOpaquePageHandle() -> String {
        var candidate = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        while pageSnapshots[candidate] != nil || pageCursors[candidate] != nil {
            candidate = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return candidate
    }

    private func invalidPageToken() -> RPCError {
        RPCErrorHelpers.validationError(
            message: "Invalid or expired page_token",
            reason: "INVALID_PAGE_TOKEN",
            field: "page_token",
        )
    }

    private static func windowOrder(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        lhs.layer == rhs.layer ? lhs.windowID < rhs.windowID : lhs.layer < rhs.layer
    }

    private static func publicSnapshotBinding(_ binding: WindowBinding) -> WindowBinding {
        WindowBinding(
            resourceID: binding.resourceID,
            applicationName: binding.applicationName,
            processIdentity: binding.processIdentity,
            info: binding.info,
            retainedElement: nil,
        )
    }

    private func makeResourceID() -> String {
        var candidate = UUID().uuidString.lowercased()
        while bindingsByResourceID[candidate] != nil {
            candidate = UUID().uuidString.lowercased()
        }
        return candidate
    }

    private func retireMissingBindings(forPID pid: pid_t, currentWindowIDs: Set<CGWindowID>) {
        for owner in Array(bindingIDsByOwner.keys) where owner.pid == pid {
            retireMissingBindings(for: owner, currentWindowIDs: currentWindowIDs)
        }
    }

    private func retireMissingBindings(
        for owner: WindowOwner,
        currentWindowIDs: Set<CGWindowID>,
    ) {
        guard var ids = bindingIDsByOwner[owner] else {
            return
        }
        for windowID in Array(ids.keys) where !currentWindowIDs.contains(windowID) {
            if let resourceID = ids.removeValue(forKey: windowID) {
                bindingsByResourceID.removeValue(forKey: resourceID)
            }
        }
        if ids.isEmpty {
            bindingIDsByOwner.removeValue(forKey: owner)
        } else {
            bindingIDsByOwner[owner] = ids
        }
    }

    private func retireReplacedOwners(current: WindowOwner) {
        for owner in Array(bindingIDsByOwner.keys)
            where owner.applicationName == current.applicationName &&
            owner.pid == current.pid &&
            owner != current
        {
            retireOwner(owner)
        }
    }

    private func retireOwner(_ owner: WindowOwner) {
        guard let ids = bindingIDsByOwner.removeValue(forKey: owner) else {
            return
        }
        for resourceID in ids.values {
            bindingsByResourceID.removeValue(forKey: resourceID)
        }
        for snapshotID in pageSnapshots.compactMap({ key, snapshot in
            snapshot.owner == owner ? key : nil
        }) {
            removePageSnapshot(snapshotID)
        }
    }
}
