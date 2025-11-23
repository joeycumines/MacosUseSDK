import Foundation
import OSLog

/// Use Logger and OSLogPrivacy to log messages with appropriate privacy levels.

private let subsystem = "com.macosusesdk"

/// Returns a configured `Logger` for the given category within the MacosUseSDK subsystem.
///
/// - Parameter category: A string identifying the logging category (e.g., "AppOpener", "InputController").
/// - Returns: A `Logger` instance configured with the subsystem and category.
public func sdkLogger(category: String) -> Logger {
    Logger(subsystem: subsystem, category: category)
}
