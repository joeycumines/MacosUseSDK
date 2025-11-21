import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseSDK
import MacosUseSDKProtos
import OSLog
import SwiftProtobuf

private let logger = MacosUseSDK.sdkLogger(category: "MacosUseServiceProvider")

extension MacosUseServiceProvider {
    func parsePID(fromName name: String) throws -> pid_t {
        try ParsingHelpers.parsePID(fromName: name)
    }

    /// Build a Window response directly from an AXUIElement using split-brain authority model.
    /// AX authority (fresh): bounds, title, minimized, hidden. Registry authority (stable): z-index, bundleID.
    /// Visible is computed from split-brain sources: (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden.
    /// This is used after window operations where CGWindowList may be stale.
    func buildWindowResponseFromAX(
        name: String, pid _: pid_t, windowId: CGWindowID, window: AXUIElement, registryInfo: WindowRegistry.WindowInfo? = nil,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        // 1. Get Fresh AX Data (Background Thread) - The Authority for Geometry + State
        // CRITICAL FIX: AX APIs are thread-safe and should NOT block MainActor
        let (axBounds, axTitle, axMinimized, axHidden) = await Task.detached(priority: .userInitiated) { () -> (Macosusesdk_V1_Bounds, String, Bool, Bool) in
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?

            // Fetch Position
            var bounds = Macosusesdk_V1_Bounds()
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
               let val = posValue, CFGetTypeID(val) == AXValueGetTypeID()
            {
                let axVal = unsafeDowncast(val, to: AXValue.self)
                var point = CGPoint.zero
                if AXValueGetValue(axVal, .cgPoint, &point) {
                    bounds.x = Double(point.x)
                    bounds.y = Double(point.y)
                }
            }

            // Fetch Size
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
               let val = sizeValue, CFGetTypeID(val) == AXValueGetTypeID()
            {
                let axVal = unsafeDowncast(val, to: AXValue.self)
                var size = CGSize.zero
                if AXValueGetValue(axVal, .cgSize, &size) {
                    bounds.width = Double(size.width)
                    bounds.height = Double(size.height)
                }
            }

            // Fetch Title
            var title = ""
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let str = titleValue as? String
            {
                title = str
            }

            // CRITICAL FIX: Query kAXMinimizedAttribute per AX Authority constraints
            var minimized = false
            var minimizedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let boolVal = minimizedValue as? Bool
            {
                minimized = boolVal
            }

            // CRITICAL FIX: Query kAXHiddenAttribute per AX Authority constraints
            var hidden = false
            var hiddenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success,
               let boolVal = hiddenValue as? Bool
            {
                hidden = boolVal
            }

            return (bounds, title, minimized, hidden)
        }.value

        // 2. Get Metadata from Registry (No Refresh) - The Authority for Z-Index/Bundle
        // We explicitly avoid refreshWindows() to prevent 100ms lag injection
        // CRITICAL FIX: Use passed registryInfo if available (prevents nil after invalidation)
        let metadata: WindowRegistry.WindowInfo? = if let registryInfo {
            registryInfo
        } else {
            await windowRegistry.getLastKnownWindow(windowId)
        }

        // 3. CRITICAL FIX: Compute visible using fresh AX data per formula:
        // visible = (Registry.isOnScreen OR Assumption) AND NOT AX.Minimized AND NOT AX.Hidden
        // CRITICAL INSIGHT: CGWindowList lags by 10-100ms, so if we successfully queried the window
        // via AX and it's not minimized/hidden, we KNOW it's on screen regardless of what registry says.
        // This ensures mutation responses return visible=true immediately without polling delays.
        let isOnScreen = (!axMinimized && !axHidden) ? true : (metadata?.isOnScreen ?? false)
        let visible = isOnScreen && !axMinimized && !axHidden

        // 4. Construct Response
        let response = Macosusesdk_V1_Window.with {
            $0.name = name
            $0.title = axTitle // AX Authority
            $0.bounds = axBounds // AX Authority
            $0.zIndex = Int32(metadata?.layer ?? 0) // Registry Authority
            $0.bundleID = metadata?.bundleID ?? "" // Registry Authority
            $0.visible = visible // Split-brain: Registry.isOnScreen AND NOT AX.Minimized AND NOT AX.Hidden
        }

        return ServerResponse(message: response)
    }

    /// Find AXUIElement for a window, with fallback to kAXChildrenAttribute for minimized windows.
    /// Minimized windows disappear from kAXWindowsAttribute but remain in kAXChildrenAttribute.
    func findWindowElementWithMinimizedFallback(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
        // Try standard kAXWindowsAttribute first
        if let window = try? await findWindowElement(pid: pid, windowId: windowId) {
            return window
        }

        // Fallback: search kAXChildrenAttribute for minimized windows
        // CRITICAL FIX: AX APIs are thread-safe and should NOT block MainActor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let appElement = AXUIElementCreateApplication(pid)

                    var childrenValue: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        appElement, kAXChildrenAttribute as CFString, &childrenValue,
                    )
                    guard result == .success, let children = childrenValue as? [AXUIElement] else {
                        throw RPCError(code: .notFound, message: "Window not found in kAXChildren")
                    }

                    logger.debug("[findWindowElementWithMinimizedFallback] Searching \(children.count, privacy: OSLogPrivacy.public) children for ID \(windowId, privacy: OSLogPrivacy.public)")

                    // Get CGWindowList bounds for matching
                    guard
                        let windowList = CGWindowListCopyWindowInfo(
                            [.optionAll, .excludeDesktopElements], kCGNullWindowID,
                        ) as? [[String: Any]]
                    else {
                        throw RPCError(code: .notFound, message: "Failed to get window list")
                    }

                    guard
                        let cgWindow = windowList.first(where: {
                            ($0[kCGWindowNumber as String] as? Int32) == Int32(windowId)
                        })
                    else {
                        throw RPCError(code: .notFound, message: "Window ID \(windowId) not in CGWindowList")
                    }

                    guard let cgBounds = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                          let cgX = cgBounds["X"], let cgY = cgBounds["Y"],
                          let cgWidth = cgBounds["Width"], let cgHeight = cgBounds["Height"]
                    else {
                        throw RPCError(code: .notFound, message: "Failed to get bounds from CGWindow")
                    }

                    // Search children for matching bounds
                    for child in children {
                        var posValue: CFTypeRef?
                        var sizeValue: CFTypeRef?
                        let posResult = AXUIElementCopyAttributeValue(
                            child, kAXPositionAttribute as CFString, &posValue,
                        )
                        let sizeResult = AXUIElementCopyAttributeValue(
                            child, kAXSizeAttribute as CFString, &sizeValue,
                        )

                        if posResult == .success, sizeResult == .success,
                           let unwrappedPosValue = posValue,
                           let unwrappedSizeValue = sizeValue,
                           CFGetTypeID(unwrappedPosValue) == AXValueGetTypeID(),
                           CFGetTypeID(unwrappedSizeValue) == AXValueGetTypeID()
                        {
                            let pos = unsafeDowncast(unwrappedPosValue, to: AXValue.self)
                            let size = unsafeDowncast(unwrappedSizeValue, to: AXValue.self)
                            var axPos = CGPoint()
                            var axSize = CGSize()
                            if AXValueGetValue(pos, .cgPoint, &axPos), AXValueGetValue(size, .cgSize, &axSize) {
                                let deltaX = abs(axPos.x - cgX)
                                let deltaY = abs(axPos.y - cgY)
                                let deltaW = abs(axSize.width - cgWidth)
                                let deltaH = abs(axSize.height - cgHeight)

                                if deltaX < 2, deltaY < 2, deltaW < 2, deltaH < 2 {
                                    continuation.resume(returning: child)
                                    return
                                }
                            }
                        }
                    }

                    throw RPCError(code: .notFound, message: "Window not found in kAXChildren")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func findWindowElement(pid: pid_t, windowId: CGWindowID) async throws -> AXUIElement {
        // CRITICAL FIX: AX APIs are thread-safe and should NOT block MainActor
        // Run on background thread to prevent server hangs
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Get AXUIElement for application
                    let appElement = AXUIElementCreateApplication(pid)

                    // Get AXWindows attribute
                    var windowsValue: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(
                        appElement, kAXWindowsAttribute as CFString, &windowsValue,
                    )
                    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
                        throw RPCError(code: .internalError, message: "Failed to get windows for application")
                    }

                    logger.debug("[findWindowElement] Found \(windows.count, privacy: OSLogPrivacy.public) AX windows, searching for ID \(windowId, privacy: OSLogPrivacy.public)")

                    // Get CGWindowList for matching (include all windows, not just on-screen ones)
                    guard
                        let windowList = CGWindowListCopyWindowInfo(
                            [.optionAll, .excludeDesktopElements], kCGNullWindowID,
                        ) as? [[String: Any]]
                    else {
                        throw RPCError(code: .internalError, message: "Failed to get window list")
                    }

                    // Find window with matching CGWindowID
                    guard
                        let cgWindow = windowList.first(where: {
                            ($0[kCGWindowNumber as String] as? Int32) == Int32(windowId)
                        })
                    else {
                        throw RPCError(
                            code: .notFound, message: "Window with ID \(windowId) not found in CGWindowList",
                        )
                    }

                    // Get bounds from CGWindow
                    guard let cgBounds = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                          let cgX = cgBounds["X"], let cgY = cgBounds["Y"],
                          let cgWidth = cgBounds["Width"], let cgHeight = cgBounds["Height"]
                    else {
                        throw RPCError(code: .internalError, message: "Failed to get bounds from CGWindow")
                    }

                    // Find matching AXUIElement by bounds
                    var windowIndex = 0
                    for window in windows {
                        var posValue: CFTypeRef?
                        var sizeValue: CFTypeRef?
                        let positionResult = AXUIElementCopyAttributeValue(
                            window,
                            kAXPositionAttribute as CFString,
                            &posValue,
                        )
                        let sizeResult = AXUIElementCopyAttributeValue(
                            window,
                            kAXSizeAttribute as CFString,
                            &sizeValue,
                        )

                        if positionResult == .success,
                           sizeResult == .success,
                           let unwrappedPosValue = posValue,
                           let unwrappedSizeValue = sizeValue,
                           CFGetTypeID(unwrappedPosValue) == AXValueGetTypeID(),
                           CFGetTypeID(unwrappedSizeValue) == AXValueGetTypeID()
                        {
                            let pos = unsafeDowncast(unwrappedPosValue, to: AXValue.self)
                            let size = unsafeDowncast(unwrappedSizeValue, to: AXValue.self)
                            var axPos = CGPoint()
                            var axSize = CGSize()
                            if AXValueGetValue(pos, .cgPoint, &axPos), AXValueGetValue(size, .cgSize, &axSize) {
                                let deltaX = abs(axPos.x - cgX)
                                let deltaY = abs(axPos.y - cgY)
                                let deltaW = abs(axSize.width - cgWidth)
                                let deltaH = abs(axSize.height - cgHeight)

                                // Check if bounds match within reasonable tolerance (2px for minor window manager adjustments)
                                // If CGWindowList is stale (bounds don't match), we'll fail to find the window,
                                // which is correct behavior - caller should retry or use single-window optimization
                                if deltaX < 2, deltaY < 2, deltaW < 2, deltaH < 2 {
                                    continuation.resume(returning: window)
                                    return
                                }
                            }
                        }
                        windowIndex += 1
                    }

                    throw RPCError(code: .notFound, message: "AXUIElement not found for window ID \(windowId)")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Build WindowState proto from AXUIElement attributes.
    func buildWindowStateFromAX(window: AXUIElement) async throws -> Macosusesdk_V1_WindowState {
        // CRITICAL FIX: AX APIs are thread-safe and should NOT block MainActor
        await Task.detached(priority: .userInitiated) {
            var resizable = false
            var minimizable = false
            var closable = false
            var modal = false
            var floating = false

            // Check resizable (kAXResizeButtonSubroleAttribute or AXSize writability)
            var sizeSettableValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXSizeSettable" as CFString, &sizeSettableValue) == .success,
               let settable = sizeSettableValue as? Bool
            {
                resizable = settable
            }

            // Check minimizable (kAXMinimizeButtonAttribute exists)
            var minimizeButtonValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXMinimizeButton" as CFString, &minimizeButtonValue) == .success,
               minimizeButtonValue != nil
            {
                minimizable = true
            }

            // Check closable (kAXCloseButtonAttribute exists)
            var closeButtonValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXCloseButton" as CFString, &closeButtonValue) == .success,
               closeButtonValue != nil
            {
                closable = true
            }

            // Check modal (kAXModalAttribute)
            var modalValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modalValue) == .success,
               let isModal = modalValue as? Bool
            {
                modal = isModal
            }

            // Check subrole for dialog/sheet detection (common modal indicators)
            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success,
               let subrole = subroleValue as? String
            {
                // Common subroles: "AXDialog", "AXSheet", "AXFloatingWindow", "AXStandardWindow"
                if subrole.contains("Dialog") || subrole.contains("Sheet") {
                    modal = true
                } else if subrole.contains("Floating") {
                    floating = true
                }
            }

            // Query kAXHiddenAttribute directly for axHidden field
            // CRITICAL: Do NOT use composite "visible" variable that might conflate hidden with minimized
            // axHidden must ONLY reflect kAXHiddenAttribute (window explicitly hidden by app),
            // NOT minimized state (window in dock)
            var hiddenValue: CFTypeRef?
            let axHidden = if AXUIElementCopyAttributeValue(window, kAXHiddenAttribute as CFString, &hiddenValue) == .success,
                              let isHidden = hiddenValue as? Bool
            {
                isHidden
            } else {
                false // Assume not hidden if attribute missing or query fails
            }

            // Check minimized
            var minimizedValue: CFTypeRef?
            let minimized = if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                               let isMinimized = minimizedValue as? Bool
            {
                isMinimized
            } else {
                false
            }

            // Check focused (main window)
            var mainValue: CFTypeRef?
            let focused = if AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &mainValue) == .success,
                             let isMain = mainValue as? Bool
            {
                isMain
            } else {
                false
            }

            // Note: kAXFullscreenAttribute is not standard in Accessibility API
            // We leave fullscreen unset (nil) if we cannot determine it definitively
            let fullscreen: Bool? = nil

            return Macosusesdk_V1_WindowState.with {
                $0.resizable = resizable
                $0.minimizable = minimizable
                $0.closable = closable
                $0.modal = modal
                $0.floating = floating
                $0.axHidden = axHidden
                $0.minimized = minimized
                $0.focused = focused
                if let fullscreen {
                    $0.fullscreen = fullscreen
                }
            }
        }.value
    }

    func getWindowState(window: AXUIElement) async -> (
        minimized: Bool, focused: Bool?, fullscreen: Bool?,
    ) {
        // CRITICAL FIX: AX APIs are thread-safe and should NOT block MainActor
        await Task.detached(priority: .userInitiated) {
            var minimized = false
            var focused: Bool?
            let fullscreen: Bool? = nil

            // Check minimized
            var minValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minValue)
                == .success,
                let minBool = minValue as? Bool
            {
                minimized = minBool
            }

            // Check focused (main window)
            // CRITICAL FIX: Return nil if query fails, not false
            var mainValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &mainValue) == .success,
               let mainBool = mainValue as? Bool
            {
                focused = mainBool
            }
            // If query failed, focused remains nil (unknown)

            // Note: kAXFullscreenAttribute is not available in Accessibility API
            // fullscreen remains nil (unknown)

            return (minimized, focused, fullscreen)
        }.value
    }

    func getActionsForRole(_ role: String) -> [String] {
        // Return common actions based on element role
        // This is a simplified implementation
        switch role.lowercased() {
        case "button":
            ["press"]
        case "checkbox", "radiobutton":
            ["press"]
        case "slider", "scrollbar":
            ["increment", "decrement"]
        case "menu", "menuitem":
            ["press", "open", "close"]
        case "tab":
            ["press", "select"]
        case "combobox", "popupbutton":
            ["press", "open", "close"]
        case "text", "textfield", "textarea":
            ["focus", "select"]
        default:
            ["press"] // Default action
        }
    }
}
