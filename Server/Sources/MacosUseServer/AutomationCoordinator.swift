import Foundation
import AppKit
import MacosUseSDK
import CoreGraphics

/// Global actor that coordinates all SDK interactions on the main thread.
/// This is critical because the MacosUseSDK requires main thread execution
/// for all UI-related operations.
@globalActor
public final class AutomationCoordinator {
    public static let shared = AutomationCoordinator()
    
    @MainActor
    private init() {
        fputs("info: [AutomationCoordinator] Initialized on main thread\n", stderr)
    }
    
    // MARK: - Command Handlers
    
    /// Opens or activates an application and returns target info
    @MainActor
    public func handleOpenApplication(identifier: String) async throws -> TargetApplicationInfo {
        fputs("info: [AutomationCoordinator] Opening application: \(identifier)\n", stderr)
        
        let result = try await MacosUseSDK.openApplication(identifier: identifier)
        
        return TargetApplicationInfo(
            name: "targetApplications/\(result.pid)",
            pid: result.pid,
            appName: result.appName
        )
    }
    
    /// Executes a global input action (not tied to a specific PID)
    @MainActor
    public func handleGlobalInput(action: InputActionInfo, showAnimation: Bool, animationDuration: Double) async throws {
        fputs("info: [AutomationCoordinator] Executing global input action\n", stderr)
        
        let sdkAction = try convertToSDKInputAction(action)
        
        // Execute the action with or without visualization
        try await executeInputAction(sdkAction, showAnimation: showAnimation, animationDuration: animationDuration)
    }
    
    /// Performs an action on a specific target application
    @MainActor
    public func handlePerformAction(
        pid: pid_t,
        action: PrimaryActionInfo,
        options: ActionOptionsInfo
    ) async throws -> ActionResultInfo {
        fputs("info: [AutomationCoordinator] Performing action on PID \(pid)\n", stderr)
        
        let sdkAction = try convertToSDKPrimaryAction(action)
        let sdkOptions = convertToSDKActionOptions(pid: pid, options: options)
        
        let sdkResult = await MacosUseSDK.performAction(action: sdkAction, optionsInput: sdkOptions)
        
        return try convertFromSDKActionResult(sdkResult)
    }
    
    /// Traverses the accessibility tree for a specific application
    @MainActor
    public func handleTraverse(pid: pid_t, visibleOnly: Bool) async throws -> ResponseDataInfo {
        fputs("info: [AutomationCoordinator] Traversing accessibility tree for PID \(pid)\n", stderr)
        
        let sdkResponse = try MacosUseSDK.traverseAccessibilityTree(
            pid: pid,
            onlyVisibleElements: visibleOnly
        )
        
        return try convertFromSDKResponseData(sdkResponse)
    }
    
    // MARK: - Private Helpers
    
    @MainActor
    private func executeInputAction(_ action: MacosUseSDK.InputAction, showAnimation: Bool, animationDuration: Double) async throws {
        switch action {
        case .click(let point):
            if showAnimation {
                try MacosUseSDK.clickMouseAndVisualize(at: point, duration: animationDuration)
            } else {
                try MacosUseSDK.clickMouse(at: point)
            }
        case .doubleClick(let point):
            if showAnimation {
                try MacosUseSDK.doubleClickMouseAndVisualize(at: point, duration: animationDuration)
            } else {
                try MacosUseSDK.doubleClickMouse(at: point)
            }
        case .rightClick(let point):
            if showAnimation {
                try MacosUseSDK.rightClickMouseAndVisualize(at: point, duration: animationDuration)
            } else {
                try MacosUseSDK.rightClickMouse(at: point)
            }
        case .type(let text):
            if showAnimation {
                try MacosUseSDK.writeTextAndVisualize(text, duration: nil)
            } else {
                try MacosUseSDK.writeText(text)
            }
        case .press(let keyName, let flags):
            guard let keyCode = MacosUseSDK.mapKeyNameToKeyCode(keyName) else {
                throw CoordinatorError.invalidKeyName(keyName)
            }
            if showAnimation {
                try MacosUseSDK.pressKeyAndVisualize(keyCode: keyCode, flags: flags, duration: animationDuration)
            } else {
                try MacosUseSDK.pressKey(keyCode: keyCode, flags: flags)
            }
        case .move(let point):
            if showAnimation {
                try MacosUseSDK.moveMouseAndVisualize(to: point, duration: animationDuration)
            } else {
                try MacosUseSDK.moveMouse(to: point)
            }
        }
    }
}

// MARK: - Conversion Functions

// These functions convert between proto-like info structs and SDK types
// They will be updated to use actual proto types once generated

extension AutomationCoordinator {
    private func convertToSDKInputAction(_ action: InputActionInfo) throws -> MacosUseSDK.InputAction {
        switch action.type {
        case .click(let x, let y):
            return .click(point: CGPoint(x: x, y: y))
        case .doubleClick(let x, let y):
            return .doubleClick(point: CGPoint(x: x, y: y))
        case .rightClick(let x, let y):
            return .rightClick(point: CGPoint(x: x, y: y))
        case .typeText(let text):
            return .type(text: text)
        case .pressKey(let keyCombo):
            let (keyName, flags) = try parseKeyCombo(keyCombo)
            return .press(keyName: keyName, flags: flags)
        case .moveTo(let x, let y):
            return .move(to: CGPoint(x: x, y: y))
        }
    }
    
    private func convertToSDKPrimaryAction(_ action: PrimaryActionInfo) throws -> MacosUseSDK.PrimaryAction {
        switch action {
        case .input(let inputAction):
            return .input(action: try convertToSDKInputAction(inputAction))
        case .traverseOnly:
            return .traverseOnly
        }
    }
    
    private func convertToSDKActionOptions(pid: pid_t, options: ActionOptionsInfo) -> MacosUseSDK.ActionOptions {
        return MacosUseSDK.ActionOptions(
            traverseBefore: options.traverseBefore,
            traverseAfter: options.traverseAfter,
            showDiff: options.showDiff,
            onlyVisibleElements: options.onlyVisibleElements,
            showAnimation: options.showAnimation,
            animationDuration: options.animationDuration,
            pidForTraversal: pid,
            delayAfterAction: options.delayAfterAction
        )
    }
    
    private func convertFromSDKActionResult(_ result: MacosUseSDK.ActionResult) throws -> ActionResultInfo {
        return ActionResultInfo(
            pid: result.openResult?.pid ?? 0,
            appName: result.openResult?.appName ?? "",
            traversalPid: result.traversalPid ?? 0,
            primaryActionError: result.primaryActionError,
            traversalBeforeError: result.traversalBeforeError,
            traversalAfterError: result.traversalAfterError
        )
    }
    
    private func convertFromSDKResponseData(_ data: MacosUseSDK.ResponseData) throws -> ResponseDataInfo {
        return ResponseDataInfo(
            appName: data.appName,
            elementCount: data.elements.count,
            processingTime: data.processingTimeSeconds
        )
    }
    
    private func parseKeyCombo(_ combo: String) throws -> (keyName: String, flags: CGEventFlags) {
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
        delayAfterAction: Double = 0.2
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

public struct ActionResultInfo {
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
        case .invalidKeyName(let name):
            return "Invalid key name: \(name)"
        case .invalidKeyCombo(let combo):
            return "Invalid key combo: \(combo)"
        case .unknownModifier(let modifier):
            return "Unknown modifier: \(modifier)"
        }
    }
}
