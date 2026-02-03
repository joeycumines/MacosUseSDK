// Copyright 2025 Joseph Cumines
//
// Observation tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleCreateObservation handles the create_observation tool
func (s *MCPServer) handleCreateObservation(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent       string   `json:"parent"`
		Type         string   `json:"type"`
		Roles        []string `json:"roles"`
		Attributes   []string `json:"attributes"`
		PollInterval float64  `json:"poll_interval"`
		VisibleOnly  bool     `json:"visible_only"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Parent == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "parent parameter is required (e.g., applications/{id})"}},
		}, nil
	}

	// Map observation type string to enum
	obsType := pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES
	switch params.Type {
	case "element_changes", "element":
		obsType = pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES
	case "window_changes", "window":
		obsType = pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES
	case "application_changes", "application":
		obsType = pb.ObservationType_OBSERVATION_TYPE_APPLICATION_CHANGES
	case "attribute_changes", "attribute":
		obsType = pb.ObservationType_OBSERVATION_TYPE_ATTRIBUTE_CHANGES
	case "tree_changes", "tree":
		obsType = pb.ObservationType_OBSERVATION_TYPE_TREE_CHANGES
	}

	observation := &pb.Observation{
		Type: obsType,
	}

	// Add filter if specified
	if params.VisibleOnly || params.PollInterval > 0 || len(params.Roles) > 0 || len(params.Attributes) > 0 {
		observation.Filter = &pb.ObservationFilter{
			PollInterval: params.PollInterval,
			VisibleOnly:  params.VisibleOnly,
			Roles:        params.Roles,
			Attributes:   params.Attributes,
		}
	}

	op, err := s.client.CreateObservation(ctx, &pb.CreateObservationRequest{
		Parent:      params.Parent,
		Observation: observation,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to create observation: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Created observation operation: %s\nDone: %v", op.Name, op.Done),
		}},
	}, nil
}

// handleGetObservation handles the get_observation tool
func (s *MCPServer) handleGetObservation(call *ToolCall) (*ToolResult, error) {
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

	obs, err := s.client.GetObservation(ctx, &pb.GetObservationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get observation: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf(`Observation: %s
  Type: %s
  State: %s
  Created: %v`,
				obs.Name, obs.Type.String(), obs.State.String(), obs.CreateTime),
		}},
	}, nil
}

// handleListObservations handles the list_observations tool
func (s *MCPServer) handleListObservations(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent string `json:"parent"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	resp, err := s.client.ListObservations(ctx, &pb.ListObservationsRequest{
		Parent: params.Parent,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to list observations: %v", err)}},
		}, nil
	}

	if len(resp.Observations) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No observations found"}},
		}, nil
	}

	var lines []string
	for _, obs := range resp.Observations {
		lines = append(lines, fmt.Sprintf("- %s (%s, %s)", obs.Name, obs.Type.String(), obs.State.String()))
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Found %d observations:\n%s", len(resp.Observations), joinStrings(lines, "\n")),
		}},
	}, nil
}

// handleCancelObservation handles the cancel_observation tool
func (s *MCPServer) handleCancelObservation(call *ToolCall) (*ToolResult, error) {
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

	obs, err := s.client.CancelObservation(ctx, &pb.CancelObservationRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to cancel observation: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Cancelled observation: %s (state: %s)", obs.Name, obs.State.String()),
		}},
	}, nil
}
