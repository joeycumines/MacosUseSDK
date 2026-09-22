import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ExactMac
import Foundation

public final class ProductionSystemOperations: SystemOperations {
    public static let shared = ProductionSystemOperations()

    private init() {}

    public func cgWindowListCopyWindowInfo(
        options: CGWindowListOption,
        relativeToWindow: CGWindowID,
    ) throws -> [[String: Any]] {
        guard let snapshot = CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]] else {
            throw CGWindowListSnapshotError.unavailable
        }
        return snapshot
    }

    public func getRunningApplicationBundleID(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func applicationProcessIdentity(pid: pid_t) -> ApplicationProcessIdentity? {
        guard let startTime = processStartTime(pid: pid) else {
            return nil
        }
        let application = NSRunningApplication(processIdentifier: pid)
        return ApplicationProcessIdentity(
            pid: pid,
            startTimeSeconds: startTime.seconds,
            startTimeMicroseconds: startTime.microseconds,
            bundleIdentifier: application?.bundleIdentifier,
            executablePath: application?.executableURL?.standardizedFileURL.path,
        )
    }

    public func isProcessRunning(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public func isApplicationProcessRunning(_ identity: ApplicationProcessIdentity) -> Bool {
        hasSameProcessIdentity(identity)
    }

    public func requestApplicationActivation(_ identity: ApplicationProcessIdentity) -> Bool {
        guard let application = matchingApplication(identity), !application.isTerminated else {
            return false
        }
        return application.activate()
    }

    public func requestApplicationTermination(_ identity: ApplicationProcessIdentity, force: Bool) -> Bool {
        guard let application = matchingApplication(identity), !application.isTerminated else {
            return false
        }
        return force ? application.forceTerminate() : application.terminate()
    }

    private func matchingApplication(_ identity: ApplicationProcessIdentity) -> NSRunningApplication? {
        guard hasSameProcessIdentity(identity),
              let application = NSRunningApplication(processIdentifier: identity.pid)
        else {
            return nil
        }
        return application
    }

    private func hasSameProcessIdentity(_ identity: ApplicationProcessIdentity) -> Bool {
        guard let current = processStartTime(pid: identity.pid) else {
            return false
        }
        return current.seconds == identity.startTimeSeconds &&
            current.microseconds == identity.startTimeMicroseconds
    }

    private func processStartTime(pid: pid_t) -> (seconds: UInt64, microseconds: UInt64)? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize),
            )
        }
        guard actualSize == expectedSize else {
            return nil
        }
        return (
            seconds: UInt64(info.pbi_start_tvsec),
            microseconds: UInt64(info.pbi_start_tvusec),
        )
    }

    public func createAXApplication(pid: pid_t) -> AnyObject? {
        AXUIElementCreateApplication(pid) as AnyObject
    }

    public func copyAXAttribute(element: AnyObject, attribute: String) -> Any? {
        let read = copyAXAttributeResult(element: element, attribute: attribute)
        guard read.errorCode == AXError.success.rawValue else { return nil }
        return read.value
    }

    public func copyAXAttributeResult(element: AnyObject, attribute: String) -> AXAttributeRead {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, attribute as CFString, &value)
        return AXAttributeRead(errorCode: err.rawValue, value: value)
    }

    public func isAXAttributeSettable(element: AnyObject, attribute: String) -> AXAttributeSettableRead {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(ax, attribute as CFString, &settable)
        return AXAttributeSettableRead(errorCode: err.rawValue, settable: settable.boolValue)
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
        let read = readAXWindowID(element: element)
        return read.errorCode == AXError.success.rawValue ? read.windowID : nil
    }

    public func readAXWindowID(element: AnyObject) -> AXWindowIDRead {
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        let (result, id) = ExactMac.resolveAXWindowID(for: ax)
        return AXWindowIDRead(
            errorCode: result.rawValue,
            windowID: result == .success ? id : nil,
        )
    }

    public func copyAXElementAtPosition(_ point: CGPoint) -> AXElementRead {
        let x = Float(point.x)
        let y = Float(point.y)
        guard point.x.isFinite, point.y.isFinite, x.isFinite, y.isFinite else {
            return AXElementRead(
                errorCode: AXError.illegalArgument.rawValue,
                element: nil,
            )
        }
        let systemWideElement = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWideElement,
            x,
            y,
            &element,
        )
        return AXElementRead(
            errorCode: error.rawValue,
            element: element.map { $0 as AnyObject },
        )
    }

    public func getAXElementPID(element: AnyObject) -> AXElementPIDRead {
        guard CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID() else {
            return AXElementPIDRead(
                errorCode: AXError.illegalArgument.rawValue,
                pid: nil,
            )
        }
        var pid: pid_t = 0
        let error = AXUIElementGetPid(
            unsafeDowncast(element, to: AXUIElement.self),
            &pid,
        )
        return AXElementPIDRead(
            errorCode: error.rawValue,
            pid: error == .success && pid > 1 ? pid : nil,
        )
    }
}

/// The class is effectively stateless and safe for cross-task usage.
extension ProductionSystemOperations: @unchecked Sendable {}
