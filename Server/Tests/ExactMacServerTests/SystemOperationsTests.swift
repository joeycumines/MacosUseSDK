import CoreGraphics
@testable import ExactMacServer

// The mock below keeps AX elements opaque (AnyObject) so the test only depends
// on Foundation + CoreGraphics; this verifies the interface compiles cleanly.
import Foundation
import Testing

struct SystemOperationsTests {
    struct MockSystemOperations: SystemOperations {
        func cgWindowListCopyWindowInfo(options _: CGWindowListOption, relativeToWindow _: CGWindowID) -> [[String: Any]] {
            []
        }

        func getRunningApplicationBundleID(pid _: Int32) -> String? {
            nil
        }

        func createAXApplication(pid _: Int32) -> AnyObject? {
            nil
        }

        func copyAXAttribute(element _: AnyObject, attribute _: String) -> Any? {
            nil
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
    }

    @Test
    func `Mock conforms to SystemOperations and methods compile`() throws {
        let sys: SystemOperations = MockSystemOperations()

        _ = try sys.cgWindowListCopyWindowInfo(options: .optionOnScreenOnly, relativeToWindow: kCGNullWindowID)
        _ = sys.getRunningApplicationBundleID(pid: 0)
        _ = sys.createAXApplication(pid: 0)
        _ = sys.copyAXAttribute(element: NSObject(), attribute: "attr")
        _ = sys.setAXAttribute(element: NSObject(), attribute: "attr", value: "value")
        _ = sys.performAXAction(element: NSObject(), action: "do")
        _ = sys.getAXWindowID(element: NSObject())

        #expect(true, "Calls succeed and compile against the interface")
    }
}
