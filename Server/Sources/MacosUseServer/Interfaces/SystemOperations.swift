import CoreGraphics

// Interface keeps AX elements opaque (AnyObject) to avoid importing heavy
// ApplicationServices in the interface layer — implementations may use AXUIElement.
import Foundation

public protocol SystemOperations: Sendable {
    // Quartz / Registry
    func cgWindowListCopyWindowInfo(options: CGWindowListOption, relativeToWindow: CGWindowID) -> [[String: Any]]
    func getRunningApplicationBundleID(pid: pid_t) -> String?

    // Accessibility (AX) — kept intentionally opaque to avoid importing
    // ApplicationServices in interfaces. Implementations may accept concrete
    // AX types such as AXUIElement; the interface uses AnyObject instead.
    func createAXApplication(pid: Int32) -> AnyObject?
    func copyAXAttribute(element: AnyObject, attribute: String) -> Any?
    func copyAXMultipleAttributes(element: AnyObject, attributes: [String]) -> [String: Any]?
    // Mutating methods return Int32 (AXError raw value) instead of Bool to preserve error codes.
    // 0 == success (kAXErrorSuccess)
    func setAXAttribute(element: AnyObject, attribute: String, value: Any) -> Int32
    func performAXAction(element: AnyObject, action: String) -> Int32
    func getAXWindowID(element: AnyObject) -> CGWindowID?

    // SDK boundary
    func fetchAXWindowInfo(pid: Int32, windowId: CGWindowID, expectedBounds: CGRect) -> WindowInfoResult?
}

public struct WindowInfoResult {
    /// Opaque element reference. Production implementations will store AXUIElement.
    public let element: AnyObject
    public let bounds: CGRect
    public let title: String
    public let minimized: Bool
    public let hidden: Bool
    public let focused: Bool

    public init(element: AnyObject, bounds: CGRect, title: String, minimized: Bool, hidden: Bool, focused: Bool) {
        self.element = element
        self.bounds = bounds
        self.title = title
        self.minimized = minimized
        self.hidden = hidden
        self.focused = focused
    }
}
