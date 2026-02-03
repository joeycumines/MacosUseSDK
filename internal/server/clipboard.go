// Copyright 2025 Joseph Cumines
//
// Clipboard tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleGetClipboard handles the get_clipboard tool
func (s *MCPServer) handleGetClipboard(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	clipboard, err := s.client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get clipboard: %v", err)}},
		}, nil
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

	return &ToolResult{
		Content: []Content{
			{
				Type: "text",
				Text: fmt.Sprintf("Clipboard content:\n%s", content),
			},
		},
	}, nil
}

// handleWriteClipboard handles the write_clipboard tool
func (s *MCPServer) handleWriteClipboard(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Text content to write
		Text string `json:"text"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Text == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Text parameter is required"}},
		}, nil
	}

	_, err := s.client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
		Content: &pb.ClipboardContent{
			Type: pb.ContentType_CONTENT_TYPE_TEXT,
			Content: &pb.ClipboardContent_Text{
				Text: params.Text,
			},
		},
		ClearExisting: true,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to write clipboard: %v", err)}},
		}, nil
	}

	// Truncate displayed text if too long
	displayText := params.Text
	if len(displayText) > 50 {
		displayText = displayText[:47] + "..."
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Clipboard updated with %d characters: \"%s\"", len(params.Text), displayText),
		}},
	}, nil
}

// handleClearClipboard handles the clear_clipboard tool
func (s *MCPServer) handleClearClipboard(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	_, err := s.client.ClearClipboard(ctx, &pb.ClearClipboardRequest{})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to clear clipboard: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: "Clipboard cleared",
		}},
	}, nil
}

// handleGetClipboardHistory handles the get_clipboard_history tool
func (s *MCPServer) handleGetClipboardHistory(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	resp, err := s.client.GetClipboardHistory(ctx, &pb.GetClipboardHistoryRequest{
		Name: "clipboard/history",
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get clipboard history: %v", err)}},
		}, nil
	}

	if len(resp.Entries) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No clipboard history available"}},
		}, nil
	}

	var lines []string
	for i, entry := range resp.Entries {
		var contentStr string
		if entry.Content != nil {
			switch c := entry.Content.Type; c {
			case pb.ContentType_CONTENT_TYPE_TEXT:
				contentStr = entry.Content.GetText()
			case pb.ContentType_CONTENT_TYPE_URL:
				contentStr = entry.Content.GetUrl()
			case pb.ContentType_CONTENT_TYPE_IMAGE:
				contentStr = "[Image]"
			default:
				contentStr = fmt.Sprintf("[%s]", c.String())
			}
		}
		if len(contentStr) > 50 {
			contentStr = contentStr[:47] + "..."
		}
		lines = append(lines, fmt.Sprintf("%d. %s", i+1, contentStr))
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Clipboard history (%d entries):\n%s", len(resp.Entries), strings.Join(lines, "\n")),
		}},
	}, nil
}
