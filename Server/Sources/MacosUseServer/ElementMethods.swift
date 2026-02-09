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
    func traverseAccessibility(
        request: ServerRequest<Macosusesdk_V1_TraverseAccessibilityRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_TraverseAccessibilityResponse> {
        let req = request.message
        Self.logger.info("traverseAccessibility called")
        let pid = try parsePID(fromName: req.name)
        let response = try await AutomationCoordinator.shared.handleTraverse(
            pid: pid, visibleOnly: req.visibleOnly, shouldActivate: req.activate,
        )
        return ServerResponse(message: response)
    }

    func watchAccessibility(
        request: ServerRequest<Macosusesdk_V1_WatchAccessibilityRequest>,
        context _: ServerContext,
    ) async throws -> StreamingServerResponse<Macosusesdk_V1_WatchAccessibilityResponse> {
        let req = request.message
        Self.logger.info("watchAccessibility called")

        let pid = try parsePID(fromName: req.name)
        // Clamp poll interval: min 0.1s, max 60s to prevent UInt64 overflow (UInt64.max / 1e9 ≈ 18s)
        let rawInterval = req.pollInterval > 0 ? req.pollInterval : 1.0
        let pollInterval = min(max(rawInterval, 0.1), 60.0)

        return StreamingServerResponse { writer in
            var previousByPath: [String: Macosusesdk_Type_Element] = [:]

            while !Task.isCancelled {
                do {
                    let trav = try await AutomationCoordinator.shared.handleTraverse(
                        pid: pid, visibleOnly: req.visibleOnly,
                    )

                    // Build current element map keyed by path
                    var currentByPath: [String: Macosusesdk_Type_Element] = [:]
                    for element in trav.elements {
                        let pathKey = Self.elementPathKey(element)
                        currentByPath[pathKey] = element
                    }

                    // Compute diff
                    var added: [Macosusesdk_Type_Element] = []
                    var removed: [Macosusesdk_Type_Element] = []
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
                    for (pathKey, previousElement) in previousByPath {
                        if currentByPath[pathKey] == nil {
                            removed.append(previousElement)
                        }
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
                } catch {
                    // send an empty heartbeat to keep client alive
                    _ = try? await writer.write(Macosusesdk_V1_WatchAccessibilityResponse())
                }

                // Sleep for interval, but allow task cancellation to stop
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }

            // Return trailing metadata
            return [:]
        }
    }

    /// Computes attribute changes between two elements.
    /// Returns an empty array if elements are identical.
    /// - Note: Internal for testing with @testable import.
    func computeElementChanges(
        old: Macosusesdk_Type_Element,
        new: Macosusesdk_Type_Element,
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
    static func elementPathKey(_ element: Macosusesdk_Type_Element) -> String {
        if element.path.isEmpty {
            // Fallback: use role + position + size to distinguish root-level elements
            // This handles edge cases where path is empty (e.g., root application element)
            // Use safeInt() to guard against NaN/Infinity which would crash Int()
            let x = safeInt(element.hasX ? element.x : 0)
            let y = safeInt(element.hasY ? element.y : 0)
            let w = safeInt(element.hasWidth ? element.width : 0)
            let h = safeInt(element.hasHeight ? element.height : 0)
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
        Self.logger.info("findElements called")

        // Validate and parse the selector
        let selector = try SelectorParser.shared.parseSelector(req.selector)

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100

        // Find elements using ElementLocator (request more than needed to check if there's a next page)
        let maxResults = offset + pageSize + 1 // Request one extra to detect next page
        let elementsWithPaths = try await ElementLocator.shared.findElements(
            selector: selector,
            parent: req.parent,
            visibleOnly: req.visibleOnly,
            maxResults: maxResults,
        )

        // Apply pagination slice
        let totalCount = elementsWithPaths.count
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageElementsWithPaths = Array(elementsWithPaths[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        // Build response elements - elements from ElementLocator are already registered
        // with their AXUIElement references preserved. Do NOT re-register them.
        var elements = [Macosusesdk_Type_Element]()
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
        Self.logger.info("findRegionElements called")

        // Validate selector if provided
        let selector =
            req.hasSelector ? try SelectorParser.shared.parseSelector(req.selector) : nil

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100

        // Find elements in region using ElementLocator (request more than needed to check if there's a next page)
        let maxResults = offset + pageSize + 1 // Request one extra to detect next page
        let elementsWithPaths = try await ElementLocator.shared.findElementsInRegion(
            region: req.region,
            selector: selector,
            parent: req.parent,
            visibleOnly: false, // Region search doesn't have visibleOnly parameter
            maxResults: maxResults,
        )

        // Apply pagination slice
        let totalCount = elementsWithPaths.count
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageElementsWithPaths = Array(elementsWithPaths[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        // Build response elements - elements from ElementLocator are already registered
        // with their AXUIElement references preserved. Do NOT re-register them.
        var elements = [Macosusesdk_Type_Element]()
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
    ) async throws -> ServerResponse<Macosusesdk_Type_Element> {
        let req = request.message
        Self.logger.info("getElement called")

        let response = try await ElementLocator.shared.getElement(name: req.name)
        return ServerResponse(message: response)
    }

    func clickElement(
        request: ServerRequest<Macosusesdk_V1_ClickElementRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ClickElementResponse> {
        let req = request.message
        Self.logger.info("clickElement called")

        let element: Macosusesdk_Type_Element
        let pid: pid_t

        // Find the element to click
        switch req.target {
        case let .elementID(elementId):
            // Get element by ID
            guard let foundElement = await ElementRegistry.shared.getElement(elementId) else {
                throw RPCError(code: .notFound, message: "Element not found")
            }
            element = foundElement
            pid = try parsePID(fromName: req.parent)

        case let .selector(selector):
            // Find element by selector
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await ElementLocator.shared.findElements(
                selector: validatedSelector,
                parent: req.parent,
                visibleOnly: true,
                maxResults: 1,
            )

            guard let firstElement = elementsWithPaths.first else {
                throw RPCError(code: .notFound, message: "No element found matching selector")
            }

            element = firstElement.element
            pid = try parsePID(fromName: req.parent)

        case .none:
            throw RPCError(
                code: .invalidArgument, message: "Either element_id or selector must be specified",
            )
        }

        // Get element position for clicking
        guard element.hasX, element.hasY else {
            throw RPCError(code: .failedPrecondition, message: "Element has no position information")
        }
        let x = element.x
        let y = element.y

        // Determine click type
        let clickType = req.clickType

        // Perform the click using AutomationCoordinator
        switch clickType {
        case .single, .unspecified, .UNRECOGNIZED:
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .click(
                        Macosusesdk_V1_MouseClick.with {
                            $0.position = Macosusesdk_Type_Point.with {
                                $0.x = x
                                $0.y = y
                            }
                            $0.clickType = .left
                            $0.clickCount = 1
                        },
                    )
                },
                pid: pid,
                showAnimation: false,
                animationDuration: 0,
            )

        case .double:
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .click(
                        Macosusesdk_V1_MouseClick.with {
                            $0.position = Macosusesdk_Type_Point.with {
                                $0.x = x
                                $0.y = y
                            }
                            $0.clickType = .left
                            $0.clickCount = 2
                        },
                    )
                },
                pid: pid,
                showAnimation: false,
                animationDuration: 0,
            )

        case .right:
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .click(
                        Macosusesdk_V1_MouseClick.with {
                            $0.position = Macosusesdk_Type_Point.with {
                                $0.x = x
                                $0.y = y
                            }
                            $0.clickType = .right
                            $0.clickCount = 1
                        },
                    )
                },
                pid: pid,
                showAnimation: false,
                animationDuration: 0,
            )
        }

        let response = Macosusesdk_V1_ClickElementResponse.with {
            $0.success = true
            $0.element = element
        }
        return ServerResponse(message: response)
    }

    func writeElementValue(
        request: ServerRequest<Macosusesdk_V1_WriteElementValueRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WriteElementValueResponse> {
        let req = request.message
        Self.logger.info("writeElementValue called")

        let element: Macosusesdk_Type_Element
        let pid: pid_t

        // Find the element to modify
        switch req.target {
        case let .elementID(elementId):
            guard let foundElement = await ElementRegistry.shared.getElement(elementId) else {
                throw RPCError(code: .notFound, message: "Element not found")
            }
            element = foundElement
            pid = try parsePID(fromName: req.parent)

        case let .selector(selector):
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await ElementLocator.shared.findElements(
                selector: validatedSelector,
                parent: req.parent,
                visibleOnly: true,
                maxResults: 1,
            )

            guard let firstElement = elementsWithPaths.first else {
                throw RPCError(code: .notFound, message: "No element found matching selector")
            }

            element = firstElement.element
            pid = try parsePID(fromName: req.parent)

        case .none:
            throw RPCError(
                code: .invalidArgument, message: "Either element_id or selector must be specified",
            )
        }

        // Get element position for typing
        guard element.hasX, element.hasY else {
            throw RPCError(code: .failedPrecondition, message: "Element has no position information")
        }
        let x = element.x
        let y = element.y

        // Click on the element first to focus it
        try await AutomationCoordinator.shared.handleExecuteInput(
            action: Macosusesdk_V1_InputAction.with {
                $0.inputType = .click(
                    Macosusesdk_V1_MouseClick.with {
                        $0.position = Macosusesdk_Type_Point.with {
                            $0.x = x
                            $0.y = y
                        }
                        $0.clickType = .left
                        $0.clickCount = 1
                    },
                )
            },
            pid: pid,
            showAnimation: false,
            animationDuration: 0,
        )

        // Type the value
        try await AutomationCoordinator.shared.handleExecuteInput(
            action: Macosusesdk_V1_InputAction.with {
                $0.inputType = .typeText(
                    Macosusesdk_V1_TextInput.with {
                        $0.text = req.value
                    },
                )
            },
            pid: pid,
            showAnimation: false,
            animationDuration: 0,
        )

        let response = Macosusesdk_V1_WriteElementValueResponse.with {
            $0.success = true
            $0.element = element
        }
        return ServerResponse(message: response)
    }

    @MainActor
    func getElementActions(
        request: ServerRequest<Macosusesdk_V1_GetElementActionsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ElementActions> {
        let req = request.message
        Self.logger.info("getElementActions called")

        // Parse element name to get element ID
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "elements"
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid element name format")
        }

        let elementId = components[3]

        // Get element from registry
        guard let element = await ElementRegistry.shared.getElement(elementId) else {
            throw RPCError(code: .notFound, message: "Element not found")
        }

        // Try to get actions from AXUIElement first
        if let axElement = await ElementRegistry.shared.getAXElement(elementId) {
            // Query the AXUIElement for its actions
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axElement, "AXActions" as CFString, &value) == .success
            else {
                // Fallback to role-based if query fails
                let actions = getActionsForRole(element.role)
                let response = Macosusesdk_V1_ElementActions.with { $0.actions = actions }
                return ServerResponse(message: response)
            }

            if let actionsArray = value as? [String] {
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

        let element: Macosusesdk_Type_Element
        let elementID: String
        let pid: pid_t

        // Find the element
        switch req.target {
        case let .elementID(id):
            guard let foundElement = await ElementRegistry.shared.getElement(id) else {
                throw RPCError(code: .notFound, message: "Element not found")
            }
            element = foundElement
            elementID = id
            pid = try parsePID(fromName: req.parent)

        case let .selector(selector):
            let validatedSelector = try SelectorParser.shared.parseSelector(selector)
            let elementsWithPaths = try await ElementLocator.shared.findElements(
                selector: validatedSelector,
                parent: req.parent,
                visibleOnly: true,
                maxResults: 1,
            )

            guard let firstElement = elementsWithPaths.first else {
                throw RPCError(code: .notFound, message: "No element found matching selector")
            }

            element = firstElement.element
            elementID = element.elementID
            pid = try parsePID(fromName: req.parent)

        case .none:
            throw RPCError(
                code: .invalidArgument, message: "Either element_id or selector must be specified",
            )
        }

        // Try to get the AXUIElement and perform semantic action (MUST run on MainActor)
        if let axElement = await ElementRegistry.shared.getAXElement(elementID) {
            let performResult = await MainActor.run { () -> AXError in
                let actionName: String = switch req.action.lowercased() {
                case "press", "click":
                    kAXPressAction as String
                case "showmenu", "openmenu":
                    kAXShowMenuAction as String
                default:
                    req.action
                }

                return AXUIElementPerformAction(axElement, actionName as CFString)
            }

            if performResult == .success {
                let response = Macosusesdk_V1_PerformElementActionResponse.with {
                    $0.success = true
                    $0.element = element
                }
                return ServerResponse(message: response)
            }

            // If action failed but element has position, fall through to coordinate-based fallback
            if !element.hasX || !element.hasY {
                throw RPCError(
                    code: .internalError,
                    message: "AX action failed: \(performResult.rawValue) and no position available for fallback",
                )
            }
        }

        // Fallback to coordinate-based simulation if AXUIElement is nil or action failed
        guard element.hasX, element.hasY else {
            throw RPCError(
                code: .failedPrecondition, message: "Element has no AXUIElement and no position for action",
            )
        }

        let x = element.x
        let y = element.y

        switch req.action.lowercased() {
        case "press", "click":
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .click(
                        Macosusesdk_V1_MouseClick.with {
                            $0.position = Macosusesdk_Type_Point.with {
                                $0.x = x
                                $0.y = y
                            }
                            $0.clickType = .left
                            $0.clickCount = 1
                        },
                    )
                },
                pid: pid,
                showAnimation: false,
                animationDuration: 0,
            )

        case "showmenu", "openmenu":
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: Macosusesdk_V1_InputAction.with {
                    $0.inputType = .click(
                        Macosusesdk_V1_MouseClick.with {
                            $0.position = Macosusesdk_Type_Point.with {
                                $0.x = x
                                $0.y = y
                            }
                            $0.clickType = .right
                            $0.clickCount = 1
                        },
                    )
                },
                pid: pid,
                showAnimation: false,
                animationDuration: 0,
            )

        default:
            throw RPCError(
                code: .unimplemented, message: "Action '\(req.action)' is not implemented",
            )
        }

        let response = Macosusesdk_V1_PerformElementActionResponse.with {
            $0.success = true
            $0.element = element
        }
        return ServerResponse(message: response)
    }

    func waitElement(
        request: ServerRequest<Macosusesdk_V1_WaitElementRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("waitElement called (LRO)")

        // Validate selector
        let selector = try SelectorParser.shared.parseSelector(req.selector)

        // Create LRO
        let opName = "operations/waitElement/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementMetadata"
            $0.value = try Macosusesdk_V1_WaitElementMetadata.with {
                $0.selector = selector
                $0.attempts = 0
            }.serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Start background task
        Task { [operationStore] in
            do {
                let timeout = req.timeout > 0 ? req.timeout : 30.0
                let pollInterval = req.pollInterval > 0 ? req.pollInterval : 0.5
                let endTime = Date().timeIntervalSince1970 + timeout
                var attempts = 0

                while Date().timeIntervalSince1970 < endTime {
                    attempts += 1

                    // Update metadata with attempt count
                    let updatedMetadata = Macosusesdk_V1_WaitElementMetadata.with {
                        $0.selector = selector
                        $0.attempts = Int32(attempts)
                    }
                    var updatedOp = await operationStore.getOperation(name: opName) ?? op
                    updatedOp.metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
                        $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementMetadata"
                        $0.value = try updatedMetadata.serializedData()
                    }
                    await operationStore.putOperation(updatedOp)

                    // Try to find the element
                    let elementsWithPaths = try await ElementLocator.shared.findElements(
                        selector: selector,
                        parent: req.parent,
                        visibleOnly: true,
                        maxResults: 1,
                    )

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

                // Timeout - mark operation as failed
                var failedOp = await operationStore.getOperation(name: opName) ?? op
                failedOp.done = true
                failedOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.deadlineExceeded.rawValue)
                    $0.message = "Element did not appear within timeout"
                }
                await operationStore.putOperation(failedOp)

            } catch {
                // Mark operation as failed
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }

    func waitElementState(
        request: ServerRequest<Macosusesdk_V1_WaitElementStateRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("waitElementState called (LRO)")

        // Store the original selector for re-running, or create one for elementId case
        let selectorToUse: Macosusesdk_Type_ElementSelector
        let pid: pid_t

        switch req.target {
        case let .elementID(elementID):
            guard let foundElement = await ElementRegistry.shared.getElement(elementID) else {
                throw RPCError(code: .notFound, message: "Element not found")
            }
            pid = try parsePID(fromName: req.parent)

            // Create a selector based on the element's stable attributes
            // This is a fallback - ideally we'd store the original selector
            selectorToUse = Macosusesdk_Type_ElementSelector.with {
                $0.criteria = .role(foundElement.role)
                // Add more criteria if available for uniqueness
                if foundElement.hasText, !foundElement.text.isEmpty {
                    $0.criteria = .compound(
                        Macosusesdk_Type_CompoundSelector.with {
                            $0.operator = .and
                            $0.selectors = [
                                Macosusesdk_Type_ElementSelector.with { $0.criteria = .role(foundElement.role) },
                                Macosusesdk_Type_ElementSelector.with { $0.criteria = .text(foundElement.text) },
                            ]
                        },
                    )
                }
            }

        case let .selector(selector):
            selectorToUse = try SelectorParser.shared.parseSelector(selector)
            pid = try parsePID(fromName: req.parent)

        case .none:
            throw RPCError(
                code: .invalidArgument, message: "Either element_id or selector must be specified",
            )
        }

        // Create LRO
        let opName = "operations/waitElementState/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementStateMetadata"
            $0.value = try Macosusesdk_V1_WaitElementStateMetadata.with {
                $0.condition = req.condition
                $0.attempts = 0
            }.serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Find the initial element
        let initialElementsWithPaths = try await ElementLocator.shared.findElements(
            selector: selectorToUse,
            parent: req.parent,
            visibleOnly: true,
            maxResults: 1,
        )

        guard let initialElementWithPath = initialElementsWithPaths.first else {
            throw RPCError(code: .notFound, message: "Element not found")
        }

        // Get or create element ID for tracking
        let trackedElementId: String = if !initialElementWithPath.element.elementID.isEmpty {
            initialElementWithPath.element.elementID
        } else {
            await ElementRegistry.shared.registerElement(
                initialElementWithPath.element,
                pid: pid,
            )
        }

        // Start background task
        Task { [operationStore] in
            do {
                let timeout = req.timeout > 0 ? req.timeout : 30.0
                let pollInterval = req.pollInterval > 0 ? req.pollInterval : 0.5
                let endTime = Date().timeIntervalSince1970 + timeout
                var attempts = 0

                while Date().timeIntervalSince1970 < endTime {
                    attempts += 1

                    // Update metadata with attempt count
                    let updatedMetadata = Macosusesdk_V1_WaitElementStateMetadata.with {
                        $0.condition = req.condition
                        $0.attempts = Int32(attempts)
                    }
                    var updatedOp = await operationStore.getOperation(name: opName) ?? op
                    updatedOp.metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
                        $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementStateMetadata"
                        $0.value = try updatedMetadata.serializedData()
                    }
                    await operationStore.putOperation(updatedOp)

                    // Re-acquire element using selector on each iteration to handle UI redraws
                    // This is the selector-based polling approach that is resilient to element invalidation
                    let currentElementsWithPaths = try await ElementLocator.shared.findElements(
                        selector: selectorToUse,
                        parent: req.parent,
                        visibleOnly: true,
                        maxResults: 1,
                    )

                    guard let currentElementWithPath = currentElementsWithPaths.first else {
                        // Element no longer exists
                        throw RPCError(code: .notFound, message: "Element no longer available")
                    }

                    let currentElement = currentElementWithPath.element

                    if elementMatchesCondition(currentElement, condition: req.condition) {
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

                // Timeout - mark operation as failed
                var failedOp = await operationStore.getOperation(name: opName) ?? op
                failedOp.done = true
                failedOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.deadlineExceeded.rawValue)
                    $0.message = "Element did not reach expected state within timeout"
                }
                await operationStore.putOperation(failedOp)

            } catch {
                // Mark operation as failed
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }
}
