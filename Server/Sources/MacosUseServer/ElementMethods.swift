import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

private enum ElementMutationTarget: Sendable {
    case elementID(String)
    case selector(Macosusesdk_Type_ElementSelector)
}

extension MacosUseService {
    func traverseAccessibility(
        request: ServerRequest<Macosusesdk_V1_TraverseAccessibilityRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_TraverseAccessibilityResponse> {
        let req = request.message
        Self.logger.info("traverseAccessibility called")
        let pid = try await resolveApplicationPID(fromName: req.name)
        let response = try await automationCoordinator.handleTraverse(
            pid: pid,
            visibleOnly: req.visibleOnly,
            shouldActivate: false,
            applicationName: req.name,
        )
        return ServerResponse(message: response)
    }

    func watchAccessibility(
        request: ServerRequest<Macosusesdk_V1_WatchAccessibilityRequest>,
        context _: ServerContext,
    ) async throws -> StreamingServerResponse<Macosusesdk_V1_WatchAccessibilityResponse> {
        let req = request.message
        Self.logger.info("watchAccessibility called")

        let pollInterval = try RequestNumericValidation.optionalPollInterval(
            req.pollInterval,
            default: 1,
        )
        let pid = try await resolveApplicationPID(fromName: req.name)

        return StreamingServerResponse { [automationCoordinator] writer in
            let ownedStream = try await automationCoordinator.createTraversalStreamTask {
                var previousByPath: [String: Macosusesdk_V1_Element] = [:]

                while true {
                    try Task.checkCancellation()
                    let currentPID = try await self.resolveApplicationPID(fromName: req.name)
                    guard currentPID == pid else {
                        throw RPCError(code: .notFound, message: "Application process identity is stale")
                    }
                    let trav = try await automationCoordinator.handleTraverse(
                        pid: pid,
                        visibleOnly: req.visibleOnly,
                        applicationName: req.name,
                    )

                    // Build current element map keyed by path
                    var currentByPath: [String: Macosusesdk_V1_Element] = [:]
                    for element in trav.elements {
                        let pathKey = Self.elementPathKey(element)
                        currentByPath[pathKey] = element
                    }

                    // Compute diff
                    var added: [Macosusesdk_V1_Element] = []
                    var removed: [Macosusesdk_V1_Element] = []
                    var modified: [Macosusesdk_V1_ModifiedElement] = []

                    // Find added and modified elements
                    for (pathKey, currentElement) in currentByPath {
                        if let previousElement = previousByPath[pathKey] {
                            // Element existed before - check if modified
                            let changes = self.computeElementChanges(
                                old: previousElement, new: currentElement,
                            )
                            if !changes.isEmpty {
                                modified.append(Macosusesdk_V1_ModifiedElement.with {
                                    $0.oldElement = previousElement
                                    $0.newElement = currentElement
                                    $0.changes = changes
                                })
                            }
                            // If no changes, element is unchanged - don't include in response
                        } else {
                            // Element is new
                            added.append(currentElement)
                        }
                    }

                    // Find removed elements
                    for (pathKey, previousElement) in previousByPath where currentByPath[pathKey] == nil {
                        removed.append(previousElement)
                    }

                    // Only send response if there are changes (or first poll - all added)
                    let hasChanges = !added.isEmpty || !removed.isEmpty || !modified.isEmpty
                    if hasChanges {
                        let resp = Macosusesdk_V1_WatchAccessibilityResponse.with {
                            $0.added = added
                            $0.removed = removed
                            $0.modified = modified
                        }
                        try await writer.write(resp)
                    }

                    previousByPath = currentByPath
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
            }
            let producer = ownedStream.task

            do {
                let metadata = try await withTaskCancellationHandler {
                    try await withRPCCancellationHandler {
                        try await producer.value
                    } onCancelRPC: {
                        producer.cancel()
                    }
                } onCancel: {
                    producer.cancel()
                }
                await automationCoordinator.finishTraversalStream(id: ownedStream.id)
                return metadata
            } catch is CancellationError {
                producer.cancel()
                _ = await producer.result
                await automationCoordinator.finishTraversalStream(id: ownedStream.id)
                throw RPCError(code: .cancelled, message: "accessibility watch cancelled")
            } catch {
                producer.cancel()
                _ = await producer.result
                await automationCoordinator.finishTraversalStream(id: ownedStream.id)
                throw error
            }
        }
    }

    /// Computes attribute changes between two elements.
    /// Returns an empty array if elements are identical.
    /// - Note: Internal for testing with @testable import.
    func computeElementChanges(
        old: Macosusesdk_V1_Element,
        new: Macosusesdk_V1_Element,
    ) -> [Macosusesdk_V1_AttributeChange] {
        var changes: [Macosusesdk_V1_AttributeChange] = []

        // Compare role
        if old.role != new.role {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "role"
                $0.oldValue = old.role
                $0.newValue = new.role
            })
        }

        // Compare text (handle optionals)
        let oldText = old.hasText ? old.text : ""
        let newText = new.hasText ? new.text : ""
        if oldText != newText {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "text"
                $0.oldValue = oldText
                $0.newValue = newText
            })
        }

        // Compare position x (with epsilon for floating-point noise)
        let oldX = old.hasX ? old.x : 0
        let newX = new.hasX ? new.x : 0
        if !Self.doubleApproxEqual(oldX, newX) {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "x"
                $0.oldValue = String(oldX)
                $0.newValue = String(newX)
            })
        }

        // Compare position y (with epsilon for floating-point noise)
        let oldY = old.hasY ? old.y : 0
        let newY = new.hasY ? new.y : 0
        if !Self.doubleApproxEqual(oldY, newY) {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "y"
                $0.oldValue = String(oldY)
                $0.newValue = String(newY)
            })
        }

        // Compare width (with epsilon for floating-point noise)
        let oldWidth = old.hasWidth ? old.width : 0
        let newWidth = new.hasWidth ? new.width : 0
        if !Self.doubleApproxEqual(oldWidth, newWidth) {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "width"
                $0.oldValue = String(oldWidth)
                $0.newValue = String(newWidth)
            })
        }

        // Compare height (with epsilon for floating-point noise)
        let oldHeight = old.hasHeight ? old.height : 0
        let newHeight = new.hasHeight ? new.height : 0
        if !Self.doubleApproxEqual(oldHeight, newHeight) {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "height"
                $0.oldValue = String(oldHeight)
                $0.newValue = String(newHeight)
            })
        }

        // Compare enabled
        let oldEnabled = old.hasEnabled ? old.enabled : true
        let newEnabled = new.hasEnabled ? new.enabled : true
        if oldEnabled != newEnabled {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "enabled"
                $0.oldValue = String(oldEnabled)
                $0.newValue = String(newEnabled)
            })
        }

        // Compare focused
        let oldFocused = old.hasFocused ? old.focused : false
        let newFocused = new.hasFocused ? new.focused : false
        if oldFocused != newFocused {
            changes.append(Macosusesdk_V1_AttributeChange.with {
                $0.attribute = "focused"
                $0.oldValue = String(oldFocused)
                $0.newValue = String(newFocused)
            })
        }

        return changes
    }

    /// Generates a unique path key for an element.
    /// Handles empty paths by using role + position + size as fallback to avoid collisions.
    /// - Note: Static for testing with @testable import.
    static func elementPathKey(_ element: Macosusesdk_V1_Element) -> String {
        if element.path.isEmpty {
            // Fallback: use elementId + role + position + size to distinguish elements
            // without path info. Including elementId avoids collisions for same-role
            // siblings at identical coordinates (e.g., two identical buttons stacked).
            let x = safeInt(element.hasX ? element.x : 0)
            let y = safeInt(element.hasY ? element.y : 0)
            let w = safeInt(element.hasWidth ? element.width : 0)
            let h = safeInt(element.hasHeight ? element.height : 0)
            if !element.elementID.isEmpty {
                return "id:\(element.elementID)"
            }
            return "root:\(element.role)@\(x),\(y)/\(w)x\(h)"
        }
        return element.path.map(String.init).joined(separator: "/")
    }

    /// Safely converts a Double to Int, returning 0 for NaN, Infinity, or values outside Int range.
    private static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        // Guard against values outside Int range (extremely unlikely for UI coordinates)
        guard value >= Double(Int.min), value <= Double(Int.max) else { return 0 }
        return Int(value)
    }

    /// Epsilon for floating-point comparisons (1 pixel tolerance for AX coordinate noise).
    private static let coordinateEpsilon: Double = 1.0

    /// Returns true if two doubles are approximately equal within epsilon.
    private static func doubleApproxEqual(_ lhs: Double, _ rhs: Double, epsilon: Double = coordinateEpsilon) -> Bool {
        abs(lhs - rhs) < epsilon
    }

    func findElements(
        request: ServerRequest<Macosusesdk_V1_FindElementsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_FindElementsResponse> {
        let req = request.message
        Self.logger.info("findElements called (forceRefresh=\(req.forceRefresh, privacy: .public))")

        // Validate and parse the selector
        let selector = try SelectorParser.shared.parseSelector(req.selector)
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let queryBinding = try ParsingHelpers.pageTokenQuery(
            method: "FindElements",
            parameters: [
                ("parent", req.parent),
                ("selector", req.selector.serializedData().base64EncodedString()),
                ("visible_only", String(req.visibleOnly)),
                ("force_refresh", String(req.forceRefresh)),
                ("page_size", String(pageSize)),
            ],
        )
        let offset = try ParsingHelpers.pageOffset(
            token: req.pageToken,
            queryBinding: queryBinding,
        )
        let (offsetAndPage, pageOverflow) = offset.addingReportingOverflow(pageSize)
        let (maxResults, sentinelOverflow) = offsetAndPage.addingReportingOverflow(1)
        guard !pageOverflow, !sentinelOverflow else {
            throw RPCErrorHelpers.validationError(
                message: "page_token offset is outside the current collection",
                reason: "INVALID_PAGE_TOKEN",
                field: "page_token",
            )
        }

        let pid = try await resolveApplicationOrWindowParentPID(fromName: req.parent)
        if req.forceRefresh, offset == 0 {
            let cleared = await elementRegistry.clearElements(
                forPid: pid,
                scope: req.parent,
            )
            if cleared > 0 {
                Self.logger.info("forceRefresh: cleared \(cleared, privacy: .public) cached elements for PID \(pid, privacy: .public)")
            }
        }

        // Find elements using ElementLocator (request more than needed to check if there's a next page)
        let elementsWithPaths = try await elementLocator.findElements(
            selector: selector,
            parent: req.parent,
            visibleOnly: req.visibleOnly,
            maxResults: maxResults,
        )

        // Apply pagination slice
        let totalCount = elementsWithPaths.count
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: pageSize,
            totalCount: totalCount,
        )
        let pageElementsWithPaths = Array(elementsWithPaths[range])
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: totalCount,
            queryBinding: queryBinding,
        )

        // Build response elements - elements from ElementLocator are already registered
        // with their AXUIElement references preserved. Do NOT re-register them.
        var elements = [Macosusesdk_V1_Element]()
        for (element, path) in pageElementsWithPaths {
            var protoWithPath = element
            protoWithPath.path = path
            elements.append(protoWithPath)
        }

        let response = Macosusesdk_V1_FindElementsResponse.with {
            $0.elements = elements
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func findRegionElements(
        request: ServerRequest<Macosusesdk_V1_FindRegionElementsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_FindRegionElementsResponse> {
        let req = request.message
        Self.logger.info("findRegionElements called (forceRefresh=\(req.forceRefresh, privacy: .public))")

        // Validate region coordinates are finite
        guard req.region.x.isFinite else {
            throw RPCErrorHelpers.validationError(
                message: "region.x must be a finite number",
                reason: "INVALID_COORDINATE",
                field: "region.x",
                value: String(req.region.x),
            )
        }
        guard req.region.y.isFinite else {
            throw RPCErrorHelpers.validationError(
                message: "region.y must be a finite number",
                reason: "INVALID_COORDINATE",
                field: "region.y",
                value: String(req.region.y),
            )
        }
        guard req.region.width.isFinite, req.region.width > 0 else {
            throw RPCErrorHelpers.validationError(
                message: "region.width must be a finite positive number",
                reason: "INVALID_DIMENSION",
                field: "region.width",
                value: String(req.region.width),
            )
        }
        guard req.region.height.isFinite, req.region.height > 0 else {
            throw RPCErrorHelpers.validationError(
                message: "region.height must be a finite positive number",
                reason: "INVALID_DIMENSION",
                field: "region.height",
                value: String(req.region.height),
            )
        }

        // Validate selector if provided
        let selector =
            req.hasSelector ? try SelectorParser.shared.parseSelector(req.selector) : nil
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let queryBinding = try ParsingHelpers.pageTokenQuery(
            method: "FindRegionElements",
            parameters: [
                ("parent", req.parent),
                ("region", req.region.serializedData().base64EncodedString()),
                ("selector", req.hasSelector ? req.selector.serializedData().base64EncodedString() : ""),
                ("force_refresh", String(req.forceRefresh)),
                ("page_size", String(pageSize)),
            ],
        )
        let offset = try ParsingHelpers.pageOffset(
            token: req.pageToken,
            queryBinding: queryBinding,
        )
        let (offsetAndPage, pageOverflow) = offset.addingReportingOverflow(pageSize)
        let (maxResults, sentinelOverflow) = offsetAndPage.addingReportingOverflow(1)
        guard !pageOverflow, !sentinelOverflow else {
            throw RPCErrorHelpers.validationError(
                message: "page_token offset is outside the current collection",
                reason: "INVALID_PAGE_TOKEN",
                field: "page_token",
            )
        }

        let pid = try await resolveApplicationOrWindowParentPID(fromName: req.parent)
        if req.forceRefresh, offset == 0 {
            let cleared = await elementRegistry.clearElements(
                forPid: pid,
                scope: req.parent,
            )
            if cleared > 0 {
                Self.logger.info("forceRefresh: cleared \(cleared, privacy: .public) cached elements for PID \(pid, privacy: .public)")
            }
        }

        // Find elements in region using ElementLocator (request more than needed to check if there's a next page)
        let elementsWithPaths = try await elementLocator.findElementsInRegion(
            region: req.region,
            selector: selector,
            parent: req.parent,
            visibleOnly: false, // Region search doesn't have visibleOnly parameter
            maxResults: maxResults,
        )

        // Apply pagination slice
        let totalCount = elementsWithPaths.count
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: pageSize,
            totalCount: totalCount,
        )
        let pageElementsWithPaths = Array(elementsWithPaths[range])
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: totalCount,
            queryBinding: queryBinding,
        )

        // Build response elements - elements from ElementLocator are already registered
        // with their AXUIElement references preserved. Do NOT re-register them.
        var elements = [Macosusesdk_V1_Element]()
        for (element, path) in pageElementsWithPaths {
            var protoWithPath = element
            protoWithPath.path = path
            elements.append(protoWithPath)
        }

        let response = Macosusesdk_V1_FindRegionElementsResponse.with {
            $0.elements = elements
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func getElement(
        request: ServerRequest<Macosusesdk_V1_GetElementRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Element> {
        let req = request.message
        Self.logger.info("getElement called")

        guard req.unknownFields.data.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "GetElementRequest contains unknown fields",
                reason: "UNKNOWN_FIELD",
                field: "request",
            )
        }

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }

        _ = try await resolveApplicationChildResource(req.name, collection: "elements")
        let response = try await elementLocator.getElement(name: req.name)
        return ServerResponse(message: response)
    }

    func listElements(
        request: ServerRequest<Macosusesdk_V1_ListElementsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListElementsResponse> {
        let req = request.message
        Self.logger.info("listElements called")

        guard req.unknownFields.data.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "ListElementsRequest contains unknown fields",
                reason: "UNKNOWN_FIELD",
                field: "request",
            )
        }
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListElements",
            parameters: [
                ("parent", req.parent),
                ("page_size", String(pageSize)),
            ],
        )
        let offset = try ParsingHelpers.pageOffset(
            token: req.pageToken,
            queryBinding: queryBinding,
        )
        let pid = try await resolveApplicationPID(fromName: req.parent)

        let elements = await elementRegistry.listElements(forPID: pid)
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: pageSize,
            totalCount: elements.count,
        )
        let page = Array(elements[range])
        let nextPageToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: elements.count,
            queryBinding: queryBinding,
        )

        return ServerResponse(message: Macosusesdk_V1_ListElementsResponse.with {
            $0.elements = page
            $0.nextPageToken = nextPageToken
        })
    }

    func clickElement(
        request: ServerRequest<Macosusesdk_V1_ClickElementRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ClickElementResponse> {
        let req = request.message
        Self.logger.info("clickElement called")

        let pid = try await resolveApplicationOrWindowParentPID(fromName: req.parent)
        let target = try Self.parseElementMutationTarget(req.target)
        let elementLocator = self.elementLocator
        let response = try await automationCoordinator.handlePhysicalMutationWithOwner { context, ownerID in
            let admitted = try await Self.resolveElementMutationTarget(
                target,
                parent: req.parent,
                expectedPID: pid,
                locator: elementLocator,
                context: context,
            )
            try await context.activateTarget(pid: pid)
            try await context.focusElementWindow(target: admitted)

            let exactTarget = try await context.resolveElement(
                id: admitted.elementID,
                expectedPID: pid,
                expectedScope: req.parent,
            )
            guard let axElement = exactTarget.axElement else {
                throw RPCError(code: .notFound, message: "Element reference not available")
            }
            let element = Self.refreshBoundsIfPossible(
                element: exactTarget.element,
                axElement: axElement as AnyObject,
                system: context.system,
            )
            guard Self.elementClickPointIsOnScreen(element) else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element is not visible on screen; bring it into view",
                )
            }

            let clickPoint = try Self.elementClickPoint(element)
            let action: MacosUseSDK.InputAction = switch req.clickType {
            case .single, .unspecified, .UNRECOGNIZED:
                .click(point: clickPoint)
            case .double:
                .doubleClick(point: clickPoint)
            case .right:
                .rightClick(point: clickPoint)
            }
            // C6: the physical click publishes a real, retrievable Input
            // resource; its name surfaces on the response .input field.
            let inputName = try await self.publishElementInputResource(
                action: action,
                parent: req.parent,
                ownerID: ownerID,
                route: .process(pid),
                executor: { try await context.executeInput(action, route: .process(pid)) },
            )

            return Macosusesdk_V1_ClickElementResponse.with {
                $0.success = true
                $0.element = element
                $0.input = inputName
            }
        }
        return ServerResponse(message: response)
    }

    /// Polls until the element's AX attribute matches the expected string value.
    /// Uses InputTextConvergencePolicy for centralised timeout/poll-interval tuning.
    /// Duplicates of this readback loop in directAx and keystrokeReplacement were
    /// consolidated here to avoid drift and to enable transient-AX-error handling.
    private static func waitForAXValueConvergence(
        system: SystemOperations,
        element: AnyObject,
        attribute: String,
        expected: String,
        policy: InputTextConvergencePolicy = .init(),
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.timeout)
        while true {
            try Task.checkCancellation()
            // Read via the error-code-exposing variant so transient AX
            // failures (cannotComplete / failure) can be distinguished from a
            // genuine "value has not converged yet". AX can briefly return
            // cannotComplete while AppKit settles after a routed write; those
            // must be retried, not fatal. A non-transient non-success error is
            // surfaced immediately instead of polling until the deadline.
            let read = system.copyAXAttributeResult(
                element: element,
                attribute: attribute,
            )
            if read.errorCode == AXError.success.rawValue {
                if (read.value as? String) == expected {
                    break
                }
            } else if !inputTextAXReadIsTransient(read.errorCode) {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "AX read of \(attribute) failed with AXError \(read.errorCode) while waiting for convergence",
                )
            }
            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for \(attribute) convergence",
                )
            }
            try await Task.sleep(for: policy.pollInterval)
        }
    }

    /// Shared finalize block: updates element text + focused field, commits to
    /// the element registry, and returns a populated success response.
    /// `inputResourceName` is non-empty only for the keystroke-replacement
    /// path (C6); it is left empty for the direct-AX path, which performs no
    /// physical input, so the response .input field is correctly absent.
    private static func finalizeWriteElementValue(
        element: inout Macosusesdk_V1_Element,
        expectedText: String,
        axElement: AXUIElement,
        elementID: String,
        system: SystemOperations,
        elementRegistry: ElementRegistry,
        inputResourceName: String = "",
    ) async throws -> Macosusesdk_V1_WriteElementValueResponse {
        element.text = expectedText
        if let focused = system.copyAXAttribute(
            element: axElement as AnyObject,
            attribute: kAXFocusedAttribute as String,
        ) as? Bool {
            element.focused = focused
        }
        guard await elementRegistry.updateElement(
            elementID,
            element: element,
            axElement: axElement,
        ) else {
            throw RPCError(code: .notFound, message: "Element expired before response readback")
        }
        return Macosusesdk_V1_WriteElementValueResponse.with {
            $0.success = true
            $0.element = element
            $0.input = inputResourceName
        }
    }

    func writeElementValue(
        request: ServerRequest<Macosusesdk_V1_WriteElementValueRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WriteElementValueResponse> {
        let req = request.message
        Self.logger.info("writeElementValue called")

        let pid = try await resolveApplicationOrWindowParentPID(fromName: req.parent)
        let target = try Self.parseElementMutationTarget(req.target)
        let elementLocator = self.elementLocator
        let elementRegistry = self.elementRegistry
        // Treat an omitted value as an empty string for both write modes. The
        // proto distinguishes omitted (clear) from explicit "" (set-to-empty),
        // but AXValue has no separate "clear" operation, so both write "".
        let requestValue = req.hasValue ? req.value : ""
        let writeMode = req.writeMode
        let response = try await automationCoordinator.handlePhysicalMutationWithOwner { context, ownerID in
            let admitted = try await Self.resolveElementMutationTarget(
                target,
                parent: req.parent,
                expectedPID: pid,
                locator: elementLocator,
                context: context,
            )
            try await context.activateTarget(pid: pid)
            try await context.focusElementWindow(target: admitted)

            let exactTarget = try await context.resolveElement(
                id: admitted.elementID,
                expectedPID: pid,
                expectedScope: req.parent,
            )
            guard let axElement = exactTarget.axElement else {
                throw RPCError(code: .notFound, message: "Element reference not available")
            }
            var element = Self.refreshBoundsIfPossible(
                element: exactTarget.element,
                axElement: axElement as AnyObject,
                system: context.system,
            )
            guard Self.elementClickPointIsOnScreen(element) else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element is not visible on screen; bring it into view",
                )
            }
            let canonicalRole = ElementLocator.canonicalRole(element.role)
            guard Self.roleIsTextEditable(canonicalRole) else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element role '\(element.role)' is not editable",
                )
            }

            // Default an unspecified write mode to direct AX. The switch below
            // is exhaustive over the resulting (possibly UNRECOGNIZED) value;
            // .unspecified is unreachable here (normalized above) but listed to
            // satisfy the generated enum's exhaustiveness requirement.
            let effectiveMode = writeMode == .unspecified ? .directAx : writeMode
            switch effectiveMode {
            case .directAx, .unspecified:
                // Direct AX value mutation.

                // Verify kAXValueAttribute is settable before attempting direct AX mutation.
                // The keystrokeReplacement branch intentionally bypasses this check —
                // AXSecureTextField, web/Electron controls report settable=false but are
                // keyboard-editable via Cmd+A + type.
                let settableCheck = context.system.isAXAttributeSettable(
                    element: axElement as AnyObject,
                    attribute: kAXValueAttribute as String,
                )
                guard settableCheck.errorCode == AXError.success.rawValue, settableCheck.settable else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Element AXValue is not settable (AXError \(settableCheck.errorCode))",
                    )
                }

                let setResult = context.system.setAXAttribute(
                    element: axElement as AnyObject,
                    attribute: kAXValueAttribute as String,
                    value: requestValue,
                )
                guard setResult == AXError.success.rawValue else {
                    throw RPCError(
                        code: .internalError,
                        message: "AXValue set failed for element \(exactTarget.elementID) (AXError \(setResult))",
                    )
                }

                try await Self.waitForAXValueConvergence(
                    system: context.system,
                    element: axElement as AnyObject,
                    attribute: kAXValueAttribute as String,
                    expected: requestValue,
                )
                return try await Self.finalizeWriteElementValue(
                    element: &element,
                    expectedText: requestValue,
                    axElement: axElement,
                    elementID: exactTarget.elementID,
                    system: context.system,
                    elementRegistry: elementRegistry,
                )

            case .keystrokeReplacement:
                // W2 keystroke replacement: focus the target element so Cmd+A
                // and typed text land on the correct first responder, not
                // whatever control in the window happened to hold keyboard focus.
                // Try AX focus first; AXSecureTextField/web/Electron controls
                // may reject kAXFocusedAttribute — fall back to physical click.
                let focusSetResult = context.system.setAXAttribute(
                    element: axElement as AnyObject,
                    attribute: kAXFocusedAttribute as String,
                    value: true,
                )
                if focusSetResult != AXError.success.rawValue {
                    _ = try await context.executeInput(
                        .click(
                            point: Self.elementClickPoint(element),
                        ),
                        route: .process(pid),
                    )
                }

                // Select all existing content via keyboard shortcut (Cmd+A).
                _ = try await context.executeInput(
                    .press(keyName: "a", flags: .maskCommand),
                    route: .process(pid),
                )

                let textToType = requestValue
                // C6: publish ONE real Input resource for the committing action
                // (the type or the delete that actually changes the value). The
                // preceding focus-click and Cmd+A are supporting sub-actions and
                // are not each published (the response .input field is singular).
                var committedInputName = ""
                if textToType.isEmpty {
                    // An empty replacement clears the field: with the selection
                    // active, a single Delete removes it. Dispatching typeText("")
                    // would post zero events and fail executeInput's receipt guard,
                    // so delete the selection instead.
                    let deleteAction: MacosUseSDK.InputAction = .press(keyName: "delete", flags: [])
                    committedInputName = try await self.publishElementInputResource(
                        action: deleteAction,
                        parent: req.parent,
                        ownerID: ownerID,
                        route: .process(pid),
                        executor: { try await context.executeInput(deleteAction, route: .process(pid)) },
                    )
                } else {
                    let typeAction: MacosUseSDK.InputAction = .typeText(text: textToType, charDelay: 0.01)
                    committedInputName = try await self.publishElementInputResource(
                        action: typeAction,
                        parent: req.parent,
                        ownerID: ownerID,
                        route: .process(pid),
                        executor: { try await context.executeInput(typeAction, route: .process(pid)) },
                    )
                }

                // Verify readback convergence via the shared transient-aware helper.
                try await Self.waitForAXValueConvergence(
                    system: context.system,
                    element: axElement as AnyObject,
                    attribute: kAXValueAttribute as String,
                    expected: textToType,
                )
                return try await Self.finalizeWriteElementValue(
                    element: &element,
                    expectedText: textToType,
                    axElement: axElement,
                    elementID: exactTarget.elementID,
                    system: context.system,
                    elementRegistry: elementRegistry,
                    inputResourceName: committedInputName,
                )

            case .UNRECOGNIZED:
                throw RPCError(code: .invalidArgument, message: "Unrecognized write mode")
            }
        }
        return ServerResponse(message: response)
    }

    private static func parseElementMutationTarget(
        _ target: Macosusesdk_V1_ClickElementRequest.OneOf_Target?,
    ) throws -> ElementMutationTarget {
        switch target {
        case let .elementID(id):
            return .elementID(id)
        case let .selector(selector):
            return try .selector(SelectorParser.shared.parseSelector(selector))
        case nil:
            throw RPCError(
                code: .invalidArgument,
                message: "Either element_id or selector must be specified",
            )
        }
    }

    private static func parseElementMutationTarget(
        _ target: Macosusesdk_V1_WriteElementValueRequest.OneOf_Target?,
    ) throws -> ElementMutationTarget {
        switch target {
        case let .elementID(id):
            return .elementID(id)
        case let .selector(selector):
            return try .selector(SelectorParser.shared.parseSelector(selector))
        case nil:
            throw RPCError(
                code: .invalidArgument,
                message: "Either element_id or selector must be specified",
            )
        }
    }

    private static func parseElementMutationTarget(
        _ target: Macosusesdk_V1_PerformElementActionRequest.OneOf_Target?,
    ) throws -> ElementMutationTarget {
        switch target {
        case let .elementID(id):
            return .elementID(id)
        case let .selector(selector):
            return try .selector(SelectorParser.shared.parseSelector(selector))
        case nil:
            throw RPCError(
                code: .invalidArgument,
                message: "Either element_id or selector must be specified",
            )
        }
    }

    @MainActor
    private static func resolveElementMutationTarget(
        _ target: ElementMutationTarget,
        parent: String,
        expectedPID: pid_t,
        locator: ElementLocator,
        context: PhysicalDesktopMutationContext,
    ) async throws -> RegisteredElementMutationTarget {
        let elementID: String
        switch target {
        case let .elementID(id):
            elementID = id
        case let .selector(selector):
            let matches = try await locator.findElements(
                selector: selector,
                parent: parent,
                visibleOnly: false,
                maxResults: 2,
            )
            guard let match = matches.first else {
                throw RPCError(code: .notFound, message: "No element found matching selector")
            }
            guard matches.count == 1 else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Selector matched multiple elements",
                )
            }
            elementID = match.element.elementID
        }

        return try await context.resolveElement(
            id: elementID,
            expectedPID: expectedPID,
            expectedScope: parent,
        )
    }

    /// Returns true if the canonical accessibility role indicates the element
    /// supports direct AXValue text mutation. Role strings may include a human-
    /// readable description in parentheses (e.g. "AXTextArea (text entry area)");
    /// callers should strip that suffix before passing the role here.
    /// - Note: Internal for testing with @testable import.
    static func roleIsTextEditable(_ role: String) -> Bool {
        let canonical = role.lowercased()
        let editableRoles = [
            "axtextfield",
            "axtextarea",
            "axcombobox",
            "axsearchfield",
            "axsecuretextfield",
        ]
        return editableRoles.contains(canonical)
    }

    /// Refreshes an element's bounds from the live AXUIElement when possible.
    /// This prevents elementID-based visibility checks from rejecting an element
    /// that moved on-screen after focus acquisition due to stale cached
    /// coordinates, while still keeping off-screen elements rejected.
    /// - Note: Internal for testing with @testable import.
    static func refreshBoundsIfPossible(
        element: Macosusesdk_V1_Element,
        axElement: AnyObject,
        system: SystemOperations,
    ) -> Macosusesdk_V1_Element {
        guard let positionValue = system.copyAXAttribute(
            element: axElement,
            attribute: kAXPositionAttribute as String,
        ), let sizeValue = system.copyAXAttribute(
            element: axElement,
            attribute: kAXSizeAttribute as String,
        ) else {
            // Fall back to the cached bounds if AX query fails.
            return element
        }

        let positionAXValue = positionValue as AnyObject
        let sizeAXValue = sizeValue as AnyObject
        var point = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(positionAXValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeAXValue) == AXValueGetTypeID()
        else {
            return element
        }
        let gotPoint = AXValueGetValue(
            unsafeDowncast(positionAXValue, to: AXValue.self), .cgPoint, &point,
        )
        let gotSize = AXValueGetValue(
            unsafeDowncast(sizeAXValue, to: AXValue.self), .cgSize, &size,
        )

        guard gotPoint, gotSize else {
            return element
        }

        var mutable = element
        mutable.x = Double(point.x)
        mutable.y = Double(point.y)
        mutable.width = Double(size.width)
        mutable.height = Double(size.height)
        return mutable
    }

    @MainActor
    func getElementActions(
        request: ServerRequest<Macosusesdk_V1_GetElementActionsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ElementActions> {
        let req = request.message
        Self.logger.info("getElementActions called")

        guard req.unknownFields.data.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "GetElementActionsRequest contains unknown fields",
                reason: "UNKNOWN_FIELD",
                field: "request",
            )
        }

        let resource = try await resolveApplicationChildResource(req.name, collection: "elements")

        // Resolve both the ephemeral element ID and its application owner.
        guard let element = await elementRegistry.getElement(
            resource.resourceID,
            expectedPID: resource.pid,
        ) else {
            throw RPCError(code: .notFound, message: "Element not found")
        }

        // Try to get actions from the injected AX boundary first.
        if let axElement = await elementRegistry.getAXElement(
            resource.resourceID,
            expectedPID: resource.pid,
        ) {
            if let actionsArray = system.copyAXAttribute(
                element: axElement as AnyObject,
                attribute: "AXActions",
            ) as? [String] {
                let response = Macosusesdk_V1_ElementActions.with {
                    $0.actions = actionsArray
                }
                return ServerResponse(message: response)
            }
        }

        // Fallback to role-based actions
        let actions = getActionsForRole(element.role)

        let response = Macosusesdk_V1_ElementActions.with {
            $0.actions = actions
        }
        return ServerResponse(message: response)
    }

    func performElementAction(
        request: ServerRequest<Macosusesdk_V1_PerformElementActionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_PerformElementActionResponse> {
        let req = request.message
        Self.logger.info("performElementAction called")

        // Validate action is not empty
        guard !req.action.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "action is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "action",
            )
        }

        let pid = try await resolveApplicationOrWindowParentPID(fromName: req.parent)
        let target = try Self.parseElementMutationTarget(req.target)
        let elementLocator = self.elementLocator
        let elementRegistry = self.elementRegistry
        let response = try await automationCoordinator.handlePhysicalMutation { context in
            let admitted = try await Self.resolveElementMutationTarget(
                target,
                parent: req.parent,
                expectedPID: pid,
                locator: elementLocator,
                context: context,
            )
            try await context.activateTarget(pid: pid)
            try await context.focusElementWindow(target: admitted)

            let exactTarget = try await context.resolveElement(
                id: admitted.elementID,
                expectedPID: pid,
                expectedScope: req.parent,
            )
            guard let axElement = exactTarget.axElement else {
                throw RPCError(code: .notFound, message: "Element reference not available")
            }
            let normalizedAction = req.action.lowercased()
            let actionName: String = switch normalizedAction {
            case "press", "click", "axpress":
                kAXPressAction as String
            case "showmenu", "openmenu", "axshowmenu":
                kAXShowMenuAction as String
            default:
                req.action
            }
            let performResult = context.system.performAXAction(
                element: axElement as AnyObject,
                action: actionName,
            )

            var element = Self.refreshBoundsIfPossible(
                element: exactTarget.element,
                axElement: axElement as AnyObject,
                system: context.system,
            )
            if performResult != AXError.success.rawValue {
                // A failed AX action is a precondition failure of the element
                // (the action does not apply in the element's current state),
                // not a server-internal error. Map the AXError to the closest
                // gRPC code and, for menu actions, point the caller at the
                // reliable physical alternative: a coordinate-based right click
                // (the click tool with button "right") after reading bounds via
                // read_element / get_element — kAXShowMenuAction is unsupported
                // by many elements, whereas a contextual-menu click always works.
                let isMenuAction = normalizedAction == "showmenu"
                    || normalizedAction == "openmenu"
                    || normalizedAction == "axshowmenu"
                let guidance = isMenuAction
                    ? "; this element does not support the AX menu action — read the element bounds (read_element/get_element) then use the 'click' tool with button 'right' to open a coordinate-based context menu"
                    : "; use click_element or a typed input tool for physical interactions"
                throw RPCError(
                    code: .failedPrecondition,
                    message: "AX action '\(req.action)' failed with AXError \(performResult)\(guidance)",
                )
            }

            element = Self.refreshBoundsIfPossible(
                element: element,
                axElement: axElement as AnyObject,
                system: context.system,
            )
            if let focused = context.system.copyAXAttribute(
                element: axElement as AnyObject,
                attribute: kAXFocusedAttribute as String,
            ) as? Bool {
                element.focused = focused
            }
            if let text = context.system.copyAXAttribute(
                element: axElement as AnyObject,
                attribute: kAXValueAttribute as String,
            ) as? String {
                element.text = text
            }
            guard await elementRegistry.updateElement(
                exactTarget.elementID,
                element: element,
                axElement: axElement,
            ) else {
                throw RPCError(code: .notFound, message: "Element expired before response readback")
            }

            return Macosusesdk_V1_PerformElementActionResponse.with {
                $0.success = true
                $0.element = element
            }
        }
        return ServerResponse(message: response)
    }

    func waitElement(
        request: ServerRequest<Macosusesdk_V1_WaitElementRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("waitElement called (LRO)")

        let timeout = try RequestNumericValidation.optionalTimeout(req.timeout, default: 30)
        let pollInterval = try RequestNumericValidation.optionalPollInterval(
            req.pollInterval,
            default: 0.5,
        )
        // Validate selector
        let selector = try SelectorParser.shared.parseSelector(req.selector)
        _ = try await resolveApplicationOrWindowParentPID(fromName: req.parent)

        // Create LRO
        let opName = "operations/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementMetadata"
            $0.value = try Macosusesdk_V1_WaitElementMetadata.with {
                $0.selector = selector
                $0.attempts = 0
            }.serializedData()
        }

        let op = try await operationStore.createOperation(
            name: opName,
            metadata: metadata,
            execution: { [operationStore, elementLocator] in
                do {
                    let endTime = Date().timeIntervalSince1970 + timeout
                    var attempts = 0

                    while Date().timeIntervalSince1970 < endTime {
                        try Task.checkCancellation()
                        attempts += 1

                        // Update metadata with attempt count
                        let updatedMetadata = Macosusesdk_V1_WaitElementMetadata.with {
                            $0.selector = selector
                            $0.attempts = Int32(attempts)
                        }
                        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
                            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementMetadata"
                            $0.value = try updatedMetadata.serializedData()
                        }
                        await operationStore.updateOperationMetadata(
                            name: opName,
                            metadata: metadata,
                        )

                        // Try to find the element
                        let elementsWithPaths = try await elementLocator.findElements(
                            selector: selector,
                            parent: req.parent,
                            visibleOnly: true,
                            maxResults: 2,
                        )

                        if elementsWithPaths.count > 1 {
                            await operationStore.failOperation(
                                name: opName,
                                code: Int32(RPCError.Code.failedPrecondition.rawValue),
                                message: "Selector matched multiple elements",
                            )
                            return
                        }
                        if let firstElement = elementsWithPaths.first {
                            // Element found! Complete the operation
                            // Element already has elementID from findElements() registration
                            var elementWithId = firstElement.element
                            elementWithId.path = firstElement.path

                            let response = Macosusesdk_V1_WaitElementResponse.with {
                                $0.element = elementWithId
                            }

                            try await operationStore.finishOperation(name: opName, responseMessage: response)
                            return
                        }

                        // Wait before next attempt
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    }

                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.deadlineExceeded.rawValue),
                        message: "Element did not appear within timeout",
                    )
                } catch is CancellationError {
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.cancelled.rawValue),
                        message: "Element wait cancelled",
                    )
                } catch let error as RPCError {
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(error.code.rawValue),
                        message: error.message,
                    )
                } catch {
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.internalError.rawValue),
                        message: "\(error)",
                    )
                }
            },
        )

        return ServerResponse(message: op)
    }

    func waitElementState(
        request: ServerRequest<Macosusesdk_V1_WaitElementStateRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("waitElementState called (LRO)")

        let timeout = try RequestNumericValidation.optionalTimeout(req.timeout, default: 30)
        let pollInterval = try RequestNumericValidation.optionalPollInterval(
            req.pollInterval,
            default: 0.5,
        )
        let pid = try await resolveApplicationOrWindowParentPID(fromName: req.parent)
        let initialElementWithPath: (
            element: Macosusesdk_V1_Element,
            path: [Int32],
        )

        switch req.target {
        case let .elementID(elementID):
            do {
                let target = try await elementRegistry.resolveElementForMutation(
                    elementID,
                    expectedPID: pid,
                    expectedScope: req.parent,
                )
                initialElementWithPath = (target.element, target.element.path)
            } catch let error as ElementMutationResolutionError {
                switch error {
                case .admissionClosed:
                    throw RPCError(code: .unavailable, message: "Element registry admission is closed")
                case .notFound:
                    throw RPCError(code: .notFound, message: "Element not found")
                case .ownerMismatch, .scopeMismatch:
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Element does not belong to the requested parent",
                    )
                }
            }

        case let .selector(selector):
            let parsedSelector = try SelectorParser.shared.parseSelector(selector)
            let matches = try await elementLocator.findElements(
                selector: parsedSelector,
                parent: req.parent,
                visibleOnly: false,
                maxResults: 2,
            )
            guard let match = matches.first else {
                throw RPCError(code: .notFound, message: "Element not found")
            }
            guard matches.count == 1 else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Selector matched multiple elements",
                )
            }
            initialElementWithPath = match

        case .none:
            throw RPCError(
                code: .invalidArgument, message: "Either element_id or selector must be specified",
            )
        }

        // Create LRO
        let opName = "operations/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementStateMetadata"
            $0.value = try Macosusesdk_V1_WaitElementStateMetadata.with {
                $0.condition = req.condition
                $0.attempts = 0
            }.serializedData()
        }

        let trackedElementId = initialElementWithPath.element.elementID
        guard !trackedElementId.isEmpty else {
            throw RPCError(code: .internalError, message: "Discovered element has no stable identity")
        }

        // Create the operation only after initial lookup succeeds, then atomically
        // retain the task that produces its terminal result.
        let op = try await operationStore.createOperation(
            name: opName,
            metadata: metadata,
            execution: { [operationStore, elementLocator] in
                do {
                    let endTime = Date().timeIntervalSince1970 + timeout
                    var attempts = 0

                    while Date().timeIntervalSince1970 < endTime {
                        try Task.checkCancellation()
                        attempts += 1

                        // Update metadata with attempt count
                        let updatedMetadata = Macosusesdk_V1_WaitElementStateMetadata.with {
                            $0.condition = req.condition
                            $0.attempts = Int32(attempts)
                        }
                        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
                            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementStateMetadata"
                            $0.value = try updatedMetadata.serializedData()
                        }
                        await operationStore.updateOperationMetadata(
                            name: opName,
                            metadata: metadata,
                        )

                        // Refresh the exact scope, then keep following only the
                        // same stable AX identity. A lookalike must never replace it.
                        let currentElementsWithPaths = try await elementLocator.refreshElements(
                            parent: req.parent,
                            visibleOnly: false,
                        )

                        guard let currentElementWithPath = currentElementsWithPaths.first(where: {
                            $0.element.elementID == trackedElementId
                        }) else {
                            // Element no longer exists
                            throw RPCError(code: .notFound, message: "Element no longer available")
                        }

                        let currentElement = currentElementWithPath.element

                        if self.elementMatchesCondition(currentElement, condition: req.condition) {
                            // Condition met! Complete the operation
                            var elementWithId = currentElement
                            elementWithId.elementID = trackedElementId
                            elementWithId.path = currentElementWithPath.path

                            let response = Macosusesdk_V1_WaitElementStateResponse.with {
                                $0.element = elementWithId
                            }

                            try await operationStore.finishOperation(name: opName, responseMessage: response)
                            return
                        }

                        // Wait before next attempt
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    }

                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.deadlineExceeded.rawValue),
                        message: "Element did not reach expected state within timeout",
                    )
                } catch is CancellationError {
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.cancelled.rawValue),
                        message: "Element state wait cancelled",
                    )
                } catch let error as RPCError {
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(error.code.rawValue),
                        message: error.message,
                    )
                } catch {
                    await operationStore.failOperation(
                        name: opName,
                        code: Int32(RPCError.Code.internalError.rawValue),
                        message: "\(error)",
                    )
                }
            },
        )

        return ServerResponse(message: op)
    }

    // MARK: - Element Click Coordinate Helpers

    /// Returns true if the element's geometric center lies on a connected
    /// display. This prevents physical mouse clicks at coordinates that are
    /// entirely off-screen in Global Display Coordinates.
    /// - Note: Internal for testing with @testable import.
    static func elementClickPointIsOnScreen(_ element: Macosusesdk_V1_Element) -> Bool {
        guard let center = try? elementClickPoint(element) else { return false }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        // A display containing the point means it is reachable. We intentionally
        // do not check the visible (menu/dock-excluded) rectangle here; that
        // is covered by the visibleOnly:true re-query used for selector-based
        // targets.
        return CGGetDisplaysWithPoint(center, 1, &displayID, &count) == .success && count > 0
    }

    /// Calculates the geometric center point of an element's bounds for clicking.
    /// The AX frame (kAXPositionAttribute + kAXSizeAttribute) provides top-left corner
    /// and dimensions. Clicking the geometric center maximizes hit area reliability.
    ///
    /// - Parameter element: The element to calculate the click point for.
    /// - Returns: A CGPoint at the geometric center of the element's bounds.
    /// - Throws: `RPCError` with `.failedPrecondition` if element has no position, zero size, or missing dimensions.
    static func elementClickPoint(_ element: Macosusesdk_V1_Element) throws -> CGPoint {
        guard element.hasX, element.hasY else {
            throw RPCError(code: .failedPrecondition, message: "Element has no position information")
        }
        guard element.hasWidth, element.hasHeight, element.width > 0, element.height > 0 else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Element has zero size (w=\(element.width), h=\(element.height)), cannot determine click position",
            )
        }
        let centerX = element.x + (element.width / 2)
        let centerY = element.y + (element.height / 2)
        return CGPoint(x: centerX, y: centerY)
    }
}
