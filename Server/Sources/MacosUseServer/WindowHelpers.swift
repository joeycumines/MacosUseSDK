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
    struct ResolvedApplicationResource: Sendable {
        let name: String
        let pid: pid_t
        let processIdentity: ApplicationProcessIdentity?
    }

    struct ResolvedWindowResource: Sendable {
        let applicationName: String
        let pid: pid_t
        let processIdentity: ApplicationProcessIdentity?
        let resourceID: String
        let windowID: CGWindowID
        let registryInfo: WindowRegistry.WindowInfo

        var name: String {
            "\(applicationName)/windows/\(resourceID)"
        }
    }

    struct ResolvedApplicationChildResource: Sendable {
        let applicationName: String
        let pid: pid_t
        let resourceID: String
    }

    /// Resolves an exact opaque application resource through the current
    /// process-instance state. Numeric parents are available only in explicitly
    /// isolated legacy test graphs and are never enabled by production composition.
    func resolveApplicationResource(fromName name: String) async throws -> ResolvedApplicationResource {
        if legacyPIDResourceNamesForTests {
            let pid = try ParsingHelpers.parsePID(fromName: name)
            await elementRegistry.bindApplication(name: name, pid: pid)
            return ResolvedApplicationResource(name: name, pid: pid, processIdentity: nil)
        }

        _ = try ParsingHelpers.parseOpaqueApplicationName(name)
        if await stateStore.applicationProcessGenerationLease(name: name) == nil {
            await refreshRunningApplicationState()
        }
        guard let generation = await stateStore.applicationProcessGenerationLease(name: name),
              system.isApplicationProcessRunning(generation.identity)
        else {
            throw RPCError(code: .notFound, message: "Application not found or process identity is stale")
        }
        await elementRegistry.bindApplication(name: name, pid: generation.pid)
        let resource = ResolvedApplicationResource(
            name: name,
            pid: generation.pid,
            processIdentity: generation.identity,
        )
        try await revalidateApplicationOwner(resource)
        return resource
    }

    func revalidateApplicationOwner(_ resource: ResolvedApplicationResource) async throws {
        guard let identity = resource.processIdentity else {
            return
        }
        guard let generation = await stateStore.applicationProcessGenerationLease(name: resource.name),
              generation.pid == resource.pid,
              generation.identity == identity,
              system.isApplicationProcessRunning(identity)
        else {
            throw RPCError(code: .notFound, message: "Application process identity is stale")
        }
    }

    func resolveApplicationPID(fromName name: String) async throws -> pid_t {
        try await resolveApplicationResource(fromName: name).pid
    }

    func resolveOptionalApplicationPID(fromName name: String) async throws -> pid_t? {
        if name.isEmpty || name == "applications/-" {
            return nil
        }
        return try await resolveApplicationPID(fromName: name)
    }

    func resolveApplicationOrWindowParentPID(fromName name: String) async throws -> pid_t {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 2 {
            return try await resolveApplicationPID(fromName: name)
        }
        return try await resolveWindowResource(name).pid
    }

    func validateApplicationOrWindowParentResourceName(_ name: String) throws {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 2 {
            try validateApplicationResourceName(name)
            return
        }
        _ = try parseWindowResourceName(name)
    }

    func validateApplicationResourceName(_ name: String) throws {
        if legacyPIDResourceNamesForTests {
            _ = try ParsingHelpers.parsePID(fromName: name)
        } else {
            _ = try ParsingHelpers.parseOpaqueApplicationName(name)
        }
    }

    func parseWindowResourceName(
        _ name: String,
        stateSuffix: Bool = false,
    ) throws -> (applicationName: String, resourceID: String) {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        let expectedCount = stateSuffix ? 5 : 4
        guard components.count == expectedCount,
              components[0] == "applications",
              components[2] == "windows",
              !stateSuffix || components[4] == "state"
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window resource name")
        }
        let applicationName = components[0 ... 1].joined(separator: "/")
        try validateApplicationResourceName(applicationName)
        let resourceID = try ParsingHelpers.validateResourceID(
            String(components[3]),
            field: "name",
        )
        return (applicationName, resourceID)
    }

    func resolveWindowResource(
        _ name: String,
        stateSuffix: Bool = false,
    ) async throws -> ResolvedWindowResource {
        let parsed = try parseWindowResourceName(name, stateSuffix: stateSuffix)
        let applicationName = parsed.applicationName
        let resourceID = parsed.resourceID
        let application = try await resolveApplicationResource(fromName: applicationName)
        guard let binding = await windowRegistry.resolveWindowBinding(
            resourceID: resourceID,
            applicationName: applicationName,
            pid: application.pid,
            processIdentity: application.processIdentity,
        ) else {
            throw RPCError(code: .notFound, message: "Window not found or binding is stale")
        }
        return ResolvedWindowResource(
            applicationName: applicationName,
            pid: application.pid,
            processIdentity: application.processIdentity,
            resourceID: resourceID,
            windowID: binding.windowID,
            registryInfo: binding.info,
        )
    }

    func revalidateWindowOwner(_ resource: ResolvedWindowResource) async throws {
        guard await windowRegistry.resolveWindowBinding(
            resourceID: resource.resourceID,
            applicationName: resource.applicationName,
            pid: resource.pid,
            processIdentity: resource.processIdentity,
        ) != nil else {
            throw RPCError(code: .notFound, message: "Window binding is stale")
        }
        try await revalidateApplicationOwner(
            ResolvedApplicationResource(
                name: resource.applicationName,
                pid: resource.pid,
                processIdentity: resource.processIdentity,
            ),
        )
    }

    func resolveApplicationChildResource(
        _ name: String,
        collection: String,
    ) async throws -> ResolvedApplicationChildResource {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == Substring(collection),
              !components[3].isEmpty
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid \(collection) resource name")
        }
        let resourceID = try ParsingHelpers.validateResourceID(
            String(components[3]),
            field: "name",
        )
        let applicationName = components[0 ... 1].joined(separator: "/")
        let pid = try await resolveApplicationPID(fromName: applicationName)
        return ResolvedApplicationChildResource(
            applicationName: applicationName,
            pid: pid,
            resourceID: resourceID,
        )
    }

    /// Builds a response for one already-resolved public window binding. If the
    /// same admitted AX element reports a changed CG ID, the binding is updated
    /// while its public name remains stable.
    func buildWindowResponseFromAX(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        try checkWindowReadCancellation(cancellation)
        try await revalidateWindowOwner(resource)
        let windowIDRead = system.readAXWindowID(element: window as AnyObject)
        guard windowIDRead.errorCode == AXError.success.rawValue,
              let currentWindowID = windowIDRead.windowID
        else {
            throw rpcErrorForAXRead(
                errorCode: windowIDRead.errorCode,
                attribute: "AXWindowID",
            )
        }
        let position = try readRequiredAXPoint(
            element: window as AnyObject,
            attribute: kAXPositionAttribute as String,
        )
        let size = try readRequiredAXSize(
            element: window as AnyObject,
            attribute: kAXSizeAttribute as String,
        )
        let observedBounds = CGRect(origin: position, size: size)
        guard EndpointSafeGeometry.containsValidEndpoints(
            observedBounds,
            requiresPositiveSize: false,
        ) else {
            throw RPCError(code: .unavailable, message: "Accessibility returned invalid window geometry")
        }
        let axTitle = try readOptionalAXString(
            element: window as AnyObject,
            attribute: kAXTitleAttribute as String,
            defaultValue: "",
        )
        let axMinimized = try readOptionalAXBool(
            element: window as AnyObject,
            attribute: kAXMinimizedAttribute as String,
            defaultValue: false,
        )
        guard let application = system.createAXApplication(pid: resource.pid) else {
            throw RPCError(code: .notFound, message: "Window owner is unavailable")
        }
        let ownerHidden = try readOptionalAXBool(
            element: application,
            attribute: kAXHiddenAttribute as String,
            defaultValue: false,
        )
        try checkWindowReadCancellation(cancellation)
        try await revalidateWindowOwner(resource)

        guard await windowRegistry.admitExactWindowElement(
            resourceID: resource.resourceID,
            applicationName: resource.applicationName,
            pid: resource.pid,
            processIdentity: resource.processIdentity,
            expectedWindowID: resource.windowID,
            element: window,
            observedWindowID: currentWindowID,
            observedBounds: observedBounds,
        ) != nil else {
            throw RPCError(code: .failedPrecondition, message: "Window identity changed ambiguously")
        }
        let updatedBinding = try await windowRegistry.refreshExactWindowMetadata(
            resourceID: resource.resourceID,
            applicationName: resource.applicationName,
            pid: resource.pid,
            processIdentity: resource.processIdentity,
            observedWindowID: currentWindowID,
        )
        if currentWindowID != resource.windowID {
            Self.logger.info(
                "Preserved window binding \(resource.resourceID, privacy: .private) across CG ID \(resource.windowID, privacy: .public) -> \(currentWindowID, privacy: .public)",
            )
        }

        let metadata = updatedBinding.info
        let bundleID: String = if let metaBundleID = metadata.bundleID, !metaBundleID.isEmpty {
            metaBundleID
        } else {
            system.getRunningApplicationBundleID(pid: resource.pid) ?? ""
        }
        let visible = metadata.isOnScreen && !axMinimized && !ownerHidden
        let response = Macosusesdk_V1_Window.with {
            $0.name = resource.name
            $0.title = axTitle
            $0.bounds = Macosusesdk_V1_Bounds.with {
                $0.x = position.x
                $0.y = position.y
                $0.width = size.width
                $0.height = size.height
            }
            $0.layer = metadata.layer
            $0.bundleID = bundleID
            $0.visible = visible
        }
        return ServerResponse(message: response)
    }

    /// Resolves one exact AX window under its admitted application generation.
    ///
    /// The first resolution admits exactly one `kAXWindows` member whose private
    /// window ID matches the CG snapshot. Later resolutions require the same
    /// retained AX object. A changed private ID is accepted only for that same
    /// retained object and is committed atomically to the public binding.
    func findWindowElement(
        resource: ResolvedWindowResource,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws -> AXUIElement {
        let maxRetries = 5
        let baseDelayNanoseconds: UInt64 = 50_000_000

        for attempt in 0 ..< maxRetries {
            try checkWindowReadCancellation(cancellation)
            try await revalidateWindowOwner(resource)
            guard let appElement = system.createAXApplication(pid: resource.pid) else {
                throw RPCError(code: .notFound, message: "Window owner is unavailable")
            }
            do {
                let candidates = try exactAXWindowCandidates(application: appElement)
                try await revalidateWindowOwner(resource)
                guard let binding = await windowRegistry.resolveWindowBinding(
                    resourceID: resource.resourceID,
                    applicationName: resource.applicationName,
                    pid: resource.pid,
                    processIdentity: resource.processIdentity,
                ) else {
                    throw RPCError(code: .notFound, message: "Window binding is stale")
                }

                let admitted: ExactAXWindowCandidate
                if let retained = binding.retainedElement {
                    let identityMatches = candidates.filter {
                        CFEqual($0.element, retained.element)
                    }
                    guard identityMatches.count == 1,
                          let exact = identityMatches.first
                    else {
                        await windowRegistry.retireWindowBinding(
                            resourceID: resource.resourceID,
                            applicationName: resource.applicationName,
                            pid: resource.pid,
                            processIdentity: resource.processIdentity,
                        )
                        throw RPCError(code: .notFound, message: "Exact AX window is no longer present")
                    }
                    guard candidates.filter({ $0.windowID == exact.windowID }).count == 1 else {
                        throw RPCError(code: .failedPrecondition, message: "AX window identity is ambiguous")
                    }
                    admitted = exact
                } else {
                    let idMatches = candidates.filter { $0.windowID == binding.windowID }
                    guard !idMatches.isEmpty else {
                        let observedWindowIDs = candidates
                            .sorted { $0.windowID < $1.windowID }
                            .map {
                                "\($0.windowID):\($0.bounds.origin.x),\($0.bounds.origin.y),\($0.bounds.width),\($0.bounds.height)"
                            }
                            .joined(separator: ",")
                        Self.logger.debug(
                            "Exact CG window \(binding.windowID, privacy: .public):\(binding.bounds.origin.x, privacy: .public),\(binding.bounds.origin.y, privacy: .public),\(binding.bounds.width, privacy: .public),\(binding.bounds.height, privacy: .public) was absent from \(candidates.count, privacy: .public) AX window candidates [\(observedWindowIDs, privacy: .public)]",
                        )
                        throw ExactAXWindowResolutionError.transient(
                            finalError: RPCError(
                                code: .notFound,
                                message: "Exact AX window not found",
                            ),
                        )
                    }
                    guard idMatches.count == 1, let exact = idMatches.first else {
                        throw RPCError(code: .failedPrecondition, message: "AX window identity is ambiguous")
                    }
                    admitted = exact
                }

                guard await windowRegistry.admitExactWindowElement(
                    resourceID: resource.resourceID,
                    applicationName: resource.applicationName,
                    pid: resource.pid,
                    processIdentity: resource.processIdentity,
                    expectedWindowID: binding.windowID,
                    element: admitted.element,
                    observedWindowID: admitted.windowID,
                    observedBounds: admitted.bounds,
                ) != nil else {
                    throw RPCError(code: .failedPrecondition, message: "Window identity changed ambiguously")
                }
                try checkWindowReadCancellation(cancellation)
                try await revalidateWindowOwner(resource)
                return admitted.element
            } catch let resolution as ExactAXWindowResolutionError {
                guard attempt < maxRetries - 1 else {
                    throw resolution.finalError
                }
                let delay = baseDelayNanoseconds * UInt64(1 << attempt)
                try await Task.sleep(nanoseconds: delay)
                try checkWindowReadCancellation(cancellation)
            }
        }

        throw RPCError(code: .unavailable, message: "Accessibility window enumeration failed")
    }

    private func exactAXWindowCandidates(
        application: AnyObject,
    ) throws -> [ExactAXWindowCandidate] {
        let windowsRead = system.copyAXAttributeResult(
            element: application,
            attribute: kAXWindowsAttribute as String,
        )
        if windowsRead.errorCode == AXError.cannotComplete.rawValue {
            throw transientAXWindowResolutionFailure()
        }
        guard windowsRead.errorCode == AXError.success.rawValue else {
            throw rpcErrorForAXRead(
                errorCode: windowsRead.errorCode,
                attribute: kAXWindowsAttribute as String,
            )
        }
        guard let elements = windowsRead.value as? [AXUIElement] else {
            throw unreadableAXAttribute(kAXWindowsAttribute as String)
        }

        return try elements.compactMap { element -> ExactAXWindowCandidate? in
            let roleRead = system.copyAXAttributeResult(
                element: element as AnyObject,
                attribute: kAXRoleAttribute as String,
            )
            if roleRead.errorCode == AXError.cannotComplete.rawValue {
                throw transientAXWindowResolutionFailure()
            }
            guard roleRead.errorCode == AXError.success.rawValue else {
                throw rpcErrorForAXRead(
                    errorCode: roleRead.errorCode,
                    attribute: kAXRoleAttribute as String,
                )
            }
            guard let role = roleRead.value as? String else {
                throw unreadableAXAttribute(kAXRoleAttribute as String)
            }
            guard role == kAXWindowRole as String else {
                return nil
            }

            let idRead = system.readAXWindowID(element: element as AnyObject)
            if idRead.errorCode == AXError.cannotComplete.rawValue {
                throw transientAXWindowResolutionFailure()
            }
            guard idRead.errorCode == AXError.success.rawValue,
                  let windowID = idRead.windowID,
                  windowID != kCGNullWindowID
            else {
                if idRead.errorCode == AXError.success.rawValue {
                    throw unreadableAXAttribute("AXWindowID")
                }
                throw rpcErrorForAXRead(
                    errorCode: idRead.errorCode,
                    attribute: "AXWindowID",
                )
            }

            guard let position = try readConvergingAXPoint(
                element: element as AnyObject,
                attribute: kAXPositionAttribute as String,
            ), let size = try readConvergingAXSize(
                element: element as AnyObject,
                attribute: kAXSizeAttribute as String,
            ) else {
                throw transientAXWindowResolutionFailure()
            }
            let bounds = CGRect(origin: position, size: size)
            guard EndpointSafeGeometry.containsValidEndpoints(
                bounds,
                requiresPositiveSize: false,
            ) else {
                throw unreadableAXAttribute("AXWindowGeometry")
            }
            return ExactAXWindowCandidate(
                element: element,
                windowID: windowID,
                bounds: bounds,
            )
        }
    }

    private func transientAXWindowResolutionFailure() -> ExactAXWindowResolutionError {
        ExactAXWindowResolutionError.transient(
            finalError: RPCError(
                code: .unavailable,
                message: "Accessibility window enumeration did not converge",
            ),
        )
    }

    func readRequiredAXPoint(element: AnyObject, attribute: String) throws -> CGPoint {
        let value = try readRequiredAXAttribute(element: element, attribute: attribute)
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            throw unreadableAXAttribute(attribute)
        }
        return point
    }

    func readRequiredAXSize(element: AnyObject, attribute: String) throws -> CGSize {
        let value = try readRequiredAXAttribute(element: element, attribute: attribute)
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw unreadableAXAttribute(attribute)
        }
        return size
    }

    func readRequiredAXBool(element: AnyObject, attribute: String) throws -> Bool {
        let value = try readRequiredAXAttribute(element: element, attribute: attribute)
        guard let boolean = value as? Bool else {
            throw unreadableAXAttribute(attribute)
        }
        return boolean
    }

    func readRequiredAXElement(element: AnyObject, attribute: String) throws -> AXUIElement {
        let value = try readRequiredAXAttribute(element: element, attribute: attribute)
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        return unsafeDowncast(value as CFTypeRef, to: AXUIElement.self)
    }

    /// Reads one AX attribute for convergence polling. `cannotComplete` is the
    /// only retryable outcome; every permanent error and malformed value is
    /// surfaced immediately.
    func readConvergingAXPoint(element: AnyObject, attribute: String) throws -> CGPoint? {
        guard let value = try readConvergingAXAttribute(
            element: element,
            attribute: attribute,
        ) else {
            return nil
        }
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            throw unreadableAXAttribute(attribute)
        }
        return point
    }

    func readConvergingAXSize(element: AnyObject, attribute: String) throws -> CGSize? {
        guard let value = try readConvergingAXAttribute(
            element: element,
            attribute: attribute,
        ) else {
            return nil
        }
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw unreadableAXAttribute(attribute)
        }
        return size
    }

    func readConvergingAXBool(element: AnyObject, attribute: String) throws -> Bool? {
        guard let value = try readConvergingAXAttribute(
            element: element,
            attribute: attribute,
        ) else {
            return nil
        }
        guard let boolean = value as? Bool else {
            throw unreadableAXAttribute(attribute)
        }
        return boolean
    }

    func readConvergingAXElement(element: AnyObject, attribute: String) throws -> AXUIElement? {
        guard let value = try readConvergingAXAttribute(
            element: element,
            attribute: attribute,
        ) else {
            return nil
        }
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        return unsafeDowncast(value as CFTypeRef, to: AXUIElement.self)
    }

    private func readConvergingAXAttribute(
        element: AnyObject,
        attribute: String,
    ) throws -> Any? {
        let read = system.copyAXAttributeResult(element: element, attribute: attribute)
        if read.errorCode == AXError.cannotComplete.rawValue {
            return nil
        }
        guard read.errorCode == AXError.success.rawValue else {
            throw rpcErrorForAXRead(errorCode: read.errorCode, attribute: attribute)
        }
        guard let value = read.value else {
            throw unreadableAXAttribute(attribute)
        }
        return value
    }

    func readOptionalAXBool(
        element: AnyObject,
        attribute: String,
        defaultValue: Bool,
    ) throws -> Bool {
        guard let value = try readOptionalAXAttribute(element: element, attribute: attribute) else {
            return defaultValue
        }
        guard let boolean = value as? Bool else {
            throw unreadableAXAttribute(attribute)
        }
        return boolean
    }

    func readOptionalAXString(
        element: AnyObject,
        attribute: String,
        defaultValue: String,
    ) throws -> String {
        guard let value = try readOptionalAXAttribute(element: element, attribute: attribute) else {
            return defaultValue
        }
        guard let string = value as? String else {
            throw unreadableAXAttribute(attribute)
        }
        return string
    }

    func readOptionalAXElementExists(element: AnyObject, attribute: String) throws -> Bool {
        guard let value = try readOptionalAXAttribute(element: element, attribute: attribute) else {
            return false
        }
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
            throw unreadableAXAttribute(attribute)
        }
        return true
    }

    func readOptionalAXAttribute(element: AnyObject, attribute: String) throws -> Any? {
        let read = system.copyAXAttributeResult(element: element, attribute: attribute)
        if read.errorCode == AXError.success.rawValue {
            guard let value = read.value else {
                throw unreadableAXAttribute(attribute)
            }
            return value
        }
        if read.errorCode == AXError.attributeUnsupported.rawValue ||
            read.errorCode == AXError.noValue.rawValue
        {
            return nil
        }
        throw rpcErrorForAXRead(errorCode: read.errorCode, attribute: attribute)
    }

    func readRequiredAXAttribute(element: AnyObject, attribute: String) throws -> Any {
        let read = system.copyAXAttributeResult(element: element, attribute: attribute)
        guard read.errorCode == AXError.success.rawValue else {
            throw rpcErrorForAXRead(errorCode: read.errorCode, attribute: attribute)
        }
        guard let value = read.value else {
            throw unreadableAXAttribute(attribute)
        }
        return value
    }

    func rpcErrorForAXRead(errorCode: Int32, attribute: String) -> RPCError {
        let code: RPCError.Code = switch errorCode {
        case AXError.invalidUIElement.rawValue:
            .notFound
        case AXError.apiDisabled.rawValue:
            .permissionDenied
        default:
            .unavailable
        }
        return RPCError(code: code, message: "Accessibility attribute \(attribute) is unavailable")
    }

    func rpcErrorForAXMutation(errorCode: Int32, operation: String) -> RPCError {
        let code: RPCError.Code = switch errorCode {
        case AXError.apiDisabled.rawValue:
            .permissionDenied
        case AXError.invalidUIElement.rawValue:
            .notFound
        case AXError.actionUnsupported.rawValue,
             AXError.attributeUnsupported.rawValue,
             AXError.notImplemented.rawValue:
            .failedPrecondition
        default:
            .unavailable
        }
        return RPCError(code: code, message: "Accessibility \(operation) failed")
    }

    func unreadableAXAttribute(_ attribute: String) -> RPCError {
        RPCError(code: .unavailable, message: "Accessibility attribute \(attribute) has an invalid value")
    }

    func checkWindowReadCancellation(_ cancellation: ServerContext.RPCCancellationHandle? = nil) throws {
        guard !Task.isCancelled, cancellation?.isCancelled != true else {
            throw RPCError(code: .cancelled, message: "Window read cancelled")
        }
    }

    func readAXPoint(window: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = system.copyAXAttribute(element: window as AnyObject, attribute: attribute),
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    func readAXSize(window: AXUIElement, attribute: String) -> CGSize? {
        guard let value = system.copyAXAttribute(element: window as AnyObject, attribute: attribute),
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeDowncast(value as CFTypeRef, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    func readAXBool(window: AXUIElement, attribute: String) -> Bool? {
        system.copyAXAttribute(
            element: window as AnyObject,
            attribute: attribute,
        ) as? Bool
    }

    func waitForWindowFocusConvergence(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        application: AnyObject,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowMutationConvergencePolicy.timeout)
        var stableReads = 0

        while true {
            try checkWindowReadCancellation(cancellation)
            try await revalidateWindowOwner(resource)
            // The focus convergence predicate mirrors the READ contract
            // (buildWindowStateFromAX / buildWindowResponseFromAX report a window
            // as focused solely via kAXMainAttribute on the window element). The
            // prior 5-way conjunction additionally demanded kAXFocusedAttribute
            // on the window and kAXMainWindowAttribute/kAXFocusedWindowAttribute
            // on the application, but AppKit document windows (e.g. TextEdit) do
            // not reliably report those, so the conjunction never stabilized and
            // FocusWindow timed out. Requiring the app to be frontmost plus the
            // window to be main is exactly what the read path reports as focused,
            // so convergence and reads agree.
            let frontmost = try readConvergingAXBool(
                element: application,
                attribute: kAXFrontmostAttribute as String,
            )
            let main = try readConvergingAXBool(
                element: window as AnyObject,
                attribute: kAXMainAttribute as String,
            )
            let focused = frontmost == true && main == true
            stableReads = focused ? stableReads + 1 : 0
            if stableReads >= windowMutationConvergencePolicy.stableReadCount {
                return
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for window focus convergence",
                )
            }
            try await Task.sleep(for: windowMutationConvergencePolicy.pollInterval)
        }
    }

    func waitForWindowPointConvergence(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        previous: CGPoint,
        requested: CGPoint,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws -> CGPoint {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowMutationConvergencePolicy.timeout)
        var stableCandidate: CGPoint?
        var stableReads = 0

        while true {
            try checkWindowReadCancellation(cancellation)
            try await revalidateWindowOwner(resource)
            if let observed = try readConvergingAXPoint(
                element: window as AnyObject,
                attribute: kAXPositionAttribute as String,
            ),
                approximatelyEqual(observed, requested) || !approximatelyEqual(observed, previous)
            {
                if let stableCandidate, approximatelyEqual(observed, stableCandidate) {
                    stableReads += 1
                } else {
                    stableCandidate = observed
                    stableReads = 1
                }
                if stableReads >= windowMutationConvergencePolicy.stableReadCount {
                    return observed
                }
            } else {
                stableCandidate = nil
                stableReads = 0
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for window position convergence",
                )
            }
            try await Task.sleep(for: windowMutationConvergencePolicy.pollInterval)
        }
    }

    func waitForWindowSizeConvergence(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        previous: CGSize,
        requested: CGSize,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws -> CGSize {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowMutationConvergencePolicy.timeout)
        var stableCandidate: CGSize?
        var stableReads = 0

        while true {
            try checkWindowReadCancellation(cancellation)
            try await revalidateWindowOwner(resource)
            if let observed = try readConvergingAXSize(
                element: window as AnyObject,
                attribute: kAXSizeAttribute as String,
            ),
                approximatelyEqual(observed, requested) || !approximatelyEqual(observed, previous)
            {
                if let stableCandidate, approximatelyEqual(observed, stableCandidate) {
                    stableReads += 1
                } else {
                    stableCandidate = observed
                    stableReads = 1
                }
                if stableReads >= windowMutationConvergencePolicy.stableReadCount {
                    return observed
                }
            } else {
                stableCandidate = nil
                stableReads = 0
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for window size convergence",
                )
            }
            try await Task.sleep(for: windowMutationConvergencePolicy.pollInterval)
        }
    }

    func waitForWindowBooleanConvergence(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        attribute: String,
        expected: Bool,
        operation: String,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowMutationConvergencePolicy.timeout)
        var stableReads = 0

        while true {
            try checkWindowReadCancellation(cancellation)
            try await revalidateWindowOwner(resource)
            if try readConvergingAXBool(
                element: window as AnyObject,
                attribute: attribute,
            ) == expected {
                stableReads += 1
                if stableReads >= windowMutationConvergencePolicy.stableReadCount {
                    return
                }
            } else {
                stableReads = 0
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for window \(operation) convergence",
                )
            }
            try await Task.sleep(for: windowMutationConvergencePolicy.pollInterval)
        }
    }

    func waitForWindowDisappearance(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: windowMutationConvergencePolicy.timeout)
        var stableAbsentReads = 0

        while true {
            try checkWindowReadCancellation(cancellation)
            if exactWindowPresence(resource: resource, window: window) == false {
                stableAbsentReads += 1
                if stableAbsentReads >= windowMutationConvergencePolicy.stableReadCount {
                    return
                }
            } else {
                stableAbsentReads = 0
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for window disappearance",
                )
            }
            try await Task.sleep(for: windowMutationConvergencePolicy.pollInterval)
        }
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= windowMutationConvergencePolicy.geometryTolerance &&
            abs(lhs.y - rhs.y) <= windowMutationConvergencePolicy.geometryTolerance
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= windowMutationConvergencePolicy.geometryTolerance &&
            abs(lhs.height - rhs.height) <= windowMutationConvergencePolicy.geometryTolerance
    }

    /// Returns nil when AX cannot prove either presence or absence. An empty
    /// exact AX window enumeration or termination of the admitted process proves
    /// absence; title/bounds heuristics are deliberately not used.
    private func exactWindowPresence(
        resource: ResolvedWindowResource,
        window: AXUIElement,
    ) -> Bool? {
        if let identity = resource.processIdentity {
            guard system.isApplicationProcessRunning(identity) else {
                return false
            }
        } else if !system.isProcessRunning(pid: resource.pid) {
            return false
        }

        guard let application = system.createAXApplication(pid: resource.pid) else {
            return nil
        }
        let candidateRead = system.copyAXAttributeResult(
            element: application,
            attribute: kAXWindowsAttribute as String,
        )
        guard candidateRead.errorCode == AXError.success.rawValue,
              let candidates = candidateRead.value as? [AXUIElement]
        else {
            return nil
        }
        guard !candidates.isEmpty else {
            return false
        }

        return candidates.contains { CFEqual($0, window) }
    }

    /// Builds a truthful WindowState from one exact AX window and its owner
    /// application. Error codes and type mismatches remain observable rather
    /// than being flattened into false capability values.
    func buildWindowStateFromAX(
        resource: ResolvedWindowResource,
        window: AXUIElement,
        cancellation: ServerContext.RPCCancellationHandle? = nil,
    ) async throws -> Macosusesdk_V1_WindowState {
        try checkWindowReadCancellation(cancellation)
        try await revalidateWindowOwner(resource)
        guard let application = system.createAXApplication(pid: resource.pid) else {
            throw RPCError(code: .notFound, message: "Window owner is unavailable")
        }

        let settableRead = system.isAXAttributeSettable(
            element: window as AnyObject,
            attribute: kAXSizeAttribute as String,
        )
        guard settableRead.errorCode == AXError.success.rawValue else {
            throw rpcErrorForAXRead(
                errorCode: settableRead.errorCode,
                attribute: kAXSizeAttribute as String,
            )
        }
        let minimizable = try readOptionalAXElementExists(
            element: window as AnyObject,
            attribute: kAXMinimizeButtonAttribute as String,
        )
        let closable = try readOptionalAXElementExists(
            element: window as AnyObject,
            attribute: kAXCloseButtonAttribute as String,
        )
        let explicitModal = try readRequiredAXBool(
            element: window as AnyObject,
            attribute: kAXModalAttribute as String,
        )
        let subrole = try readOptionalAXString(
            element: window as AnyObject,
            attribute: kAXSubroleAttribute as String,
            defaultValue: "",
        )
        let axHidden = try readOptionalAXBool(
            element: application,
            attribute: kAXHiddenAttribute as String,
            defaultValue: false,
        )
        let minimized = try readOptionalAXBool(
            element: window as AnyObject,
            attribute: kAXMinimizedAttribute as String,
            defaultValue: false,
        )
        let focused = try readRequiredAXBool(
            element: window as AnyObject,
            attribute: kAXMainAttribute as String,
        )
        let modalSubroles = [
            kAXDialogSubrole as String,
            kAXSystemDialogSubrole as String,
        ]
        let floatingSubroles = [
            kAXFloatingWindowSubrole as String,
            kAXSystemFloatingWindowSubrole as String,
        ]

        try checkWindowReadCancellation(cancellation)
        try await revalidateWindowOwner(resource)
        return Macosusesdk_V1_WindowState.with {
            $0.resizable = settableRead.settable
            $0.minimizable = minimizable
            $0.closable = closable
            $0.modal = explicitModal || modalSubroles.contains(subrole)
            $0.floating = floatingSubroles.contains(subrole)
            $0.axHidden = axHidden
            $0.minimized = minimized
            $0.focused = focused
        }
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

private enum ExactAXWindowResolutionError: Error {
    case transient(finalError: RPCError)

    var finalError: RPCError {
        switch self {
        case let .transient(finalError):
            finalError
        }
    }
}

private struct ExactAXWindowCandidate {
    let element: AXUIElement
    let windowID: CGWindowID
    let bounds: CGRect
}
