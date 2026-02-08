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
    @MainActor
    public func handleOpenApplication(identifier: String) async throws -> Macosusesdk_V1_Application {
        logger.info("Opening application: \(identifier, privacy: .private)")

        let result = try await MacosUseSDK.openApplication(identifier: identifier)

        return Macosusesdk_V1_Application.with {
            $0.name = "applications/\(result.pid)"
            $0.pid = Int32(result.pid)
            $0.displayName = result.appName
        }
    }

    /// Executes an input action globally or on a specific PID
    @MainActor
    public func handleExecuteInput(
        action: Macosusesdk_V1_InputAction, pid: pid_t?, showAnimation: Bool, animationDuration: Double,
    ) async throws {
        logger.info("Executing input action")

        let sdkAction = try convertFromProtoInputAction(action)

        if pid != nil {
            // Execute on specific app - but since it's input, perhaps move mouse or something, but for now, global
            try await executeInputAction(
                sdkAction, showAnimation: showAnimation, animationDuration: animationDuration,
            )
        } else {
            try await executeInputAction(
                sdkAction, showAnimation: showAnimation, animationDuration: animationDuration,
            )
        }
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
        }
    }
}

extension AutomationCoordinator {
    private nonisolated func convertFromProtoInputAction(_ action: Macosusesdk_V1_InputAction) throws
        -> MacosUseSDK.InputAction
    {
        switch action.inputType {
        case let .click(mouseClick):
            guard mouseClick.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("click missing position")
            }
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
            // CRITICAL: Proto coordinates come from AXUIElement (kAXPositionAttribute) which use
            // the same Global Display Coordinate System as CGEvent (top-left origin).
            // NO conversion needed.
            return .move(to: CGPoint(x: mouseMove.position.x, y: mouseMove.position.y))
        case let .buttonDown(buttonDown):
            guard buttonDown.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("buttonDown missing position")
            }
            let point = CGPoint(x: buttonDown.position.x, y: buttonDown.position.y)
            let button = convertButtonType(buttonDown.button)
            let modifiers = try convertModifiers(buttonDown.modifiers)
            return .mouseDown(point: point, button: button, modifiers: modifiers)
        case let .buttonUp(buttonUp):
            guard buttonUp.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("buttonUp missing position")
            }
            let point = CGPoint(x: buttonUp.position.x, y: buttonUp.position.y)
            let button = convertButtonType(buttonUp.button)
            let modifiers = try convertModifiers(buttonUp.modifiers)
            return .mouseUp(point: point, button: button, modifiers: modifiers)
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

    public var errorDescription: String? {
        switch self {
        case let .invalidKeyName(name):
            "Invalid key name: \(name)"
        case let .invalidKeyCombo(combo):
            "Invalid key combo: \(combo)"
        case let .unknownModifier(modifier):
            "Unknown modifier: \(modifier)"
        }
    }
}
