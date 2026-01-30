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
    func listDisplays(
        request: ServerRequest<Macosusesdk_V1_ListDisplaysRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListDisplaysResponse> {
        let req = request.message
        Self.logger.info("listDisplays called")

        // Enumerate active displays using CoreGraphics
        let maxDisplays: UInt32 = 64
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        let err = CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
        if err != CGError.success {
            throw RPCError(code: .internalError, message: "Failed to enumerate displays: \(err)")
        }

        var displays: [Macosusesdk_V1_Display] = []
        for i in 0 ..< Int(displayCount) {
            let did = activeDisplays[i]
            let bounds = CGDisplayBounds(did)

            var displayMsg = Macosusesdk_V1_Display()
            displayMsg.displayID = Int64(did)
            displayMsg.frame = Macosusesdk_Type_Region.with {
                $0.x = Double(bounds.origin.x)
                $0.y = Double(bounds.origin.y)
                $0.width = Double(bounds.size.width)
                $0.height = Double(bounds.size.height)
            }

            // Some NSScreen APIs must be used on the main thread. Capture only Sendable values (NSRect, Double).
            var visibleRegion = Macosusesdk_Type_Region()
            var backingScale = 1.0
            let (maybeVisibleFrame, maybeBackingScale): (NSRect?, Double) = await MainActor.run {
                if let screen = NSScreen.screens.first(where: { scr in
                    if let n = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        return n.uint32Value == did
                    }
                    return false
                }) {
                    return (screen.visibleFrame, screen.backingScaleFactor)
                }
                return (nil, 1.0)
            }

            if let visibleFrame = maybeVisibleFrame {
                backingScale = maybeBackingScale
                visibleRegion = Macosusesdk_Type_Region.with {
                    $0.x = Double(bounds.origin.x + visibleFrame.origin.x)
                    // Convert from AppKit (bottom-left origin) visibleFrame to Global Display Coordinates (top-left origin)
                    $0.y = Double(bounds.origin.y + (bounds.size.height - (visibleFrame.origin.y + visibleFrame.size.height)))
                    $0.width = Double(visibleFrame.size.width)
                    $0.height = Double(visibleFrame.size.height)
                }
            } else {
                // Fallback to full frame if NSScreen not found
                visibleRegion = displayMsg.frame
            }

            displayMsg.visibleFrame = visibleRegion
            displayMsg.isMain = (CGDisplayIsMain(did) != 0)
            displayMsg.scale = backingScale

            displays.append(displayMsg)
        }

        // Sort results deterministically by display ID
        displays.sort { $0.displayID < $1.displayID }

        // Pagination per AIP-158
        let offset: Int = if req.pageToken.isEmpty { 0 } else { try decodePageToken(req.pageToken) }
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = displays.count
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let page = Array(displays[startIndex ..< endIndex])
        let nextPageToken = if endIndex < totalCount { encodePageToken(offset: endIndex) } else { "" }

        let response = Macosusesdk_V1_ListDisplaysResponse.with {
            $0.displays = page
            $0.nextPageToken = nextPageToken
        }

        return ServerResponse(message: response)
    }
}
