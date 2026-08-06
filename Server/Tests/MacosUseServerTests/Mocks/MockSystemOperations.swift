import ApplicationServices
import CoreGraphics
import Foundation
@testable import MacosUseServer

final class MockSystemOperations: SystemOperations {
    struct SetAXAttributeCall {
        let attribute: String
        let value: Any
    }

    struct CopyAXAttributeCall: Equatable {
        let attribute: String
    }

    struct PerformAXActionCall: Equatable {
        let action: String
    }

    struct ApplicationTerminationCall: Equatable {
        let identity: ApplicationProcessIdentity
        let force: Bool
    }

    struct ApplicationActivationCall: Equatable {
        let identity: ApplicationProcessIdentity
    }

    var cgWindowList: [[String: Any]]
    var bundleIDs: [pid_t: String]
    var axAttributes: [String: Any]
    var setAXAttributeResult: Int32
    var performAXActionResult: Int32
    var applySuccessfulAXWritesToAttributes: Bool
    /// Optional per-attribute override for the AX-settability read, decoupled
    /// from `setAXAttributeResult`. When an attribute is present here, its exact
    /// `AXAttributeSettableRead` is returned; otherwise the legacy heuristic
    /// applies. This lets a test express "this attribute is NOT settable even
    /// though a set would succeed" (the not-settable failure path that the
    /// legacy heuristic masked by short-circuiting to (success, true)).
    var axAttributeSettable: [String: AXAttributeSettableRead]
    var applicationIdentities: [pid_t: ApplicationProcessIdentity]
    var applicationProcessIdentityHandler: (@Sendable (pid_t) -> ApplicationProcessIdentity?)?
    var applicationProcessRunningHandler:
        (@Sendable (ApplicationProcessIdentity) -> Bool)?
    var applicationActivationHandler: (@Sendable (ApplicationProcessIdentity) -> Bool)?
    var axElementAtPositionHandler: (@Sendable (CGPoint) -> AXElementRead)?
    var axElementPIDHandler: (@Sendable (AnyObject) -> AXElementPIDRead)?
    var axWindowIDHandler: (@Sendable (AnyObject) -> CGWindowID?)?
    var runningPIDs: Set<pid_t>
    var runningApplicationIdentities: Set<ApplicationProcessIdentity>
    var gracefulTerminationResult: Bool
    var activationResult: Bool
    var forceTerminationResult: Bool
    var stopOnGracefulTermination: Bool
    var stopOnForceTermination: Bool
    private(set) var setAXAttributeCalls: [SetAXAttributeCall] = []
    private(set) var copyAXAttributeCalls: [CopyAXAttributeCall] = []
    private(set) var performAXActionCalls: [PerformAXActionCall] = []
    private(set) var applicationTerminationCalls: [ApplicationTerminationCall] = []
    private(set) var applicationActivationCalls: [ApplicationActivationCall] = []

    init(
        cgWindowList: [[String: Any]] = [],
        bundleIDs: [pid_t: String] = [:],
        axAttributes: [String: Any] = [:],
        setAXAttributeResult: Int32 = 1,
        performAXActionResult: Int32 = 1,
        applySuccessfulAXWritesToAttributes: Bool = false,
        axAttributeSettable: [String: AXAttributeSettableRead] = [:],
        applicationIdentities: [pid_t: ApplicationProcessIdentity] = [:],
        applicationProcessIdentityHandler: (@Sendable (pid_t) -> ApplicationProcessIdentity?)? = nil,
        applicationProcessRunningHandler:
        (@Sendable (ApplicationProcessIdentity) -> Bool)? = nil,
        applicationActivationHandler: (@Sendable (ApplicationProcessIdentity) -> Bool)? = nil,
        axElementAtPositionHandler: (@Sendable (CGPoint) -> AXElementRead)? = nil,
        axElementPIDHandler: (@Sendable (AnyObject) -> AXElementPIDRead)? = nil,
        axWindowIDHandler: (@Sendable (AnyObject) -> CGWindowID?)? = nil,
        runningPIDs: Set<pid_t> = [],
        runningApplicationIdentities: Set<ApplicationProcessIdentity> = [],
        activationResult: Bool = true,
        gracefulTerminationResult: Bool = true,
        forceTerminationResult: Bool = true,
        stopOnGracefulTermination: Bool = true,
        stopOnForceTermination: Bool = true,
    ) {
        self.cgWindowList = cgWindowList
        self.bundleIDs = bundleIDs
        self.axAttributes = axAttributes
        self.setAXAttributeResult = setAXAttributeResult
        self.performAXActionResult = performAXActionResult
        self.applySuccessfulAXWritesToAttributes = applySuccessfulAXWritesToAttributes
        self.axAttributeSettable = axAttributeSettable
        self.applicationIdentities = applicationIdentities
        self.applicationProcessIdentityHandler = applicationProcessIdentityHandler
        self.applicationProcessRunningHandler = applicationProcessRunningHandler
        self.applicationActivationHandler = applicationActivationHandler
        self.axElementAtPositionHandler = axElementAtPositionHandler
        self.axElementPIDHandler = axElementPIDHandler
        self.axWindowIDHandler = axWindowIDHandler
        self.runningPIDs = runningPIDs
        self.runningApplicationIdentities = runningApplicationIdentities
        self.activationResult = activationResult
        self.gracefulTerminationResult = gracefulTerminationResult
        self.forceTerminationResult = forceTerminationResult
        self.stopOnGracefulTermination = stopOnGracefulTermination
        self.stopOnForceTermination = stopOnForceTermination
    }

    func cgWindowListCopyWindowInfo(options _: CGWindowListOption, relativeToWindow _: CGWindowID) -> [[String: Any]] {
        cgWindowList
    }

    func getRunningApplicationBundleID(pid: pid_t) -> String? {
        if let v = bundleIDs[pid] {
            return v
        }
        return "com.example.mock"
    }

    func applicationProcessIdentity(pid: pid_t) -> ApplicationProcessIdentity? {
        if let applicationProcessIdentityHandler {
            return applicationProcessIdentityHandler(pid)
        }
        return applicationIdentities[pid]
    }

    func isProcessRunning(pid: pid_t) -> Bool {
        runningPIDs.contains(pid) || runningApplicationIdentities.contains { $0.pid == pid }
    }

    func isApplicationProcessRunning(_ identity: ApplicationProcessIdentity) -> Bool {
        if let applicationProcessRunningHandler {
            return applicationProcessRunningHandler(identity)
        }
        return runningApplicationIdentities.contains(identity)
    }

    func requestApplicationActivation(_ identity: ApplicationProcessIdentity) -> Bool {
        applicationActivationCalls.append(.init(identity: identity))
        if let applicationActivationHandler {
            return applicationActivationHandler(identity)
        }
        return activationResult && runningApplicationIdentities.contains(identity)
    }

    func requestApplicationTermination(_ identity: ApplicationProcessIdentity, force: Bool) -> Bool {
        applicationTerminationCalls.append(.init(identity: identity, force: force))
        let result = force ? forceTerminationResult : gracefulTerminationResult
        let shouldStop = force ? stopOnForceTermination : stopOnGracefulTermination
        if result, shouldStop {
            runningApplicationIdentities.remove(identity)
            runningPIDs.remove(identity.pid)
        }
        return result
    }

    func createAXApplication(pid: Int32) -> AnyObject? {
        // Create a real AXUIElement for the PID so code can unsafeDowncast
        AXUIElementCreateApplication(pid) as AnyObject
    }

    func copyAXAttribute(element _: AnyObject, attribute: String) -> Any? {
        copyAXAttributeCalls.append(CopyAXAttributeCall(attribute: attribute))
        if let value = axAttributes[attribute] {
            return value
        }

        return nil
    }

    func copyAXMultipleAttributes(element _: AnyObject, attributes _: [String]) -> [String: Any]? {
        nil
    }

    func isAXAttributeSettable(element _: AnyObject, attribute: String) -> AXAttributeSettableRead {
        // An explicit per-attribute override wins, so a test can express an
        // exact settability (including NOT-settable) independent of the
        // set-result. Without this, the legacy heuristic below short-circuits
        // to (success, true) whenever a set would succeed, masking the
        // not-settable failure path (C11).
        if let override = axAttributeSettable[attribute] {
            return override
        }
        if axAttributes[attribute] != nil || setAXAttributeResult == AXError.success.rawValue {
            return AXAttributeSettableRead(errorCode: AXError.success.rawValue, settable: true)
        }
        return AXAttributeSettableRead(errorCode: Int32.min, settable: false)
    }

    func setAXAttribute(element _: AnyObject, attribute: String, value: Any) -> Int32 {
        setAXAttributeCalls.append(SetAXAttributeCall(attribute: attribute, value: value))
        if applySuccessfulAXWritesToAttributes,
           setAXAttributeResult == AXError.success.rawValue
        {
            axAttributes[attribute] = value
        }
        return setAXAttributeResult
    }

    func performAXAction(element _: AnyObject, action: String) -> Int32 {
        performAXActionCalls.append(PerformAXActionCall(action: action))
        return performAXActionResult
    }

    func copyAXElementAtPosition(_ point: CGPoint) -> AXElementRead {
        axElementAtPositionHandler?(point)
            ?? AXElementRead(errorCode: Int32.min, element: nil)
    }

    func getAXElementPID(element: AnyObject) -> AXElementPIDRead {
        axElementPIDHandler?(element)
            ?? AXElementPIDRead(errorCode: Int32.min, pid: nil)
    }

    func getAXWindowID(element: AnyObject) -> CGWindowID? {
        axWindowIDHandler?(element)
    }
}

extension MockSystemOperations: @unchecked Sendable {}
