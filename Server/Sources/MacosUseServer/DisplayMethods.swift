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

    func getDisplay(
        request: ServerRequest<Macosusesdk_V1_GetDisplayRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Display> {
        let req = request.message
        Self.logger.info("getDisplay called for \(req.name, privacy: .public)")

        // Parse the display ID from the resource name
        // Format: displays/{display_id}
        let components = req.name.split(separator: "/")
        guard components.count == 2, components[0] == "displays" else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid display resource name: \(req.name). Expected format: displays/{display_id}",
            )
        }

        guard let displayID = UInt32(components[1]) else {
            throw RPCError(
                code: .invalidArgument,
                message: "Invalid display ID: \(components[1])",
            )
        }

        // Get display bounds
        let bounds = CGDisplayBounds(displayID)
        if bounds.origin.x.isNaN || bounds.origin.y.isNaN {
            throw RPCError(
                code: .notFound,
                message: "Display not found: \(displayID)",
            )
        }

        // Query NSScreen for visible frame and scale
        let screenInfo = await MainActor.run { () -> (localVisibleX: Double, localVisibleY: Double, visibleW: Double, visibleH: Double, scale: Double)? in
            for screen in NSScreen.screens {
                if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    let screenDid = CGDirectDisplayID(n.uint32Value)
                    if screenDid == displayID {
                        let screenFrame = screen.frame
                        let visibleFrame = screen.visibleFrame
                        let localX = Double(visibleFrame.origin.x - screenFrame.origin.x)
                        let localY = Double(visibleFrame.origin.y - screenFrame.origin.y)
                        return (localX, localY, Double(visibleFrame.size.width), Double(visibleFrame.size.height), Double(screen.backingScaleFactor))
                    }
                }
            }
            return nil
        }

        let displayMsg = Macosusesdk_V1_Display.with {
            $0.name = req.name
            $0.displayID = Int64(displayID)

            // Frame in Global Display Coordinates (top-left origin)
            $0.frame = Macosusesdk_Type_Region.with {
                $0.x = Double(bounds.origin.x)
                $0.y = Double(bounds.origin.y)
                $0.width = Double(bounds.size.width)
                $0.height = Double(bounds.size.height)
            }

            // Visible frame
            if let entry = screenInfo {
                $0.visibleFrame = Macosusesdk_Type_Region.with {
                    $0.x = Double(bounds.origin.x + CGFloat(entry.localVisibleX))
                    $0.y = Double(bounds.origin.y + (bounds.size.height - CGFloat(entry.localVisibleY + entry.visibleH)))
                    $0.width = entry.visibleW
                    $0.height = entry.visibleH
                }
                $0.scale = entry.scale
            } else {
                // Fallback to full frame
                $0.visibleFrame = $0.frame
                $0.scale = 1.0
            }

            $0.isMain = (CGDisplayIsMain(displayID) != 0)
        }

        return ServerResponse(message: displayMsg)
    }

    func captureCursorPosition(
        request _: ServerRequest<Macosusesdk_V1_CaptureCursorPositionRequest>,
        context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureCursorPositionResponse> {
        Self.logger.info("captureCursorPosition called")

        // Get cursor position from CoreGraphics
        // CGEvent returns Mouse Position in Global Display Coordinates (top-left origin)
        guard let event = CGEvent(source: nil) else {
            throw RPCError(code: .internalError, message: "Failed to create CGEvent for cursor position")
        }
        let cursorLocation = event.location

        // Find which display the cursor is on
        var displayForCursor = "displays/unknown"
        let maxDisplays: UInt32 = 64
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        let err = activeDisplays.withUnsafeMutableBufferPointer { ptr in
            CGGetActiveDisplayList(maxDisplays, ptr.baseAddress, &displayCount)
        }
        if err == CGError.success {
            for i in 0 ..< Int(displayCount) {
                let did = activeDisplays[i]
                let bounds = CGDisplayBounds(did)
                if cursorLocation.x >= bounds.origin.x,
                   cursorLocation.x < bounds.origin.x + bounds.size.width,
                   cursorLocation.y >= bounds.origin.y,
                   cursorLocation.y < bounds.origin.y + bounds.size.height
                {
                    displayForCursor = "displays/\(did)"
                    break
                }
            }
        }

        let response = Macosusesdk_V1_CaptureCursorPositionResponse.with {
            $0.x = cursorLocation.x
            $0.y = cursorLocation.y
            $0.display = displayForCursor
        }

        return ServerResponse(message: response)
    }
}
