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
		Parent    string `json:"parent"`
		PageSize  int32  `json:"page_size"`
		PageToken string `json:"page_token"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	resp, err := s.client.ListWindows(ctx, &pb.ListWindowsRequest{
		Parent:    params.Parent,
		PageSize:  params.PageSize,
		PageToken: params.PageToken,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list windows: %v", err)}},
		}, nil
	}

	if len(resp.Windows) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No windows found"}},
		}, nil
	}

	var lines []string
	for _, w := range resp.Windows {
		visibleMark := ""
		if w.Visible {
			visibleMark = " [visible]"
		}
		lines = append(lines, fmt.Sprintf("- %s (%s)%s @ (%.0f, %.0f) %.0fx%.0f",
			w.Title, w.Name, visibleMark, w.Bounds.X, w.Bounds.Y, w.Bounds.Width, w.Bounds.Height))
	}

	resultText := fmt.Sprintf("Found %d windows:\n%s", len(resp.Windows), joinStrings(lines, "\n"))
	if resp.NextPageToken != "" {
		resultText += fmt.Sprintf("\n\nMore results available. Use page_token: %s", resp.NextPageToken)
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: resultText}},
	}, nil
}

// handleGetWindow handles the get_window tool
func (s *MCPServer) handleGetWindow(call *ToolCall) (*ToolResult, error) {
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
			Content: []Content{{Type: "text", Text: "name parameter is required (e.g., applications/123/windows/456)"}},
		}, nil
	}

	w, err := s.client.GetWindow(ctx, &pb.GetWindowRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get window: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf(`Window: %s
  Title: %s
  Position: (%.0f, %.0f)
  Size: %.0fx%.0f
  Visible: %v
  Z-Index: %d
  Bundle ID: %s`,
				w.Name, w.Title, w.Bounds.X, w.Bounds.Y, w.Bounds.Width, w.Bounds.Height,
				w.Visible, w.ZIndex, w.BundleId),
		}},
	}, nil
}

// handleFocusWindow handles the focus_window tool
func (s *MCPServer) handleFocusWindow(call *ToolCall) (*ToolResult, error) {
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
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	w, err := s.client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to focus window: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Focused window: %s (%s)", w.Title, w.Name)}},
	}, nil
}

// handleMoveWindow handles the move_window tool
func (s *MCPServer) handleMoveWindow(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name string  `json:"name"`
		X    float64 `json:"x"`
		Y    float64 `json:"y"`
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
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	w, err := s.client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: params.Name,
		X:    params.X,
		Y:    params.Y,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to move window: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Moved window %s to (%.0f, %.0f)", w.Title, w.Bounds.X, w.Bounds.Y),
		}},
	}, nil
}

// handleResizeWindow handles the resize_window tool
func (s *MCPServer) handleResizeWindow(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name   string  `json:"name"`
		Width  float64 `json:"width"`
		Height float64 `json:"height"`
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
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	if params.Width <= 0 || params.Height <= 0 {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "width and height must be positive"}},
		}, nil
	}

	w, err := s.client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   params.Name,
		Width:  params.Width,
		Height: params.Height,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to resize window: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Resized window %s to %.0fx%.0f", w.Title, w.Bounds.Width, w.Bounds.Height),
		}},
	}, nil
}

// handleMinimizeWindow handles the minimize_window tool
func (s *MCPServer) handleMinimizeWindow(call *ToolCall) (*ToolResult, error) {
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
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	w, err := s.client.MinimizeWindow(ctx, &pb.MinimizeWindowRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to minimize window: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Minimized window: %s", w.Title)}},
	}, nil
}

// handleRestoreWindow handles the restore_window tool
func (s *MCPServer) handleRestoreWindow(call *ToolCall) (*ToolResult, error) {
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
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	w, err := s.client.RestoreWindow(ctx, &pb.RestoreWindowRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to restore window: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Restored window: %s", w.Title)}},
	}, nil
}

// handleCloseWindow handles the close_window tool
func (s *MCPServer) handleCloseWindow(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name  string `json:"name"`
		Force bool   `json:"force"`
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
			Content: []Content{{Type: "text", Text: "name parameter is required"}},
		}, nil
	}

	resp, err := s.client.CloseWindow(ctx, &pb.CloseWindowRequest{
		Name:  params.Name,
		Force: params.Force,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to close window: %v", err)}},
		}, nil
	}

	if !resp.Success {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Window close operation was not successful"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: fmt.Sprintf("Closed window: %s", params.Name)}},
	}, nil
}
