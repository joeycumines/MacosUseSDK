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

        // Validate filePath is not empty
        guard !req.filePath.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "file_path is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "file_path",
            )
        }

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

        // Validate filePath is not empty
        guard !req.filePath.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "file_path is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "file_path",
            )
        }

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

        // Validate directoryPath is not empty
        guard !req.directoryPath.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "directory_path is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "directory_path",
            )
        }

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
            throw RPCErrorHelpers.validationError(
                message: "file_paths is required (at least one file path)",
                reason: "REQUIRED_FIELD_MISSING",
                field: "file_paths",
            )
        }

        guard !req.targetElementID.isEmpty else {
            throw RPCErrorHelpers.validationError(
                message: "target_element_id is required",
                reason: "REQUIRED_FIELD_MISSING",
                field: "target_element_id",
            )
        }

        // Validate duration is finite and non-negative
        guard req.duration.isFinite, req.duration >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "duration must be a finite non-negative number",
                reason: "INVALID_DIMENSION",
                field: "duration",
                value: String(req.duration),
            )
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
}
