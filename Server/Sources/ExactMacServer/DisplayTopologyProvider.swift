import AppKit
import CoreGraphics
import Foundation
import GRPCCore

struct DisplayTopologyDisplay: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let isMain: Bool
    let scale: Double

    var name: String {
        "displays/\(displayID)"
    }
}

struct DisplayTopologySnapshot: Sendable {
    struct ActiveDisplay: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let isMain: Bool
    }

    struct Screen: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let visibleFrame: CGRect
        let scale: Double
    }

    let displays: [DisplayTopologyDisplay]

    init(displays: [DisplayTopologyDisplay]) {
        self.displays = displays.sorted { $0.displayID < $1.displayID }
    }

    static func reconcile(
        activeDisplays: [ActiveDisplay],
        screens: [Screen],
    ) throws -> DisplayTopologySnapshot {
        guard !activeDisplays.isEmpty else {
            throw unavailable("No active displays are available")
        }
        guard Set(activeDisplays.map(\.displayID)).count == activeDisplays.count,
              Set(screens.map(\.displayID)).count == screens.count
        else {
            throw unavailable("Display topology contains duplicate display IDs")
        }

        let screensByID = Dictionary(uniqueKeysWithValues: screens.map { ($0.displayID, $0) })
        let displays = try activeDisplays.map { active -> DisplayTopologyDisplay in
            guard active.displayID > 0,
                  EndpointSafeGeometry.containsValidEndpoints(
                      active.frame,
                      requiresPositiveSize: true,
                  ),
                  let screen = screensByID[active.displayID],
                  EndpointSafeGeometry.containsValidEndpoints(
                      screen.frame,
                      requiresPositiveSize: true,
                  ),
                  EndpointSafeGeometry.containsValidEndpoints(
                      screen.visibleFrame,
                      requiresPositiveSize: true,
                  ),
                  screen.scale.isFinite,
                  screen.scale > 0,
                  nearlyEqual(active.frame.size.width, screen.frame.size.width),
                  nearlyEqual(active.frame.size.height, screen.frame.size.height),
                  screen.frame.containsWithTolerance(screen.visibleFrame)
            else {
                throw unavailable(
                    "Display \(active.displayID) lacks coherent CoreGraphics and AppKit metadata",
                )
            }

            let localVisibleX = screen.visibleFrame.minX - screen.frame.minX
            let localVisibleBottom = screen.visibleFrame.minY - screen.frame.minY
            let localVisibleTop = screen.frame.height - (
                localVisibleBottom + screen.visibleFrame.height
            )
            let visibleFrame = CGRect(
                x: active.frame.minX + localVisibleX,
                y: active.frame.minY + localVisibleTop,
                width: screen.visibleFrame.width,
                height: screen.visibleFrame.height,
            )
            guard active.frame.containsWithTolerance(visibleFrame) else {
                throw unavailable(
                    "Display \(active.displayID) has an invalid visible frame conversion",
                )
            }
            return DisplayTopologyDisplay(
                displayID: active.displayID,
                frame: active.frame,
                visibleFrame: visibleFrame,
                isMain: active.isMain,
                scale: screen.scale,
            )
        }
        return try DisplayTopologySnapshot(displays: displays).validated()
    }

    func validated() throws -> DisplayTopologySnapshot {
        guard !displays.isEmpty,
              Set(displays.map(\.displayID)).count == displays.count,
              displays.filter(\.isMain).count == 1
        else {
            throw Self.unavailable("Display topology must contain one exact main display")
        }
        for display in displays {
            guard display.displayID > 0,
                  EndpointSafeGeometry.containsValidEndpoints(
                      display.frame,
                      requiresPositiveSize: true,
                  ),
                  EndpointSafeGeometry.containsValidEndpoints(
                      display.visibleFrame,
                      requiresPositiveSize: true,
                  ),
                  display.frame.containsWithTolerance(display.visibleFrame),
                  display.scale.isFinite,
                  display.scale > 0
            else {
                throw Self.unavailable("Display \(display.displayID) has invalid metadata")
            }
        }
        return self
    }

    func display(id: CGDirectDisplayID) -> DisplayTopologyDisplay? {
        displays.first { $0.displayID == id }
    }

    func mainDisplay() throws -> DisplayTopologyDisplay {
        guard let display = displays.first(where: \.isMain) else {
            throw Self.unavailable("The active main display is unavailable")
        }
        return display
    }

    func displays(containing region: CGRect) -> [DisplayTopologyDisplay] {
        displays.filter { $0.frame.containsWithTolerance(region) }
    }

    private static func unavailable(_ message: String) -> RPCError {
        RPCError(code: .unavailable, message: message)
    }
}

protocol DisplayTopologyProviding: Sendable {
    func snapshot() async throws -> DisplayTopologySnapshot
    func cursorLocation() async throws -> CGPoint
}

struct ProductionDisplayTopologyProvider: DisplayTopologyProviding {
    func snapshot() async throws -> DisplayTopologySnapshot {
        let maxDisplays: UInt32 = 64
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        let error = displayIDs.withUnsafeMutableBufferPointer { pointer in
            CGGetActiveDisplayList(maxDisplays, pointer.baseAddress, &displayCount)
        }
        guard error == .success else {
            throw RPCError(
                code: .unavailable,
                message: "Failed to read the active display topology: \(error)",
            )
        }

        let activeDisplays = displayIDs.prefix(Int(displayCount)).map { displayID in
            DisplayTopologySnapshot.ActiveDisplay(
                displayID: displayID,
                frame: CGDisplayBounds(displayID),
                isMain: CGDisplayIsMain(displayID) != 0,
            )
        }
        let screens = await MainActor.run {
            NSScreen.screens.compactMap { screen -> DisplayTopologySnapshot.Screen? in
                guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber"),
                ] as? NSNumber else {
                    return nil
                }
                return DisplayTopologySnapshot.Screen(
                    displayID: CGDirectDisplayID(number.uint32Value),
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    scale: screen.backingScaleFactor,
                )
            }
        }
        return try DisplayTopologySnapshot.reconcile(
            activeDisplays: activeDisplays,
            screens: screens,
        )
    }

    func cursorLocation() async throws -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            throw RPCError(code: .unavailable, message: "Failed to read cursor position")
        }
        return event.location
    }
}

private extension CGRect {
    func containsWithTolerance(_ other: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        other.minX >= minX - tolerance &&
            other.minY >= minY - tolerance &&
            other.maxX <= maxX + tolerance &&
            other.maxY <= maxY + tolerance
    }
}

private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
    abs(lhs - rhs) <= tolerance
}
