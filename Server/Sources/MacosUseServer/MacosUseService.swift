import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

final class MacosUseService: Macosusesdk_V1_MacosUse.ServiceProtocol {
    static let logger = MacosUseSDK.sdkLogger(category: "MacosUseService")
    let stateStore: AppStateStore
    let operationStore: OperationStore
    let windowRegistry: WindowRegistry
    let system: SystemOperations

    init(stateStore: AppStateStore, operationStore: OperationStore, windowRegistry: WindowRegistry, system: SystemOperations = ProductionSystemOperations.shared) {
        self.stateStore = stateStore
        self.operationStore = operationStore
        self.windowRegistry = windowRegistry
        self.system = system
    }

    /// Resolve bundle ID from PID using NSRunningApplication.
    func resolveBundleID(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Encode an offset into an opaque page token per AIP-158.
    /// The token is base64-encoded to prevent clients from relying on its structure.
    func encodePageToken(offset: Int) -> String {
        let tokenString = "offset:\(offset)"
        return Data(tokenString.utf8).base64EncodedString()
    }

    /// Decode an opaque page token to retrieve the offset per AIP-158.
    /// Throws invalidArgument if the token is malformed.
    func decodePageToken(_ token: String) throws -> Int {
        guard let data = Data(base64Encoded: token),
              let tokenString = String(data: data, encoding: .utf8)
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }

        let components = tokenString.split(separator: ":")
        guard components.count == 2, components[0] == "offset",
              let parsedOffset = Int(components[1]), parsedOffset >= 0
        else {
            throw RPCError(code: .invalidArgument, message: "Invalid page_token format")
        }
        return parsedOffset
    }

    func createInput(request: ServerRequest<Macosusesdk_V1_CreateInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_Input>
    {
        let req = request.message
        Self.logger.info("createInput called")

        let inputId = req.inputID.isEmpty ? UUID().uuidString : req.inputID
        let pid: pid_t? = req.parent.isEmpty ? nil : try parsePID(fromName: req.parent)
        let name =
            req.parent.isEmpty ? "desktopInputs/\(inputId)" : "\(req.parent)/inputs/\(inputId)"

        let input = Macosusesdk_V1_Input.with {
            $0.name = name
            $0.action = req.input.action
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
                action: req.input.action,
                pid: pid,
                showAnimation: req.input.action.showAnimation,
                animationDuration: req.input.action.animationDuration,
            )
            // Update to completed
            var completedInput = executingInput
            completedInput.state = .completed
            completedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(completedInput)
            return ServerResponse(message: completedInput)
        } catch {
            // Update to failed
            var failedInput = executingInput
            failedInput.state = .failed
            failedInput.error = error.localizedDescription
            failedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            await stateStore.addInput(failedInput)
            return ServerResponse(message: failedInput)
        }
    }

    func getInput(request: ServerRequest<Macosusesdk_V1_GetInputRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_Input>
    {
        let req = request.message
        Self.logger.info("getInput called")
        guard let input = await stateStore.getInput(name: req.name) else {
            throw RPCError(code: .notFound, message: "Input not found")
        }
        return ServerResponse(message: input)
    }

    func listInputs(request: ServerRequest<Macosusesdk_V1_ListInputsRequest>, context _: ServerContext)
        async throws -> ServerResponse<Macosusesdk_V1_ListInputsResponse>
    {
        let req = request.message
        Self.logger.info("listInputs called")
        let allInputs = await stateStore.listInputs(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedInputs = allInputs.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedInputs.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageInputs = Array(sortedInputs[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListInputsResponse.with {
            $0.inputs = pageInputs
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func createObservation(
        request: ServerRequest<Macosusesdk_V1_CreateObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        let req = request.message
        Self.logger.info("createObservation called (LRO)")

        // Parse parent resource name to get PID
        let pid = try parsePID(fromName: req.parent)

        // Generate observation ID
        let observationId =
            req.observationID.isEmpty ? UUID().uuidString : req.observationID
        let observationName = "\(req.parent)/observations/\(observationId)"

        // Create operation for LRO
        let opName = "operations/observation/\(observationId)"

        // Create initial observation in ObservationManager
        let observation = await ObservationManager.shared.createObservation(
            name: observationName,
            type: req.observation.type,
            parent: req.parent,
            filter: req.observation.hasFilter ? req.observation.filter : nil,
            pid: pid,
        )

        // Create metadata
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.Observation"
            $0.value = try observation.serializedData()
        }

        // Create LRO
        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Start observation in background
        Task { [operationStore] in
            do {
                // Start the observation
                try await ObservationManager.shared.startObservation(name: observationName)

                // Get updated observation
                guard
                    let startedObservation = await ObservationManager.shared.getObservation(
                        name: observationName)
                else {
                    throw RPCError(code: .internalError, message: "Failed to start observation")
                }

                // Mark operation as done with observation in response
                try await operationStore.finishOperation(name: opName, responseMessage: startedObservation)

            } catch {
                // Mark operation as failed
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }

    func getObservation(
        request: ServerRequest<Macosusesdk_V1_GetObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Observation> {
        let req = request.message
        Self.logger.info("getObservation called")

        // Get observation from ObservationManager
        guard let observation = await ObservationManager.shared.getObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func listObservations(
        request: ServerRequest<Macosusesdk_V1_ListObservationsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListObservationsResponse> {
        let req = request.message
        Self.logger.info("listObservations called")

        // List observations for parent
        let allObservations = await ObservationManager.shared.listObservations(parent: req.parent)

        // Sort by name for deterministic ordering
        let sortedObservations = allObservations.sorted { $0.name < $1.name }

        // Decode page_token to get offset
        let offset: Int = if req.pageToken.isEmpty {
            0
        } else {
            try decodePageToken(req.pageToken)
        }

        // Determine page size (default 100 if not specified or <= 0)
        let pageSize = req.pageSize > 0 ? Int(req.pageSize) : 100
        let totalCount = sortedObservations.count

        // Calculate slice bounds
        let startIndex = min(offset, totalCount)
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageObservations = Array(sortedObservations[startIndex ..< endIndex])

        // Generate next_page_token if more results exist
        let nextPageToken = if endIndex < totalCount {
            encodePageToken(offset: endIndex)
        } else {
            ""
        }

        let response = Macosusesdk_V1_ListObservationsResponse.with {
            $0.observations = pageObservations
            $0.nextPageToken = nextPageToken
        }
        return ServerResponse(message: response)
    }

    func cancelObservation(
        request: ServerRequest<Macosusesdk_V1_CancelObservationRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Observation> {
        let req = request.message
        Self.logger.info("cancelObservation called")

        // Cancel observation in ObservationManager
        guard
            let observation = await ObservationManager.shared.cancelObservation(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        return ServerResponse(message: observation)
    }

    func streamObservations(
        request: ServerRequest<Macosusesdk_V1_StreamObservationsRequest>,
        context _: ServerContext,
    ) async throws -> StreamingServerResponse<Macosusesdk_V1_StreamObservationsResponse> {
        let req = request.message
        Self.logger.info("streamObservations called (streaming)")

        // Verify observation exists
        guard await ObservationManager.shared.getObservation(name: req.name) != nil else {
            throw RPCError(code: .notFound, message: "Observation not found")
        }

        // Create event stream
        guard let eventStream = await ObservationManager.shared.createEventStream(name: req.name)
        else {
            throw RPCError(code: .notFound, message: "Failed to create event stream")
        }

        return StreamingServerResponse { writer async in
            // Stream events to client
            // NOTE: The for-await-in loop will suspend and yield control, allowing the gRPC
            // executor to handle this task cooperatively with others.
            for await event in eventStream {
                // Check if client disconnected
                if Task.isCancelled {
                    Self.logger.info("client disconnected from observation stream")
                    break
                }

                // Send event to client
                let response = Macosusesdk_V1_StreamObservationsResponse.with {
                    $0.event = event
                }

                do {
                    try await writer.write(response)
                } catch {
                    break
                }
            }

            // Return trailing metadata after stream completes
            return [:]
        }
    }

    func captureScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureScreenshot] Capturing screen screenshot")

        // Determine display ID (0 = main display, nil = all displays)
        let displayID: CGDirectDisplayID? =
            req.display > 0
                ? CGDirectDisplayID(req.display)
                : nil

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture screen
        let result = try await ScreenshotCapture.captureScreen(
            displayID: displayID,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) screenshot")
        return ServerResponse(message: response)
    }

    func captureElementScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureElementScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureElementScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureElementScreenshot] Capturing element screenshot")

        // Get element from registry
        guard let element = await ElementRegistry.shared.getElement(req.elementID) else {
            throw RPCError(
                code: .notFound,
                message: "Element not found: \(req.elementID)",
            )
        }

        // Check element has bounds (x, y, width, height)
        guard element.hasX, element.hasY, element.hasWidth, element.hasHeight else {
            throw RPCError(
                code: .failedPrecondition,
                message: "Element has no bounds: \(req.elementID)",
            )
        }

        // Apply padding if specified
        let padding = CGFloat(req.padding)
        let bounds = CGRect(
            x: element.x - padding,
            y: element.y - padding,
            width: element.width + (padding * 2),
            height: element.height + (padding * 2),
        )

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture element region
        let result = try await ScreenshotCapture.captureRegion(
            bounds: bounds,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureElementScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        response.elementID = req.elementID
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureElementScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) element screenshot")
        return ServerResponse(message: response)
    }

    func captureRegionScreenshot(
        request: ServerRequest<Macosusesdk_V1_CaptureRegionScreenshotRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_CaptureRegionScreenshotResponse> {
        let req = request.message
        Self.logger.info("[captureRegionScreenshot] Capturing region screenshot")

        // Validate region
        guard req.hasRegion else {
            throw RPCError(
                code: .invalidArgument,
                message: "Region is required",
            )
        }

        // Convert proto Region to CGRect
        let bounds = CGRect(
            x: req.region.x,
            y: req.region.y,
            width: req.region.width,
            height: req.region.height,
        )

        // Determine display ID (for multi-monitor setups)
        let displayID: CGDirectDisplayID? =
            req.display > 0
                ? CGDirectDisplayID(req.display)
                : nil

        // Determine format (default to PNG)
        let format = req.format == .unspecified ? .png : req.format

        // Capture region
        let result = try await ScreenshotCapture.captureRegion(
            bounds: bounds,
            displayID: displayID,
            format: format,
            quality: req.quality,
            includeOCR: req.includeOcrText,
        )

        // Build response
        var response = Macosusesdk_V1_CaptureRegionScreenshotResponse()
        response.imageData = result.data
        response.format = format
        response.width = result.width
        response.height = result.height
        if let ocrText = result.ocrText {
            response.ocrText = ocrText
        }

        Self.logger.info("[captureRegionScreenshot] Captured \(result.width, privacy: .public)x\(result.height, privacy: .public) region screenshot")
        return ServerResponse(message: response)
    }

    func automateOpenFileDialog(
        request: ServerRequest<Macosusesdk_V1_AutomateOpenFileDialogRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_AutomateOpenFileDialogResponse> {
        let req = request.message
        Self.logger.info("automateOpenFileDialog called")

        do {
            let selectedPaths = try await FileDialogAutomation.shared.automateOpenFileDialog(
                filePath: req.filePath.isEmpty ? nil : req.filePath,
                defaultDirectory: req.defaultDirectory.isEmpty ? nil : req.defaultDirectory,
                fileFilters: req.fileFilters,
                allowMultiple: req.allowMultiple,
            )

            let response = Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
                $0.success = true
                $0.selectedPaths = selectedPaths
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
                $0.success = false
                $0.error = "Failed to automate open file dialog: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func automateSaveFileDialog(
        request: ServerRequest<Macosusesdk_V1_AutomateSaveFileDialogRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_AutomateSaveFileDialogResponse> {
        let req = request.message
        Self.logger.info("automateSaveFileDialog called")

        do {
            let savedPath = try await FileDialogAutomation.shared.automateSaveFileDialog(
                filePath: req.filePath,
                defaultDirectory: req.defaultDirectory.isEmpty ? nil : req.defaultDirectory,
                defaultFilename: req.defaultFilename.isEmpty ? nil : req.defaultFilename,
                confirmOverwrite: req.confirmOverwrite,
            )

            let response = Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
                $0.success = true
                $0.savedPath = savedPath
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
                $0.success = false
                $0.error = "Failed to automate save file dialog: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func selectFile(
        request: ServerRequest<Macosusesdk_V1_SelectFileRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_SelectFileResponse> {
        let req = request.message
        Self.logger.info("selectFile called")

        do {
            let selectedPath = try await FileDialogAutomation.shared.selectFile(
                filePath: req.filePath,
                revealInFinder: req.revealFinder,
            )

            let response = Macosusesdk_V1_SelectFileResponse.with {
                $0.success = true
                $0.selectedPath = selectedPath
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_SelectFileResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_SelectFileResponse.with {
                $0.success = false
                $0.error = "Failed to select file: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func selectDirectory(
        request: ServerRequest<Macosusesdk_V1_SelectDirectoryRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_SelectDirectoryResponse> {
        let req = request.message
        Self.logger.info("selectDirectory called")

        do {
            let (selectedPath, wasCreated) = try await FileDialogAutomation.shared.selectDirectory(
                directoryPath: req.directoryPath,
                createMissing: req.createMissing,
            )

            let response = Macosusesdk_V1_SelectDirectoryResponse.with {
                $0.success = true
                $0.selectedPath = selectedPath
                $0.created = wasCreated
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_SelectDirectoryResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_SelectDirectoryResponse.with {
                $0.success = false
                $0.error = "Failed to select directory: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func dragFiles(
        request: ServerRequest<Macosusesdk_V1_DragFilesRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_DragFilesResponse> {
        Self.logger.info("dragFiles called")
        let req = request.message

        // Validate inputs
        guard !req.filePaths.isEmpty else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "At least one file path is required"
            }
            return ServerResponse(message: response)
        }

        guard !req.targetElementID.isEmpty else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Target element ID is required"
            }
            return ServerResponse(message: response)
        }

        // Get target element from registry
        guard let targetElement = await ElementRegistry.shared.getElement(req.targetElementID)
        else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Target element not found: \(req.targetElementID)"
            }
            return ServerResponse(message: response)
        }

        // Ensure element has position
        guard targetElement.hasX, targetElement.hasY else {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Target element has no position information"
            }
            return ServerResponse(message: response)
        }

        let targetPoint = CGPoint(x: targetElement.x, y: targetElement.y)
        let duration = req.duration > 0 ? req.duration : 0.5

        do {
            try await FileDialogAutomation.shared.dragFilesToElement(
                filePaths: req.filePaths,
                targetElement: targetPoint,
                duration: duration,
            )

            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = true
                $0.filesDropped = Int32(req.filePaths.count)
            }
            return ServerResponse(message: response)
        } catch let error as FileDialogError {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = error.description
            }
            return ServerResponse(message: response)
        } catch {
            let response = Macosusesdk_V1_DragFilesResponse.with {
                $0.success = false
                $0.error = "Failed to drag files: \(error.localizedDescription)"
            }
            return ServerResponse(message: response)
        }
    }

    func createMacro(
        request: ServerRequest<Macosusesdk_V1_CreateMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Macro> {
        Self.logger.info("createMacro called")
        let req = request.message

        // Validate required fields
        guard !req.macro.displayName.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "display_name is required")
        }

        guard !req.macro.actions.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "at least one action is required")
        }

        // Extract macro ID from parent if provided (format: "macros/{macro_id}")
        let macroId: String? = if !req.macroID.isEmpty { req.macroID } else { nil }

        // Create the macro in the registry
        let createdMacro = await MacroRegistry.shared.createMacro(
            macroId: macroId,
            displayName: req.macro.displayName,
            description: req.macro.description_p,
            actions: req.macro.actions,
            parameters: req.macro.parameters,
            tags: req.macro.tags,
        )

        return ServerResponse(message: createdMacro)
    }

    func getMacro(
        request: ServerRequest<Macosusesdk_V1_GetMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Macro> {
        Self.logger.info("getMacro called")
        let req = request.message

        guard let macro = await MacroRegistry.shared.getMacro(name: req.name) else {
            throw RPCError(
                code: .notFound,
                message: "Macro '\(req.name)' not found",
            )
        }

        return ServerResponse(message: macro)
    }

    func listMacros(
        request: ServerRequest<Macosusesdk_V1_ListMacrosRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ListMacrosResponse> {
        Self.logger.info("listMacros called")
        let req = request.message

        // List macros with pagination
        let pageSize = Int(req.pageSize > 0 ? req.pageSize : 50)
        let pageToken = req.pageToken.isEmpty ? nil : req.pageToken

        let (macros, nextToken) = await MacroRegistry.shared.listMacros(
            pageSize: pageSize,
            pageToken: pageToken,
        )

        let response = Macosusesdk_V1_ListMacrosResponse.with {
            $0.macros = macros
            $0.nextPageToken = nextToken ?? ""
        }
        return ServerResponse(message: response)
    }

    func updateMacro(
        request: ServerRequest<Macosusesdk_V1_UpdateMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Macro> {
        Self.logger.info("updateMacro called")
        let req = request.message

        // Parse field mask to determine what to update
        let updateMask = req.updateMask

        // Extract fields to update from req.macro
        var displayName: String?
        var description: String?
        var actions: [Macosusesdk_V1_MacroAction]?
        var parameters: [Macosusesdk_V1_MacroParameter]?
        var tags: [String]?

        // Apply field mask per AIP-134:
        // - Empty mask = full replacement (update all fields from request)
        // - Non-empty mask = partial update (update only specified fields)
        if updateMask.paths.isEmpty {
            // Full replacement - update all fields even if empty (allows field clearance)
            displayName = req.macro.displayName
            description = req.macro.description_p
            actions = req.macro.actions
            parameters = req.macro.parameters
            tags = req.macro.tags
        } else {
            // Update only specified fields
            for path in updateMask.paths {
                switch path {
                case "display_name":
                    displayName = req.macro.displayName
                case "description":
                    description = req.macro.description_p
                case "actions":
                    actions = req.macro.actions
                case "parameters":
                    parameters = req.macro.parameters
                case "tags":
                    tags = req.macro.tags
                default:
                    throw RPCError(code: .invalidArgument, message: "Invalid field path: \(path)")
                }
            }
        }

        // Update macro in registry
        guard
            let updatedMacro = await MacroRegistry.shared.updateMacro(
                name: req.macro.name,
                displayName: displayName,
                description: description,
                actions: actions,
                parameters: parameters,
                tags: tags,
            )
        else {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.macro.name)")
        }

        return ServerResponse(message: updatedMacro)
    }

    func deleteMacro(
        request: ServerRequest<Macosusesdk_V1_DeleteMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        Self.logger.info("deleteMacro called")
        let req = request.message

        // Delete macro from registry
        let deleted = await MacroRegistry.shared.deleteMacro(name: req.name)

        if !deleted {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.name)")
        }

        let response = SwiftProtobuf.Google_Protobuf_Empty()
        return ServerResponse(message: response)
    }

    func executeMacro(
        request: ServerRequest<Macosusesdk_V1_ExecuteMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        Self.logger.info("executeMacro called (LRO)")
        let req = request.message

        // Get macro from registry
        guard let macro = await MacroRegistry.shared.getMacro(name: req.macro) else {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.macro)")
        }

        // Create LRO
        let opName = "operations/executeMacro/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.ExecuteMacroMetadata"
            $0.value = try Macosusesdk_V1_ExecuteMacroMetadata.with {
                $0.macro = req.macro
                $0.totalActions = Int32(macro.actions.count)
            }.serializedData()
        }

        let op = await operationStore.createOperation(name: opName, metadata: metadata)

        // Execute macro in background
        Task { [operationStore] in
            do {
                let timeout = req.hasOptions && req.options.timeout > 0 ? req.options.timeout : 300.0

                // Execute macro
                try await MacroExecutor.shared.executeMacro(
                    macro: macro,
                    parameters: req.parameterValues,
                    parent: req.application.isEmpty ? "" : req.application,
                    timeout: timeout,
                )

                // Increment execution count
                await MacroRegistry.shared.incrementExecutionCount(name: req.macro)

                // Complete operation
                let response = Macosusesdk_V1_ExecuteMacroResponse.with {
                    $0.success = true
                    $0.actionsExecuted = Int32(macro.actions.count)
                }

                try await operationStore.finishOperation(name: opName, responseMessage: response)

            } catch let error as MacroExecutionError {
                // Mark operation as failed with macro error
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = error.description
                }
                await operationStore.putOperation(errOp)

            } catch {
                // Mark operation as failed with generic error
                var errOp = await operationStore.getOperation(name: opName) ?? op
                errOp.done = true
                errOp.error = Google_Rpc_Status.with {
                    $0.code = Int32(RPCError.Code.internalError.rawValue)
                    $0.message = "\(error)"
                }
                await operationStore.putOperation(errOp)
            }
        }

        return ServerResponse(message: op)
    }
}
