// Copyright 2025 Joseph Cumines
//
// Element tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
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
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	// Build selector from params - selector uses oneof, so we set one criterion at a time
	var selector *typepb.ElementSelector
	if params.Selector != nil {
		selector = &typepb.ElementSelector{}
		// Priority: role, then text, then text_contains
		if role, ok := params.Selector["role"].(string); ok && role != "" {
			selector.Criteria = &typepb.ElementSelector_Role{Role: role}
		} else if text, ok := params.Selector["text"].(string); ok && text != "" {
			selector.Criteria = &typepb.ElementSelector_Text{Text: text}
		} else if textContains, ok := params.Selector["text_contains"].(string); ok && textContains != "" {
			selector.Criteria = &typepb.ElementSelector_TextContains{TextContains: textContains}
		}
	}

	resp, err := s.client.FindElements(ctx, &pb.FindElementsRequest{
		Parent:   params.Parent,
		Selector: selector,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to find elements: %v", err)}},
		}, nil
	}

	if len(resp.Elements) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No elements found matching selector"}},
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
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Found %d elements:\n%s", len(resp.Elements), joinStrings(lines, "\n")),
		}},
	}, nil
}

// handleGetElement handles the get_element tool
func (s *MCPServer) handleGetElement(call *ToolCall) (*ToolResult, error) {
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

	elem, err := s.client.GetElement(ctx, &pb.GetElementRequest{Name: params.Name})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get element: %v", err)}},
		}, nil
	}

	// Format element properties - Element has x,y,width,height directly, not Bounds
	boundsStr := "unknown"
	if elem.X != nil && elem.Y != nil && elem.Width != nil && elem.Height != nil {
		boundsStr = fmt.Sprintf("(%.0f, %.0f) %.0fx%.0f",
			elem.GetX(), elem.GetY(), elem.GetWidth(), elem.GetHeight())
	}

	actionsStr := "none"
	if len(elem.Actions) > 0 {
		actionsStr = joinStrings(elem.Actions, ", ")
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf(`Element: %s
  Role: %s
  Text: %s
  Bounds: %s
  Enabled: %v
  Focused: %v
  Actions: %s`,
				elem.ElementId, elem.Role, elem.GetText(),
				boundsStr, elem.GetEnabled(), elem.GetFocused(), actionsStr),
		}},
	}, nil
}

// handleClickElement handles the click_element tool
func (s *MCPServer) handleClickElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent    string `json:"parent"`
		ElementID string `json:"element_id"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Parent == "" || params.ElementID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "parent and element_id parameters are required"}},
		}, nil
	}

	resp, err := s.client.ClickElement(ctx, &pb.ClickElementRequest{
		Parent: params.Parent,
		Target: &pb.ClickElementRequest_ElementId{ElementId: params.ElementID},
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to click element: %v", err)}},
		}, nil
	}

	if !resp.Success {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Click element operation was not successful"}},
		}, nil
	}

	elemInfo := params.ElementID
	if resp.Element != nil {
		elemInfo = fmt.Sprintf("%s (%s)", resp.Element.ElementId, resp.Element.Role)
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Clicked element: %s", elemInfo),
		}},
	}, nil
}

// handleWriteElementValue handles the write_element_value tool
func (s *MCPServer) handleWriteElementValue(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent    string `json:"parent"`
		ElementID string `json:"element_id"`
		Value     string `json:"value"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Parent == "" || params.ElementID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "parent and element_id parameters are required"}},
		}, nil
	}

	resp, err := s.client.WriteElementValue(ctx, &pb.WriteElementValueRequest{
		Parent: params.Parent,
		Target: &pb.WriteElementValueRequest_ElementId{ElementId: params.ElementID},
		Value:  params.Value,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to write element value: %v", err)}},
		}, nil
	}

	if !resp.Success {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Write element value operation was not successful"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Set value for element: %s", params.ElementID),
		}},
	}, nil
}

// handlePerformElementAction handles the perform_element_action tool
func (s *MCPServer) handlePerformElementAction(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent    string `json:"parent"`
		ElementID string `json:"element_id"`
		Action    string `json:"action"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Invalid parameters: %v", err)}},
		}, nil
	}

	if params.Parent == "" || params.ElementID == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "parent and element_id parameters are required"}},
		}, nil
	}

	if params.Action == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "action parameter is required"}},
		}, nil
	}

	resp, err := s.client.PerformElementAction(ctx, &pb.PerformElementActionRequest{
		Parent: params.Parent,
		Target: &pb.PerformElementActionRequest_ElementId{ElementId: params.ElementID},
		Action: params.Action,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to perform action: %v", err)}},
		}, nil
	}

	if !resp.Success {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Perform element action operation was not successful"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Performed %s on element: %s", params.Action, params.ElementID),
		}},
	}, nil
}
