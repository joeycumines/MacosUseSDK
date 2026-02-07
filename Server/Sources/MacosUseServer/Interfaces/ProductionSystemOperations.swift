import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacosUseSDK

/// Function pointer type for the private _AXUIElementGetWindow API.
/// Resolved dynamically via dlsym to avoid hard-linking a private symbol
/// that could be removed in future macOS releases.
///
/// NOTE: This pattern is duplicated in Sources/MacosUseSDK/WindowQuery.swift
/// because the SDK and Server are separate modules. Changes here must be mirrored there.
private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Lazily resolved function pointer for _AXUIElementGetWindow.
/// Returns nil if the symbol is not available (removed in a future macOS).
private let _axUIElementGetWindowFn: AXUIElementGetWindowFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else {
        return nil
    }
    return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
}()

public final class ProductionSystemOperations: SystemOperations {
    public static let shared = ProductionSystemOperations()

    private init() {}

    public func cgWindowListCopyWindowInfo(options: CGWindowListOption, relativeToWindow: CGWindowID) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]]) ?? []
    }

    public func getRunningApplicationBundleID(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func createAXApplication(pid: pid_t) -> AnyObject? {
        AXUIElementCreateApplication(pid) as AnyObject
    }

    public func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, attribute as CFString, &value)
        guard err == .success, let v = value else { return nil }
        return v
    }

    public func copyAXMultipleAttributes(element: AnyObject, attributes: [String]) -> [String: Any]? {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        var values: CFArray?
        let cfAttributes = attributes as CFArray
        let err = AXUIElementCopyMultipleAttributeValues(ax, cfAttributes, AXCopyMultipleAttributeOptions(), &values)
        guard err == .success, let vals = values as? [Any] else { return nil }
        var result = [String: Any]()
        for (attr, val) in zip(attributes, vals) {
            result[attr] = val
        }
        return result
    }

    public func setAXAttribute(element: AnyObject, attribute: String, value: Any) -> Int32 {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        let cfVal = value as CFTypeRef
        let err = AXUIElementSetAttributeValue(ax, attribute as CFString, cfVal)
        return err.rawValue
    }

    public func performAXAction(element: AnyObject, action: String) -> Int32 {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        let err = AXUIElementPerformAction(ax, action as CFString)
        return err.rawValue
    }

    public func getAXWindowID(element: AnyObject) -> CGWindowID? {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        var id: CGWindowID = 0
        // Try to call the private symbol via dlsym-resolved function pointer
        guard let getWindowFn = _axUIElementGetWindowFn else {
            return nil
        }
        let result = getWindowFn(ax, &id)
        if result == .success {
            return id
        }

        return nil
    }

    public func fetchAXWindowInfo(pid: pid_t, windowId: CGWindowID, expectedBounds: CGRect) -> WindowInfoResult? {
        guard let win = MacosUseSDK.fetchAXWindowInfo(pid: pid, windowId: windowId, expectedBounds: expectedBounds) else { return nil }
        return WindowInfoResult(element: win.element as AnyObject, bounds: win.bounds, title: win.title, minimized: win.isMinimized, hidden: win.isHidden, focused: win.isFocused)
    }
}

/// The class is effectively stateless and safe for cross-task usage.
extension ProductionSystemOperations: @unchecked Sendable {}
