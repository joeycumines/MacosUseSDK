import CoreGraphics
import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import GRPCCore
import XCTest

/// Defect C6 — element-path physical inputs MUST publish a real, retrievable
/// Input resource (AIP-121 resource_reference) so the `ClickElementResponse.input`
/// / `WriteElementValueResponse.input` output-only field points at something
/// `GetInput` can actually fetch.
///
/// These tests exercise `publishElementInputResource` directly with a stub
/// physical-delivery executor, proving the published resource passes through
/// the same reserve → publish → executing → finish lifecycle as the ExecuteInput
/// LRO and is retrievable via `getInput` in the COMPLETED (or FAILED) state. No
/// Accessibility or Core Graphics event delivery is required to verify this
/// resource-lifecycle contract.
final class ElementInputPublisherC6Tests: XCTestCase {
    private var service: ExactMacService!

    override func setUp() async throws {
        let registry = WindowRegistry(system: ProductionSystemOperations.shared)
        service = ExactMacService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: registry,
            system: ProductionSystemOperations.shared,
        )
    }

    override func tearDown() async throws {
        service = nil
    }

    // MARK: - Success path

    /// A physical click on an application-scoped element publishes exactly one
    /// Input resource whose name is non-empty AND retrievable via getInput in
    /// the COMPLETED state with truthful delivery evidence from the executor.
    @MainActor
    func testC6_ClickPublishesRetrievableCompletedInput() async throws {
        let parent = "applications/test-c6-click"
        let ownerID = UUID()
        let receipt = ExactMac.InputExecutionReceipt(
            route: .session,
            postedEventCount: 2,
            routedDeliveryObserved: true,
        )
        var executorInvoked = false

        let name = try await service.publishElementInputResource(
            action: .click(point: CGPoint(x: 30, y: 40)),
            parent: parent,
            ownerID: ownerID,
            route: .session,
            executor: {
                executorInvoked = true
                return receipt
            },
        )

        // The published resource name is the output-only .input value callers
        // surface; an empty string here is the C6 defect (no real resource).
        XCTAssertFalse(name.isEmpty, "publishElementInputResource must return a non-empty Input name")
        XCTAssertTrue(executorInvoked, "the physical executor must run on the success path")

        // AIP-121 retrievability: the surfaced reference MUST resolve via GetInput.
        let fetched = await service.stateStore.getInput(name: name)
        let published = try XCTUnwrap(
            fetched,
            "the surfaced Input name must be retrievable via getInput (AIP-121 resource_reference)",
        )
        XCTAssertEqual(published.state, Exactmac_V1_Input.State.completed, "successful delivery must finish COMPLETED")
        XCTAssertTrue(published.hasCompleteTime, "a terminal Input must carry a complete time")
        XCTAssertEqual(published.deliveryResult.postedEventCount, 2)
        XCTAssertTrue(published.deliveryResult.routedDeliveryObserved)
        // The target scope mirrors the element mutation parent (application).
        XCTAssertEqual(published.target.application, parent)
        // The action payload is the real click that was physically delivered.
        if case let .click(click) = published.action.inputType {
            XCTAssertEqual(click.clickType, Exactmac_V1_MouseClick.ClickType.left)
            XCTAssertEqual(click.clickCount, 1)
        } else {
            XCTFail("expected the published action to be a left click")
        }
    }

    // MARK: - Failure path

    /// When physical delivery throws, the published resource is finished FAILED
    /// (never stranded) and the original error is rethrown so the element method
    /// surfaces the real failure — not a silent empty `.input`.
    @MainActor
    func testC6_FailedDeliveryPublishesFailedInputAndRethrows() async throws {
        struct SimulatedDeliveryFailure: Error {}

        let parent = "applications/test-c6-fail"
        let ownerID = UUID()
        var executorInvoked = false
        var thrown: Error?

        do {
            _ = try await service.publishElementInputResource(
                action: .typeText(text: "hi", charDelay: 0),
                parent: parent,
                ownerID: ownerID,
                route: .session,
                executor: {
                    executorInvoked = true
                    throw SimulatedDeliveryFailure()
                },
            )
        } catch {
            thrown = error
        }

        XCTAssertTrue(executorInvoked, "the physical executor must still run before the failure is reported")
        XCTAssertTrue(thrown is SimulatedDeliveryFailure, "the original delivery error must be rethrown")

        // Exactly one Input identity was published; assert it is terminal FAILED.
        // listInputs keys on the fully-qualified owner name the store records
        // (parseInputName stores "applications/{id}" verbatim).
        let inputs = await service.stateStore.listInputs(parent: "applications/test-c6-fail")
        let failedInputs = inputs.filter { $0.state == .failed }
        XCTAssertEqual(failedInputs.count, 1, "the failed delivery must leave exactly one FAILED Input (not stranded)")
        XCTAssertEqual(failedInputs.first?.hasCompleteTime, true)
    }

    // MARK: - Unsupported action shape

    /// Actions the element paths never physically emit (e.g. raw .scroll) still
    /// deliver via the executor but publish NO resource (empty name), so the
    /// service never claims a retrievable Input it cannot describe truthfully.
    @MainActor
    func testC6_UnsupportedActionShapeDeliversButPublishesNoResource() async throws {
        let parent = "applications/test-c6-unsupported"
        let ownerID = UUID()
        var executorInvoked = false

        let name = try await service.publishElementInputResource(
            action: .scroll(at: nil, horizontal: 0, vertical: 1, duration: 0, modifiers: []), // not produced by element-path physical inputs
            parent: parent,
            ownerID: ownerID,
            route: .session,
            executor: {
                executorInvoked = true
                return ExactMac.InputExecutionReceipt(
                    route: .session,
                    postedEventCount: 1,
                    routedDeliveryObserved: true,
                )
            },
        )

        XCTAssertEqual(name, "", "an undescribable action must not fabricate a retrievable Input")
        XCTAssertTrue(executorInvoked, "delivery must still happen even when no resource is published")
        let publishedForUnsupported = await service.stateStore.listInputs(parent: "applications/test-c6-unsupported")
        XCTAssertTrue(
            publishedForUnsupported.isEmpty,
            "an unsupported action shape must publish NO Input identity (got \(publishedForUnsupported.count))",
        )
    }
}
