// Copyright 2025 Joseph Cumines
//
// Clipboard tool handler — unified clipboard with action discriminator

package server

import (
	"context"
	"encoding/json"
	"slices"
	"time"
	"unicode/utf8"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

// handleClipboard handles the clipboard tool — unified clipboard operations.
// Action discriminator: get, set, clear.
func (s *MCPServer) handleClipboard(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Action string  `json:"action"`
		Text   *string `json:"text"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Action == "" {
		return errorResult("action parameter is required (get, set, clear)"), nil
	}

	switch params.Action {
	case "get":
		return s.clipboardGet(ctx)
	case "set":
		if params.Text == nil {
			return errorResult("text parameter is required for set action"), nil
		}
		return s.clipboardSet(ctx, *params.Text)
	case "clear":
		return s.clipboardClear(ctx)
	default:
		return errorResultf("Unknown action: %s. Valid: get, set, clear", params.Action), nil
	}
}

// clipboardGet retrieves clipboard contents.
func (s *MCPServer) clipboardGet(ctx context.Context) (*ToolResult, error) {
	clipboard, err := s.client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		return grpcErrorResult(err, "clipboard"), nil
	}

	if clipboard == nil || clipboard.GetName() != "clipboard" {
		return errorResult("clipboard backend returned an invalid resource"), nil
	}
	if clipboard.Content == nil {
		if len(clipboard.GetAvailableTypes()) != 0 {
			return errorResult("clipboard backend returned inconsistent empty content"), nil
		}
		return textResult("Clipboard is empty"), nil
	}

	content := clipboard.Content
	if !clipboardHasAvailableType(clipboard, content.GetType()) {
		return errorResult("clipboard backend returned unavailable content"), nil
	}
	switch payload := content.GetContent().(type) {
	case *pb.ClipboardContent_Text:
		if content.GetType() != pb.ContentType_CONTENT_TYPE_TEXT {
			return errorResult("clipboard backend returned mismatched text content"), nil
		}
		if payload.Text == "" {
			return textResult("Clipboard text: 0 characters"), nil
		}
		return textResultf("Clipboard content:\n%s", payload.Text), nil
	case *pb.ClipboardContent_Rtf:
		if content.GetType() != pb.ContentType_CONTENT_TYPE_RTF {
			return errorResult("clipboard backend returned mismatched RTF content"), nil
		}
		return textResult("[RTF data]"), nil
	case *pb.ClipboardContent_Html:
		if content.GetType() != pb.ContentType_CONTENT_TYPE_HTML {
			return errorResult("clipboard backend returned mismatched HTML content"), nil
		}
		return textResultf("Clipboard content:\n%s", payload.Html), nil
	case *pb.ClipboardContent_Image:
		if content.GetType() != pb.ContentType_CONTENT_TYPE_IMAGE {
			return errorResult("clipboard backend returned mismatched image content"), nil
		}
		return textResult("[Image data]"), nil
	case *pb.ClipboardContent_Files:
		if content.GetType() != pb.ContentType_CONTENT_TYPE_FILES || payload.Files == nil {
			return errorResult("clipboard backend returned mismatched file content"), nil
		}
		return textResultf("[Files: %v]", payload.Files.GetPaths()), nil
	case *pb.ClipboardContent_Url:
		if content.GetType() != pb.ContentType_CONTENT_TYPE_URL {
			return errorResult("clipboard backend returned mismatched URL content"), nil
		}
		return textResultf("Clipboard content:\n%s", payload.Url), nil
	default:
		return errorResult("clipboard backend returned content without a payload"), nil
	}
}

// clipboardSet writes text to the clipboard.
func (s *MCPServer) clipboardSet(ctx context.Context, text string) (*ToolResult, error) {
	response, err := s.client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content: &pb.ClipboardContent{
			Type: pb.ContentType_CONTENT_TYPE_TEXT.Enum(),
			Content: &pb.ClipboardContent_Text{
				Text: text,
			},
		},
	})
	if err != nil {
		return grpcErrorResult(err, "clipboard"), nil
	}
	if response == nil {
		return errorResult("clipboard backend returned no write response"), nil
	}
	clipboard := response.GetClipboard()
	if !clipboardIsExactText(clipboard, text) {
		return errorResult("clipboard backend did not observe the requested text"), nil
	}
	return textResultf("Clipboard set: %d characters", utf8.RuneCountInString(text)), nil
}

// clipboardClear clears the clipboard.
func (s *MCPServer) clipboardClear(ctx context.Context) (*ToolResult, error) {
	response, err := s.client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})
	if err != nil {
		return grpcErrorResult(err, "clipboard"), nil
	}
	if response == nil {
		return errorResult("clipboard backend returned no clear response"), nil
	}
	clipboard := response.GetClipboard()
	if clipboard == nil ||
		clipboard.GetName() != "clipboard" ||
		clipboard.GetContent() != nil ||
		len(clipboard.GetAvailableTypes()) != 0 {
		return errorResult("clipboard backend did not observe an empty clipboard"), nil
	}

	return textResult("Clipboard cleared"), nil
}

func clipboardIsExactText(clipboard *pb.Clipboard, expected string) bool {
	if clipboard == nil ||
		clipboard.GetName() != "clipboard" ||
		!clipboardHasAvailableType(clipboard, pb.ContentType_CONTENT_TYPE_TEXT) {
		return false
	}
	content := clipboard.GetContent()
	if content == nil || content.GetType() != pb.ContentType_CONTENT_TYPE_TEXT {
		return false
	}
	payload, ok := content.GetContent().(*pb.ClipboardContent_Text)
	return ok && payload.Text == expected
}

func clipboardHasAvailableType(
	clipboard *pb.Clipboard,
	contentType pb.ContentType,
) bool {
	return slices.Contains(clipboard.GetAvailableTypes(), contentType)
}
