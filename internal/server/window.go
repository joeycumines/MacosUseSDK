// Copyright 2025 Joseph Cumines
//
// Window tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleListWindows handles the list_windows tool
func (s *MCPServer) handleListWindows(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent string `json:"parent"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return nil, fmt.Errorf("failed to parse arguments: %w", err)
	}

	resp, err := s.client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: params.Parent})
	if err != nil {
		return nil, fmt.Errorf("failed to list windows: %w", err)
	}

	if len(resp.Windows) == 0 {
		return &ToolResult{
			Content: []Content{
				{
					Type: "text",
					Text: "No windows found for this application",
				},
			},
		}, nil
	}

	var lines []string
	for _, w := range resp.Windows {
		lines = append(lines, fmt.Sprintf("- %s (%s)", w.Title, w.Name))
	}

	return &ToolResult{
		Content: []Content{
			{
				Type: "text",
				Text: fmt.Sprintf("Found %d windows:\n%s", len(resp.Windows), joinStrings(lines, "\n")),
			},
		},
	}, nil
}
