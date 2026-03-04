// Shared utility for resolving the private _AXUIElementGetWindow API via dlsym.
// Both the SDK (WindowQuery.swift) and the Server (ProductionSystemOperations.swift)
// use this function to bridge AXUIElement ↔ CGWindowID.

import ApplicationServices

/// Function pointer type for the private _AXUIElementGetWindow API.
/// Resolved dynamically via dlsym to avoid hard-linking a private symbol
/// that could be removed in future macOS releases.
private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Lazily resolved function pointer for _AXUIElementGetWindow.
/// Returns nil if the symbol is not available (e.g., removed in a future macOS version).
/// Thread-safe: dlsym is documented as thread-safe and the result is immutable.
private let resolvedGetWindowFn: AXUIElementGetWindowFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else {
        return nil
    }
    return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
}()

/// Attempts to resolve the CGWindowID for an AXUIElement using the private
/// `_AXUIElementGetWindow` API (resolved via `dlsym` at first use).
///
/// This is the single source of truth for `_AXUIElementGetWindow` resolution
/// across the entire codebase. Both the SDK's `fetchAXWindowInfo` and the
/// Server's `ProductionSystemOperations.getAXWindowID` delegate to this function.
///
/// - Parameter element: The AXUIElement to query.
/// - Returns: A tuple of `(result: AXError, windowID: CGWindowID)`. If the private API
///   is unavailable (symbol not found via dlsym), returns `(.failure, 0)`. If the API
///   is available but fails, returns the error code with `windowID` of 0. On success,
///   returns `(.success, windowID)`.
public func resolveAXWindowID(for element: AXUIElement) -> (result: AXError, windowID: CGWindowID) {
    guard let getWindowFn = resolvedGetWindowFn else {
        return (.failure, 0)
    }
    var windowID: CGWindowID = 0
    let result = getWindowFn(element, &windowID)
    return (result, windowID)
}
