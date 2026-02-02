import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

extension MacosUseService {
    func getWindow(
        request: ServerRequest<Macosusesdk_V1_GetWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("getWindow called for \(req.name, privacy: .public)")
        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/")
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        // CRITICAL FIX: ALWAYS use AX data for bounds (never fall back to stale CGWindowList).
        // This ensures GetWindow returns fresh geometry immediately after mutations (MoveWindow, ResizeWindow).
        // Hybrid data authority: AX is authoritative for geometry/state, Registry provides metadata.
        let axWindow = try await findWindowElement(pid: pid, windowId: windowId)
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: axWindow, registryInfo: nil)
    }

    func listWindows(
        request: ServerRequest<Macosusesdk_V1_ListWindowsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListWindowsResponse> {
        let req = request.message
        Self.logger.info("listWindows called")

        // Parse "applications/{pid}"
        let pid = try parsePID(fromName: req.parent)

        try await windowRegistry.refreshWindows(forPID: pid)
        let windowInfos = try await windowRegistry.listWindows(forPID: pid)

        // Sort by window ID for deterministic ordering
        let sortedWindowInfos = windowInfos.sorted { $0.windowID < $1.windowID }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedWindowInfos.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageWindowInfos = Array(sortedWindowInfos[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        // Build window list from registry data only - NO per-window AX queries
        // This returns fast, registry-only data (CoreGraphics only).
        // Clients MUST use GetWindowState for expensive AX queries (modal, minimizable, etc.).
        //
        // PERFORMANCE: This eliminates the O(N*M) catastrophe where N windows each
        // triggered M blocking AX queries. ListWindows now completes in <50ms regardless
        // of window count.
        let windows = pageWindowInfos.map { windowInfo in
            Macosusesdk_V1_Window.with {
                $0.name = "applications/\(pid)/windows/\(windowInfo.windowID)"
                $0.title = windowInfo.title
                $0.bounds = Macosusesdk_V1_Bounds.with {
                    $0.x = windowInfo.bounds.origin.x
                    $0.y = windowInfo.bounds.origin.y
                    $0.width = windowInfo.bounds.size.width
                    $0.height = windowInfo.bounds.size.height
                }
                $0.zIndex = Int32(windowInfo.layer)
                $0.visible = windowInfo.isOnScreen
                $0.bundleID = windowInfo.bundleID ?? ""
            }
        }

        let response = Macosusesdk_V1_ListWindowsResponse.with {
            $0.windows = windows
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func getWindowState(
        request: ServerRequest<Macosusesdk_V1_GetWindowStateRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WindowState> {
        let req = request.message
        Self.logger.info("getWindowState called for \(req.name, privacy: .public)")

        // Parse "applications/{pid}/windows/{windowId}/state"
        let components = req.name.split(separator: "/")
        guard components.count == 5,
              components[0] == "applications",
              components[2] == "windows",
              components[4] == "state",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window state name format")
        }

        // Find the window via AX API
        let axWindow = try await findWindowElement(pid: pid, windowId: windowId)

        // Build complete WindowState from AX queries
        let state = try await buildWindowStateFromAX(window: axWindow)

        // Set the resource name
        var response = state
        response.name = req.name

        return ServerResponse(message: response)
    }

    func focusWindow(
        request: ServerRequest<Macosusesdk_V1_FocusWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("focusWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let windowToFocus = try await findWindowElement(pid: pid, windowId: windowId)

        // Set kAXMainAttribute to true to focus the window
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) { [system = self.system] in
            let result = system.setAXAttribute(element: windowToFocus as AnyObject, attribute: kAXMainAttribute as String, value: true)
            guard result == 0 else {
                throw RPCError(code: .internalError, message: "Failed to focus window: AXErrorCode=\(result)")
            }
        }.value

        // Return updated window state
        return try await getWindow(
            request: ServerRequest(metadata: request.metadata, message: Macosusesdk_V1_GetWindowRequest.with { $0.name = req.name }), context: context,
        )
    }

    func moveWindow(
        request: ServerRequest<Macosusesdk_V1_MoveWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("moveWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Create AXValue and set position
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) { [system = self.system] in
            var newPosition = CGPoint(x: req.x, y: req.y)
            guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else {
                throw RPCError(code: .internalError, message: "Failed to create position value")
            }

            let result = system.setAXAttribute(element: window as AnyObject, attribute: kAXPositionAttribute as String, value: positionValue)
            guard result == 0 else {
                throw RPCError(
                    code: .internalError, message: "Failed to move window: AXErrorCode=\(result)",
                )
            }
        }.value

        // CRITICAL FIX: Refresh and fetch registry metadata BEFORE invalidation (nil registry bug fix)
        try await windowRegistry.refreshWindows(forPID: pid)

        // After move, the window may have a new CGWindowID. Try to find it by its new position.
        // Also capture the original window's registry info for metadata.
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Check if window ID changed by looking for the window at the new position
        let movedWindowInfo = await windowRegistry.findWindowByPosition(pid: pid, x: req.x, y: req.y)

        // Note: We do NOT try to re-acquire the AXUIElement even if the ID changed.
        // The original window AXUIElement should still be valid (or stale but usable for
        // querying current state). buildWindowResponseFromAX will query the actual ID
        // from the element and update the name accordingly.
        if let movedWindow = movedWindowInfo, movedWindow.windowID != windowId {
            Self.logger.info("[moveWindow] Window ID changed: \(windowId) → \(movedWindow.windowID)")
        }

        // Invalidate old cache entry
        await windowRegistry.invalidate(windowID: windowId)

        // Build response using the original AXUIElement
        // buildWindowResponseFromAX will query the current window ID from the element
        // and return the updated name if it changed
        return try await buildWindowResponseFromAX(
            name: req.name,
            pid: pid,
            windowId: windowId,
            window: window,
            registryInfo: movedWindowInfo ?? registryInfo,
        )
    }

    func resizeWindow(
        request: ServerRequest<Macosusesdk_V1_ResizeWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("resizeWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        // Get expected bounds from registry BEFORE finding the element.
        // This enables bounds-based fallback if the window ID has already regenerated.
        try await windowRegistry.refreshWindows(forPID: pid)
        let preResizeInfo = await windowRegistry.getLastKnownWindow(windowId)
        let preResizeBounds: CGRect? = if let info = preResizeInfo {
            info.bounds
        } else {
            // If we can't find the window in registry, try a more aggressive bounds search
            // using the window list (the window might have a new ID but similar bounds)
            // For now, pass nil which will trigger existing fallback logic.
            nil
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId, expectedBounds: preResizeBounds)

        // Create AXValue, set size, and verify
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) { [system = self.system] in
            var newSize = CGSize(width: req.width, height: req.height)
            guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
                throw RPCError(code: .internalError, message: "Failed to create size value")
            }

            let result = system.setAXAttribute(element: window as AnyObject, attribute: kAXSizeAttribute as String, value: sizeValue)
            guard result == 0 else {
                throw RPCError(
                    code: .internalError, message: "Failed to resize window: AXErrorCode=\(result)",
                )
            }

            // Verify AX actually applied the change
            var verifyValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &verifyValue)
                == .success,
                let unwrappedValue = verifyValue,
                CFGetTypeID(unwrappedValue) == AXValueGetTypeID()
            {
                let size = unsafeDowncast(unwrappedValue, to: AXValue.self)
                var actualSize = CGSize.zero
                if AXValueGetValue(size, .cgSize, &actualSize) {
                    Self.logger.info("After resize: requested=\(req.width, privacy: .public)x\(req.height, privacy: .public), actual=\(actualSize.width, privacy: .public)x\(actualSize.height, privacy: .public)")
                }
            }
        }.value

        // CRITICAL FIX: Refresh and fetch registry metadata BEFORE invalidation (nil registry bug fix)
        try await windowRegistry.refreshWindows(forPID: pid)

        // After resize, the window may have a new CGWindowID. Try to find it by its new bounds.
        // Also capture the original window's registry info for metadata.
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)
        let expectedBounds = CGRect(
            x: registryInfo?.bounds.origin.x ?? 0,
            y: registryInfo?.bounds.origin.y ?? 0,
            width: req.width,
            height: req.height,
        )

        // Check if window ID changed by looking for the window with the new size
        let resizedWindowInfo = await windowRegistry.findWindowByBounds(pid: pid, bounds: expectedBounds)
        let actualWindowId: CGWindowID
        let actualName: String
        let actualWindow: AXUIElement

        if let resizedWindow = resizedWindowInfo, resizedWindow.windowID != windowId {
            // Window ID changed - use the new ID and re-acquire AXUIElement
            Self.logger.info("[resizeWindow] Window ID changed: \(windowId) → \(resizedWindow.windowID)")
            actualWindowId = resizedWindow.windowID
            actualName = "applications/\(pid)/windows/\(actualWindowId)"
            // Re-acquire fresh AXUIElement for the new window ID
            actualWindow = try await findWindowElement(pid: pid, windowId: actualWindowId, expectedBounds: expectedBounds)
        } else {
            // Window ID didn't change (or we couldn't find a unique match)
            actualWindowId = windowId
            actualName = req.name
            actualWindow = window
        }

        // Invalidate old cache entry
        await windowRegistry.invalidate(windowID: windowId)

        // Build response using the (possibly re-acquired) window element
        return try await buildWindowResponseFromAX(
            name: actualName,
            pid: pid,
            windowId: actualWindowId,
            window: actualWindow,
            registryInfo: resizedWindowInfo ?? registryInfo,
        )
    }

    func minimizeWindow(
        request: ServerRequest<Macosusesdk_V1_MinimizeWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("minimizeWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Set kAXMinimizedAttribute to true
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) { [system = self.system] in
            let result = system.setAXAttribute(element: window as AnyObject, attribute: kAXMinimizedAttribute as String, value: true)
            guard result == 0 else {
                throw RPCError(
                    code: .internalError, message: "Failed to minimize window: AXErrorCode=\(result)",
                )
            }
        }.value

        // CRITICAL: AX state propagation is async - poll until minimized=true
        // This prevents race condition where we return stale state
        let startTime = Date()
        let timeout = 2.0 // 2 second timeout
        while Date().timeIntervalSince(startTime) < timeout {
            let isMinimized = await MainActor.run { () -> Bool in
                var verifyValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &verifyValue) == .success,
                   let isMinimizedValue = verifyValue as? Bool
                {
                    return isMinimizedValue
                }
                return false
            }
            if isMinimized {
                Self.logger.debug("[minimizeWindow] Verified minimized=true after \(Date().timeIntervalSince(startTime) * 1000, privacy: .public)ms")
                break
            }
            // Small yield to allow AX system to propagate change
            try? await Task.sleep(for: .milliseconds(10))
        }

        // CRITICAL FIX: Refresh and fetch registry metadata BEFORE invalidation
        try await windowRegistry.refreshWindows(forPID: pid)
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Invalidate cache to ensure subsequent reads reflect the new minimized state immediately
        await windowRegistry.invalidate(windowID: windowId)

        // Build response directly from AXUIElement
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: window, registryInfo: registryInfo)
    }

    func restoreWindow(
        request: ServerRequest<Macosusesdk_V1_RestoreWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("restoreWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        // CRITICAL FIX: Minimized windows vanish from kAXWindowsAttribute but remain in kAXChildrenAttribute
        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Set kAXMinimizedAttribute to false
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached { [system = self.system] in
            let result = system.setAXAttribute(element: window as AnyObject, attribute: kAXMinimizedAttribute as String, value: false)
            guard result == 0 else {
                throw RPCError(code: .internalError, message: "Failed to restore window: AXErrorCode=\(result)")
            }
        }.value

        // CRITICAL: AX state propagation is async - poll until minimized=false
        // This prevents race condition where we return stale state
        let startTime = Date()
        let timeout = 2.0 // 2 second timeout
        while Date().timeIntervalSince(startTime) < timeout {
            let isMinimized = await MainActor.run { () -> Bool in
                var verifyValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &verifyValue) == .success,
                   let isMinimizedValue = verifyValue as? Bool
                {
                    return isMinimizedValue
                }
                return false
            }
            if !isMinimized {
                Self.logger.debug("[restoreWindow] Verified minimized=false after \(Date().timeIntervalSince(startTime) * 1000, privacy: .public)ms")
                break
            }
            // Small yield to allow AX system to propagate change
            try? await Task.sleep(for: .milliseconds(10))
        }

        // CRITICAL FIX: Refresh registry AFTER restore to get updated isOnScreen value
        // (CGWindowList updates when window becomes visible again)
        try await windowRegistry.refreshWindows(forPID: pid)
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Invalidate cache to ensure subsequent reads reflect the restored state immediately
        await windowRegistry.invalidate(windowID: windowId)

        // Build response directly from AXUIElement (AFTER restore operation)
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: window, registryInfo: registryInfo)
    }

    func closeWindow(
        request: ServerRequest<Macosusesdk_V1_CloseWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CloseWindowResponse> {
        let req = request.message
        Self.logger.info("closeWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Get close button and press it (MUST run on MainActor)
        try await MainActor.run {
            let closeButtonValue = self.system.copyAXAttribute(element: window as AnyObject, attribute: kAXCloseButtonAttribute as String)
            guard let unwrappedCloseButtonValue = closeButtonValue,
                  CFGetTypeID(unwrappedCloseButtonValue as CFTypeRef) == AXUIElementGetTypeID()
            else {
                throw RPCError(code: .internalError, message: "Failed to get close button")
            }

            let closeButton = unsafeDowncast(unwrappedCloseButtonValue as CFTypeRef, to: AXUIElement.self)

            let result = self.system.performAXAction(element: closeButton as AnyObject, action: kAXPressAction as String)
            guard result == 0 else {
                throw RPCError(
                    code: .internalError, message: "Failed to close window: AXErrorCode=\(result)",
                )
            }
        }

        return ServerResponse(message: Macosusesdk_V1_CloseWindowResponse())
    }

    func captureWindowScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureWindowScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureWindowScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureWindowScreenshot] Capturing window screenshot")

        // Parse window resource name: applications/{pid}/windows/{windowId}
        let components = req.window.split(separator: "/")
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowIdInt = Int(components[3])
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid window resource name: \(req.window)",
            )
        }

        // Find window in registry
        try await windowRegistry.refreshWindows(forPID: pid)
        let windowInfo = try await windowRegistry.listWindows(forPID: pid).first {
            $0.windowID == CGWindowID(windowIdInt)
        }

        guard let windowInfo else {
            throw RPCError(
                code: .notFound,
                message: "Window not found: \(req.window)",
            )
        }

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture window
        let result = try await ScreenshotCapture.captureWindow(
            windowID: windowInfo.windowID,
            includeShadow: req.includeShadow,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureWindowScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        response.window = req.window
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureWindowScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) window screenshot")
        return ServerResponse(message: response)
    }
}
