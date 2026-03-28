import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

extension MacosUseService {
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

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }

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

        // Validate macro.name is not empty
        guard !req.macro.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "macro.name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "macro.name",
            )
        }

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

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }

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

        // Validate macro name is not empty
        guard !req.macro.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "macro is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "macro",
            )
        }

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
