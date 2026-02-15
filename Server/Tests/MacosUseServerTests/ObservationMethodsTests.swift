import CoreGraphics
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Unit tests for ObservationMethods RPC handlers (createObservation, getObservation, listObservations,
/// cancelObservation, streamObservations).
/// These tests verify LRO lifecycle, pagination, error handling, and validation.
final class ObservationMethodsTests: XCTestCase {
    var service: MacosUseService!
    var operationStore: OperationStore!
    private var observationManager: ObservationManager!

    override func setUp() async throws {
        let registry = WindowRegistry(system: ProductionSystemOperations.shared)
        operationStore = OperationStore()
        observationManager = ObservationManager(
            windowRegistry: registry,
            system: ProductionSystemOperations.shared,
        )
        // Set the shared instance for the tests
        ObservationManager.shared = observationManager

        service = MacosUseService(
            stateStore: AppStateStore(),
            operationStore: operationStore,
            windowRegistry: registry,
            system: ProductionSystemOperations.shared,
        )
    }

    override func tearDown() async throws {
        service = nil
        operationStore = nil
        observationManager = nil
    }

    // MARK: - Helpers

    private func makeCreateObservationRequest(
        _ msg: Macosusesdk_V1_CreateObservationRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_CreateObservationRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeGetObservationRequest(
        _ msg: Macosusesdk_V1_GetObservationRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_GetObservationRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeListObservationsRequest(
        _ msg: Macosusesdk_V1_ListObservationsRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_ListObservationsRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeCancelObservationRequest(
        _ msg: Macosusesdk_V1_CancelObservationRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_CancelObservationRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeStreamObservationsRequest(
        _ msg: Macosusesdk_V1_StreamObservationsRequest,
    ) -> GRPCCore.ServerRequest<Macosusesdk_V1_StreamObservationsRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeCreateObservationContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.CreateObservation.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeGetObservationContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.GetObservation.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeListObservationsContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ListObservations.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeCancelObservationContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.CancelObservation.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeStreamObservationsContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.StreamObservations.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    /// Helper to create a test observation using ObservationManager directly (bypasses PID parsing)
    private func createTestObservation(
        name: String,
        parent: String = "applications/12345",
        type: Macosusesdk_V1_ObservationType = .windowChanges,
        pid: pid_t = 12345,
    ) async -> Macosusesdk_V1_Observation {
        await observationManager.createObservation(
            name: name,
            type: type,
            parent: parent,
            filter: nil,
            pid: pid,
            activate: false,
        )
    }

    // MARK: - CreateObservation Tests

    func testCreateObservationReturnsLROWithProperName() async throws {
        // Setup: Use pid 1 (launchd) which always exists
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "test-obs-1"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        // Verify LRO structure
        XCTAssertTrue(op.name.hasPrefix("operations/observation/"))
        XCTAssertTrue(op.name.contains("test-obs-1"))
        XCTAssertFalse(op.done, "LRO should initially be not done (background task)")
    }

    func testCreateObservationGeneratesObservationIDWhenNotProvided() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        // observationID is empty

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertTrue(op.name.hasPrefix("operations/observation/"))
        XCTAssertFalse(op.name.isEmpty)
        // The generated ID is a UUID so it should have reasonable length
        XCTAssertGreaterThan(op.name.count, 20)
    }

    func testCreateObservationWithWindowChangesType() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "window-obs"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertFalse(op.name.isEmpty)
        XCTAssertTrue(op.hasMetadata, "LRO should have metadata with observation info")
    }

    func testCreateObservationWithElementChangesType() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .elementChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "element-obs"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertTrue(op.name.contains("element-obs"))
    }

    func testCreateObservationWithAttributeChangesType() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .attributeChanges
        observation.filter = Macosusesdk_V1_ObservationFilter.with {
            $0.attributes = ["AXValue", "AXTitle"]
        }

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "attr-obs"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertTrue(op.name.contains("attr-obs"))
    }

    func testCreateObservationWithTreeChangesType() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .treeChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "tree-obs"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertTrue(op.name.contains("tree-obs"))
    }

    func testCreateObservationWithFilter() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges
        observation.filter = Macosusesdk_V1_ObservationFilter.with {
            $0.pollInterval = 2.0
            $0.visibleOnly = true
            $0.roles = ["AXButton", "AXTextField"]
        }

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "filtered-obs"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertTrue(op.name.contains("filtered-obs"))
    }

    func testCreateObservationWithActivateOption() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges
        observation.activate = true

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "applications/1"
        request.observation = observation
        request.observationID = "activate-obs"

        let response = try await service.createObservation(
            request: makeCreateObservationRequest(request),
            context: makeCreateObservationContext(),
        )
        let op = try response.message

        XCTAssertTrue(op.name.contains("activate-obs"))
    }

    func testCreateObservationInvalidParentFormat() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = "invalid-parent-format"
        request.observation = observation

        do {
            _ = try await service.createObservation(
                request: makeCreateObservationRequest(request),
                context: makeCreateObservationContext(),
            )
            XCTFail("Expected error for invalid parent format")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testCreateObservationEmptyParent() async throws {
        var observation = Macosusesdk_V1_Observation()
        observation.type = .windowChanges

        var request = Macosusesdk_V1_CreateObservationRequest()
        request.parent = ""
        request.observation = observation

        do {
            _ = try await service.createObservation(
                request: makeCreateObservationRequest(request),
                context: makeCreateObservationContext(),
            )
            XCTFail("Expected error for empty parent")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - GetObservation Tests

    func testGetObservationRetrievesObservationByName() async throws {
        // Create observation directly in the manager
        let obsName = "applications/12345/observations/test-get-obs"
        _ = await createTestObservation(name: obsName)

        var request = Macosusesdk_V1_GetObservationRequest()
        request.name = obsName

        let response = try await service.getObservation(
            request: makeGetObservationRequest(request),
            context: makeGetObservationContext(),
        )
        let observation = try response.message

        XCTAssertEqual(observation.name, obsName)
        XCTAssertEqual(observation.type, .windowChanges)
        XCTAssertEqual(observation.state, .pending)
    }

    func testGetObservationNonExistentReturnsNotFound() async throws {
        var request = Macosusesdk_V1_GetObservationRequest()
        request.name = "applications/12345/observations/does-not-exist"

        do {
            _ = try await service.getObservation(
                request: makeGetObservationRequest(request),
                context: makeGetObservationContext(),
            )
            XCTFail("Expected NOT_FOUND error for non-existent observation")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("not found"))
        }
    }

    func testGetObservationEmptyNameReturnsValidationError() async throws {
        let request = Macosusesdk_V1_GetObservationRequest()
        // name is empty

        do {
            _ = try await service.getObservation(
                request: makeGetObservationRequest(request),
                context: makeGetObservationContext(),
            )
            XCTFail("Expected validation error for empty name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("name"))
        }
    }

    func testGetObservationReturnsCorrectState() async throws {
        // Create and start observation
        let obsName = "applications/12345/observations/test-state-obs"
        _ = await createTestObservation(name: obsName)

        // Initially pending
        var request = Macosusesdk_V1_GetObservationRequest()
        request.name = obsName

        let response = try await service.getObservation(
            request: makeGetObservationRequest(request),
            context: makeGetObservationContext(),
        )
        let observation = try response.message

        XCTAssertEqual(observation.state, .pending)
        XCTAssertTrue(observation.hasCreateTime)
    }

    func testGetObservationReturnsCorrectType() async throws {
        let obsName = "applications/12345/observations/element-type-obs"
        _ = await createTestObservation(
            name: obsName,
            type: .elementChanges,
        )

        var request = Macosusesdk_V1_GetObservationRequest()
        request.name = obsName

        let response = try await service.getObservation(
            request: makeGetObservationRequest(request),
            context: makeGetObservationContext(),
        )
        let observation = try response.message

        XCTAssertEqual(observation.type, .elementChanges)
    }

    // MARK: - ListObservations Tests

    func testListObservationsReturnsObservationsForParent() async throws {
        let parent = "applications/12345"
        _ = await createTestObservation(
            name: "\(parent)/observations/obs1",
            parent: parent,
        )
        _ = await createTestObservation(
            name: "\(parent)/observations/obs2",
            parent: parent,
        )

        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = parent

        let response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result = try response.message

        XCTAssertEqual(result.observations.count, 2)
    }

    func testListObservationsReturnsEmptyForNoObservations() async throws {
        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = "applications/99999"

        let response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result = try response.message

        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertTrue(result.nextPageToken.isEmpty)
    }

    func testListObservationsPaginationWithPageSize() async throws {
        let parent = "applications/54321"
        // Create 5 observations
        for i in 1 ... 5 {
            _ = await createTestObservation(
                name: "\(parent)/observations/obs\(String(format: "%03d", i))",
                parent: parent,
            )
        }

        // Request page size of 2
        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = parent
        request.pageSize = 2

        let response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result = try response.message

        XCTAssertEqual(result.observations.count, 2)
        XCTAssertFalse(result.nextPageToken.isEmpty, "Should have next page token when more results exist")
    }

    func testListObservationsPaginationContinuation() async throws {
        let parent = "applications/11111"
        // Create 3 observations
        for i in 1 ... 3 {
            _ = await createTestObservation(
                name: "\(parent)/observations/obs\(String(format: "%03d", i))",
                parent: parent,
            )
        }

        // Page 1
        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = parent
        request.pageSize = 2

        let page1Response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let page1 = try page1Response.message

        XCTAssertEqual(page1.observations.count, 2)
        XCTAssertFalse(page1.nextPageToken.isEmpty)

        // Page 2
        request.pageToken = page1.nextPageToken
        let page2Response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let page2 = try page2Response.message

        XCTAssertEqual(page2.observations.count, 1)
        XCTAssertTrue(page2.nextPageToken.isEmpty, "No more results should mean empty token")

        // Verify no duplicates
        let page1Names = Set(page1.observations.map(\.name))
        let page2Names = Set(page2.observations.map(\.name))
        XCTAssertTrue(page1Names.isDisjoint(with: page2Names), "Pages should not contain duplicate observations")
    }

    func testListObservationsReturnsDeterministicOrder() async throws {
        let parent = "applications/22222"
        // Create observations in non-sorted order
        _ = await createTestObservation(name: "\(parent)/observations/zebra", parent: parent)
        _ = await createTestObservation(name: "\(parent)/observations/apple", parent: parent)
        _ = await createTestObservation(name: "\(parent)/observations/mango", parent: parent)

        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = parent

        // Call twice and verify same order
        let response1 = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result1 = try response1.message

        let response2 = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result2 = try response2.message

        XCTAssertEqual(result1.observations.count, result2.observations.count)

        for (obs1, obs2) in zip(result1.observations, result2.observations) {
            XCTAssertEqual(obs1.name, obs2.name, "Order should be deterministic")
        }

        // Verify sorted by name (ascending)
        let names = result1.observations.map(\.name)
        XCTAssertEqual(names, names.sorted(), "Should be sorted alphabetically by name")
    }

    func testListObservationsEmptyNextPageTokenWhenAllResultsFit() async throws {
        let parent = "applications/33333"
        _ = await createTestObservation(name: "\(parent)/observations/only-one", parent: parent)

        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = parent
        request.pageSize = 10 // More than available

        let response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result = try response.message

        XCTAssertEqual(result.observations.count, 1)
        XCTAssertTrue(result.nextPageToken.isEmpty)
    }

    func testListObservationsDefaultPageSize() async throws {
        // This test verifies default page size behavior when pageSize is 0 or not set
        let parent = "applications/44444"
        _ = await createTestObservation(name: "\(parent)/observations/test-obs", parent: parent)

        var request = Macosusesdk_V1_ListObservationsRequest()
        request.parent = parent
        request.pageSize = 0 // Should use default

        let response = try await service.listObservations(
            request: makeListObservationsRequest(request),
            context: makeListObservationsContext(),
        )
        let result = try response.message

        // Should return results with default page size (100)
        XCTAssertGreaterThanOrEqual(result.observations.count, 1)
    }

    // MARK: - CancelObservation Tests

    func testCancelObservationChangesStateToCancelled() async throws {
        // Create observation
        let obsName = "applications/12345/observations/cancel-test-obs"
        _ = await createTestObservation(name: obsName)

        var request = Macosusesdk_V1_CancelObservationRequest()
        request.name = obsName

        let response = try await service.cancelObservation(
            request: makeCancelObservationRequest(request),
            context: makeCancelObservationContext(),
        )
        let observation = try response.message

        XCTAssertEqual(observation.name, obsName)
        XCTAssertEqual(observation.state, .cancelled)
        XCTAssertTrue(observation.hasEndTime, "Cancelled observation should have end time")
    }

    func testCancelObservationIsIdempotent() async throws {
        let obsName = "applications/12345/observations/idempotent-cancel-obs"
        _ = await createTestObservation(name: obsName)

        var request = Macosusesdk_V1_CancelObservationRequest()
        request.name = obsName

        // First cancellation
        let response1 = try await service.cancelObservation(
            request: makeCancelObservationRequest(request),
            context: makeCancelObservationContext(),
        )
        let obs1 = try response1.message
        XCTAssertEqual(obs1.state, .cancelled)

        // Second cancellation (should be idempotent)
        let response2 = try await service.cancelObservation(
            request: makeCancelObservationRequest(request),
            context: makeCancelObservationContext(),
        )
        let obs2 = try response2.message
        XCTAssertEqual(obs2.state, .cancelled)
        XCTAssertEqual(obs1.name, obs2.name)
    }

    func testCancelObservationNonExistentReturnsNotFound() async throws {
        var request = Macosusesdk_V1_CancelObservationRequest()
        request.name = "applications/12345/observations/does-not-exist-for-cancel"

        do {
            _ = try await service.cancelObservation(
                request: makeCancelObservationRequest(request),
                context: makeCancelObservationContext(),
            )
            XCTFail("Expected NOT_FOUND error for non-existent observation")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("not found"))
        }
    }

    func testCancelObservationEmptyNameReturnsValidationError() async throws {
        let request = Macosusesdk_V1_CancelObservationRequest()
        // name is empty

        do {
            _ = try await service.cancelObservation(
                request: makeCancelObservationRequest(request),
                context: makeCancelObservationContext(),
            )
            XCTFail("Expected validation error for empty name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("name"))
        }
    }

    func testCancelObservationSetsEndTime() async throws {
        let obsName = "applications/12345/observations/end-time-test-obs"
        _ = await createTestObservation(name: obsName)

        var request = Macosusesdk_V1_CancelObservationRequest()
        request.name = obsName

        let response = try await service.cancelObservation(
            request: makeCancelObservationRequest(request),
            context: makeCancelObservationContext(),
        )
        let observation = try response.message

        XCTAssertTrue(observation.hasEndTime)
        XCTAssertGreaterThan(observation.endTime.seconds, 0)
    }

    // MARK: - StreamObservations Tests

    func testStreamObservationsRequiresExistingObservation() async throws {
        var request = Macosusesdk_V1_StreamObservationsRequest()
        request.name = "applications/12345/observations/non-existent-stream"

        do {
            _ = try await service.streamObservations(
                request: makeStreamObservationsRequest(request),
                context: makeStreamObservationsContext(),
            )
            XCTFail("Expected NOT_FOUND error for non-existent observation")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("not found"))
        }
    }

    func testStreamObservationsEmptyNameReturnsValidationError() async throws {
        let request = Macosusesdk_V1_StreamObservationsRequest()
        // name is empty

        do {
            _ = try await service.streamObservations(
                request: makeStreamObservationsRequest(request),
                context: makeStreamObservationsContext(),
            )
            XCTFail("Expected validation error for empty name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertTrue(error.message.contains("name"))
        }
    }

    func testStreamObservationsCreatesEventStream() async throws {
        // Create observation in manager
        let obsName = "applications/12345/observations/stream-test-obs"
        _ = await createTestObservation(name: obsName)

        var request = Macosusesdk_V1_StreamObservationsRequest()
        request.name = obsName

        // This should not throw - it should return a streaming response
        let response = try await service.streamObservations(
            request: makeStreamObservationsRequest(request),
            context: makeStreamObservationsContext(),
        )

        // Verify we got a streaming response (can't really test the stream content without
        // actually running the observation monitoring, but we can verify it was created)
        switch response.accepted {
        case .success:
            // Expected - stream was successfully created
            break
        case let .failure(error):
            XCTFail("Expected stream to be created successfully, got error: \(error)")
        }
    }

    // MARK: - LRO Lifecycle Tests

    func testObservationLifecyclePendingState() async {
        let obsName = "applications/12345/observations/lifecycle-pending"
        let obs = await createTestObservation(name: obsName)

        XCTAssertEqual(obs.state, .pending)
        XCTAssertTrue(obs.hasCreateTime)
        XCTAssertFalse(obs.hasStartTime)
        XCTAssertFalse(obs.hasEndTime)
    }

    func testObservationLifecycleActiveState() async throws {
        let obsName = "applications/12345/observations/lifecycle-active"
        _ = await createTestObservation(name: obsName)

        // Start the observation
        try await observationManager.startObservation(name: obsName)

        // Poll until active state is reached (avoid time.Sleep per CLAUDE.md)
        var obs: Macosusesdk_V1_Observation?
        for _ in 0 ..< 100 {
            if let current = await observationManager.getObservation(name: obsName),
               current.state == .active
            {
                obs = current
                break
            }
            // Minimal yield to allow state update propagation
            await Task.yield()
        }

        guard let finalObs = obs else {
            XCTFail("Observation should exist and be active")
            return
        }

        XCTAssertEqual(finalObs.state, .active)
        XCTAssertTrue(finalObs.hasStartTime)
    }

    func testObservationLifecycleCancelledState() async throws {
        let obsName = "applications/12345/observations/lifecycle-cancelled"
        _ = await createTestObservation(name: obsName)

        // Start then cancel
        try await observationManager.startObservation(name: obsName)
        _ = await observationManager.cancelObservation(name: obsName)

        guard let obs = await observationManager.getObservation(name: obsName) else {
            XCTFail("Observation should exist")
            return
        }

        XCTAssertEqual(obs.state, .cancelled)
        XCTAssertTrue(obs.hasEndTime)
    }

    func testObservationLifecycleCompletedState() async throws {
        let obsName = "applications/12345/observations/lifecycle-completed"
        _ = await createTestObservation(name: obsName)
        try await observationManager.startObservation(name: obsName)

        // Complete the observation
        await observationManager.completeObservation(name: obsName)

        guard let obs = await observationManager.getObservation(name: obsName) else {
            XCTFail("Observation should exist")
            return
        }

        XCTAssertEqual(obs.state, .completed)
        XCTAssertTrue(obs.hasEndTime)
    }

    func testObservationLifecycleFailedState() async throws {
        let obsName = "applications/12345/observations/lifecycle-failed"
        _ = await createTestObservation(name: obsName)
        try await observationManager.startObservation(name: obsName)

        // Fail the observation
        await observationManager.failObservation(name: obsName, error: NSError(domain: "test", code: 1))

        guard let obs = await observationManager.getObservation(name: obsName) else {
            XCTFail("Observation should exist")
            return
        }

        XCTAssertEqual(obs.state, .failed)
        XCTAssertTrue(obs.hasEndTime)
    }

    // MARK: - Observation State Proto Tests

    func testObservationStateValues() {
        XCTAssertEqual(Macosusesdk_V1_Observation.State.unspecified.rawValue, 0)
        XCTAssertEqual(Macosusesdk_V1_Observation.State.pending.rawValue, 1)
        XCTAssertEqual(Macosusesdk_V1_Observation.State.active.rawValue, 2)
        XCTAssertEqual(Macosusesdk_V1_Observation.State.completed.rawValue, 3)
        XCTAssertEqual(Macosusesdk_V1_Observation.State.cancelled.rawValue, 4)
        XCTAssertEqual(Macosusesdk_V1_Observation.State.failed.rawValue, 5)
    }

    func testObservationTypeValues() {
        XCTAssertEqual(Macosusesdk_V1_ObservationType.unspecified.rawValue, 0)
        XCTAssertEqual(Macosusesdk_V1_ObservationType.elementChanges.rawValue, 1)
        XCTAssertEqual(Macosusesdk_V1_ObservationType.windowChanges.rawValue, 2)
        XCTAssertEqual(Macosusesdk_V1_ObservationType.applicationChanges.rawValue, 3)
        XCTAssertEqual(Macosusesdk_V1_ObservationType.attributeChanges.rawValue, 4)
        XCTAssertEqual(Macosusesdk_V1_ObservationType.treeChanges.rawValue, 5)
    }

    // MARK: - Observation Filter Tests

    func testObservationFilterConstruction() {
        let filter = Macosusesdk_V1_ObservationFilter.with {
            $0.pollInterval = 2.5
            $0.visibleOnly = true
            $0.roles = ["AXButton", "AXTextField"]
            $0.attributes = ["AXValue", "AXTitle"]
        }

        XCTAssertEqual(filter.pollInterval, 2.5, accuracy: 0.001)
        XCTAssertTrue(filter.visibleOnly)
        XCTAssertEqual(filter.roles.count, 2)
        XCTAssertEqual(filter.attributes.count, 2)
    }

    func testObservationFilterDefaultValues() {
        let filter = Macosusesdk_V1_ObservationFilter()

        XCTAssertEqual(filter.pollInterval, 0.0)
        XCTAssertFalse(filter.visibleOnly)
        XCTAssertTrue(filter.roles.isEmpty)
        XCTAssertTrue(filter.attributes.isEmpty)
    }

    // MARK: - Observation Event Tests

    func testObservationEventConstruction() {
        let event = Macosusesdk_V1_ObservationEvent.with {
            $0.observation = "applications/12345/observations/test"
            $0.eventTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.sequence = 42
        }

        XCTAssertEqual(event.observation, "applications/12345/observations/test")
        XCTAssertEqual(event.sequence, 42)
        XCTAssertTrue(event.hasEventTime)
    }

    func testWindowEventTypeValues() {
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.unspecified.rawValue, 0)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.created.rawValue, 1)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.destroyed.rawValue, 2)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.moved.rawValue, 3)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.resized.rawValue, 4)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.minimized.rawValue, 5)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.restored.rawValue, 6)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.focused.rawValue, 7)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.hidden.rawValue, 8)
        XCTAssertEqual(Macosusesdk_V1_WindowEvent.WindowEventType.shown.rawValue, 9)
    }

    // MARK: - Active Observation Count Tests

    func testGetActiveObservationCount() async throws {
        // Initially no active observations
        let initialCount = await observationManager.getActiveObservationCount()
        XCTAssertEqual(initialCount, 0)

        // Create and start an observation
        let obsName = "applications/12345/observations/count-test"
        _ = await createTestObservation(name: obsName)
        try await observationManager.startObservation(name: obsName)

        let activeCount = await observationManager.getActiveObservationCount()
        XCTAssertEqual(activeCount, 1)

        // Cancel it
        _ = await observationManager.cancelObservation(name: obsName)

        let finalCount = await observationManager.getActiveObservationCount()
        XCTAssertEqual(finalCount, 0)
    }

    // MARK: - Resource Name Format Tests

    func testObservationResourceNameFormat() async {
        let parent = "applications/12345"
        let obsName = "\(parent)/observations/my-obs"
        let obs = await createTestObservation(name: obsName, parent: parent)

        XCTAssertEqual(obs.name, "applications/12345/observations/my-obs")
        XCTAssertTrue(obs.name.hasPrefix("applications/"))
        XCTAssertTrue(obs.name.contains("/observations/"))
    }
}
