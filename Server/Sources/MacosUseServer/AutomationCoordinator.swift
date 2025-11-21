import AppKit
import CoreGraphics
import Foundation
import MacosUseSDK
import MacosUseSDKProtos
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

    // MARK: - Command Handlers

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

    /// Executes a global input action (not tied to a specific PID)
    @MainActor
    public func handleGlobalInput(
        action: InputActionInfo, showAnimation: Bool, animationDuration: Double,
    ) async throws {
        logger.info("Executing global input action")

        let sdkAction = try convertToSDKInputAction(action)

        // Execute the action with or without visualization
        try await executeInputAction(
            sdkAction, showAnimation: showAnimation, animationDuration: animationDuration,
        )
    }

    /// Performs an action on a specific target application
    @MainActor
    public func handlePerformAction(
        pid: pid_t,
        action: PrimaryActionInfo,
        options: ActionOptionsInfo,
    ) async throws -> ActionResultInfo {
        logger.info("Performing action on PID \(pid, privacy: .public)")

        let sdkAction = try convertToSDKPrimaryAction(action)
        let sdkOptions = convertToSDKActionOptions(pid: pid, options: options)

        let sdkResult = await MacosUseSDK.performAction(action: sdkAction, optionsInput: sdkOptions)

        return try convertFromSDKActionResult(sdkResult)
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
    @MainActor
    public func handleTraverse(pid: pid_t, visibleOnly: Bool) async throws
        -> Macosusesdk_V1_TraverseAccessibilityResponse
    {
        logger.info("Traversing accessibility tree for PID \(pid, privacy: .public)")

        do {
            // Execute traversal on MainActor (required for AX APIs)
            let sdkResponse = try await MainActor.run {
                try MacosUseSDK.traverseAccessibilityTree(
                    pid: pid,
                    onlyVisibleElements: visibleOnly,
                )
            }

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
            throw error
        } catch {
            logger.error("Unexpected error during traversal: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Private Helpers

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
        }
    }
}

// MARK: - Conversion Functions

// These functions convert between proto-like info structs and SDK types
// They will be updated to use actual proto types once generated

extension AutomationCoordinator {
    private nonisolated func convertToSDKInputAction(_ action: InputActionInfo) throws
        -> MacosUseSDK.InputAction
    {
        switch action.type {
        case let .click(x, y):
            return .click(point: CGPoint(x: x, y: y))
        case let .doubleClick(x, y):
            return .doubleClick(point: CGPoint(x: x, y: y))
        case let .rightClick(x, y):
            return .rightClick(point: CGPoint(x: x, y: y))
        case let .typeText(text):
            return .type(text: text)
        case let .pressKey(keyCombo):
            let (keyName, flags) = try parseKeyCombo(keyCombo)
            return .press(keyName: keyName, flags: flags)
        case let .moveTo(x, y):
            return .move(to: CGPoint(x: x, y: y))
        }
    }

    private nonisolated func convertToSDKPrimaryAction(_ action: PrimaryActionInfo) throws
        -> MacosUseSDK.PrimaryAction
    {
        switch action {
        case let .input(inputAction):
            try .input(action: convertToSDKInputAction(inputAction))
        case .traverseOnly:
            .traverseOnly
        }
    }

    private nonisolated func convertToSDKActionOptions(pid: pid_t, options: ActionOptionsInfo)
        -> MacosUseSDK.ActionOptions
    {
        MacosUseSDK.ActionOptions(
            traverseBefore: options.traverseBefore,
            traverseAfter: options.traverseAfter,
            showDiff: options.showDiff,
            onlyVisibleElements: options.onlyVisibleElements,
            showAnimation: options.showAnimation,
            animationDuration: options.animationDuration,
            pidForTraversal: pid,
            delayAfterAction: options.delayAfterAction,
        )
    }

    private nonisolated func convertFromSDKActionResult(_ result: MacosUseSDK.ActionResult) throws
        -> ActionResultInfo
    {
        ActionResultInfo(
            pid: result.openResult?.pid ?? 0,
            appName: result.openResult?.appName ?? "",
            traversalPid: result.traversalPid ?? 0,
            primaryActionError: result.primaryActionError,
            traversalBeforeError: result.traversalBeforeError,
            traversalAfterError: result.traversalAfterError,
        )
    }

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

            if clickType == .right {
                return .rightClick(point: CGPoint(x: mouseClick.position.x, y: mouseClick.position.y))
            } else if clickCount == 2 {
                return .doubleClick(point: CGPoint(x: mouseClick.position.x, y: mouseClick.position.y))
            } else {
                return .click(point: CGPoint(x: mouseClick.position.x, y: mouseClick.position.y))
            }
        case let .typeText(textInput):
            return .type(text: textInput.text)
        case let .pressKey(keyPress):
            let flags = try convertModifiers(keyPress.modifiers)
            return .press(keyName: keyPress.key, flags: flags)
        case let .moveMouse(mouseMove):
            guard mouseMove.hasPosition else {
                throw CoordinatorError.invalidKeyCombo("move missing position")
            }
            return .move(to: CGPoint(x: mouseMove.position.x, y: mouseMove.position.y))
        case .none:
            throw CoordinatorError.invalidKeyCombo("empty input type")
        default:
            throw CoordinatorError.invalidKeyCombo("unsupported input type")
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

    private nonisolated func parseKeyCombo(_ combo: String) throws -> (
        keyName: String, flags: CGEventFlags,
    ) {
        var flags: CGEventFlags = []
        let parts = combo.split(separator: "+").map(String.init)

        guard let keyName = parts.last else {
            throw CoordinatorError.invalidKeyCombo(combo)
        }

        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt", "option":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                throw CoordinatorError.unknownModifier(modifier)
            }
        }

        return (keyName, flags)
    }
}

// MARK: - Temporary Info Structs

// These will be replaced with generated proto types

public enum InputActionInfo {
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case typeText(String)
    case pressKey(String)
    case moveTo(x: Double, y: Double)

    var type: InputActionInfo { self }
}

public enum PrimaryActionInfo {
    case input(InputActionInfo)
    case traverseOnly
}

public struct ActionOptionsInfo {
    public let traverseBefore: Bool
    public let traverseAfter: Bool
    public let showDiff: Bool
    public let onlyVisibleElements: Bool
    public let showAnimation: Bool
    public let animationDuration: Double
    public let delayAfterAction: Double

    public init(
        traverseBefore: Bool = false,
        traverseAfter: Bool = false,
        showDiff: Bool = false,
        onlyVisibleElements: Bool = false,
        showAnimation: Bool = true,
        animationDuration: Double = 0.8,
        delayAfterAction: Double = 0.2,
    ) {
        self.traverseBefore = traverseBefore
        self.traverseAfter = traverseAfter
        self.showDiff = showDiff
        self.onlyVisibleElements = onlyVisibleElements
        self.showAnimation = showAnimation
        self.animationDuration = animationDuration
        self.delayAfterAction = delayAfterAction
    }
}

public struct ActionResultInfo: Sendable {
    public let pid: pid_t
    public let appName: String
    public let traversalPid: pid_t
    public let primaryActionError: String?
    public let traversalBeforeError: String?
    public let traversalAfterError: String?
}

public struct ResponseDataInfo {
    public let appName: String
    public let elementCount: Int
    public let processingTime: String
}

// MARK: - Errors

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
