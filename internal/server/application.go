// Copyright 2025 Joseph Cumines
//
// Application tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/server/tools"
)

// handleOpenApplication handles the open_application tool
func (s *MCPServer) handleOpenApplication(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// ID is the application identifier (name, bundle ID, or path)
		// Examples: "Calculator", "com.apple.calculator", "/Applications/Calculator.app"
		ID string `json:"id"`
		// Background opens app without stealing focus when true
		Background bool `json:"background"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.ID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "id parameter is required (application name, bundle ID, or path)"}},
		}, nil
	}

	// Start the long-running operation
	op, err := s.client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id:         params.ID,
		Background: params.Background,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to open application: %v", err)}},
		}, nil
	}

	// If the operation completed immediately, extract result
	if !op.Done {
		// Poll until complete
		opsClient := &tools.OperationClient{Client: s.opsClient}
		if err := tools.PollUntilComplete(ctx, opsClient, op.Name, 100*time.Millisecond); err != nil {
			return &ToolResult{
				IsError: true,
				Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed waiting for application to open: %v", err)}},
			}, nil
		}

		// Get the final operation state
		op, err = s.opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{Name: op.Name})
		if err != nil {
			return &ToolResult{
				IsError: true,
				Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get operation result: %v", err)}},
			}, nil
		}
	}

	// Check for operation error
	if opErr := op.GetError(); opErr != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Application open failed: %s", opErr.Message)}},
		}, nil
	}

	// Unmarshal the response
	var response pb.OpenApplicationResponse
	if result := op.GetResponse(); result != nil {
		if err := result.UnmarshalTo(&response); err != nil {
			return &ToolResult{
				IsError: true,
				Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to parse response: %v", err)}},
			}, nil
		}
	}

	app := response.Application
	if app == nil {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Application opened: %s", params.ID)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Application opened:\n  Name: %s\n  Display Name: %s\n  PID: %d",
				app.Name, app.DisplayName, app.Pid),
		}},
	}, nil
}

// handleListApplications handles the list_applications tool
func (s *MCPServer) handleListApplications(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		PageSize  int32  `json:"page_size"`
		PageToken string `json:"page_token"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.PageSize < 0 {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "page_size must be non-negative"}},
		}, nil
	}

	resp, err := s.client.ListApplications(ctx, &pb.ListApplicationsRequest{
		PageSize:  params.PageSize,
		PageToken: params.PageToken,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list applications: %v", err)}},
		}, nil
	}

	if len(resp.Applications) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No applications currently tracked"}},
		}, nil
	}

	var lines []string
	for _, app := range resp.Applications {
		lines = append(lines, fmt.Sprintf("- %s (%s, PID: %d)", app.DisplayName, app.Name, app.Pid))
	}

	result := fmt.Sprintf("Found %d applications:\n%s", len(resp.Applications), strings.Join(lines, "\n"))
	if resp.NextPageToken != "" {
		result += fmt.Sprintf("\n\nMore results available. Use page_token: %s", resp.NextPageToken)
	}

	return &ToolResult{
		Content: []Content{{Type: "text", Text: result}},
	}, nil
}

// handleGetApplication handles the get_application tool
func (s *MCPServer) handleGetApplication(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Name is the resource name, e.g., "applications/1234"
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
			Content: []Content{{Type: "text", Text: "name parameter is required (e.g., 'applications/1234')"}},
		}, nil
	}

	resp, err := s.client.GetApplication(ctx, &pb.GetApplicationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get application: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Application:\n  Name: %s\n  Display Name: %s\n  PID: %d",
				resp.Name, resp.DisplayName, resp.Pid),
		}},
	}, nil
}

// handleDeleteApplication handles the delete_application tool
func (s *MCPServer) handleDeleteApplication(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		// Name is the resource name, e.g., "applications/1234"
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
			Content: []Content{{Type: "text", Text: "name parameter is required (e.g., 'applications/1234')"}},
		}, nil
	}

	_, err := s.client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to delete application: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Application %s deleted (stopped tracking)", params.Name),
		}},
	}, nil
}
