import Foundation
import GRPC
import SwiftProtobuf
import MacosUseSDKProtos

/// This is the single, correct gRPC provider for the `MacosUseService` service.
///
/// It implements the generated `Macosusesdk_V1_MacosUseServiceAsyncProvider` protocol
/// and acts as the bridge between gRPC requests and the `AutomationCoordinator`.
final class MacosUseServiceProvider: Macosusesdk_V1_MacosUseServiceAsyncProvider {
    let stateStore: AppStateStore

    init(stateStore: AppStateStore) {
        self.stateStore = stateStore
    }

    // MARK: - Application Methods

    func openApplication(request: Macosusesdk_V1_OpenApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> Google_Longrunning_Operation {
        fputs("info: [MacosUseServiceProvider] openApplication called\n", stderr)
        let app = try await AutomationCoordinator.shared.handleOpenApplication(identifier: request.identifier)
        await stateStore.addTarget(app)
        let response = Macosusesdk_V1_OpenApplicationResponse.with {
            $0.application = app
        }
        return try Google_Longrunning_Operation.with {
            $0.name = "operations/open/\(app.pid)"
            $0.done = true
            $0.result = .response(try SwiftProtobuf.Google_Protobuf_Any.with {
                $0.typeURL = "type.googleapis.com/macosusesdk.v1.OpenApplicationResponse"
                $0.value = try response.serializedData()
            })
        }
    }

    func getApplication(request: Macosusesdk_V1_GetApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_Application {
        fputs("info: [MacosUseServiceProvider] getApplication called\n", stderr)
        let pid = try parsePID(fromName: request.name)
        guard let app = await stateStore.getTarget(pid: pid) else {
            throw GRPCStatus(code: .notFound, message: "Application not found")
        }
        return app
    }

    func listApplications(request: Macosusesdk_V1_ListApplicationsRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_ListApplicationsResponse {
        fputs("info: [MacosUseServiceProvider] listApplications called\n", stderr)
        let apps = await stateStore.listTargets()
        return Macosusesdk_V1_ListApplicationsResponse.with {
            $0.applications = apps
        }
    }

    func deleteApplication(request: Macosusesdk_V1_DeleteApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
        fputs("info: [MacosUseServiceProvider] deleteApplication called\n", stderr)
        let pid = try parsePID(fromName: request.name)
        _ = await stateStore.removeTarget(pid: pid)
        return SwiftProtobuf.Google_Protobuf_Empty()
    }

    // MARK: - Input Methods

    func createInput(request: Macosusesdk_V1_CreateInputRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_Input {
        fputs("info: [MacosUseServiceProvider] createInput called\n", stderr)
        
        let inputId = request.inputID.isEmpty ? UUID().uuidString : request.inputID
        let pid: pid_t? = request.parent.isEmpty ? nil : try parsePID(fromName: request.parent)
        let name = request.parent.isEmpty ? "desktopInputs/\(inputId)" : "\(request.parent)/inputs/\(inputId)"
        
        let input = Macosusesdk_V1_Input.with {
            $0.name = name
            $0.action = request.input.action
            $0.state = .pending
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        }
        
        await stateStore.addInput(input)
        
        // Update to executing
        var executingInput = input
        executingInput.state = .executing
        await stateStore.addInput(executingInput)
        
        do {
            try await AutomationCoordinator.shared.handleExecuteInput(
                action: request.input.action,
                pid: pid,
                showAnimation: request.input.action.showAnimation,
                animationDuration: request.input.action.animationDuration
            )
            // Update to completed
            var completedInput = executingInput
            completedInput.state = .completed
            completedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(completedInput)
            return completedInput
        } catch {
            // Update to failed
            var failedInput = executingInput
            failedInput.state = .failed
            failedInput.error = error.localizedDescription
            failedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(failedInput)
            return failedInput
        }
    }

    func getInput(request: Macosusesdk_V1_GetInputRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_Input {
        fputs("info: [MacosUseServiceProvider] getInput called\n", stderr)
        guard let input = await stateStore.getInput(name: request.name) else {
            throw GRPCStatus(code: .notFound, message: "Input not found")
        }
        return input
    }

    func listInputs(request: Macosusesdk_V1_ListInputsRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_ListInputsResponse {
        fputs("info: [MacosUseServiceProvider] listInputs called\n", stderr)
        let inputs = await stateStore.listInputs(parent: request.parent)
        return Macosusesdk_V1_ListInputsResponse.with {
            $0.inputs = inputs
        }
    }

    // MARK: - Custom Methods

    func traverseAccessibility(request: Macosusesdk_V1_TraverseAccessibilityRequest, context: GRPCAsyncServerCallContext) async throws -> Macosusesdk_V1_TraverseAccessibilityResponse {
        fputs("info: [MacosUseServiceProvider] traverseAccessibility called\n", stderr)
        let pid = try parsePID(fromName: request.name)
        return try await AutomationCoordinator.shared.handleTraverse(pid: pid, visibleOnly: request.visibleOnly)
    }

    func watchAccessibility(request: Macosusesdk_V1_WatchAccessibilityRequest, responseStream: GRPCAsyncResponseStreamWriter<Macosusesdk_V1_WatchAccessibilityResponse>, context: GRPCAsyncServerCallContext) async throws {
        fputs("info: [MacosUseServiceProvider] watchAccessibility called\n", stderr)
        // TODO: Implement
        throw GRPCStatus(code: .unimplemented, message: "watchAccessibility not implemented")
    }
}

// MARK: - Helpers

private extension MacosUseServiceProvider {
    func parsePID(fromName name: String) throws -> pid_t {
        let components = name.split(separator: "/")
        guard components.count == 2, components[0] == "applications", let pid = pid_t(components[1]) else {
            throw GRPCStatus(code: .invalidArgument, message: "Invalid application name: \(name)")
        }
        return pid
    }
}