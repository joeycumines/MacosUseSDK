// Copyright 2025 Joseph Cumines
//
// Clipboard tool handler — unified clipboard with action discriminator

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleClipboard handles the clipboard tool — unified clipboard operations.
// Action discriminator: get, set, clear.
func (s *MCPServer) handleClipboard(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Action string `json:"action"`
		Text   string `json:"text"`
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
		return s.clipboardSet(ctx, params.Text)
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

	content := "(empty)"
	if clipboard.Content != nil {
		switch c := clipboard.Content.Type; c {
		case pb.ContentType_CONTENT_TYPE_TEXT:
			content = clipboard.Content.GetText()
		case pb.ContentType_CONTENT_TYPE_RTF:
			content = "[RTF data]"
		case pb.ContentType_CONTENT_TYPE_HTML:
			content = clipboard.Content.GetHtml()
		case pb.ContentType_CONTENT_TYPE_IMAGE:
			content = "[Image data]"
		case pb.ContentType_CONTENT_TYPE_FILES:
			if files := clipboard.Content.GetFiles(); files != nil {
				content = fmt.Sprintf("[Files: %v]", files.Paths)
			}
		case pb.ContentType_CONTENT_TYPE_URL:
			content = clipboard.Content.GetUrl()
		default:
			content = fmt.Sprintf("[%s]", c.String())
		}
	}

	return textResultf("Clipboard content:\n%s", content), nil
}

// clipboardSet writes text to the clipboard.
func (s *MCPServer) clipboardSet(ctx context.Context, text string) (*ToolResult, error) {
	if text == "" {
		return errorResult("text parameter is required for set action"), nil
	}

	if errResult := validateInputLen(text, maxInputTextLen, "text"); errResult != nil {
		return errResult, nil
	}

	_, err := s.client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content: &pb.ClipboardContent{
			Type: pb.ContentType_CONTENT_TYPE_TEXT,
			Content: &pb.ClipboardContent_Text{
				Text: text,
			},
		},
		ClearExisting: true,
	})
	if err != nil {
		return grpcErrorResult(err, "clipboard"), nil
	}

	displayText := truncateText(text)
	return textResultf("Clipboard set: %d characters (\"%s\")", len(text), displayText), nil
}

// clipboardClear clears the clipboard.
func (s *MCPServer) clipboardClear(ctx context.Context) (*ToolResult, error) {
	_, err := s.client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})
	if err != nil {
		return grpcErrorResult(err, "clipboard"), nil
	}

	return textResult("Clipboard cleared"), nil
}
