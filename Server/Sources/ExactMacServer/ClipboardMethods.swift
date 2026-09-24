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
    func getClipboard(
        request: ServerRequest<Exactmac_V1_GetClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Clipboard> {
        let req = request.message
        Self.logger.info("getClipboard called")

        // Validate resource name (singleton: "clipboard")
        guard req.name == "clipboard" else {
            throw RPCError(code: .invalidArgument, message: "Invalid clipboard name: \(req.name)")
        }

        do {
            let response = try await clipboardManager.readClipboard()
            return ServerResponse(message: response)
        } catch ClipboardAccessError.queueFull {
            throw RPCError(code: .resourceExhausted, message: "Clipboard access queue is full")
        } catch is CancellationError {
            throw RPCError(code: .cancelled, message: "Clipboard read was cancelled")
        } catch {
            throw RPCError(code: .internalError, message: "Failed to read clipboard: \(error)")
        }
    }

    func writeClipboard(
        request: ServerRequest<Exactmac_V1_WriteClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_WriteClipboardResponse> {
        let req = request.message
        Self.logger.info("writeClipboard called")

        // Validate content
        guard req.hasContent else {
            throw RPCError(code: .invalidArgument, message: "Content is required")
        }

        do {
            // Clipboard ownership must always be cleared before a write,
            // irrespective of the legacy request hint.
            let clipboard = try await clipboardManager.writeClipboard(content: req.content)
            return ServerResponse(
                message: Exactmac_V1_WriteClipboardResponse.with {
                    $0.clipboard = clipboard
                },
            )
        } catch let error as ClipboardError {
            switch error {
            case .invalidContent:
                throw RPCError(code: .invalidArgument, message: error.description)
            case .writeFailed, .readFailed:
                throw RPCError(code: .internalError, message: error.description)
            }
        } catch PhysicalDesktopMutationError.queueFull {
            throw RPCError(code: .resourceExhausted, message: "Physical mutation queue is full")
        } catch PhysicalDesktopMutationError.admissionClosed {
            throw RPCError(code: .unavailable, message: "Physical mutation admission is closed")
        } catch ClipboardAccessError.queueFull {
            throw RPCError(code: .resourceExhausted, message: "Clipboard access queue is full")
        } catch is CancellationError {
            throw RPCError(code: .cancelled, message: "Clipboard write was cancelled")
        } catch {
            throw RPCError(code: .internalError, message: "Failed to write clipboard: \(error)")
        }
    }

    func clearClipboard(
        request: ServerRequest<Exactmac_V1_ClearClipboardRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ClearClipboardResponse> {
        _ = request.message
        Self.logger.info("clearClipboard called")

        do {
            let clipboard = try await clipboardManager.clearClipboard()
            return ServerResponse(
                message: Exactmac_V1_ClearClipboardResponse.with {
                    $0.clipboard = clipboard
                },
            )
        } catch let error as ClipboardError {
            throw RPCError(code: .internalError, message: error.description)
        } catch PhysicalDesktopMutationError.queueFull {
            throw RPCError(code: .resourceExhausted, message: "Physical mutation queue is full")
        } catch PhysicalDesktopMutationError.admissionClosed {
            throw RPCError(code: .unavailable, message: "Physical mutation admission is closed")
        } catch ClipboardAccessError.queueFull {
            throw RPCError(code: .resourceExhausted, message: "Clipboard access queue is full")
        } catch is CancellationError {
            throw RPCError(code: .cancelled, message: "Clipboard clear was cancelled")
        } catch {
            throw RPCError(code: .internalError, message: "Failed to clear clipboard: \(error)")
        }
    }

    func getClipboardHistory(
        request: ServerRequest<Exactmac_V1_GetClipboardHistoryRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ClipboardHistory> {
        let req = request.message
        Self.logger.info("getClipboardHistory called")

        // Validate resource name (singleton: "clipboardHistory")
        guard req.name == "clipboardHistory" else {
            throw RPCError(
                code: .invalidArgument, message: "Invalid clipboard history name: \(req.name)",
            )
        }

        let response = await clipboardHistoryManager.getHistory()
        return ServerResponse(message: response)
    }
}
