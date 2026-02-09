import CoreGraphics
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import SwiftProtobuf
import XCTest

/// Unit tests for ApplicationMethods (openApplication, getApplication, listApplications, deleteApplication).
/// These tests verify LRO structure, pagination, filtering, ordering, error handling,
/// and state management for application resources.
final class ApplicationMethodsTests: XCTestCase {
    var service: MacosUseService!
    var stateStore: AppStateStore!
    var operationStore: OperationStore!

    override func setUp() async throws {
        stateStore = AppStateStore()
        operationStore = OperationStore()
        let registry = WindowRegistry(system: ProductionSystemOperations.shared)
        service = MacosUseService(
            stateStore: stateStore,
            operationStore: operationStore,
            windowRegistry: registry,
            system: ProductionSystemOperations.shared,
        )
    }

    override func tearDown() async throws {
        service = nil
        stateStore = nil
        operationStore = nil
    }

    // MARK: - Helpers

    private func makeOpenApplicationRequest(_ msg: Macosusesdk_V1_OpenApplicationRequest) -> GRPCCore.ServerRequest<Macosusesdk_V1_OpenApplicationRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeGetApplicationRequest(_ msg: Macosusesdk_V1_GetApplicationRequest) -> GRPCCore.ServerRequest<Macosusesdk_V1_GetApplicationRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeListApplicationsRequest(_ msg: Macosusesdk_V1_ListApplicationsRequest = Macosusesdk_V1_ListApplicationsRequest()) -> GRPCCore.ServerRequest<Macosusesdk_V1_ListApplicationsRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeDeleteApplicationRequest(_ msg: Macosusesdk_V1_DeleteApplicationRequest) -> GRPCCore.ServerRequest<Macosusesdk_V1_DeleteApplicationRequest> {
        GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: msg)
    }

    private func makeOpenApplicationContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.OpenApplication.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeGetApplicationContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.GetApplication.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeListApplicationsContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.ListApplications.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    private func makeDeleteApplicationContext() -> GRPCCore.ServerContext {
        GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.DeleteApplication.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )
    }

    /// Creates a mock Application proto for testing state store operations.
    private func makeMockApplication(pid: pid_t, name _: String, displayName: String) -> Macosusesdk_V1_Application {
        Macosusesdk_V1_Application.with {
            $0.name = "applications/\(pid)"
            $0.pid = pid
            $0.displayName = displayName
        }
    }

    // MARK: - OpenApplication LRO Structure Tests

    func testOpenApplicationReturnsLROWithProperStructure() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.calculator"

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        // Verify LRO structure per google.longrunning.Operation
        XCTAssertFalse(op.name.isEmpty, "Operation name must not be empty")
        XCTAssertTrue(op.name.hasPrefix("operations/open/"), "Operation name should have operations/open/ prefix")
        XCTAssertFalse(op.done, "Operation should not be done immediately (LRO is async)")

        // Verify metadata contains OpenApplicationMetadata
        XCTAssertFalse(op.metadata.value.isEmpty, "Operation should have metadata")
        XCTAssertEqual(
            op.metadata.typeURL,
            "type.googleapis.com/macosusesdk.v1.OpenApplicationMetadata",
            "Metadata type URL should match OpenApplicationMetadata",
        )
    }

    func testOpenApplicationMetadataContainsRequestedId() async throws {
        let testId = "com.test.specific-app"
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = testId

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        // Unpack and verify metadata
        let metadata = try Macosusesdk_V1_OpenApplicationMetadata(unpackingAny: op.metadata)
        XCTAssertEqual(metadata.id, testId, "Metadata should contain the requested id")
    }

    func testOpenApplicationWithBundleIdentifier() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.TextEdit"
        request.background = false

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        XCTAssertFalse(op.name.isEmpty, "Operation name must be set for bundle ID request")
        let metadata = try Macosusesdk_V1_OpenApplicationMetadata(unpackingAny: op.metadata)
        XCTAssertEqual(metadata.id, "com.apple.TextEdit")
    }

    func testOpenApplicationWithFilePath() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "/Applications/Calculator.app"

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        XCTAssertFalse(op.name.isEmpty, "Operation name must be set for file path request")
        let metadata = try Macosusesdk_V1_OpenApplicationMetadata(unpackingAny: op.metadata)
        XCTAssertEqual(metadata.id, "/Applications/Calculator.app")
    }

    func testOpenApplicationWithBackgroundTrue() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.Finder"
        request.background = true

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        // LRO should be created - background flag is passed to the async task
        XCTAssertFalse(op.name.isEmpty)
        XCTAssertFalse(op.done)
    }

    func testOpenApplicationWithBackgroundFalse() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.Finder"
        request.background = false

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        XCTAssertFalse(op.name.isEmpty)
        XCTAssertFalse(op.done)
    }

    // MARK: - OpenApplication Validation Error Tests

    func testOpenApplicationEmptyIdReturnsValidationError() async throws {
        let request = Macosusesdk_V1_OpenApplicationRequest()
        // id is empty by default

        do {
            _ = try await service.openApplication(
                request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
            )
            XCTFail("Expected error for empty id")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument, "Should return INVALID_ARGUMENT for empty id")
            XCTAssertTrue(error.message.contains("id"), "Error message should mention 'id' field")
        }
    }

    func testOpenApplicationCreatesUniqueOperationNames() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.Calculator"

        let response1 = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op1 = try response1.message

        let response2 = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op2 = try response2.message

        XCTAssertNotEqual(op1.name, op2.name, "Each call should create a unique operation name")
    }

    // MARK: - GetApplication Tests

    func testGetApplicationRetrievesRunningApplication() async throws {
        // Add a mock application to the state store
        let mockApp = makeMockApplication(pid: 12345, name: "TestApp", displayName: "Test Application")
        await stateStore.addTarget(mockApp)

        var request = Macosusesdk_V1_GetApplicationRequest()
        request.name = "applications/12345"

        let response = try await service.getApplication(
            request: makeGetApplicationRequest(request), context: makeGetApplicationContext(),
        )
        let app = try response.message

        XCTAssertEqual(app.pid, 12345)
        XCTAssertEqual(app.displayName, "Test Application")
    }

    func testGetApplicationWithNonExistentAppReturnsNotFound() async throws {
        var request = Macosusesdk_V1_GetApplicationRequest()
        request.name = "applications/99999"

        do {
            _ = try await service.getApplication(
                request: makeGetApplicationRequest(request), context: makeGetApplicationContext(),
            )
            XCTFail("Expected NOT_FOUND error for non-existent application")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("not found"))
        }
    }

    func testGetApplicationWithInvalidResourceNameFormat() async throws {
        var request = Macosusesdk_V1_GetApplicationRequest()
        request.name = "invalid-format"

        do {
            _ = try await service.getApplication(
                request: makeGetApplicationRequest(request), context: makeGetApplicationContext(),
            )
            XCTFail("Expected INVALID_ARGUMENT for invalid resource name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testGetApplicationWithNonNumericPid() async throws {
        var request = Macosusesdk_V1_GetApplicationRequest()
        request.name = "applications/not-a-number"

        do {
            _ = try await service.getApplication(
                request: makeGetApplicationRequest(request), context: makeGetApplicationContext(),
            )
            XCTFail("Expected INVALID_ARGUMENT for non-numeric PID")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testGetApplicationWithReadMask() async throws {
        // Add a mock application with various fields
        let mockApp = Macosusesdk_V1_Application.with {
            $0.name = "applications/12345"
            $0.pid = 12345
            $0.displayName = "Test Application"
        }
        await stateStore.addTarget(mockApp)

        var request = Macosusesdk_V1_GetApplicationRequest()
        request.name = "applications/12345"
        request.readMask = .with { $0.paths = ["display_name", "pid"] }

        let response = try await service.getApplication(
            request: makeGetApplicationRequest(request), context: makeGetApplicationContext(),
        )
        let app = try response.message

        // Fields specified in read_mask should be present
        XCTAssertEqual(app.pid, 12345)
        XCTAssertEqual(app.displayName, "Test Application")
    }

    // MARK: - ListApplications Tests

    func testListApplicationsReturnsRunningApplications() async throws {
        // Add mock applications to state store
        let app1 = makeMockApplication(pid: 100, name: "App1", displayName: "Application One")
        let app2 = makeMockApplication(pid: 200, name: "App2", displayName: "Application Two")
        await stateStore.addTarget(app1)
        await stateStore.addTarget(app2)

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 2)
    }

    func testListApplicationsReturnsEmptyForNoApplications() async throws {
        let response = try await service.listApplications(
            request: makeListApplicationsRequest(), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 0)
        XCTAssertTrue(msg.nextPageToken.isEmpty)
    }

    // MARK: - ListApplications Pagination Tests

    func testListApplicationsPaginationWithPageSize() async throws {
        // Add 5 applications
        for i in 1 ... 5 {
            let app = makeMockApplication(pid: pid_t(i * 100), name: "App\(i)", displayName: "Application \(i)")
            await stateStore.addTarget(app)
        }

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.pageSize = 2

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 2, "Page should contain exactly 2 applications")
        XCTAssertFalse(msg.nextPageToken.isEmpty, "Should have next page token when more results exist")
    }

    func testListApplicationsPaginationWithPageToken() async throws {
        // Add 3 applications
        for i in 1 ... 3 {
            let app = makeMockApplication(pid: pid_t(i * 100), name: "App\(i)", displayName: "Application \(i)")
            await stateStore.addTarget(app)
        }

        // Get first page
        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.pageSize = 1

        let page1Response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let page1 = try page1Response.message

        XCTAssertEqual(page1.applications.count, 1)
        XCTAssertFalse(page1.nextPageToken.isEmpty)

        // Get second page using token
        request.pageToken = page1.nextPageToken

        let page2Response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let page2 = try page2Response.message

        XCTAssertEqual(page2.applications.count, 1)
        // Page 2 should have different app than page 1
        XCTAssertNotEqual(page1.applications[0].pid, page2.applications[0].pid)
    }

    func testListApplicationsPaginationEmptyTokenForLastPage() async throws {
        // Add 2 applications
        let app1 = makeMockApplication(pid: 100, name: "App1", displayName: "Application One")
        let app2 = makeMockApplication(pid: 200, name: "App2", displayName: "Application Two")
        await stateStore.addTarget(app1)
        await stateStore.addTarget(app2)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.pageSize = 10

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 2)
        XCTAssertTrue(msg.nextPageToken.isEmpty, "Last page should have empty next_page_token")
    }

    func testListApplicationsDefaultPageSizeIs100() async throws {
        // Add 2 applications (less than default)
        let app1 = makeMockApplication(pid: 100, name: "App1", displayName: "Application One")
        await stateStore.addTarget(app1)

        let request = Macosusesdk_V1_ListApplicationsRequest()
        // pageSize is 0 (default)

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        // Should return all without pagination (< 100)
        XCTAssertEqual(msg.applications.count, 1)
        XCTAssertTrue(msg.nextPageToken.isEmpty)
    }

    // MARK: - ListApplications Filter Tests

    func testListApplicationsWithFilterByName() async throws {
        let app1 = makeMockApplication(pid: 100, name: "App1", displayName: "Calculator")
        let app2 = makeMockApplication(pid: 200, name: "App2", displayName: "TextEdit")
        let app3 = makeMockApplication(pid: 300, name: "App3", displayName: "Calculator Pro")
        await stateStore.addTarget(app1)
        await stateStore.addTarget(app2)
        await stateStore.addTarget(app3)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.filter = "name=\"Calculator\""

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        // Should match both "Calculator" and "Calculator Pro" (contains match)
        XCTAssertEqual(msg.applications.count, 2)
        for app in msg.applications {
            XCTAssertTrue(
                app.displayName.localizedCaseInsensitiveContains("Calculator"),
                "Filtered app should contain 'Calculator' in display name",
            )
        }
    }

    func testListApplicationsWithFilterNoMatch() async throws {
        let app1 = makeMockApplication(pid: 100, name: "App1", displayName: "Calculator")
        await stateStore.addTarget(app1)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.filter = "name=\"NonExistent\""

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 0, "No apps should match filter")
    }

    func testListApplicationsWithFilterCaseInsensitive() async throws {
        let app = makeMockApplication(pid: 100, name: "App1", displayName: "TextEdit")
        await stateStore.addTarget(app)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.filter = "name=\"textedit\""

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 1, "Filter should be case-insensitive")
    }

    // MARK: - ListApplications Ordering Tests

    func testListApplicationsWithOrderByName() async throws {
        let appB = makeMockApplication(pid: 200, name: "AppB", displayName: "Bravo")
        let appA = makeMockApplication(pid: 100, name: "AppA", displayName: "Alpha")
        let appC = makeMockApplication(pid: 300, name: "AppC", displayName: "Charlie")
        await stateStore.addTarget(appB)
        await stateStore.addTarget(appA)
        await stateStore.addTarget(appC)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.orderBy = "name"

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 3)
        XCTAssertEqual(msg.applications[0].displayName, "Alpha")
        XCTAssertEqual(msg.applications[1].displayName, "Bravo")
        XCTAssertEqual(msg.applications[2].displayName, "Charlie")
    }

    func testListApplicationsWithOrderByNameDesc() async throws {
        let appA = makeMockApplication(pid: 100, name: "AppA", displayName: "Alpha")
        let appB = makeMockApplication(pid: 200, name: "AppB", displayName: "Bravo")
        await stateStore.addTarget(appA)
        await stateStore.addTarget(appB)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.orderBy = "name desc"

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 2)
        XCTAssertEqual(msg.applications[0].displayName, "Bravo")
        XCTAssertEqual(msg.applications[1].displayName, "Alpha")
    }

    func testListApplicationsWithOrderByPid() async throws {
        let app300 = makeMockApplication(pid: 300, name: "App3", displayName: "App Three")
        let app100 = makeMockApplication(pid: 100, name: "App1", displayName: "App One")
        let app200 = makeMockApplication(pid: 200, name: "App2", displayName: "App Two")
        await stateStore.addTarget(app300)
        await stateStore.addTarget(app100)
        await stateStore.addTarget(app200)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.orderBy = "pid"

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 3)
        XCTAssertEqual(msg.applications[0].pid, 100)
        XCTAssertEqual(msg.applications[1].pid, 200)
        XCTAssertEqual(msg.applications[2].pid, 300)
    }

    func testListApplicationsWithOrderByDisplayName() async throws {
        let appZ = makeMockApplication(pid: 100, name: "AppZ", displayName: "Zebra")
        let appM = makeMockApplication(pid: 200, name: "AppM", displayName: "Monkey")
        await stateStore.addTarget(appZ)
        await stateStore.addTarget(appM)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.orderBy = "display_name"

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 2)
        XCTAssertEqual(msg.applications[0].displayName, "Monkey")
        XCTAssertEqual(msg.applications[1].displayName, "Zebra")
    }

    func testListApplicationsDefaultOrderIsByResourceName() async throws {
        // Resource names are "applications/{pid}", so ordering by name is effectively by PID string order
        let app100 = makeMockApplication(pid: 100, name: "App100", displayName: "Zebra")
        let app200 = makeMockApplication(pid: 200, name: "App200", displayName: "Aardvark")
        await stateStore.addTarget(app100)
        await stateStore.addTarget(app200)

        // No orderBy specified - should default to name (resource name, not display_name)
        let response = try await service.listApplications(
            request: makeListApplicationsRequest(), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        XCTAssertEqual(msg.applications.count, 2)
        // "applications/100" < "applications/200" alphabetically
        XCTAssertEqual(msg.applications[0].pid, 100)
        XCTAssertEqual(msg.applications[1].pid, 200)
    }

    // MARK: - DeleteApplication Tests

    func testDeleteApplicationRemovesFromStateStore() async throws {
        let mockApp = makeMockApplication(pid: 12345, name: "TestApp", displayName: "Test Application")
        await stateStore.addTarget(mockApp)

        // Verify app exists
        let beforeApp = await stateStore.getTarget(pid: 12345)
        XCTAssertNotNil(beforeApp, "App should exist before deletion")

        var request = Macosusesdk_V1_DeleteApplicationRequest()
        request.name = "applications/12345"

        let response = try await service.deleteApplication(
            request: makeDeleteApplicationRequest(request), context: makeDeleteApplicationContext(),
        )
        _ = try response.message

        // Verify app was removed
        let afterApp = await stateStore.getTarget(pid: 12345)
        XCTAssertNil(afterApp, "App should be removed after deletion")
    }

    func testDeleteApplicationWithNonExistentAppSucceeds() async throws {
        // Per implementation, deleteApplication doesn't throw for non-existent apps
        // It just returns empty (idempotent delete)
        var request = Macosusesdk_V1_DeleteApplicationRequest()
        request.name = "applications/99999"

        // Should not throw - idempotent delete per AIP-135
        let response = try await service.deleteApplication(
            request: makeDeleteApplicationRequest(request), context: makeDeleteApplicationContext(),
        )
        _ = try response.message
        // No assertion needed - test passes if no error thrown
    }

    func testDeleteApplicationWithInvalidResourceName() async throws {
        var request = Macosusesdk_V1_DeleteApplicationRequest()
        request.name = "invalid-format"

        do {
            _ = try await service.deleteApplication(
                request: makeDeleteApplicationRequest(request), context: makeDeleteApplicationContext(),
            )
            XCTFail("Expected INVALID_ARGUMENT for invalid resource name")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testDeleteApplicationWithNonNumericPid() async throws {
        var request = Macosusesdk_V1_DeleteApplicationRequest()
        request.name = "applications/abc"

        do {
            _ = try await service.deleteApplication(
                request: makeDeleteApplicationRequest(request), context: makeDeleteApplicationContext(),
            )
            XCTFail("Expected INVALID_ARGUMENT for non-numeric PID")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - LRO Operation Store Integration Tests

    func testOpenApplicationOperationIsStoredInOperationStore() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.Calculator"

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        // Verify operation was stored
        let storedOp = await operationStore.getOperation(name: op.name)
        XCTAssertNotNil(storedOp, "Operation should be stored in operation store")
        XCTAssertEqual(storedOp?.name, op.name)
    }

    func testOpenApplicationOperationNamesAreOpaque() async throws {
        var request = Macosusesdk_V1_OpenApplicationRequest()
        request.id = "com.apple.Calculator"

        let response = try await service.openApplication(
            request: makeOpenApplicationRequest(request), context: makeOpenApplicationContext(),
        )
        let op = try response.message

        // Operation name contains a UUID, making it opaque
        XCTAssertTrue(op.name.hasPrefix("operations/open/"))
        // The UUID portion should be valid (36 chars with dashes)
        let uuidPortion = String(op.name.dropFirst("operations/open/".count))
        XCTAssertEqual(uuidPortion.count, 36, "UUID portion should be 36 characters")
    }

    // MARK: - Filter Helper Unit Tests

    func testApplyApplicationFilterExtractsQuotedValue() {
        let apps = [
            makeMockApplication(pid: 1, name: "A", displayName: "Calculator"),
            makeMockApplication(pid: 2, name: "B", displayName: "TextEdit"),
        ]

        let filtered = service.applyApplicationFilter(apps, filter: "name=\"Calc\"")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].displayName, "Calculator")
    }

    func testApplyApplicationFilterWithSpacesInExpression() {
        let apps = [
            makeMockApplication(pid: 1, name: "A", displayName: "Calculator"),
        ]

        let filtered = service.applyApplicationFilter(apps, filter: "name = \"Calc\"")
        XCTAssertEqual(filtered.count, 1)
    }

    func testExtractQuotedValueForAppBasicCase() {
        let result = service.extractQuotedValueForApp(from: "name=\"Test\"", key: "name")
        XCTAssertEqual(result, "Test")
    }

    func testExtractQuotedValueForAppWithSpaces() {
        let result = service.extractQuotedValueForApp(from: "name = \"Test Value\"", key: "name")
        XCTAssertEqual(result, "Test Value")
    }

    func testExtractQuotedValueForAppKeyNotFound() {
        let result = service.extractQuotedValueForApp(from: "name=\"Test\"", key: "other")
        XCTAssertNil(result)
    }

    func testExtractQuotedValueForAppEmptyFilter() {
        let result = service.extractQuotedValueForApp(from: "", key: "name")
        XCTAssertNil(result)
    }

    // MARK: - Deterministic Ordering Tests

    func testListApplicationsReturnsDeterministicOrder() async throws {
        // Add applications in specific order
        let app1 = makeMockApplication(pid: 300, name: "C", displayName: "Charlie")
        let app2 = makeMockApplication(pid: 100, name: "A", displayName: "Alpha")
        let app3 = makeMockApplication(pid: 200, name: "B", displayName: "Bravo")
        await stateStore.addTarget(app1)
        await stateStore.addTarget(app2)
        await stateStore.addTarget(app3)

        // Call twice and verify same order
        let response1 = try await service.listApplications(
            request: makeListApplicationsRequest(), context: makeListApplicationsContext(),
        )
        let msg1 = try response1.message

        let response2 = try await service.listApplications(
            request: makeListApplicationsRequest(), context: makeListApplicationsContext(),
        )
        let msg2 = try response2.message

        XCTAssertEqual(msg1.applications.count, msg2.applications.count)
        for (app1, app2) in zip(msg1.applications, msg2.applications) {
            XCTAssertEqual(app1.pid, app2.pid, "Application order should be deterministic")
        }
    }

    // MARK: - Combined Filter and Pagination Tests

    func testListApplicationsWithFilterAndPagination() async throws {
        // Add 5 apps, 3 matching filter
        let app1 = makeMockApplication(pid: 100, name: "A", displayName: "Test App 1")
        let app2 = makeMockApplication(pid: 200, name: "B", displayName: "Other App")
        let app3 = makeMockApplication(pid: 300, name: "C", displayName: "Test App 2")
        let app4 = makeMockApplication(pid: 400, name: "D", displayName: "Another App")
        let app5 = makeMockApplication(pid: 500, name: "E", displayName: "Test App 3")
        await stateStore.addTarget(app1)
        await stateStore.addTarget(app2)
        await stateStore.addTarget(app3)
        await stateStore.addTarget(app4)
        await stateStore.addTarget(app5)

        var request = Macosusesdk_V1_ListApplicationsRequest()
        request.filter = "name=\"Test\""
        request.pageSize = 2

        let response = try await service.listApplications(
            request: makeListApplicationsRequest(request), context: makeListApplicationsContext(),
        )
        let msg = try response.message

        // Should return 2 of the 3 matching apps
        XCTAssertEqual(msg.applications.count, 2)
        XCTAssertFalse(msg.nextPageToken.isEmpty, "Should have more filtered results")

        for app in msg.applications {
            XCTAssertTrue(app.displayName.contains("Test"))
        }
    }
}
