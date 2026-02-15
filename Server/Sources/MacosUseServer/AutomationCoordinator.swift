import AppKit
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

private let logger = MacosUseSDK.sdkLogger(category: "AutomationCoordinator")

/// Actor that coordinates all SDK interactions on the main thread.
/// This is critical because the MacosUseSDK requires main thread execution
/// for all UI-related operations.
public actor AutomationCoordinator {
    public static let shared = AutomationCoordinator()

    private init() {
        logger.info("Initialized")
    }

    /// Opens or activates an application and returns target info
    /// - Parameter identifier: The application name, bundle ID, or path
    /// - Parameter background: If true, opens without activating (stealing focus)
    @MainActor
    public func handleOpenApplication(identifier: String, background: Bool = false) async throws -> Macosusesdk_V1_Application {
        logger.info("Opening application: \(identifier, privacy: .private) background=\(background, privacy: .public)")

        let result = try await MacosUseSDK.openApplication(identifier: identifier, background: background)

        return Macosusesdk_V1_Application.with {
            $0.name = "applications/\(result.pid)"
            $0.pid = Int32(result.pid)
            $0.displayName = result.appName
        }
    }

    /// Executes an input action globally or on a specific PID.
    ///
    /// For keyboard-targeted actions (key press, key hold, text typing), the
    /// target application is activated (brought to the foreground) first when a
    /// PID is provided. This is necessary because CGEvent keyboard events are
    /// delivered to whichever application currently has keyboard focus, NOT to a
    /// specific process. Mouse events (click, drag, etc.) are routed by screen
    /// coordinates and do not require prior activation.
    @MainActor
    public func handleExecuteInput(
        action: Macosusesdk_V1_InputAction, pid: pid_t?, showAnimation: Bool, animationDuration: Double,
    ) async throws {
        logger.info("Executing input action")

        let sdkAction = try convertFromProtoInputAction(action)

        // Activate the target application for keyboard actions so that CGEvent
        // key events reach the correct process.
        if let pid, sdkAction.requiresKeyboardFocus {
            if let app = NSRunningApplication(processIdentifier: pid) {
                let activated = app.activate()
                if activated {
                    logger.info("Activated application PID \(pid, privacy: .public) for keyboard input")
                    // Brief pause for activation to propagate through the window server.
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                } else {
                    logger.warning("Failed to activate application PID \(pid, privacy: .public) for keyboard input")
                }
            } else {
                logger.warning("No NSRunningApplication found for PID \(pid, privacy: .public)")
            }
        }

        try await executeInputAction(
            sdkAction, showAnimation: showAnimation, animationDuration: animationDuration,
        )
    }

    /// Traverses the accessibility tree for a given PID
    /// - Parameters:
    ///   - pid: The process identifier to traverse.
    ///   - visibleOnly: When true, only geometrically visible elements are collected.
    ///   - shouldActivate: When true, the target app is activated (brought to foreground) before
    ///     traversal. Defaults to false so background polling (ObservationManager) never steals focus.
    public func handleTraverse(pid: pid_t, visibleOnly: Bool, shouldActivate: Bool = false) async throws
        -> Macosusesdk_V1_TraverseAccessibilityResponse
    {
        logger.info("Traversing accessibility tree for PID \(pid, privacy: .public) (shouldActivate=\(shouldActivate, privacy: .public))")

        // When shouldActivate is true, mark the PID on the ChangeDetector *before*
        // the activation so that the resulting NSWorkspace notification is suppressed
        // and not echoed back as a user-initiated event.
        //
        // Accepted edge case: if the app is already active, activate() won't fire but
        // sdkActivatedPIDs is still populated, causing a ≤500ms window of false
        // deactivation suppression for this PID. This is rare (requesting activation
        // for an already-active app) and the window is short.
        if shouldActivate {
            await MainActor.run {
                ChangeDetector.shared.markSDKActivation(pid: pid)
            }
        }

        do {
            // CRITICAL FIX: Run traversal on background thread to prevent main thread blocking
            // AX APIs are thread-safe and should NOT block the main actor
            let sdkResponse = try await Task.detached(priority: .userInitiated) {
                try MacosUseSDK.traverseAccessibilityTree(
                    pid: pid,
                    onlyVisibleElements: visibleOnly,
                    shouldActivate: shouldActivate,
                )
            }.value

            // Offload protobuf conversion to background to avoid blocking MainActor
            return await Task.detached {
                // Element conversion and proto building
                let elements = sdkResponse.elements.map { sdkElement in
                    Macosusesdk_Type_Element.with {
                        $0.role = sdkElement.role
                        $0.text = sdkElement.text ?? ""
                        $0.x = sdkElement.x ?? 0
                        $0.y = sdkElement.y ?? 0
                        $0.width = sdkElement.width ?? 0
                        $0.height = sdkElement.height ?? 0
                        // CRITICAL: Copy path for change detection (used as dictionary key in ObservationManager)
                        $0.path = sdkElement.path
                    }
                }

                let statistics = Macosusesdk_Type_TraversalStats.with {
                    $0.count = Int32(sdkResponse.elements.count)
                }

                return Macosusesdk_V1_TraverseAccessibilityResponse.with {
                    $0.app = sdkResponse.app_name
                    $0.elements = elements
                    $0.stats = statistics
                    $0.processingTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
                }
            }.value
        } catch let error as MacosUseSDK.MacosUseSDKError {
            logger.error("SDK error during traversal: \(error.localizedDescription, privacy: .public)")
            // Convert SDK errors to RPCError so gRPC can handle them properly
            switch error {
            case .accessibilityDenied:
                throw RPCError(code: .permissionDenied, message: error.localizedDescription)
            case let .appNotFound(pid):
                throw RPCError(code: .notFound, message: "Application with PID \(pid) not found")
            case let .jsonEncodingFailed(underlyingError):
                throw RPCError(code: .internalError, message: "JSON encoding failed: \(underlyingError.localizedDescription)")
            case let .internalError(message):
                throw RPCError(code: .internalError, message: message)
            }
        } catch {
            logger.error("Unexpected error during traversal: \(String(describing: error), privacy: .public)")
            throw RPCError(code: .unknown, message: "Unexpected error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func executeInputAction(
        _ action: MacosUseSDK.InputAction, showAnimation: Bool, animationDuration: Double,
    ) async throws {
        switch action {
        case let .click(point):
            if showAnimation {
                try await MacosUseSDK.clickMouseAndVisualize(at: point, duration: animationDuration)
            } else {
                try await MacosUseSDK.clickMouse(at: point)
            }
        case let .doubleClick(point):
            if showAnimation {
                try await MacosUseSDK.doubleClickMouseAndVisualize(at: point, duration: animationDuration)
            } else {
                try await MacosUseSDK.doubleClickMouse(at: point)
            }
        case let .rightClick(point):
            if showAnimation {
                try await MacosUseSDK.rightClickMouseAndVisualize(at: point, duration: animationDuration)
            } else {
                try await MacosUseSDK.rightClickMouse(at: point)
            }
        case let .type(text):
            if showAnimation {
                try await MacosUseSDK.writeTextAndVisualize(text, duration: nil)
            } else {
                try await MacosUseSDK.writeText(text)
            }
        case let .press(keyName, flags):
            guard let keyCode = MacosUseSDK.mapKeyNameToKeyCode(keyName) else {
                throw CoordinatorError.invalidKeyName(keyName)
            }
            if showAnimation {
                try await MacosUseSDK.pressKeyAndVisualize(
                    keyCode: keyCode, flags: flags, duration: animationDuration,
                )
            } else {
                try await MacosUseSDK.pressKey(keyCode: keyCode, flags: flags)
            }
        case let .move(point):
            if showAnimation {
                try await MacosUseSDK.moveMouseAndVisualize(to: point, duration: animationDuration)
            } else {
                try await MacosUseSDK.moveMouse(to: point)
            }
        case let .pressHold(keyName, flags, duration):
            guard let keyCode = MacosUseSDK.mapKeyNameToKeyCode(keyName) else {
                throw CoordinatorError.invalidKeyName(keyName)
            }
            // pressKeyHold does not have a visualization variant currently
            try await MacosUseSDK.pressKeyHold(keyCode: keyCode, flags: flags, duration: duration)
        case let .mouseDown(point, button, modifiers):
            // No visualization for stateful mouse events
            try await MacosUseSDK.mouseButtonDown(at: point, button: button, modifiers: modifiers)
        case let .mouseUp(point, button, modifiers):
            // No visualization for stateful mouse events
            try await MacosUseSDK.mouseButtonUp(at: point, button: button, modifiers: modifiers)
        case let .drag(from, to, button, duration):
            // Complete drag operation with incremental leftMouseDragged events
            try await MacosUseSDK.performDrag(from: from, to: to, button: button, duration: duration)
        }
    }
}

extension AutomationCoordinator {
    /// Validates that a coordinate value is finite (not NaN or ±Infinity).
    /// CGEvent behavior with non-finite coordinates is undefined and dangerous.
    private nonisolated func validateCoordinate(
        _ value: Double, field: String, inputType: String,
    ) throws {
        guard value.isFinite else {
            throw CoordinatorError.invalidCoordinate(
                "\(inputType) has non-finite \(field) coordinate: \(value)",
            )
        }
    }

    private nonisolated func convertFromProtoInputAction(_ action: Macosusesdk_V1_InputAction) throws
        -> MacosUseSDK.InputAction
    {
        switch action.inputType {
        case let .click(mouseClick):
            guard mouseClick.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("click missing position")
            }
            try validateCoordinate(mouseClick.position.x, field: "x", inputType: "click")
            try validateCoordinate(mouseClick.position.y, field: "y", inputType: "click")
            let clickType = mouseClick.clickType
            let clickCount = mouseClick.clickCount

            // CRITICAL: Proto coordinates come from AXUIElement (kAXPositionAttribute) which use
            // the same Global Display Coordinate System as CGEvent (top-left origin).
            // NO conversion needed.
            let point = CGPoint(x: mouseClick.position.x, y: mouseClick.position.y)

            if clickType == .right {
                return .rightClick(point: point)
            } else if clickCount == 2 {
                return .doubleClick(point: point)
            } else {
                return .click(point: point)
            }
        case let .typeText(textInput):
            return .type(text: textInput.text)
        case let .pressKey(keyPress):
            let flags = try convertModifiers(keyPress.modifiers)
            // Check if holdDuration is set (non-zero means hold key)
            if keyPress.holdDuration > 0 {
                return .pressHold(keyName: keyPress.key, flags: flags, duration: keyPress.holdDuration)
            }
            return .press(keyName: keyPress.key, flags: flags)
        case let .moveMouse(mouseMove):
            guard mouseMove.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("move missing position")
            }
            try validateCoordinate(mouseMove.position.x, field: "x", inputType: "move")
            try validateCoordinate(mouseMove.position.y, field: "y", inputType: "move")
            // CRITICAL: Proto coordinates come from AXUIElement (kAXPositionAttribute) which use
            // the same Global Display Coordinate System as CGEvent (top-left origin).
            // NO conversion needed.
            return .move(to: CGPoint(x: mouseMove.position.x, y: mouseMove.position.y))
        case let .buttonDown(buttonDown):
            guard buttonDown.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("buttonDown missing position")
            }
            try validateCoordinate(buttonDown.position.x, field: "x", inputType: "buttonDown")
            try validateCoordinate(buttonDown.position.y, field: "y", inputType: "buttonDown")
            let point = CGPoint(x: buttonDown.position.x, y: buttonDown.position.y)
            let button = convertButtonType(buttonDown.button)
            let modifiers = try convertModifiers(buttonDown.modifiers)
            return .mouseDown(point: point, button: button, modifiers: modifiers)
        case let .buttonUp(buttonUp):
            guard buttonUp.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("buttonUp missing position")
            }
            try validateCoordinate(buttonUp.position.x, field: "x", inputType: "buttonUp")
            try validateCoordinate(buttonUp.position.y, field: "y", inputType: "buttonUp")
            let point = CGPoint(x: buttonUp.position.x, y: buttonUp.position.y)
            let button = convertButtonType(buttonUp.button)
            let modifiers = try convertModifiers(buttonUp.modifiers)
            return .mouseUp(point: point, button: button, modifiers: modifiers)
        case let .drag(mouseDrag):
            guard mouseDrag.hasStartPosition, mouseDrag.hasEndPosition else {
                throw CoordinatorError.invalidKeyCombo("drag missing start_position or end_position")
            }
            try validateCoordinate(mouseDrag.startPosition.x, field: "start_x", inputType: "drag")
            try validateCoordinate(mouseDrag.startPosition.y, field: "start_y", inputType: "drag")
            try validateCoordinate(mouseDrag.endPosition.x, field: "end_x", inputType: "drag")
            try validateCoordinate(mouseDrag.endPosition.y, field: "end_y", inputType: "drag")
            let from = CGPoint(x: mouseDrag.startPosition.x, y: mouseDrag.startPosition.y)
            let to = CGPoint(x: mouseDrag.endPosition.x, y: mouseDrag.endPosition.y)
            let button = convertButtonType(mouseDrag.button)
            return .drag(from: from, to: to, button: button, duration: mouseDrag.duration)
        case .none:
            throw CoordinatorError.invalidKeyCombo("empty input type")
        default:
            throw CoordinatorError.invalidKeyCombo("unsupported input type")
        }
    }

    private nonisolated func convertButtonType(_ buttonType: Macosusesdk_V1_MouseClick.ClickType) -> CGMouseButton {
        switch buttonType {
        case .right:
            .right
        case .middle:
            .center
        default:
            .left
        }
    }

    private nonisolated func convertModifiers(_ modifiers: [Macosusesdk_V1_KeyPress.Modifier]) throws
        -> CGEventFlags
    {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            case .shift:
                flags.insert(.maskShift)
            case .function:
                flags.insert(.maskSecondaryFn)
            default:
                break
            }
        }
        return flags
    }
}

public enum CoordinatorError: Error, LocalizedError {
    case invalidKeyName(String)
    case invalidKeyCombo(String)
    case unknownModifier(String)
    case invalidCoordinate(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidKeyName(name):
            "Invalid key name: \(name)"
        case let .invalidKeyCombo(combo):
            "Invalid key combo: \(combo)"
        case let .unknownModifier(modifier):
            "Unknown modifier: \(modifier)"
        case let .invalidCoordinate(detail):
            "Invalid coordinate: \(detail)"
        }
    }
}
