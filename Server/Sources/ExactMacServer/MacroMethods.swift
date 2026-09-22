import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

extension ExactMacService {
    func createMacro(
        request: ServerRequest<Exactmac_V1_CreateMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Macro> {
        Self.logger.info("createMacro called")
        let req = request.message

        // Validate required fields
        guard req.hasMacro else {
            throw RPCErrorHelpers.validationError(
                message: "macro is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "macro",
            )
        }
        guard req.macro.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "macro.name must be omitted when creating a macro",
                reason: "INVALID_RESOURCE_NAME",
                field: "macro.name",
                value: req.macro.name,
            )
        }
        guard !req.macro.displayName.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "display_name is required")
        }

        guard !req.macro.actions.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "at least one action is required")
        }
        try validateMacroActions(req.macro.actions)

        // Extract macro ID from parent if provided (format: "macros/{macro_id}")
        let macroId: String? = if !req.macroID.isEmpty {
            try ParsingHelpers.validateResourceID(req.macroID, field: "macro_id")
        } else {
            nil
        }

        // Create the macro in the registry
        let createdMacro = await self.macroRegistry.createMacro(
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
        request: ServerRequest<Exactmac_V1_GetMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Macro> {
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
        _ = try ParsingHelpers.parseMacroName(req.name)

        guard let macro = await self.macroRegistry.getMacro(name: req.name) else {
            throw RPCError(
                code: .notFound,
                message: "Macro '\(req.name)' not found",
            )
        }

        return ServerResponse(message: macro)
    }

    func listMacros(
        request: ServerRequest<Exactmac_V1_ListMacrosRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListMacrosResponse> {
        Self.logger.info("listMacros called")
        let req = request.message

        // List macros with pagination
        let pageSize = try RequestNumericValidation.pageSize(req.pageSize, default: 50)
        let pageToken = req.pageToken.isEmpty ? nil : req.pageToken

        let (macros, nextToken) = try await self.macroRegistry.listMacros(
            pageSize: pageSize,
            pageToken: pageToken,
        )

        let response = Exactmac_V1_ListMacrosResponse.with {
            $0.macros = macros
            $0.nextPageToken = nextToken ?? ""
        }
        return ServerResponse(message: response)
    }

    func updateMacro(
        request: ServerRequest<Exactmac_V1_UpdateMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Macro> {
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
        _ = try ParsingHelpers.parseMacroName(req.macro.name)

        // Parse field mask to determine what to update
        let updateMask = req.updateMask

        // Extract fields to update from req.macro
        var displayName: String?
        var description: String?
        var actions: [Exactmac_V1_MacroAction]?
        var parameters: [Exactmac_V1_MacroParameter]?
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

        if let actions {
            try validateMacroActions(actions)
        }

        // Update macro in registry
        guard
            let updatedMacro = await self.macroRegistry.updateMacro(
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
        request: ServerRequest<Exactmac_V1_DeleteMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<SwiftProtobuf.Google_Protobuf_Empty> {
        Self.logger.info("deleteMacro called")
        let req = request.message

        guard !req.force else {
            throw RPCError(code: .unimplemented, message: "force deletion is not supported")
        }

        // Validate name is not empty
        guard !req.name.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "name is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "name",
            )
        }
        _ = try ParsingHelpers.parseMacroName(req.name)

        // Delete macro from registry
        let deleted = await self.macroRegistry.deleteMacro(name: req.name)

        if !deleted {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.name)")
        }

        let response = SwiftProtobuf.Google_Protobuf_Empty()
        return ServerResponse(message: response)
    }

    func executeMacro(
        request: ServerRequest<Exactmac_V1_ExecuteMacroRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Google_Longrunning_Operation> {
        Self.logger.info("executeMacro called (LRO)")
        let req = request.message
        let timeout = try RequestNumericValidation.optionalTimeout(
            req.hasOptions ? req.options.timeout : 0,
            default: 300,
            field: "options.timeout",
        )

        // Validate macro name is not empty
        guard !req.macro.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "macro is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "macro",
            )
        }
        _ = try ParsingHelpers.parseMacroName(req.macro)

        // Get macro from registry
        guard let macro = await self.macroRegistry.getMacro(name: req.macro) else {
            throw RPCError(code: .notFound, message: "Macro not found: \(req.macro)")
        }
        let requiresApplication = MacroDefinitionValidator.containsPhysicalAction(
            macro.actions,
        )
        if requiresApplication, req.application.isEmpty || req.application == "applications/-" {
            throw RPCErrorHelpers.validationError(
                message: "application is required for a physical macro",
                reason: "REQUIRED_FIELD_MISSING",
                field: "application",
            )
        }

        let parent = req.application
        let applicationGeneration: AppStateStore.ApplicationProcessGenerationLease?
        if parent.isEmpty {
            applicationGeneration = nil
        } else {
            _ = try ParsingHelpers.parseOpaqueApplicationName(parent)
            guard let generation = await stateStore.applicationProcessGenerationLease(name: parent),
                  system.isApplicationProcessRunning(generation.identity)
            else {
                throw RPCError(
                    code: .notFound,
                    message: "Application not found or process identity is stale",
                )
            }
            applicationGeneration = generation
        }
        // Create LRO
        let opName = "operations/\(UUID().uuidString)"
        let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/exactmac.v1.ExecuteMacroMetadata"
            $0.value = try Exactmac_V1_ExecuteMacroMetadata.with {
                $0.macro = req.macro
                $0.totalActions = Int32(macro.actions.count)
            }.serializedData()
        }

        let op: Google_Longrunning_Operation
        do {
            op = try await operationStore.createOperation(
                name: opName,
                metadata: metadata,
                execution: { [macroExecutor, operationStore] in
                    do {
                        // Execute macro
                        try await macroExecutor.executeMacro(
                            macro: macro,
                            operationName: opName,
                            parameters: req.parameterValues,
                            parent: parent,
                            applicationGeneration: applicationGeneration,
                            timeout: timeout,
                        )

                        // Increment execution count
                        await self.macroRegistry.incrementExecutionCount(name: req.macro)

                        // Complete operation
                        let response = Exactmac_V1_ExecuteMacroResponse.with {
                            $0.success = true
                            $0.actionsExecuted = Int32(macro.actions.count)
                        }

                        try await operationStore.finishOperation(
                            name: opName,
                            responseMessage: response,
                        )

                    } catch is CancellationError {
                        await operationStore.failOperation(
                            name: opName,
                            code: Int32(RPCError.Code.cancelled.rawValue),
                            message: "Macro execution cancelled",
                        )
                    } catch MacroExecutionError.timeout {
                        await operationStore.failOperation(
                            name: opName,
                            code: Int32(RPCError.Code.deadlineExceeded.rawValue),
                            message: MacroExecutionError.timeout.description,
                        )
                    } catch let error as RPCError {
                        await operationStore.failOperation(
                            name: opName,
                            code: Int32(error.code.rawValue),
                            message: error.message,
                        )
                    } catch let error as MacroExecutionError {
                        await operationStore.failOperation(
                            name: opName,
                            code: Int32(RPCError.Code.internalError.rawValue),
                            message: error.description,
                        )
                    } catch {
                        await operationStore.failOperation(
                            name: opName,
                            code: Int32(RPCError.Code.internalError.rawValue),
                            message: "\(error)",
                        )
                    }
                },
            )
        } catch OperationStoreError.admissionClosed {
            throw RPCError(code: .unavailable, message: "Operation admission is closed")
        } catch let error as OperationStoreError {
            throw RPCError(code: .internalError, message: "\(error)")
        }

        return ServerResponse(message: op)
    }

    private func validateMacroActions(_ actions: [Exactmac_V1_MacroAction]) throws {
        guard !actions.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "macro.actions requires at least one action",
                reason: "INVALID_MACRO",
                field: "macro.actions",
            )
        }

        do {
            try MacroDefinitionValidator.validate(actions: actions) { action in
                _ = try automationCoordinator.validateInputAction(action)
            }
        } catch let error as MacroDefinitionValidationError {
            throw RPCErrorHelpers.validationError(
                message: error.localizedDescription,
                reason: "INVALID_MACRO",
                field: "macro.actions",
            )
        }
    }
}
