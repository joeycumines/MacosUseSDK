import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

extension ExactMacService {
    func captureScreenshot(
        request: ServerRequest<Exactmac_V1_CaptureScreenshotRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_CaptureScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureScreenshot] Capturing screen screenshot")
        let encoding = try RequestNumericValidation.imageEncoding(
            format: req.format,
            quality: req.quality,
        )
        let format = encoding.format
        let quality = encoding.quality
        if !req.display.isEmpty {
            _ = try ParsingHelpers.parseDisplayName(req.display, field: "display")
        }
        let includeOCR = req.includeOcrText
        return try await captureWorkOwner.withCapture(cancellation: context.cancellation) { [self] in
            let snapshot = try await displayTopologyProvider.snapshot().validated()
            try Task.checkCancellation()
            let display = try captureDisplay(name: req.display, from: snapshot)
            try Task.checkCancellation()
            let result = try await screenshotCapture.captureDisplay(
                display,
                format: format,
                quality: quality,
                includeOCR: includeOCR,
            )
            try Task.checkCancellation()
            try validateCaptureOutput(
                result,
                display: display,
                expectedFormat: format,
                expectedRegion: display.frame,
            )
            try result.ocrResult.validate(requested: includeOCR)

            var response = Exactmac_V1_CaptureScreenshotResponse()
            response.imageData = result.data
            response.format = result.format
            response.width = result.pixelWidth
            response.height = result.pixelHeight
            response.display = display.name
            response.region = regionMessage(result.logicalFrame)
            response.scale = result.scale
            applyOCRResult(result.ocrResult, to: &response)

            Self.logger.info("[captureScreenshot] Captured \(result.pixelWidth, privacy: .public)x\(result.pixelHeight, privacy: .public) screenshot")
            return ServerResponse(message: response)
        }
    }

    func captureElementScreenshot(
        request: ServerRequest<Exactmac_V1_CaptureElementScreenshotRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_CaptureElementScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureElementScreenshot] Capturing element screenshot")
        let encoding = try RequestNumericValidation.imageEncoding(
            format: req.format,
            quality: req.quality,
        )
        let format = encoding.format
        let quality = encoding.quality

        // Validate element ID is not empty
        guard !req.elementID.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "element_id is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "element_id",
            )
        }

        // Validate padding is non-negative
        guard req.padding >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "padding must be a non-negative number",
                reason: "INVALID_DIMENSION",
                field: "padding",
                value: String(req.padding),
            )
        }
        try validateApplicationOrWindowParentResourceName(req.parent)
        _ = try ParsingHelpers.validateResourceID(req.elementID, field: "element_id")

        let includeOCR = req.includeOcrText
        return try await captureWorkOwner.withCapture(cancellation: context.cancellation) { [self] in
            let parentAuthority = try await resolveElementCaptureParentAuthority(
                req.parent,
                cancellation: context.cancellation,
            )
            let pid = parentAuthority.pid
            try Task.checkCancellation()
            let target = try await resolveElementCaptureTarget(
                elementID: req.elementID,
                parent: req.parent,
                pid: pid,
            )
            guard let admittedAXElement = target.axElement else {
                throw RPCError(code: .failedPrecondition, message: "Element has no AX identity")
            }
            try await validateElementCaptureParentAuthority(
                parentAuthority,
                element: admittedAXElement,
                cancellation: context.cancellation,
            )
            let elementBounds = try readElementCaptureBounds(admittedAXElement)

            // Route the exact scope-bound AX element's current bounds through
            // the same composition-owned region capturer, then revalidate its
            // identity and bounds before returning captured pixels.
            let snapshot = try await displayTopologyProvider.snapshot().validated()
            try Task.checkCancellation()
            let display = try captureDisplay(
                containing: elementBounds,
                explicitName: "",
                from: snapshot,
            )
            let geometry = try elementCaptureGeometry(
                elementFrame: elementBounds,
                display: display,
                paddingPixels: req.padding,
            )
            try Task.checkCancellation()
            let result = try await screenshotCapture.captureRegion(
                geometry.captureRegion,
                display: display,
                format: format,
                quality: quality,
                includeOCR: includeOCR,
            )
            try Task.checkCancellation()
            try validateCaptureOutput(
                result,
                display: display,
                expectedFormat: format,
                expectedRegion: geometry.captureRegion,
            )
            try result.ocrResult.validate(requested: includeOCR)
            try Task.checkCancellation()
            let currentTarget = try await resolveElementCaptureTarget(
                elementID: req.elementID,
                parent: req.parent,
                pid: pid,
            )
            guard let currentAXElement = currentTarget.axElement,
                  CFEqual(admittedAXElement, currentAXElement),
                  try readElementCaptureBounds(currentAXElement).nearlyEquals(elementBounds)
            else {
                throw RPCError(
                    code: .aborted,
                    message: "Element identity or bounds changed during capture",
                )
            }
            try await validateElementCaptureParentAuthority(
                parentAuthority,
                element: currentAXElement,
                cancellation: context.cancellation,
            )
            try Task.checkCancellation()

            var response = Exactmac_V1_CaptureElementScreenshotResponse()
            response.imageData = result.data
            response.format = result.format
            response.width = result.pixelWidth
            response.height = result.pixelHeight
            response.elementID = req.elementID
            response.parent = req.parent
            response.elementFrame = regionMessage(elementBounds)
            response.display = display.name
            response.region = regionMessage(result.logicalFrame)
            response.scale = result.scale
            response.padding = req.padding
            response.clipped = geometry.clipped
            applyOCRResult(result.ocrResult, to: &response)

            Self.logger.info("[captureElementScreenshot] Captured \(result.pixelWidth, privacy: .public)x\(result.pixelHeight, privacy: .public) element screenshot")
            return ServerResponse(message: response)
        }
    }

    private enum ElementCaptureParentAuthority: Sendable {
        case application(ResolvedApplicationResource)
        case window(
            resource: ResolvedWindowResource,
            exactElement: SendableAXUIElement,
        )

        var pid: pid_t {
            switch self {
            case let .application(resource):
                resource.pid
            case let .window(resource, _):
                resource.pid
            }
        }
    }

    private func resolveElementCaptureParentAuthority(
        _ parent: String,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws -> ElementCaptureParentAuthority {
        let components = parent.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 2 {
            let resource = try await resolveApplicationResource(fromName: parent)
            try await revalidateApplicationOwner(resource)
            return .application(resource)
        }

        let resource = try await resolveWindowResource(parent)
        let exactElement = try await findWindowElement(
            resource: resource,
            cancellation: cancellation,
        )
        guard let binding = await windowRegistry.resolveWindowBinding(
            resourceID: resource.resourceID,
            applicationName: resource.applicationName,
            pid: resource.pid,
            processIdentity: resource.processIdentity,
        ),
            binding.windowID == resource.windowID,
            binding.retainedElement.map({ CFEqual($0.element, exactElement) }) == true
        else {
            throw RPCError(code: .failedPrecondition, message: "Element window parent changed during admission")
        }
        return .window(
            resource: resource,
            exactElement: SendableAXUIElement(exactElement),
        )
    }

    private func validateElementCaptureParentAuthority(
        _ authority: ElementCaptureParentAuthority,
        element: AXUIElement,
        cancellation: ServerContext.RPCCancellationHandle?,
    ) async throws {
        switch authority {
        case let .application(resource):
            try await revalidateApplicationOwner(resource)
            try requireElementCapturePID(element, expectedPID: resource.pid)
        case let .window(resource, exactElement):
            try await revalidateWindowOwner(resource)
            let currentWindow = try await findWindowElement(
                resource: resource,
                cancellation: cancellation,
            )
            guard CFEqual(currentWindow, exactElement.element),
                  let binding = await windowRegistry.resolveWindowBinding(
                      resourceID: resource.resourceID,
                      applicationName: resource.applicationName,
                      pid: resource.pid,
                      processIdentity: resource.processIdentity,
                  ),
                  binding.windowID == resource.windowID,
                  binding.retainedElement.map({
                      CFEqual($0.element, exactElement.element)
                  }) == true
            else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element window parent identity changed during capture",
                )
            }
            try validateElementCaptureAncestry(
                element,
                exactWindow: exactElement.element,
                expectedPID: resource.pid,
            )
        }
    }

    private func validateElementCaptureAncestry(
        _ element: AXUIElement,
        exactWindow: AXUIElement,
        expectedPID: pid_t,
    ) throws {
        var current = element
        var visited = Set<SendableAXUIElement>()
        for _ in 0 ..< 64 {
            let wrapped = SendableAXUIElement(current)
            guard visited.insert(wrapped).inserted else {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element AX ancestry contains a cycle",
                )
            }
            try requireElementCapturePID(current, expectedPID: expectedPID)
            if CFEqual(current, exactWindow) {
                return
            }

            let parentRead = system.copyAXAttributeResult(
                element: current as AnyObject,
                attribute: kAXParentAttribute as String,
            )
            if parentRead.errorCode == AXError.attributeUnsupported.rawValue ||
                parentRead.errorCode == AXError.noValue.rawValue
            {
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element does not descend from its exact window parent",
                )
            }
            guard parentRead.errorCode == AXError.success.rawValue else {
                throw rpcErrorForAXRead(
                    errorCode: parentRead.errorCode,
                    attribute: kAXParentAttribute as String,
                )
            }
            guard let parent = parentRead.value,
                  CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID()
            else {
                throw RPCError(
                    code: .unavailable,
                    message: "Element AX ancestry contains an invalid parent",
                )
            }
            current = unsafeDowncast(parent as CFTypeRef, to: AXUIElement.self)
        }
        throw RPCError(
            code: .failedPrecondition,
            message: "Element AX ancestry exceeds the supported depth",
        )
    }

    private func requireElementCapturePID(
        _ element: AXUIElement,
        expectedPID: pid_t,
    ) throws {
        let read = system.getAXElementPID(element: element as AnyObject)
        guard read.errorCode == AXError.success.rawValue else {
            throw rpcErrorForAXRead(
                errorCode: read.errorCode,
                attribute: "AX process identity",
            )
        }
        guard let livePID = read.pid else {
            throw RPCError(
                code: .unavailable,
                message: "Element AX process identity is missing",
            )
        }
        guard livePID == expectedPID else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Element AX ancestry changed application owner",
            )
        }
    }

    private func resolveElementCaptureTarget(
        elementID: String,
        parent: String,
        pid: pid_t,
    ) async throws -> RegisteredElementMutationTarget {
        do {
            return try await elementRegistry.resolveElementForMutation(
                elementID,
                expectedPID: pid,
                expectedScope: parent,
            )
        } catch let error as ElementMutationResolutionError {
            switch error {
            case .admissionClosed:
                throw RPCError(code: .unavailable, message: "Element registry admission is closed")
            case .notFound:
                throw RPCError(code: .notFound, message: "Element not found: \(elementID)")
            case .ownerMismatch, .scopeMismatch:
                throw RPCError(
                    code: .failedPrecondition,
                    message: "Element does not belong to the requested parent",
                )
            }
        }
    }

    private func readElementCaptureBounds(_ element: AXUIElement) throws -> CGRect {
        let position = try readRequiredAXPoint(
            element: element,
            attribute: kAXPositionAttribute as String,
        )
        let size = try readRequiredAXSize(
            element: element,
            attribute: kAXSizeAttribute as String,
        )
        let bounds = CGRect(origin: position, size: size)
        guard EndpointSafeGeometry.containsValidEndpoints(
            bounds,
            requiresPositiveSize: true,
        ) else {
            throw RPCError(code: .failedPrecondition, message: "Element has invalid AX bounds")
        }
        return bounds
    }

    private func elementCaptureGeometry(
        elementFrame: CGRect,
        display: DisplayTopologyDisplay,
        paddingPixels: Int32,
    ) throws -> ElementCaptureGeometry {
        let scale = CGFloat(display.scale)
        guard scale.isFinite, scale > 0 else {
            throw RPCError(code: .unavailable, message: "Element display scale is unavailable")
        }
        let paddingPoints = CGFloat(paddingPixels) / scale
        let paddedFrame = CGRect(
            x: elementFrame.minX - paddingPoints,
            y: elementFrame.minY - paddingPoints,
            width: elementFrame.width + (paddingPoints * 2),
            height: elementFrame.height + (paddingPoints * 2),
        )
        guard EndpointSafeGeometry.containsValidEndpoints(
            paddedFrame,
            requiresPositiveSize: true,
        ) else {
            throw RPCError(code: .unavailable, message: "Element padding geometry is unavailable")
        }

        let clippedFrame = paddedFrame.intersection(display.frame)
        guard !clippedFrame.isNull,
              EndpointSafeGeometry.containsValidEndpoints(
                  clippedFrame,
                  requiresPositiveSize: true,
              ),
              clippedFrame.containsWithTolerance(elementFrame)
        else {
            throw RPCError(code: .unavailable, message: "Element capture region is unavailable")
        }

        let localMinX = (clippedFrame.minX - display.frame.minX) * scale
        let localMinY = (clippedFrame.minY - display.frame.minY) * scale
        let localMaxX = (clippedFrame.maxX - display.frame.minX) * scale
        let localMaxY = (clippedFrame.maxY - display.frame.minY) * scale
        guard localMinX.isFinite,
              localMinY.isFinite,
              localMaxX.isFinite,
              localMaxY.isFinite
        else {
            throw RPCError(code: .unavailable, message: "Element pixel geometry is unavailable")
        }

        let minX = max(display.frame.minX, display.frame.minX + floor(localMinX) / scale)
        let minY = max(display.frame.minY, display.frame.minY + floor(localMinY) / scale)
        let maxX = min(display.frame.maxX, display.frame.minX + ceil(localMaxX) / scale)
        let maxY = min(display.frame.maxY, display.frame.minY + ceil(localMaxY) / scale)
        let captureRegion = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY,
        )
        guard EndpointSafeGeometry.containsValidEndpoints(
            captureRegion,
            requiresPositiveSize: true,
        ),
            display.frame.containsWithTolerance(captureRegion),
            captureRegion.containsWithTolerance(elementFrame)
        else {
            throw RPCError(code: .unavailable, message: "Element capture region is unavailable")
        }

        return ElementCaptureGeometry(
            captureRegion: captureRegion,
            clipped: !clippedFrame.nearlyEquals(paddedFrame),
        )
    }

    func captureRegionScreenshot(
        request: ServerRequest<Exactmac_V1_CaptureRegionScreenshotRequest>, context: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_CaptureRegionScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureRegionScreenshot] Capturing region screenshot")
        let encoding = try RequestNumericValidation.imageEncoding(
            format: req.format,
            quality: req.quality,
        )
        let format = encoding.format
        let quality = encoding.quality

        // Validate region
        guard req.hasRegion else {
            throw RPCError(
                code: .invalidArgument,
                message: "Region is required",
            )
        }

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

        // Convert proto Region to CGRect
        let bounds = CGRect(
            x: req.region.x,
            y: req.region.y,
            width: req.region.width,
            height: req.region.height,
        )
        guard EndpointSafeGeometry.containsValidEndpoints(
            bounds,
            requiresPositiveSize: true,
        ) else {
            throw RPCErrorHelpers.validationError(
                message: "region endpoints must be finite",
                reason: "INVALID_COORDINATE",
                field: "region",
            )
        }
        if !req.display.isEmpty {
            _ = try ParsingHelpers.parseDisplayName(req.display, field: "display")
        }

        let includeOCR = req.includeOcrText
        return try await captureWorkOwner.withCapture(cancellation: context.cancellation) { [self] in
            let snapshot = try await displayTopologyProvider.snapshot().validated()
            try Task.checkCancellation()
            let display = try captureDisplay(
                containing: bounds,
                explicitName: req.display,
                from: snapshot,
            )
            try Task.checkCancellation()
            let result = try await screenshotCapture.captureRegion(
                bounds,
                display: display,
                format: format,
                quality: quality,
                includeOCR: includeOCR,
            )
            try Task.checkCancellation()
            try validateCaptureOutput(
                result,
                display: display,
                expectedFormat: format,
                containing: bounds,
            )
            try result.ocrResult.validate(requested: includeOCR)

            var response = Exactmac_V1_CaptureRegionScreenshotResponse()
            response.imageData = result.data
            response.format = result.format
            response.width = result.pixelWidth
            response.height = result.pixelHeight
            response.region = regionMessage(result.logicalFrame)
            response.display = display.name
            response.scale = result.scale
            applyOCRResult(result.ocrResult, to: &response)

            Self.logger.info("[captureRegionScreenshot] Captured \(result.pixelWidth, privacy: .public)x\(result.pixelHeight, privacy: .public) region screenshot")
            return ServerResponse(message: response)
        }
    }

    private func validateCaptureOutput(
        _ output: ScreenshotCaptureOutput,
        display: DisplayTopologyDisplay,
        expectedFormat: Exactmac_V1_ImageFormat,
        expectedRegion: CGRect? = nil,
        containing requestedRegion: CGRect? = nil,
    ) throws {
        guard output.displayID == display.displayID,
              output.format == expectedFormat,
              output.pixelWidth > 0,
              output.pixelHeight > 0,
              !output.data.isEmpty,
              output.scale.isFinite,
              abs(output.scale - display.scale) <= 0.001,
              EndpointSafeGeometry.containsValidEndpoints(
                  output.logicalFrame,
                  requiresPositiveSize: true,
              ),
              abs(Double(output.pixelWidth) - Double(output.logicalFrame.width) * output.scale) < 1,
              abs(Double(output.pixelHeight) - Double(output.logicalFrame.height) * output.scale) < 1,
              display.frame.containsWithTolerance(output.logicalFrame),
              expectedRegion.map({ output.logicalFrame.nearlyEquals($0) }) != false,
              requestedRegion.map({ output.logicalFrame.containsWithTolerance($0) }) != false
        else {
            throw RPCError(code: .unavailable, message: "Screenshot source metadata is inconsistent")
        }
        try EncodedImageValidation.validate(
            output.data,
            format: output.format,
            pixelWidth: output.pixelWidth,
            pixelHeight: output.pixelHeight,
        )
    }

    private func applyOCRResult(
        _ result: ScreenshotOCRResult,
        to response: inout Exactmac_V1_CaptureScreenshotResponse,
    ) {
        switch result {
        case .notRequested:
            break
        case let .text(text):
            response.ocrText = text
        case let .failure(status):
            response.ocrError = status
        }
    }

    private func applyOCRResult(
        _ result: ScreenshotOCRResult,
        to response: inout Exactmac_V1_CaptureRegionScreenshotResponse,
    ) {
        switch result {
        case .notRequested:
            break
        case let .text(text):
            response.ocrText = text
        case let .failure(status):
            response.ocrError = status
        }
    }

    private func applyOCRResult(
        _ result: ScreenshotOCRResult,
        to response: inout Exactmac_V1_CaptureElementScreenshotResponse,
    ) {
        switch result {
        case .notRequested:
            break
        case let .text(text):
            response.ocrText = text
        case let .failure(status):
            response.ocrError = status
        }
    }
}

private struct ElementCaptureGeometry {
    let captureRegion: CGRect
    let clipped: Bool
}

private extension CGRect {
    func nearlyEquals(_ other: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }

    func containsWithTolerance(_ other: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        other.minX >= minX - tolerance &&
            other.minY >= minY - tolerance &&
            other.maxX <= maxX + tolerance &&
            other.maxY <= maxY + tolerance
    }
}
