@testable import ExactMacProto
@testable import ExactMacServer
import GRPCCore
import XCTest

final class FileDialogMethodsTests: XCTestCase {
    private static let application = "applications/424242"

    private var service: ExactMacService!

    override func setUp() async throws {
        service = ExactMacService(
            stateStore: AppStateStore(),
            operationStore: OperationStore(),
            windowRegistry: WindowRegistry(system: ProductionSystemOperations.shared),
            system: ProductionSystemOperations.shared,
        )
    }

    override func tearDown() async throws {
        service = nil
    }

    private func request<Message>(_ message: Message) -> ServerRequest<Message> {
        ServerRequest(metadata: Metadata(), message: message)
    }

    private func context(_ descriptor: MethodDescriptor) -> ServerContext {
        ServerContext(
            descriptor: descriptor,
            remotePeer: "in-process:tests",
            localPeer: "in-process:server",
            cancellation: ServerContext.RPCCancellationHandle(),
        )
    }

    private func rpcError(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void,
    ) async -> RPCError? {
        do {
            try await operation()
            XCTFail("Expected RPCError", file: file, line: line)
            return nil
        } catch let error as RPCError {
            return error
        } catch {
            XCTFail("Expected RPCError, got \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertUnimplemented(
        _ error: RPCError?,
        operation: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(error?.code, .unimplemented, file: file, line: line)
        XCTAssertEqual(
            error?.message,
            "Target-owned \(operation) is not implemented",
            file: file,
            line: line,
        )
    }

    func testFileDialogRequestsCarryRequiredApplicationContext() {
        var open = Exactmac_V1_AutomateOpenFileDialogRequest()
        open.application = Self.application
        open.filePath = "/tmp/input.txt"
        open.defaultDirectory = "/tmp"
        open.fileFilters = ["*.txt"]
        open.timeout = 1
        open.allowMultiple = true

        var save = Exactmac_V1_AutomateSaveFileDialogRequest()
        save.application = Self.application
        save.filePath = "/tmp/output.txt"
        save.defaultDirectory = "/tmp"
        save.defaultFilename = "output.txt"
        save.timeout = 1
        save.confirmOverwrite = true

        XCTAssertEqual(open.application, Self.application)
        XCTAssertEqual(save.application, Self.application)
    }

    func testEveryTargetOwnedFileDialogMethodFailsClosedAsUnimplemented() async {
        var open = Exactmac_V1_AutomateOpenFileDialogRequest()
        open.application = Self.application
        let openError = await rpcError {
            _ = try await self.service.automateOpenFileDialog(
                request: self.request(open),
                context: self.context(
                    Exactmac_V1_ExactMac.Method.AutomateOpenFileDialog.descriptor,
                ),
            )
        }
        assertUnimplemented(openError, operation: "open file dialog automation")

        var save = Exactmac_V1_AutomateSaveFileDialogRequest()
        save.application = Self.application
        save.filePath = "/tmp/output.txt"
        let saveError = await rpcError {
            _ = try await self.service.automateSaveFileDialog(
                request: self.request(save),
                context: self.context(
                    Exactmac_V1_ExactMac.Method.AutomateSaveFileDialog.descriptor,
                ),
            )
        }
        assertUnimplemented(saveError, operation: "save file dialog automation")
    }

    func testEveryFileDialogMethodRequiresApplicationBeforeCapabilityError() async {
        let openError = await rpcError {
            _ = try await self.service.automateOpenFileDialog(
                request: self.request(Exactmac_V1_AutomateOpenFileDialogRequest()),
                context: self.context(
                    Exactmac_V1_ExactMac.Method.AutomateOpenFileDialog.descriptor,
                ),
            )
        }
        XCTAssertEqual(openError?.code, .invalidArgument)
        XCTAssertTrue(openError?.message.contains("application") == true)

        var save = Exactmac_V1_AutomateSaveFileDialogRequest()
        save.filePath = "/tmp/output.txt"
        let saveError = await rpcError {
            _ = try await self.service.automateSaveFileDialog(
                request: self.request(save),
                context: self.context(
                    Exactmac_V1_ExactMac.Method.AutomateSaveFileDialog.descriptor,
                ),
            )
        }
        XCTAssertEqual(saveError?.code, .invalidArgument)
        XCTAssertTrue(saveError?.message.contains("application") == true)
    }

    func testExistingRequiredFieldsAreValidatedBeforeCapabilityError() async {
        var save = Exactmac_V1_AutomateSaveFileDialogRequest()
        save.application = Self.application
        let saveError = await rpcError {
            _ = try await self.service.automateSaveFileDialog(
                request: self.request(save),
                context: self.context(
                    Exactmac_V1_ExactMac.Method.AutomateSaveFileDialog.descriptor,
                ),
            )
        }
        XCTAssertEqual(saveError?.code, .invalidArgument)
        XCTAssertTrue(saveError?.message.contains("file_path") == true)
    }
}
