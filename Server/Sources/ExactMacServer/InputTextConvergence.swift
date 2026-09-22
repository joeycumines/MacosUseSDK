import ApplicationServices
import Foundation
import GRPCCore

protocol InputTextStateReading: Sendable {
    func focusedElement(pid: pid_t) -> AXElementRead
    func attribute(element: AnyObject, attribute: String) -> AXAttributeRead
}

struct SystemInputTextStateReader: InputTextStateReading {
    let system: any SystemOperations

    func focusedElement(pid: pid_t) -> AXElementRead {
        guard let application = system.createAXApplication(pid: pid) else {
            return AXElementRead(
                errorCode: AXError.invalidUIElement.rawValue,
                element: nil,
            )
        }
        let read = system.copyAXAttributeResult(
            element: application,
            attribute: kAXFocusedUIElementAttribute as String,
        )
        guard read.errorCode == AXError.success.rawValue else {
            return AXElementRead(errorCode: read.errorCode, element: nil)
        }
        guard let element = read.value as AnyObject? else {
            return AXElementRead(
                errorCode: AXError.noValue.rawValue,
                element: nil,
            )
        }
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return AXElementRead(
                errorCode: AXError.illegalArgument.rawValue,
                element: nil,
            )
        }
        return AXElementRead(
            errorCode: AXError.success.rawValue,
            element: element,
        )
    }

    func attribute(element: AnyObject, attribute: String) -> AXAttributeRead {
        system.copyAXAttributeResult(
            element: element,
            attribute: attribute,
        )
    }
}

struct InputTextConvergencePolicy: Sendable {
    let timeout: Duration
    let pollInterval: Duration

    init(
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(25),
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }
}

struct InputTextStateBaseline: @unchecked Sendable {
    let focusedElement: AnyObject
    let value: AnyObject?
    let selectedTextRange: AnyObject?
}

@MainActor
final class InputTextPasteConvergenceCoordinator {
    private let verifier: InputTextConvergenceVerifier
    private var baseline: InputTextStateBaseline?

    init(verifier: InputTextConvergenceVerifier) {
        self.verifier = verifier
    }

    func prepare(
        text: String,
        replacePasteboardText: @escaping @Sendable (String) async throws -> Void,
    ) async throws {
        guard baseline == nil else {
            throw RPCError(
                code: .internalError,
                message: "Physical paste convergence already has an unconsumed baseline",
            )
        }
        let captured = try verifier.capture()
        try await replacePasteboardText(text)
        baseline = captured
    }

    func waitForConsumption() async throws {
        guard let baseline else {
            throw RPCError(
                code: .internalError,
                message: "Physical paste convergence has no staged baseline",
            )
        }
        defer { self.baseline = nil }
        try await verifier.waitForChange(from: baseline)
    }
}

@MainActor
struct InputTextConvergenceVerifier {
    let pid: pid_t
    let reader: any InputTextStateReading
    let policy: InputTextConvergencePolicy

    init(
        pid: pid_t,
        reader: any InputTextStateReading,
        policy: InputTextConvergencePolicy = InputTextConvergencePolicy(),
    ) {
        self.pid = pid
        self.reader = reader
        self.policy = policy
    }

    func capture() throws -> InputTextStateBaseline {
        let focusedElement = try readFocusedElement(allowTransient: false)
        let value = try readObservableAttribute(
            element: focusedElement,
            attribute: kAXValueAttribute as String,
            allowTransient: false,
        )
        let selectedTextRange = try readObservableAttribute(
            element: focusedElement,
            attribute: kAXSelectedTextRangeAttribute as String,
            allowTransient: false,
        )
        guard value != nil || selectedTextRange != nil else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Focused input element exposes no observable text state",
            )
        }
        return InputTextStateBaseline(
            focusedElement: focusedElement,
            value: value,
            selectedTextRange: selectedTextRange,
        )
    }

    func waitForChange(from baseline: InputTextStateBaseline) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: policy.timeout)
        while true {
            try Task.checkCancellation()
            do {
                let focusedElement = try readFocusedElement(allowTransient: true)
                guard inputTextObjectsEqual(
                    focusedElement,
                    baseline.focusedElement,
                ) else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Focused input element changed before physical paste consumption",
                    )
                }
                let value = try readObservableAttribute(
                    element: focusedElement,
                    attribute: kAXValueAttribute as String,
                    allowTransient: true,
                )
                let selectedTextRange = try readObservableAttribute(
                    element: focusedElement,
                    attribute: kAXSelectedTextRangeAttribute as String,
                    allowTransient: true,
                )
                guard value != nil || selectedTextRange != nil else {
                    throw RPCError(
                        code: .failedPrecondition,
                        message: "Focused input element stopped exposing observable text state",
                    )
                }
                if !inputTextOptionalObjectsEqual(value, baseline.value)
                    || !inputTextOptionalObjectsEqual(
                        selectedTextRange,
                        baseline.selectedTextRange,
                    )
                {
                    return
                }
            } catch InputTextTransientReadError.retry {
                // AX can temporarily return cannotComplete while AppKit
                // consumes a just-routed paste. Retry only that exact class.
            }

            guard clock.now < deadline else {
                throw RPCError(
                    code: .deadlineExceeded,
                    message: "Timed out waiting for physical paste consumption",
                )
            }
            if policy.pollInterval == .zero {
                await Task.yield()
            } else {
                try await Task.sleep(for: policy.pollInterval)
            }
        }
    }

    private func readFocusedElement(
        allowTransient: Bool,
    ) throws -> AnyObject {
        let read = reader.focusedElement(pid: pid)
        if allowTransient, inputTextAXReadIsTransient(read.errorCode) {
            throw InputTextTransientReadError.retry
        }
        guard read.errorCode == AXError.success.rawValue,
              let element = read.element
        else {
            throw inputTextAXReadError(
                read.errorCode,
                operation: "read focused input element",
            )
        }
        return element
    }

    private func readObservableAttribute(
        element: AnyObject,
        attribute: String,
        allowTransient: Bool,
    ) throws -> AnyObject? {
        let read = reader.attribute(
            element: element,
            attribute: attribute,
        )
        switch read.errorCode {
        case AXError.success.rawValue:
            guard let value = read.value else {
                throw RPCError(
                    code: .unavailable,
                    message: "Accessibility returned an empty successful \(attribute) read",
                )
            }
            return value as AnyObject
        case AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue:
            return nil
        default:
            if allowTransient, inputTextAXReadIsTransient(read.errorCode) {
                throw InputTextTransientReadError.retry
            }
            throw inputTextAXReadError(
                read.errorCode,
                operation: "read \(attribute)",
            )
        }
    }
}

private enum InputTextTransientReadError: Error {
    case retry
}

/// Classifies an AX error code as transient (worth retrying) vs fatal. AX can
/// briefly return `cannotComplete` / `failure` while AppKit settles after a
/// routed input; those are retried by the convergence loops. Shared by the
/// input-text verifier and the element readback helper (C19).
func inputTextAXReadIsTransient(_ errorCode: Int32) -> Bool {
    errorCode == AXError.cannotComplete.rawValue
        || errorCode == AXError.failure.rawValue
}

private func inputTextAXReadError(
    _ errorCode: Int32,
    operation: String,
) -> RPCError {
    switch errorCode {
    case AXError.apiDisabled.rawValue:
        RPCError(
            code: .permissionDenied,
            message: "Accessibility permission was lost while attempting to \(operation)",
        )
    case AXError.invalidUIElement.rawValue:
        RPCError(
            code: .failedPrecondition,
            message: "Focused input element became invalid while attempting to \(operation)",
        )
    case AXError.attributeUnsupported.rawValue, AXError.noValue.rawValue:
        RPCError(
            code: .failedPrecondition,
            message: "Focused input element does not support \(operation)",
        )
    case AXError.cannotComplete.rawValue, AXError.failure.rawValue:
        RPCError(
            code: .unavailable,
            message: "Accessibility could not \(operation)",
        )
    default:
        RPCError(
            code: .internalError,
            message: "Accessibility \(operation) failed with AXError \(errorCode)",
        )
    }
}

private func inputTextOptionalObjectsEqual(
    _ lhs: AnyObject?,
    _ rhs: AnyObject?,
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (lhs?, rhs?):
        inputTextObjectsEqual(lhs, rhs)
    default:
        false
    }
}

private func inputTextObjectsEqual(
    _ lhs: AnyObject,
    _ rhs: AnyObject,
) -> Bool {
    CFEqual(lhs, rhs)
}
