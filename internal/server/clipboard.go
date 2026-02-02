// Copyright 2025 Joseph Cumines
//
// Clipboard tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleGetClipboard handles the get_clipboard tool
func (s *MCPServer) handleGetClipboard(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return nil, fmt.Errorf("failed to parse arguments: %w", err)
	}

	clipboard, err := s.client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: params.Name})
	if err != nil {
		return nil, fmt.Errorf("failed to get clipboard: %w", err)
	}

	content := "(empty)"
	if clipboard.Content != nil {
		switch c := clipboard.Content.Type; c {
		case pb.ContentType_CONTENT_TYPE_TEXT:
			content = clipboard.Content.GetText()
		case pb.ContentType_CONTENT_TYPE_RTF:
			content = "[RTF data]"
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
