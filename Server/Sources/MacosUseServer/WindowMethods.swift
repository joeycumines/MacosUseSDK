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
    func getWindow(
        request: ServerRequest<Macosusesdk_V1_GetWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("getWindow called for \(req.name, privacy: .public)")
        try ParsingHelpers.validateWindowReadMask(req.readMask)
        let resource = try await resolveWindowResource(req.name)
        let axWindow = try await findWindowElement(
            resource: resource,
            cancellation: context.cancellation,
        )
        let fullResponse = try await buildWindowResponseFromAX(
            resource: resource,
            window: axWindow,
            cancellation: context.cancellation,
        )

        // Apply read_mask per AIP-157
        let filteredWindow = try ParsingHelpers.applyFieldMask(to: fullResponse.message, readMask: req.readMask)
        return ServerResponse(message: filteredWindow)
    }

    func listWindows(
        request: ServerRequest<Macosusesdk_V1_ListWindowsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListWindowsResponse> {
        let req = request.message
        Self.logger.info("listWindows called")
        let filterClauses = try parseWindowFilter(req.filter)
        let ordering = try parseWindowOrdering(req.orderBy)
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let application = try await resolveApplicationResource(fromName: req.parent)
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListWindows",
            parameters: [
                ("parent", application.name),
                ("filter", canonicalWindowFilter(filterClauses)),
                ("order_by", ordering.queryIdentity),
            ],
        )
        let page: WindowRegistry.WindowPage
        if req.pageToken.isEmpty {
            var windowInfos = try await windowRegistry.listWindowBindings(
                applicationName: application.name,
                pid: application.pid,
                processIdentity: application.processIdentity,
            )
            try await revalidateApplicationOwner(application)
            windowInfos = applyWindowFilter(windowInfos, clauses: filterClauses)
            let orderedWindowInfos = windowInfos.sorted {
                windowBindingPrecedes($0, $1, ordering: ordering)
            }
            page = try await windowRegistry.firstWindowPage(
                bindings: orderedWindowInfos,
                pageSize: pageSize,
                queryBinding: queryBinding,
                applicationName: application.name,
                pid: application.pid,
                processIdentity: application.processIdentity,
            )
        } else {
            try await revalidateApplicationOwner(application)
            page = try await windowRegistry.continuationWindowPage(
                token: req.pageToken,
                pageSize: pageSize,
                queryBinding: queryBinding,
                applicationName: application.name,
                pid: application.pid,
                processIdentity: application.processIdentity,
            )
        }

        // Build window list from registry data only - NO per-window AX queries
        // This returns fast, registry-only data (CoreGraphics only).
        // Clients MUST use GetWindowState for expensive AX queries (modal, minimizable, etc.).
        //
        // PERFORMANCE: This eliminates the O(N*M) catastrophe where N windows each
        // triggered M blocking AX queries. ListWindows now completes in <50ms regardless
        // of window count.
        let windows = page.bindings.map { windowInfo in
            Macosusesdk_V1_Window.with {
                $0.name = windowInfo.name
                $0.title = windowInfo.title
                $0.bounds = Macosusesdk_V1_Bounds.with {
                    $0.x = windowInfo.bounds.origin.x
                    $0.y = windowInfo.bounds.origin.y
                    $0.width = windowInfo.bounds.size.width
                    $0.height = windowInfo.bounds.size.height
                }
                $0.layer = windowInfo.layer
                $0.visible = windowInfo.isOnScreen
                $0.bundleID = windowInfo.bundleID ?? ""
            }
        }

        let response = Macosusesdk_V1_ListWindowsResponse.with {
            $0.windows = windows
            $0.nextPageToken = page.nextPageToken
        }
        return ServerResponse(message: response)
    }

    func getWindowState(
        request: ServerRequest<Macosusesdk_V1_GetWindowStateRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WindowState> {
        let req = request.message
        Self.logger.info("getWindowState called for \(req.name, privacy: .public)")

        let resource = try await resolveWindowResource(req.name, stateSuffix: true)
        let axWindow = try await findWindowElement(
            resource: resource,
            cancellation: context.cancellation,
        )

        // Build complete WindowState from AX queries
        let state = try await buildWindowStateFromAX(
            resource: resource,
            window: axWindow,
            cancellation: context.cancellation,
        )

        // Set the resource name
        var response = state
        response.name = req.name

        return ServerResponse(message: response)
    }

    func focusWindow(
        request: ServerRequest<Macosusesdk_V1_FocusWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        try await withOwnedWindowMutation(cancellation: context.cancellation) {
            try await self.focusWindowAdmitted(
                request: request,
                cancellation: context.cancellation,
            )
        }
    }

    private func focusWindowAdmitted(
        request: ServerRequest<Macosusesdk_V1_FocusWindowRequest>,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("focusWindow called")

        let resource = try await resolveWindowResource(req.name)
        let windowToFocus = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        try await revalidateWindowOwner(resource)
        guard let application = system.createAXApplication(pid: resource.pid) else {
            throw RPCError(code: .notFound, message: "Window owner is unavailable")
        }
        try checkWindowReadCancellation(cancellation)
        let setFrontmostResult = system.setAXAttribute(
            element: application,
            attribute: kAXFrontmostAttribute as String,
            value: true,
        )
        guard setFrontmostResult == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(
                errorCode: setFrontmostResult,
                operation: "set owner frontmost",
            )
        }
        try await revalidateWindowOwner(resource)
        // kAXRaiseAction is an OPTIONAL convenience action. Many focusable windows
        // (e.g. Calculator, panels, utility windows) do not implement it and return
        // kAXErrorAttributeUnsupported (-25205) / kAXErrorActionUnsupported (-25206),
        // yet are fully focusable through the authoritative attribute sets below
        // (kAXFrontmostAttribute on the application, kAXMainAttribute/kAXFocusedAttribute
        // on the window) plus the AX-read convergence predicate. Treating an
        // unsupported raise as a hard failure made FocusWindow impossible for such
        // windows even though they converge. Perform the raise best-effort: only
        // real failures (permission denied, invalid element, genuine AX errors)
        // abort; unsupported is logged and the focus sequence continues. The
        // subsequent attribute sets and waitForWindowFocusConvergence remain the
        // authoritative gate, so a no-op raise can never report unearned focus.
        let raiseResult = system.performAXAction(
            element: windowToFocus as AnyObject,
            action: kAXRaiseAction as String,
        )
        if raiseResult != AXError.success.rawValue {
            let raiseBestEffort = raiseResult == AXError.attributeUnsupported.rawValue
                || raiseResult == AXError.actionUnsupported.rawValue
                || raiseResult == AXError.notImplemented.rawValue
            if raiseBestEffort {
                Self.logger.info(
                    "raise action unsupported for window (error=\(raiseResult, privacy: .public)); focusing via attribute sets only",
                )
            } else {
                throw rpcErrorForAXMutation(
                    errorCode: raiseResult,
                    operation: "raise window",
                )
            }
        }
        try await revalidateWindowOwner(resource)
        let setMainResult = system.setAXAttribute(
            element: windowToFocus as AnyObject,
            attribute: kAXMainAttribute as String,
            value: true,
        )
        guard setMainResult == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(
                errorCode: setMainResult,
                operation: "set main window",
            )
        }
        try await revalidateWindowOwner(resource)
        let setFocusedResult = system.setAXAttribute(
            element: windowToFocus as AnyObject,
            attribute: kAXFocusedAttribute as String,
            value: true,
        )
        guard setFocusedResult == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(
                errorCode: setFocusedResult,
                operation: "set focused window",
            )
        }
        try await revalidateWindowOwner(resource)
        try await waitForWindowFocusConvergence(
            resource: resource,
            window: windowToFocus,
            application: application,
            cancellation: cancellation,
        )

        return try await buildWindowResponseFromAX(
            resource: resource,
            window: windowToFocus,
            cancellation: cancellation,
        )
    }

    func moveWindow(
        request: ServerRequest<Macosusesdk_V1_MoveWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        try await withOwnedWindowMutation(cancellation: context.cancellation) {
            try await self.moveWindowAdmitted(
                request: request,
                cancellation: context.cancellation,
            )
        }
    }

    private func moveWindowAdmitted(
        request: ServerRequest<Macosusesdk_V1_MoveWindowRequest>,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("moveWindow called")

        // Validate coordinates are finite
        guard req.x.isFinite else {
            throw RPCErrorHelpers.validationError(
                message: "x coordinate must be a finite number",
                reason: "INVALID_COORDINATE",
                field: "x",
                value: String(req.x),
            )
        }
        guard req.y.isFinite else {
            throw RPCErrorHelpers.validationError(
                message: "y coordinate must be a finite number",
                reason: "INVALID_COORDINATE",
                field: "y",
                value: String(req.y),
            )
        }

        let resource = try await resolveWindowResource(req.name)
        let window = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        try await revalidateWindowOwner(resource)
        let previousPosition = try readRequiredAXPoint(
            element: window as AnyObject,
            attribute: kAXPositionAttribute as String,
        )
        let currentSize = try readRequiredAXSize(
            element: window as AnyObject,
            attribute: kAXSizeAttribute as String,
        )
        var newPosition = CGPoint(x: req.x, y: req.y)
        guard EndpointSafeGeometry.containsValidEndpoints(
            CGRect(origin: newPosition, size: currentSize),
            requiresPositiveSize: false,
        ) else {
            throw RPCErrorHelpers.validationError(
                message: "requested window frame must have finite endpoints",
                reason: "INVALID_COORDINATE",
                field: "x",
            )
        }
        guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else {
            throw RPCError(code: .internalError, message: "Failed to create position value")
        }
        let result = system.setAXAttribute(
            element: window as AnyObject,
            attribute: kAXPositionAttribute as String,
            value: positionValue,
        )
        guard result == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(errorCode: result, operation: "move window")
        }
        _ = try await waitForWindowPointConvergence(
            resource: resource,
            window: window,
            previous: previousPosition,
            requested: newPosition,
            cancellation: cancellation,
        )

        return try await buildWindowResponseFromAX(
            resource: resource,
            window: window,
            cancellation: cancellation,
        )
    }

    func resizeWindow(
        request: ServerRequest<Macosusesdk_V1_ResizeWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        try await withOwnedWindowMutation(cancellation: context.cancellation) {
            try await self.resizeWindowAdmitted(
                request: request,
                cancellation: context.cancellation,
            )
        }
    }

    private func resizeWindowAdmitted(
        request: ServerRequest<Macosusesdk_V1_ResizeWindowRequest>,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("resizeWindow called")

        // Validate dimensions are finite and positive
        guard req.width.isFinite, req.width > 0 else {
            throw RPCErrorHelpers.validationError(
                message: "width must be a finite positive number",
                reason: "INVALID_DIMENSION",
                field: "width",
                value: String(req.width),
            )
        }
        guard req.height.isFinite, req.height > 0 else {
            throw RPCErrorHelpers.validationError(
                message: "height must be a finite positive number",
                reason: "INVALID_DIMENSION",
                field: "height",
                value: String(req.height),
            )
        }

        let resource = try await resolveWindowResource(req.name)
        let window = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        try await revalidateWindowOwner(resource)
        let previousSize = try readRequiredAXSize(
            element: window as AnyObject,
            attribute: kAXSizeAttribute as String,
        )
        let currentPosition = try readRequiredAXPoint(
            element: window as AnyObject,
            attribute: kAXPositionAttribute as String,
        )
        var newSize = CGSize(width: req.width, height: req.height)
        guard EndpointSafeGeometry.containsValidEndpoints(
            CGRect(origin: currentPosition, size: newSize),
            requiresPositiveSize: true,
        ) else {
            throw RPCErrorHelpers.validationError(
                message: "requested window frame must have finite endpoints",
                reason: "INVALID_DIMENSION",
                field: "width",
            )
        }
        guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
            throw RPCError(code: .internalError, message: "Failed to create size value")
        }
        let result = system.setAXAttribute(
            element: window as AnyObject,
            attribute: kAXSizeAttribute as String,
            value: sizeValue,
        )
        guard result == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(errorCode: result, operation: "resize window")
        }
        _ = try await waitForWindowSizeConvergence(
            resource: resource,
            window: window,
            previous: previousSize,
            requested: newSize,
            cancellation: cancellation,
        )

        return try await buildWindowResponseFromAX(
            resource: resource,
            window: window,
            cancellation: cancellation,
        )
    }

    func minimizeWindow(
        request: ServerRequest<Macosusesdk_V1_MinimizeWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        try await withOwnedWindowMutation(cancellation: context.cancellation) {
            try await self.minimizeWindowAdmitted(
                request: request,
                cancellation: context.cancellation,
            )
        }
    }

    private func minimizeWindowAdmitted(
        request: ServerRequest<Macosusesdk_V1_MinimizeWindowRequest>,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("minimizeWindow called")

        let resource = try await resolveWindowResource(req.name)
        let window = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        try await revalidateWindowOwner(resource)

        let result = system.setAXAttribute(
            element: window as AnyObject,
            attribute: kAXMinimizedAttribute as String,
            value: true,
        )
        guard result == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(errorCode: result, operation: "minimize window")
        }
        try await waitForWindowBooleanConvergence(
            resource: resource,
            window: window,
            attribute: kAXMinimizedAttribute as String,
            expected: true,
            operation: "minimize",
            cancellation: cancellation,
        )

        return try await buildWindowResponseFromAX(
            resource: resource,
            window: window,
            cancellation: cancellation,
        )
    }

    func restoreWindow(
        request: ServerRequest<Macosusesdk_V1_RestoreWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        try await withOwnedWindowMutation(cancellation: context.cancellation) {
            try await self.restoreWindowAdmitted(
                request: request,
                cancellation: context.cancellation,
            )
        }
    }

    private func restoreWindowAdmitted(
        request: ServerRequest<Macosusesdk_V1_RestoreWindowRequest>,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ServerResponse<Macosusesdk_V1_Window> {
        let req = request.message
        Self.logger.info("restoreWindow called")

        let resource = try await resolveWindowResource(req.name)
        let window = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        try await revalidateWindowOwner(resource)
        let result = system.setAXAttribute(
            element: window as AnyObject,
            attribute: kAXMinimizedAttribute as String,
            value: false,
        )
        guard result == AXError.success.rawValue else {
            throw rpcErrorForAXMutation(errorCode: result, operation: "restore window")
        }
        try await waitForWindowBooleanConvergence(
            resource: resource,
            window: window,
            attribute: kAXMinimizedAttribute as String,
            expected: false,
            operation: "restore",
            cancellation: cancellation,
        )

        return try await buildWindowResponseFromAX(
            resource: resource,
            window: window,
            cancellation: cancellation,
        )
    }

    func closeWindow(
        request: ServerRequest<Macosusesdk_V1_CloseWindowRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CloseWindowResponse> {
        guard !request.message.force else {
            throw RPCError(code: .unimplemented, message: "force close is not supported")
        }
        return try await withOwnedWindowMutation(cancellation: context.cancellation) {
            try await self.closeWindowAdmitted(
                request: request,
                cancellation: context.cancellation,
            )
        }
    }

    private func closeWindowAdmitted(
        request: ServerRequest<Macosusesdk_V1_CloseWindowRequest>,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ServerResponse<Macosusesdk_V1_CloseWindowResponse> {
        let req = request.message
        Self.logger.info("closeWindow called")

        let resource = try await resolveWindowResource(req.name)
        let window = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        try await revalidateWindowOwner(resource)

        // Get close button and press it (MUST run on MainActor)
        try await MainActor.run {
            let closeButton = try self.readRequiredAXElement(
                element: window as AnyObject,
                attribute: kAXCloseButtonAttribute as String,
            )

            let result = self.system.performAXAction(element: closeButton as AnyObject, action: kAXPressAction as String)
            guard result == AXError.success.rawValue else {
                throw self.rpcErrorForAXMutation(
                    errorCode: result,
                    operation: "close window",
                )
            }
        }
        try await waitForWindowDisappearance(
            resource: resource,
            window: window,
            cancellation: cancellation,
        )
        try checkWindowReadCancellation(cancellation)
        await windowRegistry.retireWindowBinding(
            resourceID: resource.resourceID,
            applicationName: resource.applicationName,
            pid: resource.pid,
            processIdentity: resource.processIdentity,
        )
        return ServerResponse(message: Macosusesdk_V1_CloseWindowResponse.with { $0.success = true })
    }

    private func withOwnedWindowMutation<Result: Sendable>(
        cancellation: ServerContext.RPCCancellationHandle,
        operation: @escaping @Sendable () async throws -> Result,
    ) async throws -> Result {
        guard !Task.isCancelled, cancellation.isCancelled == false else {
            throw RPCError(code: .cancelled, message: "Window mutation cancelled")
        }
        let task = Task {
            try await physicalDesktopMutationGate.withExclusiveOperation(operation)
        }
        let cancellationWatcher = Task<Void, Never> {
            do {
                try await cancellation.cancelled
                task.cancel()
            } catch {
                // The mutation settled first and owns watcher cancellation.
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            cancellationWatcher.cancel()
            await cancellationWatcher.value
            guard !Task.isCancelled, cancellation.isCancelled == false else {
                throw RPCError(code: .cancelled, message: "Window mutation cancelled")
            }
            return result
        } catch {
            cancellationWatcher.cancel()
            await cancellationWatcher.value
            if error is CancellationError ||
                Task.isCancelled ||
                cancellation.isCancelled
            {
                throw RPCError(code: .cancelled, message: "Window mutation cancelled")
            }
            throw error
        }
    }

    func captureWindowScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureWindowScreenshotRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureWindowScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureWindowScreenshot] Capturing window screenshot")
        let encoding = try RequestNumericValidation.imageEncoding(
            format: req.format,
            quality: req.quality,
        )
        let format = encoding.format
        let quality = encoding.quality
        let includeShadow = req.includeShadow
        let includeOCR = req.includeOcrText
        _ = try parseWindowResourceName(req.window)
        return try await captureWorkOwner.withCapture(cancellation: context.cancellation) { [self] in
            let resource = try await resolveWindowResource(req.window)
            try Task.checkCancellation()
            let admittedWindowElement = try await findWindowElement(
                resource: resource,
                cancellation: context.cancellation,
            )
            try Task.checkCancellation()
            try await revalidateWindowOwner(resource)
            guard let captureBinding = await windowRegistry.resolveWindowBinding(
                resourceID: resource.resourceID,
                applicationName: resource.applicationName,
                pid: resource.pid,
                processIdentity: resource.processIdentity,
            ) else {
                throw RPCError(code: .notFound, message: "Window binding is stale")
            }
            try Task.checkCancellation()
            let source = WindowScreenshotCaptureSource(
                name: resource.name,
                windowID: captureBinding.windowID,
                ownerPID: resource.pid,
                processIdentity: resource.processIdentity,
                admittedFrame: captureBinding.bounds,
            )
            let result = try await screenshotCapture.captureWindow(
                source,
                format: format,
                quality: quality,
                includeShadow: includeShadow,
                includeOCR: includeOCR,
            )
            try Task.checkCancellation()
            try validateWindowCaptureOutput(
                result,
                source: source,
                expectedFormat: format,
                expectedShadow: includeShadow,
            )
            try result.ocrResult.validate(requested: includeOCR)
            try Task.checkCancellation()
            try await revalidateWindowOwner(resource)
            let currentWindowElement = try await findWindowElement(
                resource: resource,
                cancellation: context.cancellation,
            )
            guard CFEqual(admittedWindowElement, currentWindowElement),
                  let currentBinding = await windowRegistry.resolveWindowBinding(
                      resourceID: resource.resourceID,
                      applicationName: resource.applicationName,
                      pid: resource.pid,
                      processIdentity: resource.processIdentity,
                  ),
                  currentBinding.windowID == source.windowID,
                  windowCaptureFramesEqual(
                      currentBinding.bounds,
                      source.admittedFrame,
                  ),
                  currentBinding.retainedElement.map({
                      CFEqual($0.element, admittedWindowElement)
                  }) == true
            else {
                throw RPCError(
                    code: .aborted,
                    message: "Exact window source changed during capture",
                )
            }
            try Task.checkCancellation()

            var response = Macosusesdk_V1_CaptureWindowScreenshotResponse()
            response.imageData = result.data
            response.format = result.format
            response.width = result.pixelWidth
            response.height = result.pixelHeight
            response.window = result.sourceName
            response.windowFrame = windowCaptureRegionMessage(result.windowFrame)
            response.region = windowCaptureRegionMessage(result.logicalFrame)
            response.scale = result.scale
            response.shadowIncluded = result.shadowIncluded
            response.clipped = result.clipped
            switch result.ocrResult {
            case .notRequested:
                break
            case let .text(text):
                response.ocrText = text
            case let .failure(status):
                response.ocrError = status
            }

            Self.logger.info("[captureWindowScreenshot] Captured \(result.pixelWidth, privacy: .public)x\(result.pixelHeight, privacy: .public) window screenshot")
            return ServerResponse(message: response)
        }
    }

    private func validateWindowCaptureOutput(
        _ output: WindowScreenshotCaptureOutput,
        source: WindowScreenshotCaptureSource,
        expectedFormat: Macosusesdk_V1_ImageFormat,
        expectedShadow: Bool,
    ) throws {
        let windowFrame = output.windowFrame
        let logicalFrame = output.logicalFrame
        let finiteWindowFrame = EndpointSafeGeometry.containsValidEndpoints(
            windowFrame,
            requiresPositiveSize: true,
        )
        let finiteLogicalFrame = EndpointSafeGeometry.containsValidEndpoints(
            logicalFrame,
            requiresPositiveSize: true,
        )
        let frameTolerance: CGFloat = 0.001
        let sourceFrameMatches = abs(windowFrame.minX - source.admittedFrame.minX) <= frameTolerance &&
            abs(windowFrame.minY - source.admittedFrame.minY) <= frameTolerance &&
            abs(windowFrame.width - source.admittedFrame.width) <= frameTolerance &&
            abs(windowFrame.height - source.admittedFrame.height) <= frameTolerance
        let logicalContainsWindow = windowFrame.minX >= logicalFrame.minX - frameTolerance &&
            windowFrame.minY >= logicalFrame.minY - frameTolerance &&
            windowFrame.maxX <= logicalFrame.maxX + frameTolerance &&
            windowFrame.maxY <= logicalFrame.maxY + frameTolerance

        guard output.sourceName == source.name,
              output.windowID == source.windowID,
              output.ownerPID == source.ownerPID,
              output.format == expectedFormat,
              output.pixelWidth > 0,
              output.pixelHeight > 0,
              !output.data.isEmpty,
              finiteWindowFrame,
              finiteLogicalFrame,
              sourceFrameMatches,
              logicalFrame.intersects(windowFrame),
              output.clipped == !logicalContainsWindow,
              output.scale.isFinite,
              output.scale > 0,
              abs(Double(output.pixelWidth) - Double(logicalFrame.width) * output.scale) < 1,
              abs(Double(output.pixelHeight) - Double(logicalFrame.height) * output.scale) < 1,
              output.shadowIncluded == expectedShadow
        else {
            throw RPCError(code: .unavailable, message: "Window screenshot source metadata is inconsistent")
        }
        try EncodedImageValidation.validate(
            output.data,
            format: output.format,
            pixelWidth: output.pixelWidth,
            pixelHeight: output.pixelHeight,
        )
    }

    private func windowCaptureRegionMessage(_ frame: CGRect) -> Macosusesdk_Type_Region {
        .with {
            $0.x = frame.origin.x
            $0.y = frame.origin.y
            $0.width = frame.width
            $0.height = frame.height
        }
    }

    private func windowCaptureFramesEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.001,
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    // MARK: - Filter Helpers

    /// Parses and applies the complete supported ListWindows filter grammar.
    /// Unsupported or partially recognized input fails instead of being ignored.
    func applyWindowFilter(
        _ windows: [WindowRegistry.WindowInfo],
        filter: String,
    ) throws -> [WindowRegistry.WindowInfo] {
        try applyWindowFilter(windows, clauses: parseWindowFilter(filter))
    }

    private func applyWindowFilter(
        _ windows: [WindowRegistry.WindowInfo],
        clauses: [WindowFilterClause],
    ) -> [WindowRegistry.WindowInfo] {
        var result = windows
        for clause in clauses {
            switch clause {
            case let .title(value):
                result = result.filter { titleMatches(pattern: value, title: $0.title) }
            case let .visible(value):
                result = result.filter { $0.isOnScreen == value }
            }
        }
        return result
    }

    private func applyWindowFilter(
        _ windows: [WindowRegistry.WindowBinding],
        clauses: [WindowFilterClause],
    ) -> [WindowRegistry.WindowBinding] {
        var result = windows
        for clause in clauses {
            switch clause {
            case let .title(value):
                result = result.filter { titleMatches(pattern: value, title: $0.title) }
            case let .visible(value):
                result = result.filter { $0.isOnScreen == value }
            }
        }
        return result
    }

    private func parseWindowFilter(_ rawFilter: String) throws -> [WindowFilterClause] {
        let expression = rawFilter as NSString
        let length = expression.length
        guard !rawFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let regex = try NSRegularExpression(
            pattern: #"(?:(title)\s*=\s*\"([^\"]*)\"|(visible)\s*=\s*(true|false))"#,
        )
        var clauses: [WindowFilterClause] = []
        var cursor = 0
        while cursor < length {
            let remaining = expression.substring(from: cursor)
            if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            let searchRange = NSRange(location: cursor, length: length - cursor)
            guard let match = regex.firstMatch(in: rawFilter, range: searchRange) else {
                throw invalidWindowFilter(rawFilter)
            }
            let separatorRange = NSRange(location: cursor, length: match.range.location - cursor)
            let separator = expression.substring(with: separatorRange)
            let trimmedSeparator = separator.trimmingCharacters(in: .whitespacesAndNewlines)
            if clauses.isEmpty {
                guard trimmedSeparator.isEmpty else {
                    throw invalidWindowFilter(rawFilter)
                }
            } else {
                let containsWhitespace = separator.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                guard containsWhitespace,
                      trimmedSeparator.isEmpty || trimmedSeparator.caseInsensitiveCompare("AND") == .orderedSame
                else {
                    throw invalidWindowFilter(rawFilter)
                }
            }

            if match.range(at: 1).location != NSNotFound {
                clauses.append(.title(expression.substring(with: match.range(at: 2))))
            } else {
                let value = expression.substring(with: match.range(at: 4)) == "true"
                clauses.append(.visible(value))
            }
            cursor = NSMaxRange(match.range)
        }
        return clauses
    }

    private func parseWindowOrdering(_ rawOrdering: String) throws -> WindowOrdering {
        let trimmed = rawOrdering.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WindowOrdering(terms: [.init(field: .name, descending: false)])
        }
        let rawTerms = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        var terms: [WindowOrdering.Term] = []
        var seenFields: Set<WindowOrdering.Field> = []
        for rawTerm in rawTerms {
            let parts = rawTerm.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 1 || parts.count == 2 else {
                throw invalidWindowOrdering(rawOrdering)
            }
            let field: WindowOrdering.Field = switch parts[0] {
            case "name": .name
            case "title": .title
            case "layer": .layer
            default: throw invalidWindowOrdering(rawOrdering)
            }
            guard seenFields.insert(field).inserted else {
                throw invalidWindowOrdering(rawOrdering)
            }
            let descending: Bool = switch parts.count == 2 ? parts[1] : "asc" {
            case "asc": false
            case "desc": true
            default: throw invalidWindowOrdering(rawOrdering)
            }
            terms.append(.init(field: field, descending: descending))
        }
        return WindowOrdering(terms: terms)
    }

    private func invalidWindowFilter(_ value: String) -> RPCError {
        RPCErrorHelpers.validationError(
            message: "filter contains an unsupported or malformed expression",
            reason: "INVALID_FILTER",
            field: "filter",
            value: value,
        )
    }

    private func invalidWindowOrdering(_ value: String) -> RPCError {
        RPCErrorHelpers.validationError(
            message: "order_by must be a comma-separated list of name, title, or layer with optional asc or desc",
            reason: "INVALID_ORDER_BY",
            field: "order_by",
            value: value,
        )
    }

    private func canonicalWindowFilter(_ clauses: [WindowFilterClause]) -> String {
        ParsingHelpers.pageTokenQuery(
            method: "ListWindowsFilter",
            parameters: clauses.enumerated().map { index, clause in
                switch clause {
                case let .title(value):
                    ("\(index):title", value)
                case let .visible(value):
                    ("\(index):visible", String(value))
                }
            },
        )
    }

    private func windowBindingPrecedes(
        _ lhs: WindowRegistry.WindowBinding,
        _ rhs: WindowRegistry.WindowBinding,
        ordering: WindowOrdering,
    ) -> Bool {
        for term in ordering.terms {
            let comparison: ComparisonResult = switch term.field {
            case .name:
                lhs.name.compare(rhs.name)
            case .title:
                lhs.title.compare(rhs.title)
            case .layer:
                if lhs.layer == rhs.layer {
                    .orderedSame
                } else {
                    lhs.layer < rhs.layer ? .orderedAscending : .orderedDescending
                }
            }
            guard comparison != .orderedSame else {
                continue
            }
            return term.descending
                ? comparison == .orderedDescending
                : comparison == .orderedAscending
        }
        return lhs.name < rhs.name
    }

    private func titleMatches(pattern: String, title: String) -> Bool {
        let patternCharacters = Array(pattern)
        let titleCharacters = Array(title)
        var patternIndex = 0
        var titleIndex = 0
        var starIndex: Int?
        var starTitleIndex = 0

        while titleIndex < titleCharacters.count {
            if patternIndex < patternCharacters.count,
               patternCharacters[patternIndex] == titleCharacters[titleIndex]
            {
                patternIndex += 1
                titleIndex += 1
            } else if patternIndex < patternCharacters.count,
                      patternCharacters[patternIndex] == "*"
            {
                starIndex = patternIndex
                patternIndex += 1
                starTitleIndex = titleIndex
            } else if let starIndex {
                patternIndex = starIndex + 1
                starTitleIndex += 1
                titleIndex = starTitleIndex
            } else {
                return false
            }
        }
        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }

    /// Extracts a quoted value from a filter expression like key="value"
    /// Note: Internal visibility for unit testing.
    func extractQuotedValue(from filter: String, key: String) -> String? {
        // Pattern: key="value" or key = "value"
        let pattern = "\(key)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(filter.startIndex ..< filter.endIndex, in: filter)
        guard let match = regex.firstMatch(in: filter, options: [], range: range) else {
            return nil
        }
        guard let valueRange = Range(match.range(at: 1), in: filter) else {
            return nil
        }
        return String(filter[valueRange])
    }
}

private enum WindowFilterClause {
    case title(String)
    case visible(Bool)
}

private struct WindowOrdering {
    struct Term {
        let field: Field
        let descending: Bool
    }

    enum Field: Hashable {
        case name
        case title
        case layer
    }

    let terms: [Term]

    var queryIdentity: String {
        terms.map { term in
            let field = switch term.field {
            case .name: "name"
            case .title: "title"
            case .layer: "layer"
            }
            return "\(field) \(term.descending ? "desc" : "asc")"
        }.joined(separator: ",")
    }
}
