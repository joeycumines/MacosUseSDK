// Copyright 2025 Joseph Cumines
//
// Window tool handlers — focus_window, move_window, resize_window, list_windows

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleFocusWindow handles the focus_window tool — bring a window to the front.
func (s *MCPServer) cuaHandleFocusWindow(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Window string `json:"window"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Window == "" {
		return errorResult("window parameter is required"), nil
	}

	w, err := s.client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: params.Window})
	if err != nil {
		return grpcErrorResult(err, "focus_window"), nil
	}

	return textResultf("Focused window: %s (%s)", w.Title, w.Name), nil
}

// handleMoveWindow handles the move_window tool — move a window to new coordinates.
// Coordinates use Global Display Coordinates (top-left origin).
func (s *MCPServer) cuaHandleMoveWindow(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Window string  `json:"window"`
		X      float64 `json:"x"`
		Y      float64 `json:"y"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Window == "" {
		return errorResult("window parameter is required"), nil
	}

	if math.IsNaN(params.X) || math.IsInf(params.X, 0) || math.IsNaN(params.Y) || math.IsInf(params.Y, 0) {
		return errorResult("x and y must be finite numbers"), nil
	}

	w, err := s.client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: params.Window,
		X:    params.X,
		Y:    params.Y,
	})
	if err != nil {
		return grpcErrorResult(err, "move_window"), nil
	}

	return textResultf("Moved window %s to %s", w.Title, boundsPosition(w.Bounds)), nil
}

// handleResizeWindow handles the resize_window tool — resize a window.
func (s *MCPServer) cuaHandleResizeWindow(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Window string  `json:"window"`
		Width  float64 `json:"width"`
		Height float64 `json:"height"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Window == "" {
		return errorResult("window parameter is required"), nil
	}

	if params.Width <= 0 || params.Height <= 0 {
		return errorResult("width and height must be positive"), nil
	}
	if math.IsNaN(params.Width) || math.IsInf(params.Width, 0) || math.IsNaN(params.Height) || math.IsInf(params.Height, 0) {
		return errorResult("width and height must be finite numbers"), nil
	}

	w, err := s.client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   params.Window,
		Width:  params.Width,
		Height: params.Height,
	})
	if err != nil {
		return grpcErrorResult(err, "resize_window"), nil
	}

	return textResultf("Resized window %s to %s", w.Title, boundsSize(w.Bounds)), nil
}

// handleListWindows handles the list_windows tool — list open windows.
func (s *MCPServer) cuaHandleListWindows(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		App       string `json:"app"`
		PageSize  int32  `json:"page_size"`
		PageToken string `json:"page_token"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.PageSize < 0 {
		return errorResult("page_size must be non-negative"), nil
	}

	resp, err := s.client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:    params.App,
		PageSize:  params.PageSize,
		PageToken: params.PageToken,
	})
	if err != nil {
		return grpcErrorResult(err, "list_windows"), nil
	}

	if len(resp.Windows) == 0 {
		return textResult("No windows found"), nil
	}

	var lines []string
	for _, w := range resp.Windows {
		visibleMark := ""
		if w.Visible {
			visibleMark = " [visible]"
		}
		lines = append(lines, fmt.Sprintf("- %s (%s)%s @ %s",
			w.Title, w.Name, visibleMark, boundsString(w.Bounds)))
	}

	resultText := fmt.Sprintf("Found %d windows:\n%s", len(resp.Windows), strings.Join(lines, "\n"))
	if resp.NextPageToken != "" {
		resultText += fmt.Sprintf("\n\nMore results available. Use page_token: %s", resp.NextPageToken)
	}

	return textResult(resultText), nil
}
