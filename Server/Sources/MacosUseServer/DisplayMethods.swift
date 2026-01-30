import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

// swiftlint:disable conditional_assignment
// Notes: conditional_assignment is intentionally disabled here because we assign
// several related properties of the Display proto using expression-style logic
// to keep the conversion localized and clear.

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
        let err = activeDisplays.withUnsafeMutableBufferPointer { ptr in
            CGGetActiveDisplayList(maxDisplays, ptr.baseAddress, &displayCount)
        }
        if err != CGError.success {
            throw RPCError(code: .internalError, message: "Failed to enumerate displays: \(err)")
        }

        // Build list of (did, bounds) so we can compute visible frames on the MainActor in a single hop
        var displayInfos: [(did: CGDirectDisplayID, bounds: CGRect)] = []
        for i in 0 ..< Int(displayCount) {
            let did = activeDisplays[i]
            let bounds = CGDisplayBounds(did)
            displayInfos.append((did: did, bounds: bounds))
        }

        // Query NSScreen on the main thread once and capture only Sendable primitives (local offsets and scale)
        let screenMap: [CGDirectDisplayID: (localVisibleX: Double, localVisibleY: Double, visibleW: Double, visibleH: Double, scale: Double)] = await MainActor.run {
            var m: [CGDirectDisplayID: (Double, Double, Double, Double, Double)] = [:]
            for screen in NSScreen.screens {
                if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    let did = CGDirectDisplayID(n.uint32Value)
                    // visibleFrame and frame are in AppKit coordinates (bottom-left origin, global)
                    let screenFrame = screen.frame
                    let visibleFrame = screen.visibleFrame

                    // Compute local offsets of visibleFrame relative to the screen's frame (both AppKit coords)
                    let localX = Double(visibleFrame.origin.x - screenFrame.origin.x)
                    let localY = Double(visibleFrame.origin.y - screenFrame.origin.y)

                    m[did] = (localX, localY, Double(visibleFrame.size.width), Double(visibleFrame.size.height), Double(screen.backingScaleFactor))
                }
            }
            return m
        }

        var displays: [Macosusesdk_V1_Display] = []
        for info in displayInfos {
            let did = info.did
            let bounds = info.bounds

            let displayMsg = Macosusesdk_V1_Display.with {
                $0.displayID = Int64(did)

                // Frame in Global Display Coordinates (top-left origin)
                $0.frame = Macosusesdk_Type_Region.with {
                    $0.x = Double(bounds.origin.x)
                    $0.y = Double(bounds.origin.y)
                    $0.width = Double(bounds.size.width)
                    $0.height = Double(bounds.size.height)
                }

                // Visible frame: compute from NSScreen local offsets if available
                $0.visibleFrame = if let entry = screenMap[did] {
                    Macosusesdk_Type_Region.with {
                        $0.x = Double(bounds.origin.x + CGFloat(entry.localVisibleX))
                        $0.y = Double(bounds.origin.y + (bounds.size.height - CGFloat(entry.localVisibleY + entry.visibleH)))
                        $0.width = entry.visibleW
                        $0.height = entry.visibleH
                    }
                } else {
                    // Fallback to full frame if NSScreen not found
                    Macosusesdk_Type_Region.with {
                        $0.x = Double(bounds.origin.x)
                        $0.y = Double(bounds.origin.y)
                        $0.width = Double(bounds.size.width)
                        $0.height = Double(bounds.size.height)
                    }
                }

                $0.scale = if let entry = screenMap[did] {
                    entry.scale
                } else {
                    1.0
                }

                $0.isMain = (CGDisplayIsMain(did) != 0)
            }

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
        let nextPageToken = endIndex < totalCount ? encodePageToken(offset: endIndex) : ""

        let response = Macosusesdk_V1_ListDisplaysResponse.with {
            $0.displays = page
            $0.nextPageToken = nextPageToken
        }

        return ServerResponse(message: response)
    }
}
