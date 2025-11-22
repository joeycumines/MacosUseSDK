import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseSDK
import MacosUseSDKProtos
import OSLog
import SwiftProtobuf

/// This is the single, correct gRPC provider for the `MacosUse` service.
///
/// It implements the generated `Macosusesdk_V1_MacosUse.ServiceProtocol` protocol
/// and acts as the bridge between gRPC requests and the `AutomationCoordinator`.
final class MacosUseServiceProvider: Macosusesdk_V1_MacosUse.ServiceProtocol {
    static let logger = MacosUseSDK.sdkLogger(category: "MacosUseServiceProvider")
    let stateStore: AppStateStore
    let operationStore: OperationStore
    let windowRegistry: WindowRegistry

    init(stateStore: AppStateStore, operationStore: OperationStore, windowRegistry: WindowRegistry) {
        self.stateStore = stateStore
        self.operationStore = operationStore
        self.windowRegistry = windowRegistry
    }

    // MARK: - Helper Methods

    /// Resolve bundle ID from PID using NSRunningApplication.
    private func resolveBundleID(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Encode an offset into an opaque page token per AIP-158.
    /// The token is base64-encoded to prevent clients from relying on its structure.
    private func encodePageToken(offset: Int) -> String {
        let tokenString = "offset:\(offset)"
        return Data(tokenString.utf8).base64EncodedString()
    }

    /// Decode an opaque page token to retrieve the offset per AIP-158.
    /// Throws invalidArgument if the token is malformed.
    private func decodePageToken(_ token: String) throws -> Int {
        guard let data = Data(base64Encoded: token),
              let tokenString = String(data: data, encoding: .utf8)
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }

        let components = tokenString.split(separator: ":")
        guard components.count == 2, components[0] == "offset",
              let parsedOffset = Int(components[1]), parsedOffset >= 0
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }
        return parsedOffset
    }

    // MARK: - Application Methods

    func openApplication(
        request: ServerRequest<Macosusesdk_V1_OpenApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("openApplication called")

        Self.logger.info("openApplication called (LRO)")

        // Create an operation and return immediately
        let opName = "operations/open/\(UUID().uuidString)"

        // optional metadata could include the requested id
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.OpenApplicationMetadata"
            $0.value = try Macosusesdk_V1_OpenApplicationMetadata.with { $0.id = req.id }
                .serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Schedule actual open on background task (coordinator runs on @MainActor internally)
        Task { [operationStore, stateStore] in
            do {
                let app = try await AutomationCoordinator.shared.handleOpenApplication(
                    identifier: req.id)
                await stateStore.addTarget(app)

                let response = Macosusesdk_V1_OpenApplicationResponse.with {
                    $0.application = app
                }

                try await operationStore.finishOperation(name: opName, responseMessage: response)
            } catch {
                // mark operation as done with an error in the response's metadata
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = 13
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }

    func getApplication(
        request: ServerRequest<Macosusesdk_V1_GetApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Application> {
        let req = request.message
        Self.logger.info("getApplication called")
        let pid = try parsePID(fromName: req.name)
        guard let app = await stateStore.getTarget(pid: pid) else {
            throw RPCError(code: .notFound, message: "Application not found")
        }
        return ServerResponse(message: app)
    }

    func listApplications(
        request: ServerRequest<Macosusesdk_V1_ListApplicationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListApplicationsResponse> {
        let req = request.message
        Self.logger.info("listApplications called")
        let allApps = await stateStore.listTargets()

        // Sort by name for deterministic ordering
        let sortedApps = allApps.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedApps.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageApps = Array(sortedApps[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListApplicationsResponse.with {
            $0.applications = pageApps
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func deleteApplication(
        request: ServerRequest<Macosusesdk_V1_DeleteApplicationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        Self.logger.info("deleteApplication called")
        let pid = try parsePID(fromName: req.name)
        _ = await stateStore.removeTarget(pid: pid)
        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    // MARK: - Input Methods

    func createInput(request: ServerRequest<Macosusesdk_V1_CreateInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_Input>
    {
        let req = request.message
        Self.logger.info("createInput called")

        let inputId = req.inputID.isEmpty ? UUID().uuidString : req.inputID
        let pid: pid_t? = req.parent.isEmpty ? nil : try parsePID(fromName: req.parent)
        let name =
            req.parent.isEmpty ? "desktopInputs/\(inputId)" : "\(req.parent)/inputs/\(inputId)"

        let input = Macosusesdk_V1_Input.with {
            $0.name = name
            $0.action = req.input.action
            $0.state = .pending
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        }

        await stateStore.addInput(input)

        // Update to executing
        var executingInput = input
        executingInput.state = .executing
        await stateStore.addInput(executingInput)

        do {
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: req.input.action,
                pid: pid,
                showAnimation: req.input.action.showAnimation,
                animationDuration: req.input.action.animationDuration,
            )
            // Update to completed
            var completedInput = executingInput
            completedInput.state = .completed
            completedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(completedInput)
            return ServerResponse(message: completedInput)
        } catch {
            // Update to failed
            var failedInput = executingInput
            failedInput.state = .failed
            failedInput.error = error.localizedDescription
            failedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(failedInput)
            return ServerResponse(message: failedInput)
        }
    }

    func getInput(request: ServerRequest<Macosusesdk_V1_GetInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_Input>
    {
        let req = request.message
        Self.logger.info("getInput called")
        guard let input = await stateStore.getInput(name: req.name) else {
            throw RPCError(code: .notFound, message: "Input not found")
        }
        return ServerResponse(message: input)
    }

    func listInputs(request: ServerRequest<Macosusesdk_V1_ListInputsRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_ListInputsResponse>
    {
        let req = request.message
        Self.logger.info("listInputs called")
        let allInputs = await stateStore.listInputs(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedInputs = allInputs.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedInputs.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageInputs = Array(sortedInputs[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListInputsResponse.with {
            $0.inputs = pageInputs
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    // MARK: - Custom Methods

    func traverseAccessibility(
        request: ServerRequest<Macosusesdk_V1_TraverseAccessibilityRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_TraverseAccessibilityResponse> {
        let req = request.message
        Self.logger.info("traverseAccessibility called")
        let pid = try parsePID(fromName: req.name)
        let response = try await AutomationCoordinator.shared.handleTraverse(
            pid: pid, visibleOnly: req.visibleOnly,
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
        let pollInterval = req.pollInterval > 0 ? req.pollInterval : 1.0

        return StreamingServerResponse { writer in
            var previous: [Macosusesdk_Type_Element] = []

            while !Task.isCancelled {
                do {
                    let trav = try await AutomationCoordinator.shared.handleTraverse(
                        pid: pid, visibleOnly: req.visibleOnly,
                    )

                    // Naive diff: if previous empty, send all as added; otherwise send elements as modified
                    let resp = Macosusesdk_V1_WatchAccessibilityResponse.with {
                        if previous.isEmpty {
                            $0.added = trav.elements
                        } else {
                            $0.modified = trav.elements.map { element in
                                Macosusesdk_V1_ModifiedElement.with {
                                    $0.oldElement = Macosusesdk_Type_Element()
                                    $0.newElement = element
                                }
                            }
                        }
                    }

                    try await writer.write(resp)
                    previous = trav.elements
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

    // MARK: - Window Methods

    func getWindow(
        request: ServerRequest<Macosusesdk_V1_GetWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("getWindow called for \(req.name, privacy: .private)")
        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/")
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        // CRITICAL FIX: ALWAYS use AX data for bounds (never fall back to stale CGWindowList).
        // This ensures GetWindow returns fresh geometry immediately after mutations (MoveWindow, ResizeWindow).
        // The "split-brain" model mandates: AX is authority for geometry, Registry is authority for metadata.
        let axWindow = try await findWindowElement(pid: pid, windowId: windowId)
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: axWindow, registryInfo: nil)
    }

    func listWindows(
        request: ServerRequest<Macosusesdk_V1_ListWindowsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListWindowsResponse> {
        let req = request.message
        Self.logger.info("listWindows called")

        // Parse "applications/{pid}"
        let pid = try parsePID(fromName: req.parent)

        try await windowRegistry.refreshWindows(forPID: pid)
        let windowInfos = try await windowRegistry.listWindows(forPID: pid)

        // Sort by window ID for deterministic ordering
        let sortedWindowInfos = windowInfos.sorted { $0.windowID < $1.windowID }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedWindowInfos.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageWindowInfos = Array(sortedWindowInfos[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        // Build window list from registry data only - NO per-window AX queries
        // This returns fast, registry-only data (CoreGraphics only).
        // Clients MUST use GetWindowState for expensive AX queries (modal, minimizable, etc.).
        //
        // PERFORMANCE: This eliminates the O(N*M) catastrophe where N windows each
        // triggered M blocking AX queries. ListWindows now completes in <50ms regardless
        // of window count.
        let windows = pageWindowInfos.map { windowInfo in
            Macosusesdk_V1_Window.with {
                $0.name = "applications/\(pid)/windows/\(windowInfo.windowID)"
                $0.title = windowInfo.title
                $0.bounds = Macosusesdk_V1_Bounds.with {
                    $0.x = windowInfo.bounds.origin.x
                    $0.y = windowInfo.bounds.origin.y
                    $0.width = windowInfo.bounds.size.width
                    $0.height = windowInfo.bounds.size.height
                }
                $0.zIndex = Int32(windowInfo.layer)
                $0.visible = windowInfo.isOnScreen
                $0.bundleID = windowInfo.bundleID ?? ""
            }
        }

        let response = Macosusesdk_V1_ListWindowsResponse.with {
            $0.windows = windows
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func getWindowState(
        request: ServerRequest<Macosusesdk_V1_GetWindowStateRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WindowState> {
        let req = request.message
        Self.logger.info("getWindowState called for \(req.name, privacy: .private)")

        // Parse "applications/{pid}/windows/{windowId}/state"
        let components = req.name.split(separator: "/")
        guard components.count == 5,
              components[0] == "applications",
              components[2] == "windows",
              components[4] == "state",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window state name format")
        }

        // Find the window via AX API
        let axWindow = try await findWindowElement(pid: pid, windowId: windowId)

        // Build complete WindowState from AX queries
        let state = try await buildWindowStateFromAX(window: axWindow)

        // Set the resource name
        var response = state
        response.name = req.name

        return ServerResponse(message: response)
    }

    func focusWindow(
        request: ServerRequest<Macosusesdk_V1_FocusWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("focusWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let windowToFocus = try await findWindowElement(pid: pid, windowId: windowId)

        // Set kAXMainAttribute to true to focus the window
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) {
            let mainResult = AXUIElementSetAttributeValue(
                windowToFocus, kAXMainAttribute as CFString, kCFBooleanTrue,
            )
            guard mainResult == .success else {
                throw RPCError(code: .internalError, message: "Failed to focus window")
            }
        }.value

        // Return updated window state
        return try await getWindow(
            request: ServerRequest(metadata: request.metadata, message: Macosusesdk_V1_GetWindowRequest.with { $0.name = req.name }), context: context,
        )
    }

    func moveWindow(
        request: ServerRequest<Macosusesdk_V1_MoveWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("moveWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Create AXValue and set position
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) {
            var newPosition = CGPoint(x: req.x, y: req.y)
            guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else {
                throw RPCError(code: .internalError, message: "Failed to create position value")
            }

            let setResult = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, positionValue,
            )
            guard setResult == .success else {
                throw RPCError(
                    code: .internalError, message: "Failed to move window: \(setResult.rawValue)",
                )
            }
        }.value

        // CRITICAL FIX: Refresh and fetch registry metadata BEFORE invalidation (nil registry bug fix)
        try await windowRegistry.refreshWindows(forPID: pid)
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Invalidate cache to ensure subsequent reads reflect the new position immediately
        await windowRegistry.invalidate(windowID: windowId)

        // Build response directly from AXUIElement (CGWindowList may be stale)
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: window, registryInfo: registryInfo)
    }

    func resizeWindow(
        request: ServerRequest<Macosusesdk_V1_ResizeWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("resizeWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Create AXValue, set size, and verify
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) {
            var newSize = CGSize(width: req.width, height: req.height)
            guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
                throw RPCError(code: .internalError, message: "Failed to create size value")
            }

            let setResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            guard setResult == .success else {
                throw RPCError(
                    code: .internalError, message: "Failed to resize window: \(setResult.rawValue)",
                )
            }

            // Verify AX actually applied the change
            var verifyValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &verifyValue)
                == .success,
                let unwrappedValue = verifyValue,
                CFGetTypeID(unwrappedValue) == AXValueGetTypeID()
            {
                let size = unsafeDowncast(unwrappedValue, to: AXValue.self)
                var actualSize = CGSize.zero
                if AXValueGetValue(size, .cgSize, &actualSize) {
                    Self.logger.info("After resize: requested=\(req.width, privacy: .public)x\(req.height, privacy: .public), actual=\(actualSize.width, privacy: .public)x\(actualSize.height, privacy: .public)")
                }
            }
        }.value

        // CRITICAL FIX: Refresh and fetch registry metadata BEFORE invalidation (nil registry bug fix)
        try await windowRegistry.refreshWindows(forPID: pid)
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Invalidate cache to ensure subsequent reads reflect the new size immediately
        await windowRegistry.invalidate(windowID: windowId)

        // Build response directly from AXUIElement (CGWindowList may be stale)
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: window, registryInfo: registryInfo)
    }

    func minimizeWindow(
        request: ServerRequest<Macosusesdk_V1_MinimizeWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("minimizeWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Set kAXMinimizedAttribute to true
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) {
            let setResult = AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanTrue,
            )
            guard setResult == .success else {
                throw RPCError(
                    code: .internalError, message: "Failed to minimize window: \(setResult.rawValue)",
                )
            }
        }.value

        // CRITICAL: AX state propagation is async - poll until minimized=true
        // This prevents race condition where we return stale state
        let startTime = Date()
        let timeout = 2.0 // 2 second timeout
        while Date().timeIntervalSince(startTime) < timeout {
            let isMinimized = await MainActor.run { () -> Bool in
                var verifyValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &verifyValue) == .success,
                   let isMinimizedValue = verifyValue as? Bool
                {
                    return isMinimizedValue
                }
                return false
            }
            if isMinimized {
                Self.logger.debug("[minimizeWindow] Verified minimized=true after \(Date().timeIntervalSince(startTime) * 1000, privacy: .public)ms")
                break
            }
            // Small yield to allow AX system to propagate change
            try? await Task.sleep(for: .milliseconds(10))
        }

        // CRITICAL FIX: Refresh and fetch registry metadata BEFORE invalidation
        try await windowRegistry.refreshWindows(forPID: pid)
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Invalidate cache to ensure subsequent reads reflect the new minimized state immediately
        await windowRegistry.invalidate(windowID: windowId)

        // Build response directly from AXUIElement
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: window, registryInfo: registryInfo)
    }

    func restoreWindow(
        request: ServerRequest<Macosusesdk_V1_RestoreWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("restoreWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        // CRITICAL FIX: Minimized windows vanish from kAXWindowsAttribute but remain in kAXChildrenAttribute
        let window = try await findWindowElementWithMinimizedFallback(pid: pid, windowId: windowId)

        // Set kAXMinimizedAttribute to false
        // CRITICAL FIX: AX set operations are thread-safe and should NOT block MainActor
        try await Task.detached(priority: .userInitiated) {
            let setResult = AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanFalse,
            )
            guard setResult == .success else {
                throw RPCError(
                    code: .internalError, message: "Failed to restore window: \(setResult.rawValue)",
                )
            }
        }.value

        // CRITICAL: AX state propagation is async - poll until minimized=false
        // This prevents race condition where we return stale state
        let startTime = Date()
        let timeout = 2.0 // 2 second timeout
        while Date().timeIntervalSince(startTime) < timeout {
            let isMinimized = await MainActor.run { () -> Bool in
                var verifyValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &verifyValue) == .success,
                   let isMinimizedValue = verifyValue as? Bool
                {
                    return isMinimizedValue
                }
                return false
            }
            if !isMinimized {
                Self.logger.debug("[restoreWindow] Verified minimized=false after \(Date().timeIntervalSince(startTime) * 1000, privacy: .public)ms")
                break
            }
            // Small yield to allow AX system to propagate change
            try? await Task.sleep(for: .milliseconds(10))
        }

        // CRITICAL FIX: Refresh registry AFTER restore to get updated isOnScreen value
        // (CGWindowList updates when window becomes visible again)
        try await windowRegistry.refreshWindows(forPID: pid)
        let registryInfo = await windowRegistry.getLastKnownWindow(windowId)

        // Invalidate cache to ensure subsequent reads reflect the restored state immediately
        await windowRegistry.invalidate(windowID: windowId)

        // Build response directly from AXUIElement (AFTER restore operation)
        return try await buildWindowResponseFromAX(name: req.name, pid: pid, windowId: windowId, window: window, registryInfo: registryInfo)
    }

    func closeWindow(
        request: ServerRequest<Macosusesdk_V1_CloseWindowRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CloseWindowResponse> {
        let req = request.message
        Self.logger.info("closeWindow called")

        // Parse "applications/{pid}/windows/{windowId}"
        let components = req.name.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowId = CGWindowID(components[3])
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid window name format")
        }

        let window = try await findWindowElement(pid: pid, windowId: windowId)

        // Get close button and press it (MUST run on MainActor)
        try await MainActor.run {
            var closeButtonValue: CFTypeRef?
            let closeResult = AXUIElementCopyAttributeValue(
                window, kAXCloseButtonAttribute as CFString, &closeButtonValue,
            )
            guard closeResult == .success,
                  let unwrappedCloseButtonValue = closeButtonValue,
                  CFGetTypeID(unwrappedCloseButtonValue) == AXUIElementGetTypeID()
            else {
                throw RPCError(code: .internalError, message: "Failed to get close button")
            }

            let closeButton = unsafeDowncast(unwrappedCloseButtonValue, to: AXUIElement.self)

            let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            guard pressResult == .success else {
                throw RPCError(
                    code: .internalError, message: "Failed to close window: \(pressResult.rawValue)",
                )
            }
        }

        return ServerResponse(message: Macosusesdk_V1_CloseWindowResponse())
    }

    // MARK: - Element Methods

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

        // Convert to proto elements and register them
        var elements = [Macosusesdk_Type_Element]()
        let pid = try parsePID(fromName: req.parent)
        for (element, path) in pageElementsWithPaths {
            let protoElement = element
            // Generate and assign element ID
            let elementId = await ElementRegistry.shared.registerElement(protoElement, pid: pid)
            var protoWithId = protoElement
            protoWithId.elementID = elementId
            protoWithId.path = path
            elements.append(protoWithId)
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

        // Convert to proto elements and register them
        var elements = [Macosusesdk_Type_Element]()
        let pid = try parsePID(fromName: req.parent)
        for (element, path) in pageElementsWithPaths {
            let protoElement = element
            // Generate and assign element ID
            let elementId = await ElementRegistry.shared.registerElement(protoElement, pid: pid)
            var protoWithId = protoElement
            protoWithId.elementID = elementId
            protoWithId.path = path
            elements.append(protoWithId)
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
                        })
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
                        })
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
                        })
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
                    })
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
                    })
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
                        })
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
                        })
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
                        var elementWithId = firstElement.element
                        let elementId = try await ElementRegistry.shared.registerElement(
                            elementWithId, pid: parsePID(fromName: req.parent),
                        )
                        elementWithId.elementID = elementId
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
                        })
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

    // MARK: - Observation Methods

    func createObservation(
        request: ServerRequest<Macosusesdk_V1_CreateObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("createObservation called (LRO)")

        // Parse parent resource name to get PID
        let pid = try parsePID(fromName: req.parent)

        // Generate observation ID
        let observationId =
            req.observationID.isEmpty ? UUID().uuidString : req.observationID
        let observationName = "\(req.parent)/observations/\(observationId)"

        // Create operation for LRO
        let opName = "operations/observation/\(observationId)"

        // Create initial observation in ObservationManager
        let observation = await ObservationManager.shared.createObservation(
            name: observationName,
            type: req.observation.type,
            parent: req.parent,
            filter: req.observation.hasFilter ? req.observation.filter : nil,
            pid: pid,
        )

        // Create metadata
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.Observation"
            $0.value = try observation.serializedData()
        }

        // Create LRO
        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Start observation in background
        Task { [operationStore] in
            do {
                // Start the observation
                try await ObservationManager.shared.startObservation(name: observationName)

                // Get updated observation
                guard
                    let startedObservation = await ObservationManager.shared.getObservation(
                        name: observationName)
                else {
                    throw RPCError(code: .internalError, message: "Failed to start observation")
                }

                // Mark operation as done with observation in response
                try await operationStore.finishOperation(name: opName, responseMessage: startedObservation)

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

    func getObservation(
        request: ServerRequest<Macosusesdk_V1_GetObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Observation> {
        let req = request.message
        Self.logger.info("getObservation called")

        // Get observation from ObservationManager
        guard let observation = await ObservationManager.shared.getObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func listObservations(
        request: ServerRequest<Macosusesdk_V1_ListObservationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListObservationsResponse> {
        let req = request.message
        Self.logger.info("listObservations called")

        // List observations for parent
        let allObservations = await ObservationManager.shared.listObservations(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedObservations = allObservations.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedObservations.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageObservations = Array(sortedObservations[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListObservationsResponse.with {
            $0.observations = pageObservations
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func cancelObservation(
        request: ServerRequest<Macosusesdk_V1_CancelObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Observation> {
        let req = request.message
        Self.logger.info("cancelObservation called")

        // Cancel observation in ObservationManager
        guard
            let observation = await ObservationManager.shared.cancelObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func streamObservations(
        request: ServerRequest<Macosusesdk_V1_StreamObservationsRequest>,
        context _: ServerContext,
    ) async throws -> StreamingServerResponse<Macosusesdk_V1_StreamObservationsResponse> {
        let req = request.message
        Self.logger.info("streamObservations called (streaming)")

        // Verify observation exists
        guard await ObservationManager.shared.getObservation(name: req.name) != nil else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        // Create event stream
        guard let eventStream = await ObservationManager.shared.createEventStream(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Failed to create event stream")
        }

        return StreamingServerResponse { writer async in
            // Stream events to client
            // NOTE: The for-await-in loop will suspend and yield control, allowing the gRPC
            // executor to handle this task cooperatively with others.
            for await event in eventStream {
                // Check if client disconnected
                if Task.isCancelled {
                    Self.logger.info("client disconnected from observation stream")
                    break
                }

                // Send event to client
                let response = Macosusesdk_V1_StreamObservationsResponse.with {
                    $0.event = event
                }

                do {
                    try await writer.write(response)
                } catch {
                    break
                }
            }

            // Return trailing metadata after stream completes
            return [:]
        }
    }

    // MARK: - Session Methods

    func createSession(
        request: ServerRequest<Macosusesdk_V1_CreateSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Session> {
        let req = request.message
        Self.logger.info("createSession called")

        // Extract session parameters from request
        let sessionId = req.sessionID.isEmpty ? nil : req.sessionID
        let displayName =
            req.session.displayName.isEmpty ? "Unnamed Session" : req.session.displayName
        let metadata = req.session.metadata

        // Create session in SessionManager
        let session = await SessionManager.shared.createSession(
            sessionId: sessionId,
            displayName: displayName,
            metadata: metadata,
        )

        return ServerResponse(message: session)
    }

    func getSession(
        request: ServerRequest<Macosusesdk_V1_GetSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Session> {
        let req = request.message
        Self.logger.info("getSession called")

        // Get session from SessionManager
        guard let session = await SessionManager.shared.getSession(name: req.name) else {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: session)
    }

    func listSessions(
        request: ServerRequest<Macosusesdk_V1_ListSessionsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListSessionsResponse> {
        let req = request.message
        Self.logger.info("listSessions called")

        // List sessions from SessionManager with pagination
        let pageSize = Int(req.pageSize)
        let pageToken = req.pageToken.isEmpty ? nil : req.pageToken

        let (sessions, nextToken) = await SessionManager.shared.listSessions(
            pageSize: pageSize,
            pageToken: pageToken,
        )

        let response = Macosusesdk_V1_ListSessionsResponse.with {
            $0.sessions = sessions
            $0.nextPageToken = nextToken ?? ""
        }
        return ServerResponse(message: response)
    }

    func deleteSession(
        request: ServerRequest<Macosusesdk_V1_DeleteSessionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        let req = request.message
        Self.logger.info("deleteSession called")

        // Delete session from SessionManager
        let deleted = await SessionManager.shared.deleteSession(name: req.name)

        if !deleted {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: SwiftProtobuf.Google_Protobuf_Empty())
    }

    func beginTransaction(
        request: ServerRequest<Macosusesdk_V1_BeginTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_BeginTransactionResponse> {
        let req = request.message
        Self.logger.info("beginTransaction called")

        do {
            // Begin transaction in SessionManager
            let isolationLevel =
                req.isolationLevel == .unspecified ? .serializable : req.isolationLevel
            let timeout = req.timeout > 0 ? req.timeout : 300.0

            let (transactionId, session) = try await SessionManager.shared.beginTransaction(
                sessionName: req.session,
                isolationLevel: isolationLevel,
                timeout: timeout,
            )

            let response = Macosusesdk_V1_BeginTransactionResponse.with {
                $0.transactionID = transactionId
                $0.session = session
            }
            return ServerResponse(message: response)
        } catch let error as SessionError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to begin transaction: \(error)")
        }
    }

    func commitTransaction(
        request: ServerRequest<Macosusesdk_V1_CommitTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Transaction> {
        let req = request.message
        Self.logger.info("commitTransaction called")

        do {
            // Commit transaction in SessionManager
            let transaction = try await SessionManager.shared
                .commitTransaction(
                    sessionName: req.name,
                    transactionId: req.transactionID,
                )

            return ServerResponse(message: transaction)
        } catch let error as SessionError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to commit transaction: \(error)")
        }
    }

    func rollbackTransaction(
        request: ServerRequest<Macosusesdk_V1_RollbackTransactionRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Transaction> {
        let req = request.message
        Self.logger.info("rollbackTransaction called")

        do {
            // Rollback transaction in SessionManager
            let transaction = try await SessionManager.shared
                .rollbackTransaction(
                    sessionName: req.name,
                    transactionId: req.transactionID,
                    revisionId: req.revisionID,
                )

            return ServerResponse(message: transaction)
        } catch let error as SessionError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to rollback transaction: \(error)")
        }
    }

    func getSessionSnapshot(
        request: ServerRequest<Macosusesdk_V1_GetSessionSnapshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_SessionSnapshot> {
        let req = request.message
        Self.logger.info("getSessionSnapshot called")

        // Get session snapshot from SessionManager
        guard let snapshot = await SessionManager.shared.getSessionSnapshot(sessionName: req.name)
        else {
            throw RPCError(code: .notFound, message: "Session not found: \(req.name)")
        }

        return ServerResponse(message: snapshot)
    }

    // MARK: - Screenshot Methods

    func captureScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureScreenshot] Capturing screen screenshot")

        // Determine display ID (0 = main display, nil = all displays)
        let displayID: CGDirectDisplayID? =
            req.display > 0
                ? CGDirectDisplayID(req.display)
                : nil

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture screen
        let result = try await ScreenshotCapture.captureScreen(
            displayID: displayID,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) screenshot")
        return ServerResponse(message: response)
    }

    func captureWindowScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureWindowScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureWindowScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureWindowScreenshot] Capturing window screenshot")

        // Parse window resource name: applications/{pid}/windows/{windowId}
        let components = req.window.split(separator: "/")
        guard components.count == 4,
              components[0] == "applications",
              components[2] == "windows",
              let pid = pid_t(components[1]),
              let windowIdInt = Int(components[3])
        else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid window resource name: \(req.window)",
            )
        }

        // Find window in registry
        try await windowRegistry.refreshWindows(forPID: pid)
        let windowInfo = try await windowRegistry.listWindows(forPID: pid).first {
            $0.windowID == CGWindowID(windowIdInt)
        }

        guard let windowInfo else {
            throw RPCError(
                code: .notFound,
                message: "Window not found: \(req.window)",
            )
        }

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture window
        let result = try await ScreenshotCapture.captureWindow(
            windowID: windowInfo.windowID,
            includeShadow: req.includeShadow,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureWindowScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        response.window = req.window
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureWindowScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) window screenshot")
        return ServerResponse(message: response)
    }

    func captureElementScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureElementScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureElementScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureElementScreenshot] Capturing element screenshot")

        // Get element from registry
        guard let element = await ElementRegistry.shared.getElement(req.elementID) else {
            throw RPCError(
                code: .notFound,
                message: "Element not found: \(req.elementID)",
            )
        }

        // Check element has bounds (x, y, width, height)
        guard element.hasX, element.hasY, element.hasWidth, element.hasHeight else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Element has no bounds: \(req.elementID)",
            )
        }

        // Apply padding if specified
        let padding = CGFloat(req.padding)
        let bounds = CGRect(
            x: element.x - padding,
            y: element.y - padding,
            width: element.width + (padding * 2),
            height: element.height + (padding * 2),
        )

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture element region
        let result = try await ScreenshotCapture.captureRegion(
            bounds: bounds,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureElementScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        response.elementID = req.elementID
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureElementScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) element screenshot")
        return ServerResponse(message: response)
    }

    func captureRegionScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureRegionScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureRegionScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureRegionScreenshot] Capturing region screenshot")

        // Validate region
        guard req.hasRegion else {
            throw RPCError(
                code: .invalidArgument,
                message: "Region is required",
            )
        }

        // Convert proto Region to CGRect
        let bounds = CGRect(
            x: req.region.x,
            y: req.region.y,
            width: req.region.width,
            height: req.region.height,
        )

        // Determine display ID (for multi-monitor setups)
        let displayID: CGDirectDisplayID? =
            req.display > 0
                ? CGDirectDisplayID(req.display)
                : nil

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture region
        let result = try await ScreenshotCapture.captureRegion(
            bounds: bounds,
            displayID: displayID,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureRegionScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureRegionScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) region screenshot")
        return ServerResponse(message: response)
    }

    // MARK: - Clipboard Methods

    func getClipboard(
        request: ServerRequest<Macosusesdk_V1_GetClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Clipboard> {
        let req = request.message
        Self.logger.info("getClipboard called")

        // Validate resource name (singleton: "clipboard")
        guard req.name == "clipboard" else {
            throw RPCError(code: .invalidArgument, message: "Invalid clipboard name: \(req.name)")
        }

        let response = await ClipboardManager.shared.readClipboard()
        return ServerResponse(message: response)
    }

    func writeClipboard(
        request: ServerRequest<Macosusesdk_V1_WriteClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WriteClipboardResponse> {
        let req = request.message
        Self.logger.info("writeClipboard called")

        // Validate content
        guard req.hasContent else {
            throw RPCError(code: .invalidArgument, message: "Content is required")
        }

        do {
            // Write to clipboard
            let clipboard = try await ClipboardManager.shared.writeClipboard(
                content: req.content,
                clearExisting: req.clearExisting_p,
            )

            let response = Macosusesdk_V1_WriteClipboardResponse.with {
                $0.success = true
                $0.type = clipboard.content.type
            }
            return ServerResponse(message: response)
        } catch let error as ClipboardError {
            throw RPCError(code: .internalError, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to write clipboard: \(error)")
        }
    }

    func clearClipboard(
        request: ServerRequest<Macosusesdk_V1_ClearClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ClearClipboardResponse> {
        _ = request.message
        Self.logger.info("clearClipboard called")

        await ClipboardManager.shared.clearClipboard()

        let response = Macosusesdk_V1_ClearClipboardResponse.with {
            $0.success = true
        }
        return ServerResponse(message: response)
    }

    func getClipboardHistory(
        request: ServerRequest<Macosusesdk_V1_GetClipboardHistoryRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ClipboardHistory> {
        let req = request.message
        Self.logger.info("getClipboardHistory called")

        // Validate resource name (singleton: "clipboard/history")
        guard req.name == "clipboard/history" else {
            throw RPCError(
                code: .invalidArgument, message: "Invalid clipboard history name: \(req.name)",
            )
        }

        let response = await ClipboardHistoryManager.shared.getHistory()
        return ServerResponse(message: response)
    }

    // MARK: - File Dialog Methods

    func automateOpenFileDialog(
        request: ServerRequest<Macosusesdk_V1_AutomateOpenFileDialogRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_AutomateOpenFileDialogResponse> {
        let req = request.message
        Self.logger.info("automateOpenFileDialog called")

        do {
            let selectedPaths = try await FileDialogAutomation.shared.automateOpenFileDialog(
                filePath: req.filePath.isEmpty ? nil : req.filePath,
                defaultDirectory: req.defaultDirectory.isEmpty ? nil : req.defaultDirectory,
                fileFilters: req.fileFilters,
                allowMultiple: req.allowMultiple,
            )

            let response = Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
                $0.success = true
                $0.selectedPaths = selectedPaths
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
                $0.success = false
                $0.error = "Failed to automate open file dialog: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func automateSaveFileDialog(
        request: ServerRequest<Macosusesdk_V1_AutomateSaveFileDialogRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_AutomateSaveFileDialogResponse> {
        let req = request.message
        Self.logger.info("automateSaveFileDialog called")

        do {
            let savedPath = try await FileDialogAutomation.shared.automateSaveFileDialog(
                filePath: req.filePath,
                defaultDirectory: req.defaultDirectory.isEmpty ? nil : req.defaultDirectory,
                defaultFilename: req.defaultFilename.isEmpty ? nil : req.defaultFilename,
                confirmOverwrite: req.confirmOverwrite,
            )

            let response = Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
                $0.success = true
                $0.savedPath = savedPath
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
                $0.success = false
                $0.error = "Failed to automate save file dialog: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func selectFile(
        request: ServerRequest<Macosusesdk_V1_SelectFileRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_SelectFileResponse> {
        let req = request.message
        Self.logger.info("selectFile called")

        do {
            let selectedPath = try await FileDialogAutomation.shared.selectFile(
                filePath: req.filePath,
                revealInFinder: req.revealFinder,
            )

            let response = Macosusesdk_V1_SelectFileResponse.with {
                $0.success = true
                $0.selectedPath = selectedPath
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_SelectFileResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_SelectFileResponse.with {
                $0.success = false
                $0.error = "Failed to select file: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func selectDirectory(
        request: ServerRequest<Macosusesdk_V1_SelectDirectoryRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_SelectDirectoryResponse> {
        let req = request.message
        Self.logger.info("selectDirectory called")

        do {
            let (selectedPath, wasCreated) = try await FileDialogAutomation.shared.selectDirectory(
                directoryPath: req.directoryPath,
                createMissing: req.createMissing,
            )

            let response = Macosusesdk_V1_SelectDirectoryResponse.with {
                $0.success = true
                $0.selectedPath = selectedPath
                $0.created = wasCreated
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_SelectDirectoryResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_SelectDirectoryResponse.with {
                $0.success = false
                $0.error = "Failed to select directory: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func dragFiles(
        request: ServerRequest<Macosusesdk_V1_DragFilesRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_DragFilesResponse> {
        Self.logger.info("dragFiles called")
        let req = request.message

        // Validate inputs
        guard !req.filePaths.isEmpty else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "At least one file path is required"
            }
            return ServerResponse(message: response)
        }

        guard !req.targetElementID.isEmpty else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Target element ID is required"
            }
            return ServerResponse(message: response)
        }

        // Get target element from registry
        guard let targetElement = await ElementRegistry.shared.getElement(req.targetElementID)
        else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Target element not found: \(req.targetElementID)"
            }
            return ServerResponse(message: response)
        }

        // Ensure element has position
        guard targetElement.hasX, targetElement.hasY else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Target element has no position information"
            }
            return ServerResponse(message: response)
        }

        let targetPoint = CGPoint(x: targetElement.x, y: targetElement.y)
        let duration = req.duration > 0 ? req.duration : 0.5

        do {
            try await FileDialogAutomation.shared.dragFilesToElement(
                filePaths: req.filePaths,
                targetElement: targetPoint,
                duration: duration,
            )

            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = true
                $0.filesDropped = Int32(req.filePaths.count)
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Failed to drag files: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    // MARK: - Macro Methods

    func createMacro(
        request: ServerRequest<Macosusesdk_V1_CreateMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Macro> {
        Self.logger.info("createMacro called")
        let req = request.message

        // Validate required fields
        guard !req.macro.displayName.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "display_name is required")
        }

        guard !req.macro.actions.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "at least one action is required")
        }

        // Extract macro ID from parent if provided (format: "macros/{macro_id}")
        let macroId: String? = if !req.macroID.isEmpty { req.macroID } else { nil }

        // Create the macro in the registry
        let createdMacro = await MacroRegistry.shared.createMacro(
            macroId: macroId,
            displayName: req.macro.displayName,
            description: req.macro.description_p,
            actions: req.macro.actions,
            parameters: req.macro.parameters,
            tags: req.macro.tags,
        )

        return ServerResponse(message: createdMacro)
    }

    func getMacro(
        request: ServerRequest<Macosusesdk_V1_GetMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Macro> {
        Self.logger.info("getMacro called")
        let req = request.message

        guard let macro = await MacroRegistry.shared.getMacro(name: req.name) else {
            throw RPCError(
                code: .notFound,
                message: "Macro '\(req.name)' not found",
            )
        }

        return ServerResponse(message: macro)
    }

    func listMacros(
        request: ServerRequest<Macosusesdk_V1_ListMacrosRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListMacrosResponse> {
        Self.logger.info("listMacros called")
        let req = request.message

        // List macros with pagination
        let pageSize = Int(req.pageSize > 0 ? req.pageSize : 50)
        let pageToken = req.pageToken.isEmpty ? nil : req.pageToken

        let (macros, nextToken) = await MacroRegistry.shared.listMacros(
            pageSize: pageSize,
            pageToken: pageToken,
        )

        let response = Macosusesdk_V1_ListMacrosResponse.with {
            $0.macros = macros
            $0.nextPageToken = nextToken ?? ""
        }
        return ServerResponse(message: response)
    }

    func updateMacro(
        request: ServerRequest<Macosusesdk_V1_UpdateMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Macro> {
        Self.logger.info("updateMacro called")
        let req = request.message

        // Parse field mask to determine what to update
        let updateMask = req.updateMask

        // Extract fields to update from req.macro
        var displayName: String?
        var description: String?
        var actions: [Macosusesdk_V1_MacroAction]?
        var parameters: [Macosusesdk_V1_MacroParameter]?
        var tags: [String]?

        // Apply field mask per AIP-134:
        // - Empty mask = full replacement (update all fields from request)
        // - Non-empty mask = partial update (update only specified fields)
        if updateMask.paths.isEmpty {
            // Full replacement - update all fields even if empty (allows field clearance)
            displayName = req.macro.displayName
            description = req.macro.description_p
            actions = req.macro.actions
            parameters = req.macro.parameters
            tags = req.macro.tags
        } else {
            // Update only specified fields
            for path in updateMask.paths {
                switch path {
                case "display_name":
                    displayName = req.macro.displayName
                case "description":
                    description = req.macro.description_p
                case "actions":
                    actions = req.macro.actions
                case "parameters":
                    parameters = req.macro.parameters
                case "tags":
                    tags = req.macro.tags
                default:
                    throw RPCError(code: .invalidArgument, message: "Invalid field path: \(path)")
                }
            }
        }

        // Update macro in registry
        guard
            let updatedMacro = await MacroRegistry.shared.updateMacro(
                name: req.macro.name,
                displayName: displayName,
                description: description,
                actions: actions,
                parameters: parameters,
                tags: tags,
            )
        else {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.macro.name)")
        }

        return ServerResponse(message: updatedMacro)
    }

    func deleteMacro(
        request: ServerRequest<Macosusesdk_V1_DeleteMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        Self.logger.info("deleteMacro called")
        let req = request.message

        // Delete macro from registry
        let deleted = await MacroRegistry.shared.deleteMacro(name: req.name)

        if !deleted {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.name)")
        }

        let response = SwiftProtobuf.Google_Protobuf_Empty()
        return ServerResponse(message: response)
    }

    func executeMacro(
        request: ServerRequest<Macosusesdk_V1_ExecuteMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        Self.logger.info("executeMacro called (LRO)")
        let req = request.message

        // Get macro from registry
        guard let macro = await MacroRegistry.shared.getMacro(name: req.macro) else {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.macro)")
        }

        // Create LRO
        let opName = "operations/executeMacro/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.ExecuteMacroMetadata"
            $0.value = try Macosusesdk_V1_ExecuteMacroMetadata.with {
                $0.macro = req.macro
                $0.totalActions = Int32(macro.actions.count)
            }.serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Execute macro in background
        Task { [operationStore] in
            do {
                let timeout = req.hasOptions && req.options.timeout > 0 ? req.options.timeout : 300.0

                // Execute macro
                try await MacroExecutor.shared.executeMacro(
                    macro: macro,
                    parameters: req.parameterValues,
                    parent: req.application.isEmpty ? "" : req.application,
                    timeout: timeout,
                )

                // Increment execution count
                await MacroRegistry.shared.incrementExecutionCount(name: req.macro)

                // Complete operation
                let response = Macosusesdk_V1_ExecuteMacroResponse.with {
                    $0.success = true
                    $0.actionsExecuted = Int32(macro.actions.count)
                }

                try await operationStore.finishOperation(name: opName, responseMessage: response)

            } catch let error as MacroExecutionError {
                // Mark operation as failed with macro error
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = error.description
                }
                await operationStore.putOperation(errOp)

            } catch {
                // Mark operation as failed with generic error
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

    // MARK: - Script Methods

    func executeAppleScript(
        request: ServerRequest<Macosusesdk_V1_ExecuteAppleScriptRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ExecuteAppleScriptResponse> {
        Self.logger.info("executeAppleScript called")
        let req = request.message

        // Parse timeout from Duration
        let timeout: TimeInterval = if req.hasTimeout {
            Double(req.timeout.seconds) + (Double(req.timeout.nanos) / 1_000_000_000)
        } else {
            30.0 // Default 30 seconds
        }

        do {
            // Execute AppleScript using ScriptExecutor
            let result = try await ScriptExecutor.shared.executeAppleScript(
                req.script,
                timeout: timeout,
                compileOnly: req.compileOnly,
            )

            let response = Macosusesdk_V1_ExecuteAppleScriptResponse.with {
                $0.success = result.success
                $0.output = result.output
                if let error = result.error {
                    $0.error = error
                }
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
                    $0.seconds = Int64(result.duration)
                    $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
                }
            }
            return ServerResponse(message: response)
        } catch let error as ScriptExecutionError {
            let response = Macosusesdk_V1_ExecuteAppleScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = error.description
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_ExecuteAppleScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = "Unexpected error: \(error.localizedDescription)"
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        }
    }

    func executeJavaScript(
        request: ServerRequest<Macosusesdk_V1_ExecuteJavaScriptRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ExecuteJavaScriptResponse> {
        Self.logger.info("executeJavaScript called")
        let req = request.message

        // Parse timeout from Duration
        let timeout: TimeInterval = if req.hasTimeout {
            Double(req.timeout.seconds) + (Double(req.timeout.nanos) / 1_000_000_000)
        } else {
            30.0 // Default 30 seconds
        }

        do {
            // Execute JavaScript using ScriptExecutor
            let result = try await ScriptExecutor.shared.executeJavaScript(
                req.script,
                timeout: timeout,
                compileOnly: req.compileOnly,
            )

            let response = Macosusesdk_V1_ExecuteJavaScriptResponse.with {
                $0.success = result.success
                $0.output = result.output
                if let error = result.error {
                    $0.error = error
                }
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
                    $0.seconds = Int64(result.duration)
                    $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
                }
            }
            return ServerResponse(message: response)
        } catch let error as ScriptExecutionError {
            let response = Macosusesdk_V1_ExecuteJavaScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = error.description
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_ExecuteJavaScriptResponse.with {
                $0.success = false
                $0.output = ""
                $0.error = "Unexpected error: \(error.localizedDescription)"
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        }
    }

    func executeShellCommand(
        request: ServerRequest<Macosusesdk_V1_ExecuteShellCommandRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ExecuteShellCommandResponse> {
        Self.logger.info("executeShellCommand called")
        let req = request.message

        // Parse timeout from Duration
        let timeout: TimeInterval = if req.hasTimeout {
            Double(req.timeout.seconds) + (Double(req.timeout.nanos) / 1_000_000_000)
        } else {
            30.0 // Default 30 seconds
        }

        // Extract shell (default to /bin/bash)
        let shell = req.shell.isEmpty ? "/bin/bash" : req.shell

        // Extract working directory (optional)
        let workingDir = req.workingDirectory.isEmpty ? nil : req.workingDirectory

        // Extract environment (optional)
        let environment =
            req.environment.isEmpty
                ? nil : Dictionary(uniqueKeysWithValues: req.environment.map { ($0.key, $0.value) })

        // Extract stdin (optional)
        let stdin = req.stdin.isEmpty ? nil : req.stdin

        do {
            // Execute shell command using ScriptExecutor
            let result = try await ScriptExecutor.shared.executeShellCommand(
                req.command,
                args: Array(req.args),
                workingDirectory: workingDir,
                environment: environment,
                timeout: timeout,
                stdin: stdin,
                shell: shell,
            )

            let response = Macosusesdk_V1_ExecuteShellCommandResponse.with {
                $0.success = result.success
                $0.stdout = result.stdout
                $0.stderr = result.stderr
                $0.exitCode = result.exitCode
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
                    $0.seconds = Int64(result.duration)
                    $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
                }
                if let error = result.error {
                    $0.error = error
                }
            }
            return ServerResponse(message: response)
        } catch let error as ScriptExecutionError {
            let response = Macosusesdk_V1_ExecuteShellCommandResponse.with {
                $0.success = false
                $0.stdout = ""
                $0.stderr = ""
                $0.exitCode = -1
                $0.error = error.description
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_ExecuteShellCommandResponse.with {
                $0.success = false
                $0.stdout = ""
                $0.stderr = ""
                $0.exitCode = -1
                $0.error = "Unexpected error: \(error.localizedDescription)"
                $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
            }
            return ServerResponse(message: response)
        }
    }

    func validateScript(
        request: ServerRequest<Macosusesdk_V1_ValidateScriptRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ValidateScriptResponse> {
        Self.logger.info("validateScript called")
        let req = request.message

        // Convert proto ScriptType to internal ScriptType
        let scriptType: ScriptType
        switch req.type {
        case .applescript:
            scriptType = .appleScript
        case .jxa:
            scriptType = .jxa
        case .shell:
            scriptType = .shell
        case .unspecified, .UNRECOGNIZED:
            throw RPCError(code: .invalidArgument, message: "Script type must be specified")
        }

        do {
            // Validate script using ScriptExecutor
            let result = try await ScriptExecutor.shared.validateScript(req.script, type: scriptType)

            let response = Macosusesdk_V1_ValidateScriptResponse.with {
                $0.valid = result.valid
                $0.errors = result.errors
                $0.warnings = result.warnings
            }
            return ServerResponse(message: response)
        } catch let error as ScriptExecutionError {
            let response = Macosusesdk_V1_ValidateScriptResponse.with {
                $0.valid = false
                $0.errors = [error.description]
                $0.warnings = []
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_ValidateScriptResponse.with {
                $0.valid = false
                $0.errors = ["Unexpected error: \(error.localizedDescription)"]
                $0.warnings = []
            }
            return ServerResponse(message: response)
        }
    }

    func getScriptingDictionaries(
        request: ServerRequest<Macosusesdk_V1_GetScriptingDictionariesRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ScriptingDictionaries> {
        Self.logger.info("getScriptingDictionaries called")
        let req = request.message

        // Validate resource name (singleton: "scriptingDictionaries")
        guard req.name == "scriptingDictionaries" else {
            throw RPCError(
                code: .invalidArgument, message: "Invalid scripting dictionaries name: \(req.name)",
            )
        }

        // Get all tracked applications
        let applications = await stateStore.listTargets()

        var dictionaries: [Macosusesdk_V1_ScriptingDictionary] = []

        // For each application, check if it has scripting support
        for app in applications {
            // Resolve bundle ID from PID
            let pid = app.pid
            let bundleId = resolveBundleID(forPID: pid) ?? "unknown"

            // Create dictionary entry for the application
            let dictionary = Macosusesdk_V1_ScriptingDictionary.with {
                $0.application = app.name
                $0.bundleID = bundleId
                // Most macOS applications support AppleScript
                $0.supportsApplescript = true
                // JXA is supported by apps that support AppleScript
                $0.supportsJxa = true
                // Note: Getting actual scripting commands/classes would require
                // parsing the application's scripting dictionary (sdef file)
                // which is complex - for now, return common commands
                $0.commands = ["activate", "quit", "open", "close", "save"]
                $0.classes = ["application", "window", "document"]
            }
            dictionaries.append(dictionary)
        }

        // Add system-level applications that are always available
        let systemApps = [
            ("Finder", "com.apple.finder"),
            ("System Events", "com.apple.systemevents"),
            ("Safari", "com.apple.Safari"),
            ("Terminal", "com.apple.Terminal"),
        ]

        for (name, bundleId) in systemApps where !dictionaries.contains(where: { $0.bundleID == bundleId }) {
            let dictionary = Macosusesdk_V1_ScriptingDictionary.with {
                $0.application = name
                $0.bundleID = bundleId
                $0.supportsApplescript = true
                $0.supportsJxa = true
                $0.commands = ["activate", "quit", "open", "close"]
                $0.classes = ["application", "window"]
            }
            dictionaries.append(dictionary)
        }

        let response = Macosusesdk_V1_ScriptingDictionaries.with {
            $0.dictionaries = dictionaries
        }
        return ServerResponse(message: response)
    }
}
