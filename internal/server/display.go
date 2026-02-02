// Copyright 2025 Joseph Cumines
//
// Display tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleListDisplays handles the list_displays tool
func (s *MCPServer) handleListDisplays(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	resp, err := s.client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		return nil, fmt.Errorf("failed to list displays: %w", err)
	}

	if len(resp.Displays) == 0 {
		return &ToolResult{
			Content: []Content{
				{
					Type: "text",
					Text: "No displays found",
				},
			},
		}, nil
	}

	var lines []string
	for _, d := range resp.Displays {
		mainMark := ""
		if d.IsMain {
			mainMark = " (main)"
		}
		lines = append(lines, fmt.Sprintf(
			"- Display %d%s: %.0fx%.0f @ (%.0f, %.0f), scale %.1f",
			d.DisplayId, mainMark,
			d.Frame.Width, d.Frame.Height,
			d.Frame.X, d.Frame.Y,
			d.Scale,
		))
	}

	return &ToolResult{
		Content: []Content{
			{
				Type: "text",
				Text: fmt.Sprintf("Found %d displays:\n%s", len(resp.Displays), joinStrings(lines, "\n")),
			},
		},
	}, nil
}

// handleGetDisplay handles the get_display tool
func (s *MCPServer) handleGetDisplay(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string `json:"name"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return nil, fmt.Errorf("failed to parse arguments: %w", err)
	}

	display, err := s.client.GetDisplay(ctx, &pb.GetDisplayRequest{Name: params.Name})
	if err != nil {
		return nil, fmt.Errorf("failed to get display: %w", err)
	}

	mainMark := ""
	if display.IsMain {
		mainMark = " (main)"
	}

	return &ToolResult{
		Content: []Content{
			{
				Type: "text",
				Text: fmt.Sprintf(`Display: %s
  Display ID: %d%s
  Frame: %.0fx%.0f @ (%.0f, %.0f)
  Visible Frame: %.0fx%.0f @ (%.0f, %.0f)
  Scale: %.1f`,
					display.Name,
					display.DisplayId, mainMark,
					display.Frame.Width, display.Frame.Height, display.Frame.X, display.Frame.Y,
					display.VisibleFrame.Width, display.VisibleFrame.Height, display.VisibleFrame.X, display.VisibleFrame.Y,
					display.Scale,
				),
			},
		},
	}, nil
}

// joinStrings joins strings with a separator
func joinStrings(strs []string, sep string) string {
	if len(strs) == 0 {
		return ""
	}
	result := strs[0]
	for i := 1; i < len(strs); i++ {
		result += sep + strs[i]
	}
	return result
}
