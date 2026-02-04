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
			"- Display %d%s: %s, scale %.1f",
			d.DisplayId, mainMark,
			frameString(d.Frame),
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
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Name == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "name parameter is required (e.g., 'displays/12345')"}},
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
  Frame: %s
  Visible Frame: %s
  Scale: %.1f`,
					display.Name,
					display.DisplayId, mainMark,
					frameString(display.Frame),
					frameString(display.VisibleFrame),
					display.Scale,
				),
			},
		},
	}, nil
}

// handleCursorPosition handles the cursor_position tool.
//
// Retrieves the current cursor position in Global Display Coordinates (top-left origin):
//   - Origin (0,0) is at the top-left corner of the main display
//   - Y increases downward
//   - Also returns which display the cursor is currently on
func (s *MCPServer) handleCursorPosition(_ *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	resp, err := s.client.CaptureCursorPosition(ctx, &pb.CaptureCursorPositionRequest{})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get cursor position: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{
			{
				Type: "text",
				Text: fmt.Sprintf("Cursor position: (%.0f, %.0f) on %s", resp.X, resp.Y, resp.Display),
			},
		},
	}, nil
}
