import AppKit // Needed for Process and potentially other things later
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

private let logger = sdkLogger(category: "InputController")

// --- Dynamic Key Code Resolution via TIS/UCKeyTranslate ---

/// Resolves a `CGKeyCode` for a given character by querying the current keyboard
/// input source via TIS and translating each virtual key code with `UCKeyTranslate`.
///
/// This enables correct key-code mapping on non-US keyboard layouts (AZERTY,
/// QWERTZ, Dvorak, etc.) where the physical key that produces a given character
/// differs from the US-QWERTY assumption.
///
/// - Parameter character: A single-character string to resolve (e.g. "a", "z", "/").
/// - Returns: The `CGKeyCode` whose unmodified output matches `character`
///   (case-insensitive), or `nil` if no match is found or the TIS APIs are
///   unavailable.
public func resolveKeyCode(for character: String) -> CGKeyCode? {
    guard character.count == 1 else {
        logger.warning(
            "resolveKeyCode called with multi-character string; returning nil",
        )
        return nil
    }

    let target = character.lowercased()

    // 1. Obtain the current keyboard input source.
    guard let sourceRef = TISCopyCurrentKeyboardInputSource() else {
        logger.warning("TISCopyCurrentKeyboardInputSource returned nil")
        return nil
    }
    let source = sourceRef.takeRetainedValue()

    // 2. Get the Unicode key layout data.
    guard
        let layoutDataRef = TISGetInputSourceProperty(
            source, kTISPropertyUnicodeKeyLayoutData,
        )
    else {
        logger.warning(
            "TISGetInputSourceProperty returned nil for kTISPropertyUnicodeKeyLayoutData",
        )
        return nil
    }

    let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
    let layoutPtr = unsafeBitCast(
        CFDataGetBytePtr(layoutData),
        to: UnsafePointer<UCKeyboardLayout>.self,
    )

    let keyboardType = UInt32(LMGetKbdType())

    // 3. Iterate virtual key codes 0-127 and translate each.
    var deadKeyState: UInt32 = 0
    let maxLength = 4
    var chars = [UniChar](repeating: 0, count: maxLength)
    var actualLength = 0

    for keyCode: UInt16 in 0 ... 127 {
        deadKeyState = 0
        actualLength = 0

        let status = UCKeyTranslate(
            layoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0, // no modifiers
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            maxLength,
            &actualLength,
            &chars,
        )

        guard status == noErr, actualLength > 0 else { continue }

        let produced = String(
            utf16CodeUnits: chars, count: actualLength,
        ).lowercased()

        if produced == target {
            logger.debug(
                "resolveKeyCode: '\(character, privacy: .public)' -> keyCode \(keyCode, privacy: .public)",
            )
            return CGKeyCode(keyCode)
        }
    }

    logger.info(
        "resolveKeyCode: no key code found for '\(character, privacy: .public)' on current layout",
    )
    return nil
}

/// --- Add new Error Cases for Input Control ---
public extension MacosUseSDKError {
    /// Add specific error cases relevant to InputController
    static func inputInvalidArgument(_ message: String) -> MacosUseSDKError {
        .internalError("Input Argument Error: \(message)") // Reuse internalError or create specific types
    }

    static func inputSimulationFailed(_ message: String) -> MacosUseSDKError {
        .internalError("Input Simulation Failed: \(message)")
    }

    static func osascriptExecutionFailed(status: Int32, message: String = "")
        -> MacosUseSDKError
    {
        .internalError("osascript execution failed with status \(status). \(message)")
    }
}

// --- Constants for Key Codes ---
// These match the constants used in the Rust macos.rs code for consistency
public let KEY_RETURN: CGKeyCode = 36
public let KEY_TAB: CGKeyCode = 48
public let KEY_SPACE: CGKeyCode = 49
public let KEY_DELETE: CGKeyCode = 51 // Matches 'delete' (backspace on many keyboards)
public let KEY_ESCAPE: CGKeyCode = 53
public let KEY_ARROW_LEFT: CGKeyCode = 123
public let KEY_ARROW_RIGHT: CGKeyCode = 124
public let KEY_ARROW_DOWN: CGKeyCode = 125
public let KEY_ARROW_UP: CGKeyCode = 126
// Add other key codes as needed (consider making them public if the tool needs direct access)

// --- Helper Functions (Internal or Fileprivate) ---

/// Creates a CGEventSource or throws
private func createEventSource() throws -> CGEventSource {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw MacosUseSDKError.inputSimulationFailed("failed to create event source")
    }
    return source
}

/// Posts a CGEvent or throws
private func postEvent(_ event: CGEvent?, actionDescription: String) async throws {
    guard let event else {
        throw MacosUseSDKError.inputSimulationFailed("failed to create \(actionDescription) event")
    }
    event.post(tap: .cghidEventTap)
    // Add a small delay after posting, crucial for some applications
    try await Task.sleep(nanoseconds: 15_000_000) // 15 milliseconds
}

// --- Public Input Simulation Functions ---

/// Simulates pressing and releasing a key with optional modifier flags.
/// - Parameters:
///   - keyCode: The `CGKeyCode` of the key to press.
///   - flags: The modifier flags (`CGEventFlags`) to apply (e.g., `.maskCommand`, `.maskShift`).
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) async throws {
    logger.info("simulating key press: (code: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public))")
    let source = try createEventSource()

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = flags // Apply modifier flags
    try await postEvent(keyDown, actionDescription: "key down (code: \(keyCode), flags: \(flags.rawValue))")

    // Short delay between key down and key up is often necessary
    // Task.sleep now handled in postEvent

    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = flags // Apply modifier flags for key up as well
    try await postEvent(keyUp, actionDescription: "key up (code: \(keyCode), flags: \(flags.rawValue))")
    logger.info("key press simulation complete.")
}

/// Simulates pressing and holding a key for a specified duration.
/// - Parameters:
///   - keyCode: The `CGKeyCode` of the key to press.
///   - flags: The modifier flags (`CGEventFlags`) to apply (e.g., `.maskCommand`, `.maskShift`).
///   - duration: The duration in seconds to hold the key down before releasing.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func pressKeyHold(keyCode: CGKeyCode, flags: CGEventFlags = [], duration: Double) async throws {
    logger.info(
        "simulating key hold: (code: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public), duration: \(duration, privacy: .public)s)",
    )
    let source = try createEventSource()

    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    keyDown?.flags = flags
    try await postEvent(keyDown, actionDescription: "key down (code: \(keyCode), flags: \(flags.rawValue))")

    // Hold the key for the specified duration
    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyUp?.flags = flags
    try await postEvent(keyUp, actionDescription: "key up (code: \(keyCode), flags: \(flags.rawValue))")
    logger.info("key hold simulation complete.")
}

/// Simulates pressing a mouse button down without releasing.
/// Used for stateful drag operations where button down and up are separate events.
/// - Parameters:
///   - point: The `CGPoint` where the button should be pressed (Global Display Coordinates).
///   - button: The mouse button (`.left`, `.right`, `.center`).
///   - modifiers: Optional modifier flags to hold during the press.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func mouseButtonDown(at point: CGPoint, button: CGMouseButton = .left, modifiers: CGEventFlags = [])
    async throws
{
    logger.info(
        "simulating mouse button down at: (\(point.x, privacy: .public), \(point.y, privacy: .public)), button: \(button.rawValue, privacy: .public)",
    )
    let source = try createEventSource()

    let mouseType: CGEventType = switch button {
    case .left:
        .leftMouseDown
    case .right:
        .rightMouseDown
    case .center:
        .otherMouseDown
    default:
        .leftMouseDown
    }

    let mouseDown = CGEvent(
        mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: point,
        mouseButton: button,
    )
    mouseDown?.flags = modifiers
    try await postEvent(mouseDown, actionDescription: "mouse button down at (\(point.x), \(point.y))")
    logger.info("mouse button down simulation complete.")
}

/// Simulates releasing a mouse button.
/// Used for stateful drag operations where button down and up are separate events.
/// - Parameters:
///   - point: The `CGPoint` where the button should be released (Global Display Coordinates).
///   - button: The mouse button (`.left`, `.right`, `.center`).
///   - modifiers: Optional modifier flags to hold during the release.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func mouseButtonUp(at point: CGPoint, button: CGMouseButton = .left, modifiers: CGEventFlags = [])
    async throws
{
    logger.info(
        "simulating mouse button up at: (\(point.x, privacy: .public), \(point.y, privacy: .public)), button: \(button.rawValue, privacy: .public)",
    )
    let source = try createEventSource()

    let mouseType: CGEventType = switch button {
    case .left:
        .leftMouseUp
    case .right:
        .rightMouseUp
    case .center:
        .otherMouseUp
    default:
        .leftMouseUp
    }

    let mouseUp = CGEvent(
        mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: point,
        mouseButton: button,
    )
    mouseUp?.flags = modifiers
    try await postEvent(mouseUp, actionDescription: "mouse button up at (\(point.x), \(point.y))")
    logger.info("mouse button up simulation complete.")
}

/// Simulates a left mouse click at the specified screen coordinates.
/// Does not move the cursor first. Call `moveMouse` beforehand if needed.
/// - Parameter point: The `CGPoint` where the click should occur.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func clickMouse(at point: CGPoint) async throws {
    logger.info("simulating left click at: (\(point.x, privacy: .public), \(point.y, privacy: .public))")
    let source = try createEventSource()

    // Create and post mouse down event
    let mouseDown = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point,
        mouseButton: .left,
    )
    try await postEvent(mouseDown, actionDescription: "mouse down at (\(point.x), \(point.y))")

    // Short delay - moved into postEvent
    // Task.sleep now handled in postEvent

    // Create and post mouse up event
    let mouseUp = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point,
        mouseButton: .left,
    )
    try await postEvent(mouseUp, actionDescription: "mouse up at (\(point.x), \(point.y))")
    logger.info("left click simulation complete.")
}

/// Simulates a left mouse double click at the specified screen coordinates.
/// Does not move the cursor first. Call `moveMouse` beforehand if needed.
/// - Parameter point: The `CGPoint` where the double click should occur.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func doubleClickMouse(at point: CGPoint) async throws {
    logger.info("simulating double-click at: (\(point.x, privacy: .public), \(point.y, privacy: .public))")
    let source = try createEventSource()

    // Use the specific double-click event type directly
    let doubleClickEvent = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point,
        mouseButton: .left,
    )
    doubleClickEvent?.setIntegerValueField(.mouseEventClickState, value: 2) // Set click count
    try await postEvent(
        doubleClickEvent, actionDescription: "double click down at (\(point.x), \(point.y))",
    )

    // Task.sleep now handled in postEvent

    let mouseUpEvent = CGEvent(
        mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point,
        mouseButton: .left,
    )
    mouseUpEvent?.setIntegerValueField(.mouseEventClickState, value: 2) // Set click count
    try await postEvent(mouseUpEvent, actionDescription: "double click up at (\(point.x), \(point.y))")
    logger.info("double-click simulation complete.")
}

/// Simulates a right mouse click at the specified coordinates
/// Simulates a right mouse click at the specified screen coordinates.
/// Does not move the cursor first. Call `moveMouse` beforehand if needed.
/// - Parameter point: The `CGPoint` where the right click should occur.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func rightClickMouse(at point: CGPoint) async throws {
    logger.info("simulating right-click at: (\(point.x, privacy: .public), \(point.y, privacy: .public))")
    let source = try createEventSource()

    // Create and post mouse down event (RIGHT button)
    let mouseDown = CGEvent(
        mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point,
        mouseButton: .right,
    )
    try await postEvent(mouseDown, actionDescription: "right mouse down at (\(point.x), \(point.y))")

    // Short delay - moved into postEvent
    // Task.sleep now handled in postEvent

    // Create and post mouse up event (RIGHT button)
    let mouseUp = CGEvent(
        mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point,
        mouseButton: .right,
    )
    try await postEvent(mouseUp, actionDescription: "right mouse up at (\(point.x), \(point.y))")
    logger.info("right-click simulation complete.")
}

/// Moves the mouse cursor to the specified screen coordinates.
/// - Parameter point: The `CGPoint` to move the cursor to.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func moveMouse(to point: CGPoint) async throws {
    logger.info("moving mouse to: (\(point.x, privacy: .public), \(point.y, privacy: .public))")
    let source = try createEventSource()

    // .mouseMoved type doesn't require a button state
    let mouseMove = CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left,
    ) // Button doesn't matter for move
    try await postEvent(mouseMove, actionDescription: "mouse move to (\(point.x), \(point.y))")
    logger.info("mouse move simulation complete.")
}

/// Simulates typing a string of text using AppleScript `keystroke`.
/// This is generally more reliable for arbitrary text than simulating individual key presses.
/// - Parameter text: The `String` to type.
/// - Throws: `MacosUseSDKError` if the osascript command fails to execute or returns an error.
public func writeText(_ text: String) async throws {
    // Using AppleScript's 'keystroke' is simplest for arbitrary text,
    // as it handles character mapping, keyboard layouts, etc.
    // A pure CGEvent approach would require complex character-to-keycode+flags mapping.
    logger.info("simulating text writing: \"\(text, privacy: .private)\" (using AppleScript)")

    // Escape double quotes and backslashes within the text for AppleScript string
    let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"",
    )
    let script = "tell application \"System Events\" to keystroke \"\(escapedText)\""

    // Use a continuation to bridge the callback-based Process API to async/await
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            // Break retain cycle by clearing the handler
            proc.terminationHandler = nil
            if status == 0 {
                continuation.resume()
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString =
                    String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? ""
                logger.error("osascript failed: \(status, privacy: .public) \(errorString, privacy: .public)")
                continuation.resume(
                    throwing: MacosUseSDKError.osascriptExecutionFailed(status: status, message: errorString),
                )
            }
        }

        do {
            try process.run()
        } catch {
            continuation.resume(
                throwing: MacosUseSDKError.inputSimulationFailed(
                    "failed to run osascript: \(error.localizedDescription)",
                ),
            )
        }
    }
    logger.info("text writing simulation complete.")
}

/// Maps common key names (case-insensitive) to their CGKeyCode. Public for potential use by the tool.
/// Maps common key names (case-insensitive) or a numeric string to their `CGKeyCode`.
/// - Parameter keyName: The name of the key (e.g., "return", "a", "esc") or a string representation of the key code number.
/// - Returns: The corresponding `CGKeyCode` or `nil` if the name is not recognized and cannot be parsed as a number.
public func mapKeyNameToKeyCode(_ keyName: String) -> CGKeyCode? {
    let lowered = keyName.lowercased()

    // --- Special Keys (layout-independent, hardcoded) ---
    switch lowered {
    case "return", "enter": return KEY_RETURN
    case "tab": return KEY_TAB
    case "space": return KEY_SPACE
    case "delete", "backspace": return KEY_DELETE
    case "escape", "esc": return KEY_ESCAPE
    case "left": return KEY_ARROW_LEFT
    case "right": return KEY_ARROW_RIGHT
    case "down": return KEY_ARROW_DOWN
    case "up": return KEY_ARROW_UP
    // Function Keys (layout-independent, hardcoded)
    case "f1": return 122
    case "f2": return 120
    case "f3": return 99
    case "f4": return 118
    case "f5": return 96
    case "f6": return 97
    case "f7": return 98
    case "f8": return 100
    case "f9": return 101
    case "f10": return 109
    case "f11": return 103
    case "f12": return 111
    // Add F13-F20 if needed
    default:
        break // Fall through to dynamic / fallback resolution below.
    }

    // --- Single characters: try dynamic TIS/UCKeyTranslate resolution first ---
    if lowered.count == 1 {
        if let dynamicCode = resolveKeyCode(for: lowered) {
            return dynamicCode
        }
        logger.info(
            "dynamic resolution failed for '\(keyName, privacy: .public)', falling back to US-QWERTY map",
        )
    }

    // --- Fallback: US-QWERTY hardcoded map ---
    switch lowered {
    // Letters
    case "a": return 0
    case "b": return 11
    case "c": return 8
    case "d": return 2
    case "e": return 14
    case "f": return 3
    case "g": return 5
    case "h": return 4
    case "i": return 34
    case "j": return 38
    case "k": return 40
    case "l": return 37
    case "m": return 46
    case "n": return 45
    case "o": return 31
    case "p": return 35
    case "q": return 12
    case "r": return 15
    case "s": return 1
    case "t": return 17
    case "u": return 32
    case "v": return 9
    case "w": return 13
    case "x": return 7
    case "y": return 16
    case "z": return 6
    // Numbers (Main Keyboard Row)
    case "1": return 18
    case "2": return 19
    case "3": return 20
    case "4": return 21
    case "5": return 23
    case "6": return 22
    case "7": return 26
    case "8": return 28
    case "9": return 25
    case "0": return 29
    // Symbols (Common - May vary significantly by layout)
    case "-": return 27
    case "=": return 24
    case "[": return 33
    case "]": return 30
    case "\\": return 42 // Backslash
    case ";": return 41
    case "'": return 39 // Quote
    case ",": return 43
    case ".": return 47
    case "/": return 44
    case "`": return 50 // Grave accent / Tilde
    default:
        // If not a known name, attempt to interpret it as a raw key code number
        logger.info(
            "key '\(keyName, privacy: .public)' not explicitly mapped, attempting conversion to CGKeyCode number.",
        )
        return CGKeyCode(keyName) // Returns nil if conversion fails
    }
}

// --- Removed Main Script Logic ---
// The argument parsing, switch statement, fail(), completeSuccessfully(), startTime
// and related logic have been removed from this file. They will be handled by the
// InputControllerTool executable's main.swift.

// --- Retained Helper Structures/Functions if needed by public API ---
// (e.g., mapKeyNameToKeyCode is now public)
