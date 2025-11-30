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
    func getClipboard(
        request: ServerRequest<Macosusesdk_V1_GetClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_Clipboard> {
        let req = request.message
        Self.logger.info("getClipboard called")

        // Validate resource name (singleton: "clipboard")
        guard req.name == "clipboard" else {
            throw RPCError(code: .invalidArgument, message: "Invalid clipboard name: \(req.name)")
        }

        let response = await ClipboardManager.shared.readClipboard()
        return ServerResponse(message: response)
    }

    func writeClipboard(
        request: ServerRequest<Macosusesdk_V1_WriteClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_WriteClipboardResponse> {
        let req = request.message
        Self.logger.info("writeClipboard called")

        // Validate content
        guard req.hasContent else {
            throw RPCError(code: .invalidArgument, message: "Content is required")
        }

        do {
            // Write to clipboard
            let clipboard = try await ClipboardManager.shared.writeClipboard(
                content: req.content,
                req.clearExisting_p,
            )

            let response = Macosusesdk_V1_WriteClipboardResponse.with {
                $0.success = true
                $0.type = clipboard.content.type
            }
            return ServerResponse(message: response)
        } catch let error as ClipboardError {
            throw RPCError(code: .internalError, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: "Failed to write clipboard: \(error)")
        }
    }

    func clearClipboard(
        request: ServerRequest<Macosusesdk_V1_ClearClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ClearClipboardResponse> {
        _ = request.message
        Self.logger.info("clearClipboard called")

        await ClipboardManager.shared.clearClipboard()

        let response = Macosusesdk_V1_ClearClipboardResponse.with {
            $0.success = true
        }
        return ServerResponse(message: response)
    }

    func getClipboardHistory(
        request: ServerRequest<Macosusesdk_V1_GetClipboardHistoryRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Macosusesdk_V1_ClipboardHistory> {
        let req = request.message
        Self.logger.info("getClipboardHistory called")

        // Validate resource name (singleton: "clipboard/history")
        guard req.name == "clipboard/history" else {
            throw RPCError(
                code: .invalidArgument, message: "Invalid clipboard history name: \(req.name)",
            )
        }

        let response = await ClipboardHistoryManager.shared.getHistory()
        return ServerResponse(message: response)
    }
}
