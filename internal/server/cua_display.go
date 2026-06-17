// Copyright 2025 Joseph Cumines
//
// Display tool handler — get_display (combines ListDisplays + CaptureCursorPosition)

package server

import (
	"context"
	"fmt"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleGetDisplay handles the get_display tool — returns display info and cursor position.
func (s *MCPServer) cuaHandleGetDisplay(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	// Get displays
	displaysResp, err := s.client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		return grpcErrorResult(err, "get_display"), nil
	}

	// Get cursor position
	cursorResp, cursorErr := s.client.CaptureCursorPosition(ctx, &pb.CaptureCursorPositionRequest{})

	// Build display info
	var displayLines []string
	for _, d := range displaysResp.Displays {
		mainMark := ""
		if d.IsMain {
			mainMark = " (main)"
		}
		displayLines = append(displayLines, fmt.Sprintf(
			"- Display %d%s: %s, visible: %s, scale %.1f",
			d.DisplayId, mainMark,
			frameString(d.Frame),
			frameString(d.VisibleFrame),
			d.Scale,
		))
	}

	var result strings.Builder
	result.WriteString(fmt.Sprintf("Displays (%d):\n%s", len(displaysResp.Displays), strings.Join(displayLines, "\n")))

	if cursorErr == nil && cursorResp != nil {
		result.WriteString(fmt.Sprintf("\n\nCursor position: (%.0f, %.0f) on %s", cursorResp.X, cursorResp.Y, cursorResp.Display))
	}

	return textResult(result.String()), nil
}
