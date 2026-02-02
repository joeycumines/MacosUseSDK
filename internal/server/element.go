// Copyright 2025 Joseph Cumines
//
// Element tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleFindElements handles the find_elements tool
func (s *MCPServer) handleFindElements(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent   string                 `json:"parent"`
		Selector map[string]interface{} `json:"selector"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return nil, fmt.Errorf("failed to parse arguments: %w", err)
	}

	resp, err := s.client.FindElements(ctx, &pb.FindElementsRequest{
		Parent:   params.Parent,
		Selector: nil, // Simplified: just pass nil for now
	})
	if err != nil {
		return nil, fmt.Errorf("failed to find elements: %w", err)
	}

	if len(resp.Elements) == 0 {
		return &ToolResult{
			Content: []Content{
				{
					Type: "text",
					Text: "No elements found",
				},
			},
		}, nil
	}

	var lines []string
	for i, elem := range resp.Elements {
		role := elem.Role
		if role == "" {
			role = "(unknown)"
		}
		text := elem.GetText()
		if text == "" {
			text = "(no text)"
		}
		lines = append(lines, fmt.Sprintf("%d. %s - %s (%s)", i+1, elem.ElementId, text, role))
	}

	return &ToolResult{
		Content: []Content{
			{
				Type: "text",
				Text: fmt.Sprintf("Found %d elements:\n%s", len(resp.Elements), joinStrings(lines, "\n")),
			},
		},
	}, nil
}

// parseSelector is not used - simplified implementation above
