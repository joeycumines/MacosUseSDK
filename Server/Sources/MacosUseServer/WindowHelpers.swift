import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseSDK
import MacosUseSDKProtos
import OSLog
import SwiftProtobuf

// Use the shared logger from MacosUseServiceProvider (module-level)

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
        // Try standard kAXWindowsAttribute first (now using SDK primitive)
        if let window = try? await findWindowElement(pid: pid, windowId: windowId) {
            return window
        }

        // Fallback: The SDK's fetchAXWindowInfo only checks kAXWindowsAttribute.
        // For minimized windows, we need to check kAXChildrenAttribute with the same heuristic logic.
        // CRITICAL FIX: AX APIs are thread-safe and should NOT block MainActor
        return try await Task.detached(priority: .userInitiated) {
            // Get CGWindowList snapshot for expected bounds hint
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

            let expectedBounds = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
            let expectedTitle = cgWindow[kCGWindowName as String] as? String

            // Now search kAXChildrenAttribute with heuristic matching
            let appElement = AXUIElementCreateApplication(pid)

            var childrenValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement, kAXChildrenAttribute as CFString, &childrenValue,
            )
            guard result == .success, let children = childrenValue as? [AXUIElement] else {
                throw RPCError(code: .notFound, message: "Window not found in kAXChildren")
            }

            Self.logger.debug("[findWindowElementWithMinimizedFallback] Searching \(children.count, privacy: OSLogPrivacy.public) children for ID \(windowId, privacy: OSLogPrivacy.public)")

            // Use batched IPC approach similar to SDK
            let attributes: [CFString] = [
                kAXPositionAttribute as CFString,
                kAXSizeAttribute as CFString,
                kAXTitleAttribute as CFString,
            ]

            var bestMatch: AXUIElement?
            var bestScore = CGFloat.greatestFiniteMagnitude
            // Accept any match found (no threshold) to handle extreme CGWindowList staleness
            let matchThreshold = CGFloat.greatestFiniteMagnitude

            for child in children {
                var valuesArray: CFArray?
                let valuesResult = AXUIElementCopyMultipleAttributeValues(child, attributes as CFArray, AXCopyMultipleAttributeOptions(), &valuesArray)

                guard valuesResult == .success,
                      let values = valuesArray as? [AnyObject],
                      values.count == attributes.count
                else {
                    continue
                }

                // Extract Position
                var axPosition = CGPoint.zero
                let posVal = values[0]
                if CFGetTypeID(posVal) == AXValueGetTypeID() {
                    // swiftlint:disable:next force_cast
                    let axVal = posVal as! AXValue
                    if AXValueGetType(axVal) == .cgPoint {
                        AXValueGetValue(axVal, .cgPoint, &axPosition)
                    } else {
                        continue
                    }
                } else {
                    continue
                }

                // Extract Size
                var axSize = CGSize.zero
                let sizeVal = values[1]
                if CFGetTypeID(sizeVal) == AXValueGetTypeID() {
                    // swiftlint:disable:next force_cast
                    let axVal = sizeVal as! AXValue
                    if AXValueGetType(axVal) == .cgSize {
                        AXValueGetValue(axVal, .cgSize, &axSize)
                    } else {
                        continue
                    }
                } else {
                    continue
                }

                let axBounds = CGRect(origin: axPosition, size: axSize)

                // Calculate heuristic score
                let originDiff = hypot(axBounds.origin.x - expectedBounds.origin.x, axBounds.origin.y - expectedBounds.origin.y)
                let sizeDiff = hypot(axBounds.width - expectedBounds.width, axBounds.height - expectedBounds.height)
                var score = originDiff + sizeDiff

                // Title bonus
                let axTitle = values[2] as? String ?? ""
                if let expectedTitle, !expectedTitle.isEmpty, axTitle == expectedTitle {
                    score *= 0.5
                }

                if score < bestScore {
                    bestScore = score
                    bestMatch = child
                }
            }

            if bestScore <= matchThreshold, let match = bestMatch {
                return match
            }

            throw RPCError(code: .notFound, message: "Window not found in kAXChildren")
        }.value
    }

    func findWindowElement(pid: pid_t, windowId: CGWindowID, expectedBounds: CGRect? = nil, expectedTitle: String? = nil) async throws -> AXUIElement {
        // CRITICAL FIX: Use SDK's fetchAXWindowInfo primitive for consolidated logic
        // This fixes the race condition by using heuristic matching instead of strict 2px tolerance
        // and improves performance via batched IPC (1N vs 2N calls)
        try await Task.detached(priority: .userInitiated) {
            let bounds: CGRect
            let title: String?

            // If caller provides expectedBounds (e.g., from WindowRegistry cache after mutation),
            // use those to avoid fetching stale CGWindowList snapshot
            if let expectedBounds {
                bounds = expectedBounds
                title = expectedTitle
            } else {
                // Get CGWindowList snapshot for expected bounds hint
                // CRITICAL FIX: During rapid mutations or window creation, CGWindowList may be stale/incomplete.
                // Treat CG data as best-effort hint only; fallback to zero rect if window not found.
                let windowList = CGWindowListCopyWindowInfo(
                    [.optionAll, .excludeDesktopElements], kCGNullWindowID,
                ) as? [[String: Any]] ?? []

                // Find window with matching CGWindowID
                if let cgWindow = windowList.first(where: {
                    ($0[kCGWindowNumber as String] as? Int32) == Int32(windowId)
                }),
                    let cgBounds = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                    let cgX = cgBounds["X"], let cgY = cgBounds["Y"],
                    let cgWidth = cgBounds["Width"], let cgHeight = cgBounds["Height"]
                {
                    // Use CG bounds as hint
                    bounds = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
                    title = cgWindow[kCGWindowName as String] as? String
                } else {
                    // CRITICAL FALLBACK: Window not in CGWindowList (stale snapshot during mutation).
                    // Use zero rect as hint; fetchAXWindowInfo will still match based on PID filtering.
                    // This ensures GetWindow succeeds immediately after mutations without waiting for CG refresh.
                    bounds = .zero
                    title = nil
                }
            }

            // Use SDK primitive with heuristic matching (race-resistant)
            guard let windowInfo = MacosUseSDK.fetchAXWindowInfo(
                pid: pid,
                windowId: windowId,
                expectedBounds: bounds,
                expectedTitle: title,
            ) else {
                throw RPCError(code: .notFound, message: "AXUIElement not found for window ID \(windowId)")
            }

            return windowInfo.element
        }.value
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
