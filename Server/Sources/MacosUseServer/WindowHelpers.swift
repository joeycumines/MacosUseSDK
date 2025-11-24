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
    func parsePID(fromName name: String) throws -> pid_t {
        try ParsingHelpers.parsePID(fromName: name)
    }

    /// Build a Window response directly from an AXUIElement using hybrid data authority.
    /// AX data is authoritative for geometry and state; Registry provides metadata (z-index, bundle ID).
    func buildWindowResponseFromAX(
        name: String, pid _: pid_t, windowId: CGWindowID, window: AXUIElement, registryInfo: WindowRegistry.WindowInfo? = nil,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        // 1. Get Fresh AX Data (Background Thread) - The Authority for Geometry + State
        let (axBounds, axTitle, axMinimized, axHidden) = await Task.detached(priority: .userInitiated) { [system = self.system] () -> (Macosusesdk_V1_Bounds, String, Bool, Bool) in
            // Fetch Position
            var bounds = Macosusesdk_V1_Bounds()
            if let posValue = system.copyAXAttribute(element: window as AnyObject, attribute: kAXPositionAttribute as String),
               CFGetTypeID(posValue as CFTypeRef) == AXValueGetTypeID()
            {
                let axVal = unsafeDowncast(posValue as CFTypeRef, to: AXValue.self)
                var point = CGPoint.zero
                if AXValueGetValue(axVal, .cgPoint, &point) {
                    bounds.x = Double(point.x)
                    bounds.y = Double(point.y)
                }
            }

            // Fetch Size
            if let sizeValue = system.copyAXAttribute(element: window as AnyObject, attribute: kAXSizeAttribute as String),
               CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID()
            {
                let axVal = unsafeDowncast(sizeValue as CFTypeRef, to: AXValue.self)
                var size = CGSize.zero
                if AXValueGetValue(axVal, .cgSize, &size) {
                    bounds.width = Double(size.width)
                    bounds.height = Double(size.height)
                }
            }

            // Fetch Title
            var title = ""
            if let titleValue = system.copyAXAttribute(element: window as AnyObject, attribute: kAXTitleAttribute as String),
               let str = titleValue as? String
            {
                title = str
            }

            // Query kAXMinimizedAttribute
            var minimized = false
            if let minimizedValue = system.copyAXAttribute(element: window as AnyObject, attribute: kAXMinimizedAttribute as String),
               let boolVal = minimizedValue as? Bool
            {
                minimized = boolVal
            }

            // Query kAXHiddenAttribute
            var hidden = false
            if let hiddenValue = system.copyAXAttribute(element: window as AnyObject, attribute: kAXHiddenAttribute as String),
               let boolVal = hiddenValue as? Bool
            {
                hidden = boolVal
            }

            return (bounds, title, minimized, hidden)
        }.value

        // 2. Get Metadata from Registry (No Refresh) - The Authority for Z-Index/Bundle
        let metadata: WindowRegistry.WindowInfo? = if let registryInfo {
            registryInfo
        } else {
            await windowRegistry.getLastKnownWindow(windowId)
        }

        // 3. CRITICAL FIX: Compute visible using AX-first optimistic approach:
        // If not minimized and not hidden, assume visible=true (AX-first, ignoring stale registry).
        // Otherwise fall back to registry.isOnScreen (may be stale but better than false negative).
        // NOTE: Algebraically the final `visible` value reduces to `!axMinimized && !axHidden` —
        // the fallback cannot change the final result when `axMinimized || axHidden` is true.
        // We keep the intermediate `isOnScreen` for explanatory clarity but treat AX as authoritative.
        let isOnScreen = (!axMinimized && !axHidden) ? true : (metadata?.isOnScreen ?? false)
        let visible = isOnScreen && !axMinimized && !axHidden

        // 4. Construct Response
        let response = Macosusesdk_V1_Window.with {
            $0.name = name
            $0.title = axTitle // AX Authority
            $0.bounds = axBounds // AX Authority
            $0.zIndex = Int32(metadata?.layer ?? 0) // Registry Authority
            $0.bundleID = metadata?.bundleID ?? "" // Registry Authority
            $0.visible = visible
        }

        return ServerResponse(message: response)
    }

    /// Find AXUIElement for a window, with fallback to kAXChildrenAttribute for minimized windows.
    func findWindowElement(pid: pid_t, windowId: CGWindowID, expectedBounds: CGRect? = nil, _: String? = nil) async throws -> AXUIElement {
        // 1. Try Private API Exact Match
        let match = await Task.detached(priority: .userInitiated) { () -> AXUIElement? in
            guard let appElementAny = self.system.createAXApplication(pid: pid) else { return nil }
            let appElement = unsafeDowncast(appElementAny, to: AXUIElement.self)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else { return nil }

            for window in windows {
                if let axID = self.system.getAXWindowID(element: window as AnyObject), axID == windowId {
                    return window
                }
            }
            return nil
        }.value

        if let match { return match }

        // 2. Fallback to SDK Heuristics
        return try await Task.detached(priority: .userInitiated) {
            let bounds: CGRect
            var usedZeroFallback = false

            if let expectedBounds {
                bounds = expectedBounds
            } else {
                // Try to fetch from CGWindowList if not provided
                let windowList = self.system.cgWindowListCopyWindowInfo(options: [.optionAll, .excludeDesktopElements], relativeToWindow: kCGNullWindowID)
                if let cgWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? Int32) == Int32(windowId) }),
                   let cgBounds = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                   let cgX = cgBounds["X"], let cgY = cgBounds["Y"],
                   let cgWidth = cgBounds["Width"], let cgHeight = cgBounds["Height"]
                {
                    bounds = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
                } else {
                    bounds = .zero
                    usedZeroFallback = true
                }
            }

            // Ambiguity Check
            if usedZeroFallback {
                guard let appElementAny = self.system.createAXApplication(pid: pid) else {
                    throw RPCError(code: .failedPrecondition, message: "Ambiguous window match")
                }
                let appElement = unsafeDowncast(appElementAny, to: AXUIElement.self)
                var windowsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                   let windows = windowsRef as? [AXUIElement], windows.count > 1
                {
                    throw RPCError(code: .failedPrecondition, message: "Ambiguous window match")
                }
            }

            guard let windowInfo = self.system.fetchAXWindowInfo(pid: pid, windowId: windowId, expectedBounds: bounds) else {
                throw RPCError(code: .notFound, message: "AXUIElement not found")
            }
            return unsafeDowncast(windowInfo.element, to: AXUIElement.self)
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
