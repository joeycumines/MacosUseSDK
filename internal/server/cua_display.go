// Copyright 2025 Joseph Cumines
//
// Display tool handler — get_display (combines ListDisplays + CaptureCursorPosition)

package server

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

// handleGetDisplay handles the get_display tool — returns display info and cursor position.
func (s *MCPServer) cuaHandleGetDisplay(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	displays, err := loadAndValidateDisplayTopology(ctx, s.client)
	if err != nil {
		if _, ok := errors.AsType[*displayResponseValidationError](err); ok {
			return errorResultf("Invalid display response: %v", err), nil
		}
		return grpcErrorResult(err, "get_display"), nil
	}

	cursorResp, cursorErr := s.client.CaptureCursorPosition(ctx, &pb.CaptureCursorPositionRequest{})
	if cursorErr != nil {
		return grpcErrorResult(cursorErr, "get_display"), nil
	}
	if err := validateCursorTopology(cursorResp, displays); err != nil {
		return errorResultf("Invalid cursor response: %v", err), nil
	}

	var displayLines []string
	for _, display := range displays {
		mainMark := ""
		if display.IsMain {
			mainMark = ", main"
		}
		displayLines = append(displayLines, fmt.Sprintf(
			"- %s (id %d%s): %s, visible: %s, scale %s",
			display.Name,
			display.DisplayId,
			mainMark,
			frameString(display.Frame),
			frameString(display.VisibleFrame),
			strconv.FormatFloat(display.Scale, 'g', -1, 64),
		))
	}

	var result strings.Builder
	result.WriteString(fmt.Sprintf("Displays (%d):\n%s", len(displays), strings.Join(displayLines, "\n")))
	result.WriteString(fmt.Sprintf(
		"\n\nCursor position: (%s, %s) on %s",
		strconv.FormatFloat(cursorResp.X, 'g', -1, 64),
		strconv.FormatFloat(cursorResp.Y, 'g', -1, 64),
		cursorResp.Display,
	))

	return textResult(result.String()), nil
}
