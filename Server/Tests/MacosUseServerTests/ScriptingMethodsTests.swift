import Foundation
import GRPCCore
@testable import MacosUseProto
@testable import MacosUseServer
import XCTest

final class ScriptingMethodsTests: XCTestCase {
    func testGetScriptingDictionariesUsesSystemBundleID() async throws {
        let store = AppStateStore()
        let pid: pid_t = 4242
        let app = Macosusesdk_V1_Application.with {
            $0.name = "applications/\(pid)"
            $0.pid = pid
            $0.displayName = "MyApp"
        }

        await store.addTarget(app)

        let mock = MockSystemOperations(bundleIDs: [pid: "com.test.bundle"])
        let registry = WindowRegistry(system: mock)
        let provider = MacosUseService(stateStore: store, operationStore: OperationStore(), windowRegistry: registry, system: mock)

        let req = Macosusesdk_V1_GetScriptingDictionariesRequest.with { $0.name = "scriptingDictionaries" }

        let serverReq = GRPCCore.ServerRequest(metadata: GRPCCore.Metadata(), message: req)
        let context = GRPCCore.ServerContext(
            descriptor: Macosusesdk_V1_MacosUse.Method.GetScriptingDictionaries.descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: GRPCCore.ServerContext.RPCCancellationHandle(),
        )

        let response = try await provider.getScriptingDictionaries(request: serverReq, context: context)

        let msg = try response.message

        let found = msg.dictionaries.first { $0.bundleID == "com.test.bundle" }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.application, "applications/\(pid)")
    }
}
