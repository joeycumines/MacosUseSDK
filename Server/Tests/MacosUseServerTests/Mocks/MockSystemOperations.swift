import ApplicationServices
import CoreGraphics
import Foundation
@testable import MacosUseServer

final class MockSystemOperations: SystemOperations {
    var cgWindowList: [[String: Any]]
    var axWindowInfos: [String: WindowInfoResult]
    var bundleIDs: [pid_t: String]

    init(cgWindowList: [[String: Any]] = [], axWindowInfos: [String: WindowInfoResult] = [:], bundleIDs: [pid_t: String] = [:]) {
        self.cgWindowList = cgWindowList
        self.axWindowInfos = axWindowInfos
        self.bundleIDs = bundleIDs
    }

    func cgWindowListCopyWindowInfo(options _: CGWindowListOption, relativeToWindow _: CGWindowID) -> [[String: Any]] {
        cgWindowList
    }

    func getRunningApplicationBundleID(pid: pid_t) -> String? {
        if let v = bundleIDs[pid] { return v }
        return "com.example.mock"
    }

    func createAXApplication(pid: Int32) -> AnyObject? {
        // Create a real AXUIElement for the PID so code can unsafeDowncast
        AXUIElementCreateApplication(pid) as AnyObject
    }

    func copyAXAttribute(element _: AnyObject, attribute: String) -> Any? {
        // To support buildWindowResponseFromAX testing, we need to return mock AX attributes
        // based on the stored axWindowInfos. We can use a convention where the element
        // description or a known mapping provides the window ID, but for simplicity in tests,
        // we'll search through all infos and return the first match.
        // This is a test double - it doesn't need to be perfect, just functional.

        for info in axWindowInfos.values {
            // Return attributes from the stored WindowInfoResult
            switch attribute {
            case kAXTitleAttribute as String:
                return info.title as Any
            case kAXMinimizedAttribute as String:
                return info.minimized as Any
            case kAXHiddenAttribute as String:
                return info.hidden as Any
            case kAXFocusedAttribute as String:
                return info.focused as Any
            case kAXPositionAttribute as String:
                var point = CGPoint(x: info.bounds.origin.x, y: info.bounds.origin.y)
                return AXValueCreate(.cgPoint, &point)
            case kAXSizeAttribute as String:
                var size = CGSize(width: info.bounds.size.width, height: info.bounds.size.height)
                return AXValueCreate(.cgSize, &size)
            default:
                return nil
            }
        }
        return nil
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func setAXAttribute(element _: AnyObject, attribute _: String, value _: Any) -> Int32 {
        1
    }

    func performAXAction(element _: AnyObject, action _: String) -> Int32 {
        1
    }

    func getAXWindowID(element _: AnyObject) -> CGWindowID? {
        nil
    }

    func fetchAXWindowInfo(pid: Int32, windowId: CGWindowID, expectedBounds _: CGRect) -> WindowInfoResult? {
        let key = "\(pid):\(windowId)"
        return axWindowInfos[key]
    }
}

extension MockSystemOperations: @unchecked Sendable {}
