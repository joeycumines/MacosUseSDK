import GRPCCore
import MacosUseProto
import OSLog

extension MacosUseService {
    func automateOpenFileDialog(
        request: ServerRequest<Macosusesdk_V1_AutomateOpenFileDialogRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_AutomateOpenFileDialogResponse> {
        let req = request.message
        Self.logger.info("automateOpenFileDialog called")

        _ = try RequestNumericValidation.optionalTimeout(req.timeout, default: 30)
        try Self.validateFileDialogApplication(req.application)
        throw Self.targetOwnedFileDialogUnavailable("open file dialog automation")
    }

    func automateSaveFileDialog(
        request: ServerRequest<Macosusesdk_V1_AutomateSaveFileDialogRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_AutomateSaveFileDialogResponse> {
        let req = request.message
        Self.logger.info("automateSaveFileDialog called")

        _ = try RequestNumericValidation.optionalTimeout(req.timeout, default: 30)
        // Validate filePath is not empty
        guard !req.filePath.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "file_path is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "file_path",
            )
        }

        try Self.validateFileDialogApplication(req.application)
        throw Self.targetOwnedFileDialogUnavailable("save file dialog automation")
    }
}

private extension MacosUseService {
    static func validateFileDialogApplication(_ application: String) throws {
        guard !application.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "application is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "application",
            )
        }
    }

    static func targetOwnedFileDialogUnavailable(_ operation: String) -> RPCError {
        RPCError(
            code: .unimplemented,
            message: "Target-owned \(operation) is not implemented",
        )
    }
}
