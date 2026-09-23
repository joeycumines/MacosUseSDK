import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore

// MARK: - C6: Real, retrievable Input resources for element-path physical inputs

//
// Defect C6: ClickElementResponse.input / WriteElementValueResponse.input are
// OUTPUT_ONLY resource_reference fields to a retrievable exactmac/Input.
// They MUST be populated with the name of a real Input resource (one GetInput
// can retrieve) when a physical input transaction executed, and absent for
// purely-AX paths. Previously every element-path executeInput was
// fire-and-forget and the .input field was always empty.
//
// This file adds the bridge: a focused converter from the SDK InputAction
// (used directly by element methods) to the proto InputAction + InputTarget
// that the AppStateStore Input lifecycle requires, and a publisher that mirrors
// the ExecuteInput LRO lifecycle (reserve -> publish -> executing -> execute ->
// finish completed) so the published Input is real and retrievable via GetInput.

extension ExactMacService {
    /// Publishes one real, retrievable Input resource for an element-path
    /// physical input and returns its fully-qualified resource name. The
    /// resource passes through the same reserve->publish->executing->finish
    /// lifecycle as the ExecuteInput LRO, so GetInput(name) retrieves it.
    ///
    /// On any failure before publication the reserved identity is abandoned. On
    /// execution failure the resource is finished FAILED with conservative
    /// delivery evidence (mirroring InputMethods), so no identity is stranded.
    ///
    /// - Parameters:
    ///   - action: The SDK input action that was/will be physically delivered.
    ///   - parent: The element mutation parent (e.g. "applications/{pid}").
    ///   - ownerID: The mutation-gate owner UUID (from handlePhysicalMutationWithOwner).
    ///   - route: The exact delivery route used for the physical input.
    ///   - executor: Closure performing the physical delivery (the existing
    ///     `context.executeInput`) and returning the SDK delivery receipt.
    /// - Returns: The published Input's resource name (empty if publication
    ///   could not proceed).
    @MainActor
    func publishElementInputResource(
        action: ExactMac.InputAction,
        parent: String,
        ownerID: UUID,
        route _: ExactMac.InputDeliveryRoute,
        executor: @MainActor () async throws -> ExactMac.InputExecutionReceipt,
    ) async throws -> String {
        // Build the proto action + a minimal, truthful InputTarget describing
        // the application/window scope targeted by the element mutation.
        guard let protoAction = try? Self.elementInputActionProto(from: action) else {
            // Unsupported action shape for publication: deliver the physical
            // input but do not claim a resource we cannot describe truthfully.
            _ = try await executor()
            return ""
        }
        let target = Self.elementInputTargetProto(parent: parent)

        // Allocate a unique Input identity bound to this exact mutation owner.
        let inputParent = parent
        let inputID = UUID().uuidString
        let name = "\(inputParent)/inputs/\(inputID)"
        // parseInputName validates the resource-name shape the store relies on.
        _ = try? ParsingHelpers.parseInputName(name)

        let reservation = await stateStore.reserveInputIdentity(
            name: name,
            ownerID: ownerID,
        )
        let lease: AppStateStore.InputIdentityLease
        switch reservation {
        case let .reserved(reserved):
            lease = reserved
        case .duplicate:
            // Vanishingly unlikely (UUID collision); fall back to delivering the
            // input without a published resource rather than failing the action.
            _ = try await executor()
            return ""
        case .admissionClosed:
            throw RPCError(code: .unavailable, message: "Input admission is closed")
        }

        // Publish PENDING -> EXECUTING so the resource is visible to GetInput
        // and in the correct pre-terminal state before delivery.
        guard await stateStore.publishPendingInput(
            lease: lease,
            action: protoAction,
            target: target,
        ) != nil else {
            _ = await stateStore.abandonInputIdentity(lease)
            _ = try await executor()
            return ""
        }
        _ = await stateStore.markInputExecuting(lease: lease)

        // Deliver the physical input. On success, finish COMPLETED with the
        // observed delivery receipt; on failure, finish FAILED so the identity
        // is terminal and not stranded, then surface the original error.
        do {
            let receipt = try await executor()
            guard let postedEventCount = Int32(exactly: receipt.postedEventCount) else {
                throw RPCError(
                    code: .internalError,
                    message: "Input delivery event count exceeded the public range",
                )
            }
            let delivery = inputDeliveryResult(
                commitment: .committedAndSettled,
                postedEventCount: postedEventCount,
                routedDeliveryObserved: receipt.routedDeliveryObserved,
            )
            switch await stateStore.finishInput(lease: lease, outcome: .completed(delivery)) {
            case let .finished(completedInput):
                return completedInput.name
            case .leaseLost, .missingPublishedState, .alreadyTerminal:
                // The input was physically delivered; return the name even if
                // terminal persistence raced, so the caller can still surface it.
                return name
            }
        } catch {
            let evidence: (postedEventCount: Int, routedDeliveryObserved: Bool) = if let failure = error as? ExactMac.InputExecutionFailure {
                (
                    max(0, failure.postedEventCount),
                    failure.routedDeliveryObserved,
                )
            } else {
                (0, false)
            }
            let delivery = inputDeliveryResult(
                commitment: evidence.postedEventCount > 0 || evidence.routedDeliveryObserved
                    ? .possiblyCommitted : .noEffect,
                postedEventCount: Int32(clamping: evidence.postedEventCount),
                routedDeliveryObserved: evidence.routedDeliveryObserved,
            )
            let isCancellation = error is CancellationError
                || (error as? ExactMac.InputExecutionFailure).map {
                    isInputCancellation($0.underlying)
                } == true
            let outcome: AppStateStore.InputTerminalOutcome = isCancellation
                ? .cancelled(error: error.localizedDescription, delivery: delivery)
                : .failed(error: error.localizedDescription, delivery: delivery)
            _ = await stateStore.finishInput(lease: lease, outcome: outcome)
            throw error
        }
    }

    /// Builds a proto InputAction from an SDK InputAction for the action types
    /// the element paths emit (click variants, press, typeText). Returns nil
    /// for shapes not produced by the element paths (they never reach here).
    private static func elementInputActionProto(
        from action: ExactMac.InputAction,
    ) throws -> Exactmac_V1_InputAction? {
        switch action {
        case let .click(point):
            return .with { $0.click = mouseClick(point: point, button: .left, clickCount: 1) }
        case let .doubleClick(point):
            return .with { $0.click = mouseClick(point: point, button: .left, clickCount: 2) }
        case let .rightClick(point):
            return .with { $0.click = mouseClick(point: point, button: .right, clickCount: 1) }
        case let .clickSequence(point, button, clickCount, modifiers):
            return .with {
                $0.click = mouseClick(
                    point: point,
                    button: protoMouseButton(button),
                    clickCount: clickCount,
                    modifiers: protoModifiers(modifiers),
                )
            }
        case let .typeText(text, charDelay):
            guard !text.isEmpty else { return nil }
            return .with {
                $0.typeText = .with {
                    $0.text = text
                    $0.charDelay = charDelay
                }
            }
        case let .press(keyName, flags):
            return .with {
                $0.pressKey = .with {
                    $0.key = keyName
                    $0.modifiers = protoModifiers(flags)
                }
            }
        case let .pressHold(keyName, flags, duration):
            return .with {
                $0.pressKey = .with {
                    $0.key = keyName
                    $0.modifiers = protoModifiers(flags)
                    $0.holdDuration = duration
                }
            }
        // Element paths do not emit these; reject conservatively.
        case .type, .pressKeyCode, .pressKeyCodeHold, .move, .movePointer,
             .drag, .dragPath, .scroll, .hover:
            return nil
        }
    }

    /// Derives a minimal, truthful InputTarget from the element mutation
    /// parent. Element mutations are scoped to one application or window, so
    /// the target destination mirrors that scope.
    private static func elementInputTargetProto(
        parent: String,
    ) -> Exactmac_V1_InputTarget {
        .with {
            if parent.contains("/windows/") || parent.contains("/window-") {
                $0.window = parent
            } else {
                $0.application = parent
            }
        }
    }

    private static func mouseClick(
        point: CGPoint,
        button: Exactmac_V1_MouseClick.ClickType,
        clickCount: Int,
        modifiers: [Exactmac_V1_KeyPress.Modifier] = [],
    ) -> Exactmac_V1_MouseClick {
        .with {
            $0.position = .with {
                $0.x = point.x
                $0.y = point.y
            }
            $0.clickType = button
            $0.clickCount = Int32(clickCount)
            $0.modifiers = modifiers
        }
    }

    private static func protoMouseButton(
        _ button: CGMouseButton,
    ) -> Exactmac_V1_MouseClick.ClickType {
        switch button {
        case .left: return .left
        case .right: return .right
        case .center: return .middle
        @unknown default: return .left
        }
    }

    private static func protoModifiers(
        _ flags: CGEventFlags,
    ) -> [Exactmac_V1_KeyPress.Modifier] {
        var out: [Exactmac_V1_KeyPress.Modifier] = []
        if flags.contains(.maskCommand) {
            out.append(.command)
        }
        if flags.contains(.maskAlternate) {
            out.append(.option)
        }
        if flags.contains(.maskControl) {
            out.append(.control)
        }
        if flags.contains(.maskShift) {
            out.append(.shift)
        }
        if flags.contains(.maskSecondaryFn) {
            out.append(.function)
        }
        if flags.contains(.maskAlphaShift) {
            out.append(.capsLock)
        }
        return out
    }
}
