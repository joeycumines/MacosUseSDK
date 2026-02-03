// Copyright 2025 Joseph Cumines
//
// Display tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleListDisplays handles the list_displays tool
func (s *MCPServer) handleListDisplays(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	resp, err := s.client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list displays: %v", err)}},
		}, nil
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
				Text: fmt.Sprintf("Found %d displays:\n%s", len(resp.Displays), strings.Join(lines, "\n")),
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
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to parse arguments: %v", err)}},
		}, nil
	}

	display, err := s.client.GetDisplay(ctx, &pb.GetDisplayRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get display: %v", err)}},
		}, nil
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
