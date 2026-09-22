import CoreGraphics
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

extension ExactMacService {
    /// Compatibility helper for existing pure tests. Production RPCs resolve
    /// cursor ownership from the injected immutable topology snapshot below.
    static func displayNameForCursor(
        cursorLocation: CGPoint,
        activeDisplays: [CGDirectDisplayID],
    ) throws -> String {
        for displayID in activeDisplays where displayID > 0 {
            let bounds = CGDisplayBounds(displayID)
            if bounds.containsHalfOpen(cursorLocation) {
                let name = "displays/\(displayID)"
                _ = try ParsingHelpers.parseDisplayName(name, field: "display")
                return name
            }
        }
        throw RPCError(
            code: .internalError,
            message: "Cursor position does not belong to an active display",
        )
    }

    func listDisplays(
        request: ServerRequest<Exactmac_V1_ListDisplaysRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListDisplaysResponse> {
        let req = request.message
        Self.logger.info("listDisplays called")
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize)
        let queryBinding = ParsingHelpers.pageTokenQuery(
            method: "ListDisplays",
            parameters: [("page_size", String(pageSize))],
        )
        let offset = try ParsingHelpers.pageOffset(
            token: req.pageToken,
            queryBinding: queryBinding,
        )
        let snapshot = try await displayTopologyProvider.snapshot().validated()
        let displays = snapshot.displays.map(displayMessage)
        let range = try ParsingHelpers.pageRange(
            offset: offset,
            pageSize: pageSize,
            totalCount: displays.count,
        )
        let response = Exactmac_V1_ListDisplaysResponse.with {
            $0.displays = Array(displays[range])
            $0.nextPageToken = ParsingHelpers.nextPageToken(
                endOffset: range.upperBound,
                totalCount: displays.count,
                queryBinding: queryBinding,
            )
        }
        return ServerResponse(message: response)
    }

    func getDisplay(
        request: ServerRequest<Exactmac_V1_GetDisplayRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Display> {
        let req = request.message
        Self.logger.info("getDisplay called for \(req.name, privacy: .public)")
        let displayID = try ParsingHelpers.parseDisplayName(req.name).displayID
        let snapshot = try await displayTopologyProvider.snapshot().validated()
        guard let display = snapshot.display(id: displayID) else {
            throw RPCError(code: .notFound, message: "Display not found: \(req.name)")
        }
        return ServerResponse(message: displayMessage(display))
    }

    func captureCursorPosition(
        request _: ServerRequest<Exactmac_V1_CaptureCursorPositionRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_CaptureCursorPositionResponse> {
        Self.logger.info("captureCursorPosition called")
        let snapshot = try await displayTopologyProvider.snapshot().validated()
        let location = try await displayTopologyProvider.cursorLocation()
        let matches = snapshot.displays.filter { $0.frame.containsHalfOpen(location) }
        guard matches.count == 1, let display = matches.first else {
            throw RPCError(
                code: .unavailable,
                message: "Cursor position does not belong to one exact active display",
            )
        }
        return ServerResponse(
            message: Exactmac_V1_CaptureCursorPositionResponse.with {
                $0.x = location.x
                $0.y = location.y
                $0.display = display.name
            },
        )
    }

    private func displayMessage(_ display: DisplayTopologyDisplay) -> Exactmac_V1_Display {
        Exactmac_V1_Display.with {
            $0.name = display.name
            $0.displayID = Int64(display.displayID)
            $0.frame = regionMessage(display.frame)
            $0.visibleFrame = regionMessage(display.visibleFrame)
            $0.isMain = display.isMain
            $0.scale = display.scale
        }
    }

    func captureDisplay(
        name: String,
        from snapshot: DisplayTopologySnapshot,
    ) throws -> DisplayTopologyDisplay {
        guard !name.isEmpty else {
            return try snapshot.mainDisplay()
        }
        let displayID = try ParsingHelpers.parseDisplayName(name, field: "display").displayID
        guard let display = snapshot.display(id: displayID) else {
            throw RPCError(code: .notFound, message: "Display not found: \(name)")
        }
        return display
    }

    func captureDisplay(
        containing region: CGRect,
        explicitName: String,
        from snapshot: DisplayTopologySnapshot,
    ) throws -> DisplayTopologyDisplay {
        if !explicitName.isEmpty {
            let display = try captureDisplay(name: explicitName, from: snapshot)
            guard display.frame.containsWithTolerance(region) else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "Region is not fully contained by the selected display",
                )
            }
            return display
        }
        let matches = snapshot.displays(containing: region)
        guard matches.count == 1, let display = matches.first else {
            throw RPCError(
                code: .invalidArgument,
                message: matches.isEmpty
                    ? "Region crosses or falls outside active displays"
                    : "Region belongs to multiple active displays",
            )
        }
        return display
    }

    func regionMessage(_ frame: CGRect) -> Exactmac_Type_Region {
        Exactmac_Type_Region.with {
            $0.x = frame.origin.x
            $0.y = frame.origin.y
            $0.width = frame.width
            $0.height = frame.height
        }
    }
}

private extension CGRect {
    func containsHalfOpen(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    func containsWithTolerance(_ other: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        other.minX >= minX - tolerance &&
            other.minY >= minY - tolerance &&
            other.maxX <= maxX + tolerance &&
            other.maxY <= maxY + tolerance
    }
}
