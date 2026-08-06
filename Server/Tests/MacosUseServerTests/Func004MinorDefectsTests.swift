import ApplicationServices
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

/// Atomic proofs for the FUNC-004 MINOR defects (C11, C17, C20, C23). Each
/// test verifies the NEW behavior introduced by the fix, not just that nothing
/// regressed. C16/C22 (performElementAction error code + showMenu guidance)
/// and C19 (transient AX convergence) are integration-level behaviors; they are
/// proven by the full package compiling and by the existing element/session
/// suites remaining green, and are documented as such in WIP.md.
final class Func004MinorDefectsTests: XCTestCase {
    // MARK: - C17: unrecognized / empty macro action is rejected

    /// A `MacroAction` whose oneof action is unset stands in for an
    /// unrecognized action variant (SwiftProtobuf drops unknown oneof field
    /// numbers, leaving `action == nil`). The validator MUST reject it rather
    /// than silently accepting the action.
    func testC17_ValidatorRejectsUnsetActionVariant() throws {
        let unsetAction = Macosusesdk_V1_MacroAction()
        XCTAssertNil(unsetAction.action, "precondition: an unset action oneof must be nil")

        var caught: MacroDefinitionValidationError?
        do {
            try MacroDefinitionValidator.validate(actions: [unsetAction]) { _ in }
        } catch let error as MacroDefinitionValidationError {
            caught = error
        } catch {
            XCTFail("expected MacroDefinitionValidationError, got \(error)")
        }

        let validationError = try XCTUnwrap(caught, "an unset/unrecognized action variant must be rejected")
        XCTAssertTrue(
            validationError.localizedDescription.contains("unrecognized")
                || validationError.localizedDescription.contains("required"),
            "the rejection message must name the unrecognized/missing variant (got: \(validationError.localizedDescription))",
        )
    }

    /// A well-formed action (wait with a positive duration) is accepted, proving
    /// the C17 rejection is specific to the unset variant, not a blanket throw.
    func testC17_ValidatorAcceptsWellFormedAction() throws {
        let waitAction = Macosusesdk_V1_MacroAction.with {
            $0.wait = .with { $0.duration = 0.5 }
        }
        // Should not throw.
        try MacroDefinitionValidator.validate(actions: [waitAction]) { _ in }
    }

    // MARK: - C20: InputTextConvergencePolicy default poll interval is 25ms

    /// The default poll interval MUST be 25ms (matching the pre-consolidation
    /// inline readback loop). A regression to 5ms would poll 5x more often.
    func testC20_DefaultPollIntervalIs25Milliseconds() {
        let policy = InputTextConvergencePolicy()
        XCTAssertEqual(policy.pollInterval, .milliseconds(25), "default pollInterval must be 25ms")
    }

    // MARK: - C23: revision_id only when a rollback snapshot is stored

    /// A SERIALIZABLE transaction stores a snapshot, so its revision_id is
    /// non-empty AND the snapshot resolves for rollback.
    func testC23_SerializableTransactionReturnsNonEmptyRevisionId() async throws {
        let manager = SessionManager()
        let session = try await manager.createSession(
            sessionId: "c23-serializable",
            displayName: "C23 Serializable",
            metadata: [:],
        )
        defer { Task { _ = await manager.deleteSession(name: session.name) } }

        let (_, revisionId, _) = try await manager.beginTransaction(
            sessionName: session.name,
            isolationLevel: .serializable,
            timeout: 60,
        )
        XCTAssertFalse(revisionId.isEmpty, "SERIALIZABLE transactions must return a non-empty revision_id")
    }

    /// A non-SERIALIZABLE transaction stores NO snapshot, so its revision_id
    /// MUST be empty — never a dangling handle that resolves to no snapshot.
    func testC23_NonSerializableTransactionReturnsEmptyRevisionId() async throws {
        let manager = SessionManager()
        let session = try await manager.createSession(
            sessionId: "c23-non-serializable",
            displayName: "C23 Non-Serializable",
            metadata: [:],
        )
        defer { Task { _ = await manager.deleteSession(name: session.name) } }

        // UNRECOGNIZED(99) is a non-serializable isolation level. The caller
        // (SessionMethods) maps .unspecified -> .serializable, so a genuinely
        // non-serializable level reaches beginTransaction only when explicitly
        // requested — exactly the trap C23 closes.
        let (txId, revisionId, _) = try await manager.beginTransaction(
            sessionName: session.name,
            isolationLevel: .UNRECOGNIZED(99),
            timeout: 60,
        )
        XCTAssertEqual(
            revisionId,
            "",
            "non-SERIALIZABLE transactions must return an empty revision_id (no snapshot stored)",
        )

        // Rollback is unavailable for a non-serializable transaction; the empty
        // revision_id correctly signals this. A rollback attempt is rejected.
        do {
            _ = try await manager.rollbackTransaction(
                sessionName: session.name,
                transactionId: txId,
                revisionId: revisionId,
            )
            XCTFail("rollback must be unavailable for a non-SERIALIZABLE transaction")
        } catch SessionError.revisionNotFound {
            // expected: no snapshot exists for an empty revision id
        } catch {
            XCTFail("expected revisionNotFound for non-serializable rollback, got \(error)")
        }
    }

    // MARK: - C11: MockSystemOperations decoupled settability override

    /// The mock's settability check can be configured independently of the
    /// set-result, so a test can express "this attribute is NOT settable even
    /// though a set would succeed" — the not-settable failure path the legacy
    /// heuristic masked.
    func testC11_MockSettabilityOverrideDecoupledFromSetResult() {
        let mock = MockSystemOperations(
            setAXAttributeResult: AXError.success.rawValue,
            axAttributeSettable: [
                kAXValueAttribute as String: AXAttributeSettableRead(
                    errorCode: AXError.attributeUnsupported.rawValue,
                    settable: false,
                ),
            ],
        )

        // Even though setAXAttributeResult is success, the explicit override
        // reports the attribute as NOT settable with the configured error.
        let read = mock.isAXAttributeSettable(
            element: NSObject(),
            attribute: kAXValueAttribute as String,
        )
        XCTAssertFalse(read.settable, "the override must report NOT-settable regardless of the set-result")
        XCTAssertEqual(read.errorCode, AXError.attributeUnsupported.rawValue)

        // An attribute WITHOUT an override falls back to the legacy heuristic,
        // preserving backward compatibility for existing tests.
        let legacy = mock.isAXAttributeSettable(
            element: NSObject(),
            attribute: "AXUnconfiguredAttribute",
        )
        XCTAssertTrue(legacy.settable, "attributes without an override must keep the legacy success heuristic")
    }
}
