import AppKit // Needed for Process and potentially other things later
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit
import Foundation
import OSLog

private let logger = sdkLogger(category: "InputController")

// --- Dynamic Key Code Resolution via TIS/UCKeyTranslate ---

public struct KeyboardInputSourceIdentity: Hashable, Sendable {
    public let sourceID: String
    public let unicodeLayoutSHA256: String
    public let keyboardType: UInt32

    public init(
        sourceID: String,
        unicodeLayoutSHA256: String,
        keyboardType: UInt32,
    ) {
        self.sourceID = sourceID
        self.unicodeLayoutSHA256 = unicodeLayoutSHA256
        self.keyboardType = keyboardType
    }
}

public struct ResolvedInputKey: Hashable, Sendable {
    public let keyCode: CGKeyCode
    public let sourceIdentity: KeyboardInputSourceIdentity?

    public init(
        keyCode: CGKeyCode,
        sourceIdentity: KeyboardInputSourceIdentity?,
    ) {
        self.keyCode = keyCode
        self.sourceIdentity = sourceIdentity
    }
}

private struct KeyboardLayoutSnapshot {
    let layoutData: CFData
    let identity: KeyboardInputSourceIdentity
}

private func keyboardLayoutSnapshot() -> KeyboardLayoutSnapshot? {
    guard let sourceRef = TISCopyCurrentKeyboardInputSource() else {
        logger.warning("TISCopyCurrentKeyboardInputSource returned nil")
        return nil
    }
    let source = sourceRef.takeRetainedValue()
    guard let sourceIDRef = TISGetInputSourceProperty(
        source,
        kTISPropertyInputSourceID,
    ), let layoutDataRef = TISGetInputSourceProperty(
        source,
        kTISPropertyUnicodeKeyLayoutData,
    )
    else {
        logger.warning("Current keyboard input source lacks identity or Unicode layout data")
        return nil
    }
    let sourceID = unsafeBitCast(sourceIDRef, to: CFString.self) as String
    let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
    let digest = SHA256.hash(data: layoutData as Data)
        .map { String(format: "%02x", $0) }
        .joined()
    return KeyboardLayoutSnapshot(
        layoutData: layoutData,
        identity: KeyboardInputSourceIdentity(
            sourceID: sourceID,
            unicodeLayoutSHA256: digest,
            keyboardType: UInt32(LMGetKbdType()),
        ),
    )
}

public func currentKeyboardInputSourceIdentity() -> KeyboardInputSourceIdentity? {
    keyboardLayoutSnapshot()?.identity
}

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

    guard let layout = keyboardLayoutSnapshot() else {
        return nil
    }
    let layoutData = layout.layoutData
    let layoutPtr = unsafeBitCast(
        CFDataGetBytePtr(layoutData),
        to: UnsafePointer<UCKeyboardLayout>.self,
    )

    let keyboardType = layout.identity.keyboardType

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

private let maximumInputHoldDuration = 3600.0
private let maximumDragDuration = 60.0
private let maximumPointerDuration = 60.0
private let maximumHoverDuration = 3600.0
private let maximumClickCount = 10

private func durationNanoseconds(_ duration: Double, maximum: Double, field: String) throws -> UInt64 {
    guard duration.isFinite, duration >= 0, duration <= maximum else {
        throw MacosUseSDKError.inputInvalidArgument(
            "\(field) must be finite and between 0 and \(maximum) seconds",
        )
    }
    return UInt64(duration * 1_000_000_000)
}

private func postSingleInputEvent(
    _ event: InputEvent,
    backend: any InputEventBackend,
) async throws -> UInt64 {
    let prepared = try backend.prepare(event)
    try Task.checkCancellation()
    return try await backend.post(prepared)
}

private func scheduledOffset(
    index: Int,
    intervalCount: Int,
    totalNanoseconds: UInt64,
) -> UInt64 {
    precondition(index >= 0 && index <= intervalCount)
    precondition(intervalCount > 0)
    return totalNanoseconds * UInt64(index) / UInt64(intervalCount)
}

private func scheduledDeadline(
    start: UInt64,
    offset: UInt64,
) -> UInt64 {
    let (deadline, overflow) = start.addingReportingOverflow(offset)
    precondition(!overflow)
    return deadline
}

private func pauseUntilDeadline(
    _ deadline: UInt64,
    backend: any InputEventBackend,
) async throws {
    while true {
        let now = backend.monotonicTimeNanoseconds()
        guard now < deadline else {
            return
        }
        try await backend.pause(nanoseconds: deadline - now)
    }
}

private enum InputCleanupSettlement {
    case settled
    case processRouteRetired
}

private func settleRouteBoundCleanup(
    backend: any InputEventBackend,
    _ operation: @escaping @Sendable () async throws -> Void,
) async -> InputCleanupSettlement {
    let worker = Task.detached(priority: .userInitiated) {
        var retryDelayNanoseconds: UInt64 = 1_000_000
        while true {
            do {
                try await operation()
                return InputCleanupSettlement.settled
            } catch is InputProcessRouteRetired {
                return InputCleanupSettlement.processRouteRetired
            } catch {
                // A posted down event or detached cursor creates a durable
                // release obligation. Caller cancellation cannot terminate
                // this joined worker. Backoff remains bounded so persistent OS
                // failure is visible without monopolizing an executor.
                await backend.pauseForCleanupRetry(
                    nanoseconds: retryDelayNanoseconds,
                )
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds * 2,
                    100_000_000,
                )
            }
        }
    }
    return await worker.value
}

private func settleLocalCleanup(
    backend: any InputEventBackend,
    _ operation: @escaping @Sendable () async throws -> Void,
) async {
    let worker = Task.detached(priority: .userInitiated) {
        var retryDelayNanoseconds: UInt64 = 1_000_000
        while true {
            do {
                try await operation()
                return
            } catch {
                // Cursor reassociation is host-global safety restoration. A
                // retired process route cannot discharge this local duty.
                await backend.pauseForCleanupRetry(
                    nanoseconds: retryDelayNanoseconds,
                )
                retryDelayNanoseconds = min(
                    retryDelayNanoseconds * 2,
                    100_000_000,
                )
            }
        }
    }
    await worker.value
}

private func postPairedInputEvents(
    down: InputEvent,
    up: InputEvent,
    holdNanoseconds: UInt64 = 0,
    backend: any InputEventBackend,
) async throws {
    try backend.checkPostAccess()
    // Pre-create both events before posting down. The production backend then
    // needs no allocation or fallible event construction to perform cleanup.
    let preparedDown = try backend.prepare(down)
    let preparedUp = try backend.prepare(up)
    let cleanupObligationKind: InputCleanupObligationKind = switch down {
    case .keyDown, .unicodeKeyDown:
        .keyRelease
    case .mouseDown:
        .pointerRelease
    case .keyUp, .unicodeKeyUp, .mouseUp, .mouseMove, .mouseDrag, .scroll:
        preconditionFailure("paired input requires a key or pointer down event")
    }
    try await postPreparedInputEvents(
        down: preparedDown,
        up: preparedUp,
        cleanupObligationKind: cleanupObligationKind,
        holdNanoseconds: holdNanoseconds,
        backend: backend,
    )
}

@discardableResult
private func postPreparedInputEvents(
    down preparedDown: PreparedInputEvent,
    up preparedUp: PreparedInputEvent,
    cleanupObligationKind: InputCleanupObligationKind,
    holdNanoseconds: UInt64 = 0,
    backend: any InputEventBackend,
) async throws -> UInt64 {
    try Task.checkCancellation()
    let cleanupTracker = backend as? any InputCleanupObligationTracking
    let cleanupObligation = cleanupTracker?.armCleanupObligation(
        cleanupObligationKind,
    )

    do {
        // A throwing backend call may have committed the down event before it
        // reported failure. Arm the matching release before invoking it.
        let downPostTime = try await backend.post(preparedDown)
        if holdNanoseconds > 0 {
            try await pauseUntilDeadline(
                scheduledDeadline(start: downPostTime, offset: holdNanoseconds),
                backend: backend,
            )
        } else {
            // Preserve an injectable cancellation boundary without inflating
            // the documented down-to-up duration.
            try await backend.pause(nanoseconds: 0)
        }
        try Task.checkCancellation()
        _ = try await backend.post(preparedUp)
        if let cleanupObligation {
            cleanupTracker?.settleCleanupObligation(cleanupObligation)
        }
        return downPostTime
    } catch {
        if preparedDown.invocationEvidence == .notInvoked {
            if let cleanupObligation {
                cleanupTracker?.abandonCleanupObligation(cleanupObligation)
            }
            throw error
        }
        let settlement = await settleRouteBoundCleanup(backend: backend) {
            _ = try await backend.postForCleanup(preparedUp)
        }
        if let cleanupObligation {
            switch settlement {
            case .settled:
                cleanupTracker?.settleCleanupObligation(cleanupObligation)
            case .processRouteRetired:
                cleanupTracker?.abandonCleanupObligation(cleanupObligation)
            }
        }
        throw error
    }
}

// --- Public Input Simulation Functions ---

/// Simulates pressing and releasing a key with optional modifier flags.
/// - Parameters:
///   - keyCode: The `CGKeyCode` of the key to press.
///   - flags: The modifier flags (`CGEventFlags`) to apply (e.g., `.maskCommand`, `.maskShift`).
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) async throws {
    try await pressKey(
        keyCode: keyCode,
        flags: flags,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func pressKey(
    keyCode: CGKeyCode,
    flags: CGEventFlags = [],
    backend: any InputEventBackend,
) async throws {
    logger.info("simulating key press: (code: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public))")
    try await postPairedInputEvents(
        down: .keyDown(keyCode: keyCode, flags: flags),
        up: .keyUp(keyCode: keyCode, flags: flags),
        backend: backend,
    )
    logger.info("key press simulation complete.")
}

/// Simulates pressing and holding a key for a specified duration.
/// - Parameters:
///   - keyCode: The `CGKeyCode` of the key to press.
///   - flags: The modifier flags (`CGEventFlags`) to apply (e.g., `.maskCommand`, `.maskShift`).
///   - duration: The duration in seconds to hold the key down before releasing.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func pressKeyHold(keyCode: CGKeyCode, flags: CGEventFlags = [], duration: Double) async throws {
    try await pressKeyHold(
        keyCode: keyCode,
        flags: flags,
        duration: duration,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func pressKeyHold(
    keyCode: CGKeyCode,
    flags: CGEventFlags = [],
    duration: Double,
    backend: any InputEventBackend,
) async throws {
    logger.info(
        "simulating key hold: (code: \(keyCode, privacy: .public), flags: \(flags.rawValue, privacy: .public), duration: \(duration, privacy: .public)s)",
    )
    let holdNanoseconds = try durationNanoseconds(
        duration,
        maximum: maximumInputHoldDuration,
        field: "key hold duration",
    )
    try await postPairedInputEvents(
        down: .keyDown(keyCode: keyCode, flags: flags),
        up: .keyUp(keyCode: keyCode, flags: flags),
        holdNanoseconds: holdNanoseconds,
        backend: backend,
    )
    logger.info("key hold simulation complete.")
}

/// Simulates a complete mouse click sequence at Global Display Coordinates
/// (top-left origin). Every event carries the supplied modifier flags, and each
/// successful down is synchronously paired with an up even under cancellation.
/// The cursor is synchronously warped to the click coordinate after all events
/// are prepared and before the first event is posted.
public func clickMouse(
    at point: CGPoint,
    button: CGMouseButton = .left,
    clickCount: Int = 1,
    modifiers: CGEventFlags = [],
) async throws {
    try await clickMouse(
        at: point,
        button: button,
        clickCount: clickCount,
        modifiers: modifiers,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func clickMouse(
    at point: CGPoint,
    button: CGMouseButton = .left,
    clickCount: Int = 1,
    modifiers: CGEventFlags = [],
    backend: any InputEventBackend,
) async throws {
    guard point.x.isFinite, point.y.isFinite else {
        throw MacosUseSDKError.inputInvalidArgument("click coordinates must be finite")
    }
    guard (1 ... maximumClickCount).contains(clickCount) else {
        throw MacosUseSDKError.inputInvalidArgument(
            "click count must be between 1 and \(maximumClickCount)",
        )
    }
    try backend.checkPostAccess()
    logger.info(
        "simulating click sequence at: (\(point.x, privacy: .public), \(point.y, privacy: .public)), button: \(button.rawValue, privacy: .public), count: \(clickCount, privacy: .public)",
    )

    let preparedPairs = try (1 ... clickCount).map { clickIndex in
        let clickState = Int64(clickIndex)
        return try (
            backend.prepare(.mouseDown(
                point: point,
                button: button,
                modifiers: modifiers,
                clickCount: clickState,
            )),
            backend.prepare(.mouseUp(
                point: point,
                button: button,
                modifiers: modifiers,
                clickCount: clickState,
            )),
        )
    }
    try Task.checkCancellation()
    try await backend.warpCursor(x: point.x, y: point.y)
    for (down, up) in preparedPairs {
        try await postPreparedInputEvents(
            down: down,
            up: up,
            cleanupObligationKind: .pointerRelease,
            backend: backend,
        )
    }
    logger.info("click sequence simulation complete.")
}

/// Simulates a left mouse double click at the specified screen coordinates.
/// The cursor is synchronously warped to the exact coordinate before posting.
/// - Parameter point: The `CGPoint` where the double click should occur.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func doubleClickMouse(at point: CGPoint) async throws {
    try await doubleClickMouse(at: point, backend: CoreGraphicsInputEventBackend())
}

func doubleClickMouse(at point: CGPoint, backend: any InputEventBackend) async throws {
    try await clickMouse(at: point, clickCount: 2, backend: backend)
}

/// Simulates a right mouse click at the specified screen coordinates.
/// The cursor is synchronously warped to the exact coordinate before posting.
/// - Parameter point: The `CGPoint` where the right click should occur.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func rightClickMouse(at point: CGPoint) async throws {
    try await rightClickMouse(at: point, backend: CoreGraphicsInputEventBackend())
}

func rightClickMouse(at point: CGPoint, backend: any InputEventBackend) async throws {
    try await clickMouse(at: point, button: .right, backend: backend)
}

/// Moves the mouse cursor to the specified screen coordinates. Each generated
/// movement first warps the hardware cursor to its exact Global Display
/// Coordinate and then posts the matching movement event.
/// - Parameter point: The `CGPoint` to move the cursor to.
/// - Throws: `MacosUseSDKError` if the event source cannot be created or the event cannot be posted.
public func moveMouse(
    to point: CGPoint,
    duration: Double = 0,
    modifiers: CGEventFlags = [],
) async throws {
    try await moveMouse(
        to: point,
        duration: duration,
        modifiers: modifiers,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func moveMouse(
    to point: CGPoint,
    duration: Double = 0,
    modifiers: CGEventFlags = [],
    backend: any InputEventBackend,
) async throws {
    guard point.x.isFinite, point.y.isFinite else {
        throw MacosUseSDKError.inputInvalidArgument("move coordinates must be finite")
    }
    let durationNanoseconds = try durationNanoseconds(
        duration,
        maximum: maximumPointerDuration,
        field: "move duration",
    )
    try backend.checkPostAccess()
    logger.info("moving mouse to: (\(point.x, privacy: .public), \(point.y, privacy: .public))")
    if durationNanoseconds == 0 {
        let prepared = try backend.prepare(.mouseMove(point: point, modifiers: modifiers))
        try Task.checkCancellation()
        try await backend.warpCursor(x: point.x, y: point.y)
        try Task.checkCancellation()
        _ = try await backend.post(prepared)
        logger.info("mouse move simulation complete.")
        return
    }

    let start = try backend.cursorPosition()
    guard start.x.isFinite, start.y.isFinite else {
        throw MacosUseSDKError.inputSimulationFailed("cursor position is not finite")
    }
    let steps = 20
    let preparedMoves = try (1 ... steps).map { step in
        let fraction = Double(step) / Double(steps)
        let intermediate = CGPoint(
            x: start.x + ((point.x - start.x) * fraction),
            y: start.y + ((point.y - start.y) * fraction),
        )
        return try (
            intermediate,
            backend.prepare(.mouseMove(point: intermediate, modifiers: modifiers)),
        )
    }
    var firstPostTime: UInt64?
    for (index, move) in preparedMoves.enumerated() {
        if let firstPostTime {
            try await pauseUntilDeadline(
                scheduledDeadline(
                    start: firstPostTime,
                    offset: scheduledOffset(
                        index: index,
                        intervalCount: preparedMoves.count - 1,
                        totalNanoseconds: durationNanoseconds,
                    ),
                ),
                backend: backend,
            )
        }
        try Task.checkCancellation()
        try await backend.warpCursor(x: move.0.x, y: move.0.y)
        try Task.checkCancellation()
        let postTime = try await backend.post(move.1)
        if firstPostTime == nil {
            firstPostTime = postTime
        }
    }
    logger.info("mouse move simulation complete.")
}

private func scrollDelta(_ value: Double, field: String) throws -> Int32 {
    guard value.isFinite else {
        throw MacosUseSDKError.inputInvalidArgument("\(field) must be finite")
    }
    let rounded = value.rounded(.toNearestOrAwayFromZero)
    guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else {
        throw MacosUseSDKError.inputInvalidArgument("\(field) is outside the supported range")
    }
    let result = Int32(rounded)
    guard value == 0 || result != 0 else {
        throw MacosUseSDKError.inputInvalidArgument(
            "\(field) magnitude must be at least one pixel",
        )
    }
    return result
}

public func scrollMouse(
    at point: CGPoint? = nil,
    horizontal: Double,
    vertical: Double,
    duration: Double = 0,
    modifiers: CGEventFlags = [],
) async throws {
    try await scrollMouse(
        at: point,
        horizontal: horizontal,
        vertical: vertical,
        duration: duration,
        modifiers: modifiers,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func scrollMouse(
    at point: CGPoint? = nil,
    horizontal: Double,
    vertical: Double,
    duration: Double = 0,
    modifiers: CGEventFlags = [],
    backend: any InputEventBackend,
) async throws {
    if let point, !point.x.isFinite || !point.y.isFinite {
        throw MacosUseSDKError.inputInvalidArgument("scroll coordinates must be finite")
    }
    let horizontalDelta = try scrollDelta(horizontal, field: "horizontal scroll delta")
    let verticalDelta = try scrollDelta(vertical, field: "vertical scroll delta")
    guard horizontalDelta != 0 || verticalDelta != 0 else {
        throw MacosUseSDKError.inputInvalidArgument("scroll must have a non-zero delta")
    }
    let totalDuration = try durationNanoseconds(
        duration,
        maximum: maximumPointerDuration,
        field: "scroll duration",
    )
    try backend.checkPostAccess()
    let resolvedPoint = try point ?? backend.cursorPosition()
    guard resolvedPoint.x.isFinite, resolvedPoint.y.isFinite else {
        throw MacosUseSDKError.inputSimulationFailed(
            "cursor position is not finite",
        )
    }
    let maximumMagnitude = max(abs(Int64(horizontalDelta)), abs(Int64(verticalDelta)))
    let steps = totalDuration == 0 ? 1 : Int(min(20, maximumMagnitude))
    let preparedEvents = try (0 ..< steps).map { step in
        let nextNumerator = Int64(step + 1)
        let priorNumerator = Int64(step)
        let divisor = Int64(steps)
        let stepHorizontal = Int32(
            (Int64(horizontalDelta) * nextNumerator / divisor)
                - (Int64(horizontalDelta) * priorNumerator / divisor),
        )
        let stepVertical = Int32(
            (Int64(verticalDelta) * nextNumerator / divisor)
                - (Int64(verticalDelta) * priorNumerator / divisor),
        )
        return try backend.prepare(.scroll(
            point: resolvedPoint,
            horizontal: stepHorizontal,
            vertical: stepVertical,
            modifiers: modifiers,
        ))
    }
    if point != nil {
        try Task.checkCancellation()
        try await backend.warpCursor(x: resolvedPoint.x, y: resolvedPoint.y)
    }
    let scheduleOrigin = backend.monotonicTimeNanoseconds()
    for (index, prepared) in preparedEvents.enumerated() {
        let offset = if preparedEvents.count == 1 {
            totalDuration
        } else {
            scheduledOffset(
                index: index,
                intervalCount: preparedEvents.count - 1,
                totalNanoseconds: totalDuration,
            )
        }
        if offset > 0 {
            try await pauseUntilDeadline(
                scheduledDeadline(
                    start: scheduleOrigin,
                    offset: offset,
                ),
                backend: backend,
            )
        }
        try Task.checkCancellation()
        _ = try await backend.post(prepared)
    }
}

public func hoverMouse(at point: CGPoint, duration: Double) async throws {
    try await hoverMouse(
        at: point,
        duration: duration,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func hoverMouse(
    at point: CGPoint,
    duration: Double,
    backend: any InputEventBackend,
) async throws {
    let hoverDuration = try durationNanoseconds(
        duration,
        maximum: maximumHoverDuration,
        field: "hover duration",
    )
    guard hoverDuration > 0 else {
        throw MacosUseSDKError.inputInvalidArgument("hover duration must be greater than zero")
    }
    guard point.x.isFinite, point.y.isFinite else {
        throw MacosUseSDKError.inputInvalidArgument("hover coordinates must be finite")
    }
    try backend.checkPostAccess()
    let prepared = try backend.prepare(.mouseMove(point: point, modifiers: []))
    try Task.checkCancellation()
    try await backend.warpCursor(x: point.x, y: point.y)
    try Task.checkCancellation()
    let postTime = try await backend.post(prepared)
    try await pauseUntilDeadline(
        scheduledDeadline(start: postTime, offset: hoverDuration),
        backend: backend,
    )
}

/// Performs a complete mouse drag operation from start to end position.
///
/// Warps the system cursor to the start position first (required for drag recognition),
/// then executes: buttonDown → each caller-supplied path waypoint with a
/// corresponding drag event and cursor warp → buttonUp. The path is
/// authoritative and is never interpolated or rewritten.
///
/// IMPORTANT: CGEvent's `mouseCursorPosition` alone does NOT physically reposition the system
/// cursor. The window manager tracks the hardware cursor for drag operations, so we must use
/// `CGWarpMouseCursorPosition` to synchronise the physical cursor with each drag event.
/// `CGAssociateMouseAndMouseCursorPosition(false)` is called during the drag to prevent the
/// physical mouse from fighting the warp, and re-enabled on completion.
///
/// COORDINATE SYSTEM: Global Display Coordinates (top-left origin, Y increases downward).
///
/// - Parameters:
///   - from: Starting position in Global Display Coordinates.
///   - to: Ending position in Global Display Coordinates.
///   - button: Mouse button to use for drag (default: left).
///   - duration: Total duration of drag in seconds (0 = fast drag with minimal delays).
/// - Throws: `MacosUseSDKError` if any event cannot be created or posted.
public func performDrag(from: CGPoint, to: CGPoint, button: CGMouseButton = .left, duration: Double = 0) async throws {
    try await performDrag(
        path: [from, to],
        button: button,
        duration: duration,
        modifiers: [],
        backend: CoreGraphicsInputEventBackend(),
    )
}

func performDrag(
    from: CGPoint,
    to: CGPoint,
    button: CGMouseButton = .left,
    duration: Double = 0,
    backend: any InputEventBackend,
) async throws {
    try await performDrag(
        path: [from, to],
        button: button,
        duration: duration,
        modifiers: [],
        backend: backend,
    )
}

public func performDrag(
    path: [CGPoint],
    button: CGMouseButton = .left,
    duration: Double = 0,
    modifiers: CGEventFlags = [],
) async throws {
    try await performDrag(
        path: path,
        button: button,
        duration: duration,
        modifiers: modifiers,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func performDrag(
    path: [CGPoint],
    button: CGMouseButton = .left,
    duration: Double = 0,
    modifiers: CGEventFlags = [],
    backend: any InputEventBackend,
) async throws {
    guard (2 ... 100).contains(path.count) else {
        throw MacosUseSDKError.inputInvalidArgument(
            "drag path must contain between 2 and 100 points",
        )
    }
    guard path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
        throw MacosUseSDKError.inputInvalidArgument("drag coordinates must be finite")
    }
    let from = path[0]
    let to = path[path.count - 1]
    logger.info(
        "performing drag from: (\(from.x, privacy: .public), \(from.y, privacy: .public)) to: (\(to.x, privacy: .public), \(to.y, privacy: .public))",
    )

    let totalDurationNanoseconds = try durationNanoseconds(
        duration,
        maximum: maximumDragDuration,
        field: "drag duration",
    )
    try backend.checkPostAccess()
    let points = path
    // Prepare every fallible event before detaching the cursor or posting down.
    let preparedDown = try backend.prepare(.mouseDown(
        point: from,
        button: button,
        modifiers: modifiers,
        clickCount: 1,
    ))
    let preparedDrags = try points.dropFirst().map { point in
        try backend.prepare(.mouseDrag(
            point: point,
            button: button,
            modifiers: modifiers,
        ))
    }
    let preparedUps = try points.map { point in
        try backend.prepare(.mouseUp(
            point: point,
            button: button,
            modifiers: modifiers,
            clickCount: 1,
        ))
    }

    var currentPointIndex = 0
    var buttonReleaseRequired = false
    var cursorReassociationRequired = false
    let cleanupTracker = backend as? any InputCleanupObligationTracking
    var pointerReleaseObligation: InputCleanupObligation?
    var cursorReassociationObligation: InputCleanupObligation?

    do {
        try Task.checkCancellation()
        try await backend.warpCursor(x: from.x, y: from.y)
        try Task.checkCancellation()
        cursorReassociationObligation = cleanupTracker?.armCleanupObligation(
            .cursorReassociation,
        )
        cursorReassociationRequired = true
        try await backend.setCursorAssociated(false)
        try await backend.pause(nanoseconds: 0)

        try Task.checkCancellation()
        pointerReleaseObligation = cleanupTracker?.armCleanupObligation(
            .pointerRelease,
        )
        buttonReleaseRequired = true
        let downPostTime = try await backend.post(preparedDown)

        let intervalCount = preparedDrags.count + 1
        for (index, preparedDrag) in preparedDrags.enumerated() {
            let pointIndex = index + 1
            let point = points[pointIndex]
            try await pauseUntilDeadline(
                scheduledDeadline(
                    start: downPostTime,
                    offset: scheduledOffset(
                        index: pointIndex,
                        intervalCount: intervalCount,
                        totalNanoseconds: totalDurationNanoseconds,
                    ),
                ),
                backend: backend,
            )
            try Task.checkCancellation()
            try await backend.warpCursor(x: point.x, y: point.y)
            currentPointIndex = pointIndex
            try Task.checkCancellation()
            _ = try await backend.post(preparedDrag)
        }

        try await pauseUntilDeadline(
            scheduledDeadline(
                start: downPostTime,
                offset: totalDurationNanoseconds,
            ),
            backend: backend,
        )
        try Task.checkCancellation()
        _ = try await backend.post(preparedUps[currentPointIndex])
        buttonReleaseRequired = false
        if let pointerReleaseObligation {
            cleanupTracker?.settleCleanupObligation(pointerReleaseObligation)
        }
        try await backend.setCursorAssociated(true)
        cursorReassociationRequired = false
        if let cursorReassociationObligation {
            cleanupTracker?.settleCleanupObligation(
                cursorReassociationObligation,
            )
        }
    } catch {
        if buttonReleaseRequired {
            if preparedDown.invocationEvidence == .notInvoked {
                if let pointerReleaseObligation {
                    cleanupTracker?.abandonCleanupObligation(
                        pointerReleaseObligation,
                    )
                }
            } else {
                let preparedRelease = preparedUps[currentPointIndex]
                let settlement = await settleRouteBoundCleanup(backend: backend) {
                    _ = try await backend.postForCleanup(preparedRelease)
                }
                if let pointerReleaseObligation {
                    switch settlement {
                    case .settled:
                        cleanupTracker?.settleCleanupObligation(
                            pointerReleaseObligation,
                        )
                    case .processRouteRetired:
                        cleanupTracker?.abandonCleanupObligation(
                            pointerReleaseObligation,
                        )
                    }
                }
            }
        }
        if cursorReassociationRequired {
            await settleLocalCleanup(backend: backend) {
                try await backend.setCursorAssociated(true)
            }
            if let cursorReassociationObligation {
                cleanupTracker?.settleCleanupObligation(
                    cursorReassociationObligation,
                )
            }
        }
        throw error
    }

    logger.info("drag operation complete.")
}

/// Types Unicode text through Core Graphics without launching an orphanable
/// subprocess. Each grapheme is represented by a pre-created down/up pair.
public func writeText(_ text: String, characterDelay: Double = 0) async throws {
    try await writeText(
        text,
        characterDelay: characterDelay,
        backend: CoreGraphicsInputEventBackend(),
    )
}

func writeText(
    _ text: String,
    characterDelay: Double = 0,
    backend: any InputEventBackend,
) async throws {
    let delayNanoseconds = try durationNanoseconds(
        characterDelay,
        maximum: maximumPointerDuration,
        field: "character delay",
    )
    try backend.checkPostAccess()
    let characters = text.map(String.init)
    let preparedPairs = try characters.map { character in
        try (
            backend.prepare(.unicodeKeyDown(text: character)),
            backend.prepare(.unicodeKeyUp(text: character)),
        )
    }
    var priorDownPostTime: UInt64?
    for pair in preparedPairs {
        if let priorDownPostTime, delayNanoseconds > 0 {
            try await pauseUntilDeadline(
                scheduledDeadline(
                    start: priorDownPostTime,
                    offset: delayNanoseconds,
                ),
                backend: backend,
            )
        }
        priorDownPostTime = try await postPreparedInputEvents(
            down: pair.0,
            up: pair.1,
            cleanupObligationKind: .keyRelease,
            backend: backend,
        )
    }
    logger.info("text writing simulation complete.")
}

/// Types arbitrary Unicode through physical Command-V pairs while a
/// composition owner supplies and restores the process-global pasteboard.
/// One fresh down/up pair is prepared for every grapheme so delivery and
/// release ownership remain exact across cancellation.
public func writeTextByPasting(
    _ text: String,
    characterDelay: Double = 0,
    pasteKeyCode: CGKeyCode,
    preparePasteboardText: @escaping @Sendable (String) async throws -> Void,
    awaitPasteboardConsumption: @escaping @Sendable () async throws -> Void,
    backend: any InputEventBackend,
) async throws {
    let delayNanoseconds = try durationNanoseconds(
        characterDelay,
        maximum: maximumPointerDuration,
        field: "character delay",
    )
    try backend.checkPostAccess()
    let characters = text.map(String.init)
    let preparedPairs = try characters.map { _ in
        try (
            backend.prepare(.keyDown(keyCode: pasteKeyCode, flags: .maskCommand)),
            backend.prepare(.keyUp(keyCode: pasteKeyCode, flags: .maskCommand)),
        )
    }
    var priorDownPostTime: UInt64?
    for (character, pair) in zip(characters, preparedPairs) {
        if let priorDownPostTime, delayNanoseconds > 0 {
            try await pauseUntilDeadline(
                scheduledDeadline(
                    start: priorDownPostTime,
                    offset: delayNanoseconds,
                ),
                backend: backend,
            )
        }
        try Task.checkCancellation()
        try await preparePasteboardText(character)
        try Task.checkCancellation()
        priorDownPostTime = try await postPreparedInputEvents(
            down: pair.0,
            up: pair.1,
            cleanupObligationKind: .keyRelease,
            backend: backend,
        )
        try await awaitPasteboardConsumption()
    }
    logger.info("physical Unicode paste sequence complete.")
}

/// Executes one complete semantic input action through the supplied event
/// backend. The same implementation is used by production Core Graphics
/// posting and by non-posting verification backends, so tests exercise event
/// preparation, timing, cancellation, and cleanup below the service layer.
///
/// Visualization is intentionally separate from this primitive: callers that
/// render feedback should do so around this operation without changing the
/// event sequence or its ownership guarantees.
@MainActor
public func executeInputAction(
    _ action: InputAction,
    backend: any InputEventBackend,
) async throws {
    switch action {
    case let .click(point):
        try await clickMouse(at: point, backend: backend)
    case let .doubleClick(point):
        try await clickMouse(at: point, clickCount: 2, backend: backend)
    case let .rightClick(point):
        try await clickMouse(at: point, button: .right, backend: backend)
    case let .clickSequence(point, button, clickCount, modifiers):
        try await clickMouse(
            at: point,
            button: button,
            clickCount: clickCount,
            modifiers: modifiers,
            backend: backend,
        )
    case let .type(text):
        try await writeText(text, backend: backend)
    case let .typeText(text, characterDelay):
        try await writeText(
            text,
            characterDelay: characterDelay,
            backend: backend,
        )
    case let .press(keyName, flags):
        guard let keyCode = mapKeyNameToKeyCode(keyName) else {
            throw MacosUseSDKError.inputInvalidArgument("Unknown key name: \(keyName)")
        }
        try await pressKey(keyCode: keyCode, flags: flags, backend: backend)
    case let .pressHold(keyName, flags, duration):
        guard let keyCode = mapKeyNameToKeyCode(keyName) else {
            throw MacosUseSDKError.inputInvalidArgument("Unknown key name: \(keyName)")
        }
        try await pressKeyHold(
            keyCode: keyCode,
            flags: flags,
            duration: duration,
            backend: backend,
        )
    case let .pressKeyCode(keyCode, flags):
        try await pressKey(keyCode: keyCode, flags: flags, backend: backend)
    case let .pressKeyCodeHold(keyCode, flags, duration):
        try await pressKeyHold(
            keyCode: keyCode,
            flags: flags,
            duration: duration,
            backend: backend,
        )
    case let .move(point):
        try await moveMouse(to: point, backend: backend)
    case let .movePointer(point, duration, modifiers):
        try await moveMouse(
            to: point,
            duration: duration,
            modifiers: modifiers,
            backend: backend,
        )
    case let .drag(from, to, button, duration):
        try await performDrag(
            from: from,
            to: to,
            button: button,
            duration: duration,
            backend: backend,
        )
    case let .dragPath(points, button, duration, modifiers):
        try await performDrag(
            path: points,
            button: button,
            duration: duration,
            modifiers: modifiers,
            backend: backend,
        )
    case let .scroll(point, horizontal, vertical, duration, modifiers):
        try await scrollMouse(
            at: point,
            horizontal: horizontal,
            vertical: vertical,
            duration: duration,
            modifiers: modifiers,
            backend: backend,
        )
    case let .hover(point, duration):
        try await hoverMouse(at: point, duration: duration, backend: backend)
    }
}

/// Executes one complete semantic input action with the production Core
/// Graphics backend.
@MainActor
public func executeInputAction(_ action: InputAction) async throws {
    try await executeInputAction(
        action,
        backend: CoreGraphicsInputEventBackend(),
    )
}

/// Maps layout-independent key names and single characters from the current
/// keyboard input source to their `CGKeyCode`.
///
/// Character lookup deliberately has no US-QWERTY or numeric-keycode fallback:
/// if the current input source cannot produce the requested character, the
/// caller's intent cannot be executed truthfully.
public func layoutIndependentKeyCode(for keyName: String) -> CGKeyCode? {
    let lowered = keyName.lowercased()

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
    default:
        // Numeric fallback: a multi-character pure decimal string that parses
        // as a non-negative integer is treated as a raw, layout-independent
        // CGKeyCode. This lets callers address keys outside the named map
        // (F13-F24, media keys, non-US layout positions) by their numeric code.
        // A SINGLE digit ("0".."9") is intentionally NOT intercepted here: it
        // is a single character and must fall through to layout translation in
        // resolveInputKey, where it resolves to the real hardware key code for
        // the active keyboard layout (e.g. "0" -> 29 on US layouts). Int(String)
        // rejects whitespace and non-digits; a leading "+" is accepted (e.g.
        // "+5" parses to 5, which is the raw code the caller asked for), so the
        // UInt16 range guard below is what actually bounds valid key codes.
        // Values outside the UInt16 key-code range are not valid key codes and
        // are rejected.
        if lowered.count > 1,
           let raw = Int(lowered),
           (0 ... Int(UInt16.max)).contains(raw)
        {
            return CGKeyCode(raw)
        }
        return nil
    }
}

/// Resolves one validated public key intent against one exact keyboard-input
/// source snapshot. Named keys are layout-independent; character keys retain
/// the source ID, layout-data digest, and keyboard type used for translation.
public func resolveInputKey(_ keyName: String) -> ResolvedInputKey? {
    if let keyCode = layoutIndependentKeyCode(for: keyName) {
        return ResolvedInputKey(keyCode: keyCode, sourceIdentity: nil)
    }
    let lowered = keyName.lowercased()
    guard lowered.count == 1, let layout = keyboardLayoutSnapshot() else {
        return nil
    }

    let layoutPtr = unsafeBitCast(
        CFDataGetBytePtr(layout.layoutData),
        to: UnsafePointer<UCKeyboardLayout>.self,
    )
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
            0,
            layout.identity.keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            maxLength,
            &actualLength,
            &chars,
        )
        guard status == noErr, actualLength > 0 else { continue }
        let produced = String(
            utf16CodeUnits: chars,
            count: actualLength,
        ).lowercased()
        if produced == lowered {
            return ResolvedInputKey(
                keyCode: CGKeyCode(keyCode),
                sourceIdentity: layout.identity,
            )
        }
    }
    return nil
}

public func mapKeyNameToKeyCode(_ keyName: String) -> CGKeyCode? {
    resolveInputKey(keyName)?.keyCode
}
