import Foundation
import GRPC
import SwiftProtobuf
import MacosUseSDKProtos

/// This is the single, correct gRPC provider for the `MacosUseService` service.
///
/// It implements the generated `Macosusesdk_V1_MacosUseServiceAsyncProvider` protocol
/// and acts as the bridge between gRPC requests and the `AutomationCoordinator`.
final class MacosUseServiceProvider: Macosusesdk_V1_MacosUseAsyncProvider {
    let stateStore: AppStateStore
    let operationStore: OperationStore

    init(stateStore: AppStateStore, operationStore: OperationStore) {
        self.stateStore = stateStore
        self.operationStore = operationStore
    }

    // MARK: - Application Methods

    func openApplication(request: Macosusesdk_V1_OpenApplicationRequest, context: GRPCAsyncServerCallContext) async throws -> Google_Longrunning_Operation {
        fputs("info: [MacosUseServiceProvider] openApplication called\n", stderr)

        fputs("info: [MacosUseServiceProvider] openApplication called (LRO)\n", stderr)

        // Create an operation and return immediately
        let opName = "operations/open/\(UUID().uuidString)"

        // optional metadata could include the requested id
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.OpenApplicationMetadata"
            $0.value = try Macosusesdk_V1_OpenApplicationMetadata.with { $0.id = request.id }.serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Schedule actual open on background task (coordinator runs on @MainActor internally)
        Task {
            do {
                let app = try await AutomationCoordinator.shared.handleOpenApplication(identifier: request.id)
                await stateStore.addTarget(app)

                let response = Macosusesdk_V1_OpenApplicationResponse.with {
                    $0.application = app
                }

                try await operationStore.finishOperation(name: opName, responseMessage: response)
            } catch {
                // mark operation as done with an error in the response's metadata
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = SwiftProtobuf.Google_Rpc_Status.with {
                    $0.code = 13
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return op
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

        let pid = try parsePID(fromName: request.name)
        let pollInterval = request.pollInterval > 0 ? request.pollInterval : 1.0

        var previous: [Macosusesdk_Type_Element] = []

        while !Task.isCancelled {
            do {
                let trav = try await AutomationCoordinator.shared.handleTraverse(pid: pid, visibleOnly: request.visibleOnly)

                // Naive diff: if previous empty, send all as added; otherwise send elements as modified
                let resp = Macosusesdk_V1_WatchAccessibilityResponse.with {
                    if previous.isEmpty {
                        $0.added = trav.elements
                    } else {
                        $0.modified = trav.elements.map { element in
                            Macosusesdk_V1_ModifiedElement.with {
                                $0.previous = Macosusesdk_Type_Element()
                                $0.current = element
                            }
                        }
                    }
                }

                try await responseStream.send(resp)
                previous = trav.elements
            } catch {
                // send an empty heartbeat to keep client alive
                let _ = try? await responseStream.send(Macosusesdk_V1_WatchAccessibilityResponse())
            }

            // Sleep for interval, but allow task cancellation to stop
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}

// MARK: - Helpers

private extension MacosUseServiceProvider {
    func parsePID(fromName name: String) throws -> pid_t {
        let components = name.split(separator: "/").map(String.init)
        guard components.count >= 2, components[0] == "applications", let pidInt = Int32(components[1]) else {
            throw GRPCStatus(code: .invalidArgument, message: "Invalid application name: \(name)")
        }
        return pid_t(pidInt)
    }
}