import CoreGraphics

// Interface keeps AX elements opaque (AnyObject) to avoid importing heavy
// ApplicationServices in the interface layer — implementations may use AXUIElement.
import Foundation

public struct AXAttributeRead: @unchecked Sendable {
    public let errorCode: Int32
    public let value: Any?

    public init(errorCode: Int32, value: Any?) {
        self.errorCode = errorCode
        self.value = value
    }
}

public struct AXAttributeSettableRead: Sendable {
    public let errorCode: Int32
    public let settable: Bool

    public init(errorCode: Int32, settable: Bool) {
        self.errorCode = errorCode
        self.settable = settable
    }
}

public struct AXElementRead: @unchecked Sendable {
    public let errorCode: Int32
    public let element: AnyObject?

    public init(errorCode: Int32, element: AnyObject?) {
        self.errorCode = errorCode
        self.element = element
    }
}

public struct AXElementPIDRead: Sendable {
    public let errorCode: Int32
    public let pid: pid_t?

    public init(errorCode: Int32, pid: pid_t?) {
        self.errorCode = errorCode
        self.pid = pid
    }
}

public struct AXWindowIDRead: Sendable {
    public let errorCode: Int32
    public let windowID: CGWindowID?

    public init(errorCode: Int32, windowID: CGWindowID?) {
        self.errorCode = errorCode
        self.windowID = windowID
    }
}

public enum CGWindowListSnapshotError: Error, Sendable {
    case unavailable
}

public protocol SystemOperations: Sendable {
    /// Quartz / Registry
    func cgWindowListCopyWindowInfo(
        options: CGWindowListOption,
        relativeToWindow: CGWindowID,
    ) throws -> [[String: Any]]
    func getRunningApplicationBundleID(pid: pid_t) -> String?

    // Process lifecycle. The identity is captured when an application becomes
    // owned so a later delete cannot signal an unrelated process after PID reuse.
    func applicationProcessIdentity(pid: pid_t) -> ApplicationProcessIdentity?
    func isProcessRunning(pid: pid_t) -> Bool
    func isApplicationProcessRunning(_ identity: ApplicationProcessIdentity) -> Bool
    func requestApplicationActivation(_ identity: ApplicationProcessIdentity) -> Bool
    func requestApplicationTermination(_ identity: ApplicationProcessIdentity, force: Bool) -> Bool

    // Accessibility (AX) — kept intentionally opaque to avoid importing
    // ApplicationServices in interfaces. Implementations may accept concrete
    // AX types such as AXUIElement; the interface uses AnyObject instead.
    func createAXApplication(pid: Int32) -> AnyObject?
    func copyAXAttribute(element: AnyObject, attribute: String) -> Any?
    func copyAXAttributeResult(element: AnyObject, attribute: String) -> AXAttributeRead
    func isAXAttributeSettable(element: AnyObject, attribute: String) -> AXAttributeSettableRead
    func copyAXMultipleAttributes(element: AnyObject, attributes: [String]) -> [String: Any]?
    // Mutating methods return Int32 (AXError raw value) instead of Bool to preserve error codes.
    // 0 == success (kAXErrorSuccess)
    func setAXAttribute(element: AnyObject, attribute: String, value: Any) -> Int32
    func performAXAction(element: AnyObject, action: String) -> Int32
    func getAXWindowID(element: AnyObject) -> CGWindowID?
    func readAXWindowID(element: AnyObject) -> AXWindowIDRead
    func copyAXElementAtPosition(_ point: CGPoint) -> AXElementRead
    func getAXElementPID(element: AnyObject) -> AXElementPIDRead
}

public struct ApplicationProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64
    public let bundleIdentifier: String?
    public let executablePath: String?

    public init(
        pid: pid_t,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64,
        bundleIdentifier: String?,
        executablePath: String?,
    ) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}

/// Default lifecycle behavior for read-only window/AX test doubles that do not
/// own processes. Lifecycle-aware implementations override these methods.
public extension SystemOperations {
    func copyAXAttributeResult(element: AnyObject, attribute: String) -> AXAttributeRead {
        guard let value = copyAXAttribute(element: element, attribute: attribute) else {
            return AXAttributeRead(
                errorCode: Int32.min,
                value: nil,
            )
        }
        return AXAttributeRead(errorCode: 0, value: value)
    }

    func isAXAttributeSettable(element _: AnyObject, attribute _: String) -> AXAttributeSettableRead {
        AXAttributeSettableRead(errorCode: Int32.min, settable: false)
    }

    func copyAXElementAtPosition(_: CGPoint) -> AXElementRead {
        AXElementRead(errorCode: Int32.min, element: nil)
    }

    func readAXWindowID(element: AnyObject) -> AXWindowIDRead {
        let windowID = getAXWindowID(element: element)
        return AXWindowIDRead(
            errorCode: windowID == nil ? Int32.min : 0,
            windowID: windowID,
        )
    }

    func getAXElementPID(element _: AnyObject) -> AXElementPIDRead {
        AXElementPIDRead(errorCode: Int32.min, pid: nil)
    }

    func applicationProcessIdentity(pid _: pid_t) -> ApplicationProcessIdentity? {
        nil
    }

    func isProcessRunning(pid _: pid_t) -> Bool {
        false
    }

    func isApplicationProcessRunning(_: ApplicationProcessIdentity) -> Bool {
        false
    }

    func requestApplicationActivation(_: ApplicationProcessIdentity) -> Bool {
        false
    }

    func requestApplicationTermination(_: ApplicationProcessIdentity, force _: Bool) -> Bool {
        false
    }
}
