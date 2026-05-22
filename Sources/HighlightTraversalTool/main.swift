import AppKit // Required for NSApplication and RunLoop
import Foundation
import MacosUseSDK // Your library

/// --- Helper Function for Argument Parsing ---
/// Simple parser for "--duration <value>" and PID
func parseArguments() -> (pid: Int32?, duration: Double?) {
    var pid: Int32?
    var duration: Double?
    var waitingForDurationValue = false

    // Skip the executable path
    for arg in CommandLine.arguments.dropFirst() {
        if waitingForDurationValue {
            if let durationValue = Double(arg), durationValue > 0 {
                duration = durationValue
            } else {
                fputs("error: Invalid value provided after --duration.\n", stderr)
                return (nil, nil) // Indicate parsing error
            }
            waitingForDurationValue = false
        } else if arg == "--duration" {
            waitingForDurationValue = true
        } else if pid == nil, let pidValue = Int32(arg) {
            pid = pidValue
        } else {
            fputs("error: Unexpected argument '\(arg)'.\n", stderr)
            return (nil, nil) // Indicate parsing error
        }
    }

    // Check if duration flag was seen but value is missing
    if waitingForDurationValue {
        fputs("error: Missing value after --duration flag.\n", stderr)
        return (nil, nil)
    }

    // Check if PID was found
    if pid == nil {
        fputs("error: Missing required PID argument.\n", stderr)
        return (nil, nil)
    }

    return (pid, duration)
}

// --- Main Execution Logic ---

/// 1. Parse Arguments
let (parsedPID, parsedDuration) = parseArguments()

guard let targetPID = parsedPID else {
    // Error messages printed by parser
    fputs("\nusage: HighlightTraversalTool <PID> [--duration <seconds>]\n", stderr)
    fputs("  <PID>: Process ID of the application to highlight.\n", stderr)
    fputs(
        "  --duration <seconds>: How long the highlights should stay visible (default: 3.0).\n", stderr,
    )
    fputs("\nexample: HighlightTraversalTool 14154 --duration 5\n", stderr)
    exit(1)
}

/// Use provided duration or default
let highlightDuration = parsedDuration ?? 3.0

fputs("info: Target PID: \(targetPID), Highlight Duration: \(highlightDuration) seconds.\n", stderr)

// Wrap async calls in a Task
Task {
    do {
        // 2. Perform Traversal FIRST
        fputs("info: Calling traverseAccessibilityTree (visible only)...\n", stderr)
        let responseData = try MacosUseSDK.traverseAccessibilityTree(
            pid: targetPID, onlyVisibleElements: true,
        )
        fputs(
            "info: Traversal complete. Found \(responseData.elements.count) visible elements.\n", stderr,
        )

        // 4. Encode the ResponseData to JSON
        fputs("info: Encoding traversal response to JSON...\n", stderr)
        let encoder = JSONEncoder()
        // Optionally make the output prettier
        // encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // Uncomment for human-readable JSON
        let jsonData = try encoder.encode(responseData)

        // 5. Print JSON to standard output
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw MacosUseSDKError.internalError("Failed to convert JSON data to UTF-8 string.")
        }
        print(jsonString) // Print JSON to stdout
        fputs("info: Successfully printed JSON response to stdout.\n", stderr)

        // 3. Dispatch Highlighting using the traversal results
        fputs(
            "info: Preparing visual highlights for \(responseData.elements.count) elements...\n", stderr,
        )

        await MainActor.run {
            let screenHeight = NSScreen.main?.frame.height ?? 1080
            let descriptors = responseData.elements.compactMap { OverlayDescriptor(element: $0, screenHeight: screenHeight) }

            if !descriptors.isEmpty {
                fputs("info: Presenting visuals for \(highlightDuration) seconds...\n", stderr)
                let config = VisualsConfig(duration: highlightDuration, animationStyle: .none)

                Task { @MainActor in
                    await presentVisuals(overlays: descriptors, configuration: config)
                    fputs("info: Visuals complete. Exiting.\n", stderr)
                    exit(0)
                }
            } else {
                fputs("info: No valid elements to highlight. Exiting.\n", stderr)
                exit(0)
            }
        }

        // Task completes here, but the inner Task (visuals) keeps running on MainActor until exit(0)

    } catch let error as MacosUseSDKError {
        // Specific SDK errors
        fputs("❌ Error from MacosUseSDK: \(error.localizedDescription)\n", stderr)
        exit(1)
    } catch {
        // Other errors (e.g., JSON encoding failure)
        fputs("❌ An unexpected error occurred: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Keep the process alive so the Task can run
RunLoop.main.run()

/*

 swift run HighlightTraversalTool $(swift run AppOpenerTool Messages) --duration 5

 */
