// Copyright 2025 Joseph Cumines
//
// Element tool handlers

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleFindElements handles the find_elements tool
func (s *MCPServer) handleFindElements(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Selector map[string]interface{} `json:"selector"`
		Parent   string                 `json:"parent"`
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
			Text: fmt.Sprintf("Found %d elements:\n%s", len(resp.Elements), strings.Join(lines, "\n")),
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
		actionsStr = strings.Join(elem.Actions, ", ")
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
			Content: []Content{{Type: "text", Text: "Click failed: operation was not successful"}},
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
			Content: []Content{{Type: "text", Text: "Write value failed: operation was not successful"}},
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
			Content: []Content{{Type: "text", Text: "Action failed: operation was not successful"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Performed %s on element: %s", params.Action, params.ElementID),
		}},
	}, nil
}

// handleTraverseAccessibility handles the traverse_accessibility tool
func (s *MCPServer) handleTraverseAccessibility(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name        string `json:"name"`
		VisibleOnly bool   `json:"visible_only"`
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

	resp, err := s.client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name:        params.Name,
		VisibleOnly: params.VisibleOnly,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to traverse accessibility tree: %v", err)}},
		}, nil
	}

	if len(resp.Elements) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No elements found in accessibility tree"}},
		}, nil
	}

	// Format elements hierarchically
	var lines []string
	for i, elem := range resp.Elements {
		role := elem.Role
		if role == "" {
			role = "(unknown)"
		}
		text := elem.GetText()
		if text == "" {
			text = "(no text)"
		} else if len(text) > 50 {
			text = text[:50] + "..."
		}
		lines = append(lines, fmt.Sprintf("%d. [%s] %s - %s", i+1, role, elem.ElementId, text))
	}

	statsInfo := ""
	if resp.Stats != nil {
		statsInfo = fmt.Sprintf("\nStats: %d elements, %d visible", resp.Stats.Count, resp.Stats.VisibleElementsCount)
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Accessibility tree for %s (%d elements):%s\n%s",
				resp.App, len(resp.Elements), statsInfo, strings.Join(lines, "\n")),
		}},
	}, nil
}

// handleFindRegionElements handles the find_region_elements tool
func (s *MCPServer) handleFindRegionElements(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Selector map[string]interface{} `json:"selector"`
		Parent   string                 `json:"parent"`
		X        float64                `json:"x"`
		Y        float64                `json:"y"`
		Width    float64                `json:"width"`
		Height   float64                `json:"height"`
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
			Content: []Content{{Type: "text", Text: "parent parameter is required"}},
		}, nil
	}

	// Build region
	region := &typepb.Region{
		X:      params.X,
		Y:      params.Y,
		Width:  params.Width,
		Height: params.Height,
	}

	// Build optional selector
	var selector *typepb.ElementSelector
	if params.Selector != nil {
		selector = &typepb.ElementSelector{}
		if role, ok := params.Selector["role"].(string); ok && role != "" {
			selector.Criteria = &typepb.ElementSelector_Role{Role: role}
		} else if text, ok := params.Selector["text"].(string); ok && text != "" {
			selector.Criteria = &typepb.ElementSelector_Text{Text: text}
		}
	}

	resp, err := s.client.FindRegionElements(ctx, &pb.FindRegionElementsRequest{
		Parent:   params.Parent,
		Region:   region,
		Selector: selector,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to find elements in region: %v", err)}},
		}, nil
	}

	if len(resp.Elements) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No elements found in region"}},
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
		} else if len(text) > 40 {
			text = text[:40] + "..."
		}
		lines = append(lines, fmt.Sprintf("%d. %s - %s (%s)", i+1, elem.ElementId, text, role))
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Found %d elements in region (%.0f,%.0f %.0fx%.0f):\n%s",
				len(resp.Elements), params.X, params.Y, params.Width, params.Height, strings.Join(lines, "\n")),
		}},
	}, nil
}

// handleWaitElement handles the wait_element tool (long-running operation)
func (s *MCPServer) handleWaitElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Selector     map[string]interface{} `json:"selector"`
		Parent       string                 `json:"parent"`
		Timeout      float64                `json:"timeout"`
		PollInterval float64                `json:"poll_interval"`
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
			Content: []Content{{Type: "text", Text: "parent parameter is required"}},
		}, nil
	}

	// Build selector
	var selector *typepb.ElementSelector
	if params.Selector != nil {
		selector = &typepb.ElementSelector{}
		if role, ok := params.Selector["role"].(string); ok && role != "" {
			selector.Criteria = &typepb.ElementSelector_Role{Role: role}
		} else if text, ok := params.Selector["text"].(string); ok && text != "" {
			selector.Criteria = &typepb.ElementSelector_Text{Text: text}
		} else if textContains, ok := params.Selector["text_contains"].(string); ok && textContains != "" {
			selector.Criteria = &typepb.ElementSelector_TextContains{TextContains: textContains}
		}
	}

	if selector == nil || selector.Criteria == nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "selector with role, text, or text_contains is required"}},
		}, nil
	}

	// Default timeout
	timeout := params.Timeout
	if timeout <= 0 {
		timeout = 30.0
	}

	pollInterval := params.PollInterval
	if pollInterval <= 0 {
		pollInterval = 0.5
	}

	op, err := s.client.WaitElement(ctx, &pb.WaitElementRequest{
		Parent:       params.Parent,
		Selector:     selector,
		Timeout:      timeout,
		PollInterval: pollInterval,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to start wait operation: %v", err)}},
		}, nil
	}

	// Poll operation until complete or context expires
	for !op.Done {
		select {
		case <-ctx.Done():
			return &ToolResult{
				IsError: true,
				Content: []Content{{Type: "text", Text: "Wait operation timed out"}},
			}, nil
		case <-time.After(500 * time.Millisecond):
			op, err = s.opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{Name: op.Name})
			if err != nil {
				return &ToolResult{
					IsError: true,
					Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to poll operation: %v", err)}},
				}, nil
			}
		}
	}

	if op.GetError() != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Wait failed: %s", op.GetError().Message)}},
		}, nil
	}

	// Parse response
	var resp pb.WaitElementResponse
	if err := op.GetResponse().UnmarshalTo(&resp); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to parse wait response: %v", err)}},
		}, nil
	}

	if resp.Element == nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "Element not found within timeout"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Element found: %s (%s) - %s",
				resp.Element.ElementId, resp.Element.Role, resp.Element.GetText()),
		}},
	}, nil
}

// handleWaitElementState handles the wait_element_state tool (long-running operation)
func (s *MCPServer) handleWaitElementState(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent       string  `json:"parent"`
		ElementID    string  `json:"element_id"`
		Condition    string  `json:"condition"`
		Value        string  `json:"value"`
		Timeout      float64 `json:"timeout"`
		PollInterval float64 `json:"poll_interval"`
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

	if params.Condition == "" {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: "condition parameter is required (enabled, focused, text_equals, text_contains)"}},
		}, nil
	}

	// Build state condition
	var condition *pb.StateCondition
	switch params.Condition {
	case "enabled":
		condition = &pb.StateCondition{Condition: &pb.StateCondition_Enabled{Enabled: true}}
	case "focused":
		condition = &pb.StateCondition{Condition: &pb.StateCondition_Focused{Focused: true}}
	case "text_equals":
		condition = &pb.StateCondition{Condition: &pb.StateCondition_TextEquals{TextEquals: params.Value}}
	case "text_contains":
		condition = &pb.StateCondition{Condition: &pb.StateCondition_TextContains{TextContains: params.Value}}
	default:
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Unknown condition: %s", params.Condition)}},
		}, nil
	}

	timeout := params.Timeout
	if timeout <= 0 {
		timeout = 30.0
	}

	pollInterval := params.PollInterval
	if pollInterval <= 0 {
		pollInterval = 0.5
	}

	op, err := s.client.WaitElementState(ctx, &pb.WaitElementStateRequest{
		Parent:       params.Parent,
		Target:       &pb.WaitElementStateRequest_ElementId{ElementId: params.ElementID},
		Condition:    condition,
		Timeout:      timeout,
		PollInterval: pollInterval,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to start wait operation: %v", err)}},
		}, nil
	}

	// Poll operation until complete
	for !op.Done {
		select {
		case <-ctx.Done():
			return &ToolResult{
				IsError: true,
				Content: []Content{{Type: "text", Text: "Wait operation timed out"}},
			}, nil
		case <-time.After(500 * time.Millisecond):
			op, err = s.opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{Name: op.Name})
			if err != nil {
				return &ToolResult{
					IsError: true,
					Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to poll operation: %v", err)}},
				}, nil
			}
		}
	}

	if op.GetError() != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Wait failed: %s", op.GetError().Message)}},
		}, nil
	}

	// Parse response
	var resp pb.WaitElementStateResponse
	if err := op.GetResponse().UnmarshalTo(&resp); err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to parse wait response: %v", err)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Element %s reached state '%s': %s (%s)",
				params.ElementID, params.Condition, resp.Element.GetText(), resp.Element.Role),
		}},
	}, nil
}

// handleGetElementActions handles the get_element_actions tool
func (s *MCPServer) handleGetElementActions(call *ToolCall) (*ToolResult, error) {
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

	resp, err := s.client.GetElementActions(ctx, &pb.GetElementActionsRequest{
		Name: params.Name,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to get element actions: %v", err)}},
		}, nil
	}

	if len(resp.Actions) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: fmt.Sprintf("No actions available for element: %s", params.Name)}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Available actions for %s:\n%s", params.Name, strings.Join(resp.Actions, ", ")),
		}},
	}, nil
}

// handleWatchAccessibility handles the watch_accessibility tool for streaming accessibility changes
func (s *MCPServer) handleWatchAccessibility(call *ToolCall) (*ToolResult, error) {
	// Note: This tool initiates an accessibility watch stream.
	// In a full implementation, this would use server-sent events or similar
	// streaming mechanism. For now, we return a single snapshot with guidance.

	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Name         string  `json:"name"`
		PollInterval float64 `json:"poll_interval"`
		VisibleOnly  bool    `json:"visible_only"`
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

	// For HTTP transport with SSE, streaming will be handled by transport layer.
	// For stdio, we use a polling approach.
	stream, err := s.client.WatchAccessibility(ctx, &pb.WatchAccessibilityRequest{
		Name:         params.Name,
		PollInterval: params.PollInterval,
		VisibleOnly:  params.VisibleOnly,
	})
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to start accessibility watch: %v", err)}},
		}, nil
	}

	// Receive first message to confirm stream is active
	msg, err := stream.Recv()
	if err != nil {
		return &ToolResult{
			IsError: true,
			Content: []Content{{Type: "text", Text: fmt.Sprintf("Failed to receive accessibility update: %v", err)}},
		}, nil
	}

	var changes []string
	if len(msg.Added) > 0 {
		changes = append(changes, fmt.Sprintf("%d elements added", len(msg.Added)))
	}
	if len(msg.Removed) > 0 {
		changes = append(changes, fmt.Sprintf("%d elements removed", len(msg.Removed)))
	}
	if len(msg.Modified) > 0 {
		changes = append(changes, fmt.Sprintf("%d elements modified", len(msg.Modified)))
	}

	if len(changes) == 0 {
		return &ToolResult{
			Content: []Content{{Type: "text", Text: "No accessibility changes detected"}},
		}, nil
	}

	return &ToolResult{
		Content: []Content{{
			Type: "text",
			Text: fmt.Sprintf("Accessibility changes for %s: %s\n\nNote: For continuous streaming, use stream_observations tool instead.", params.Name, strings.Join(changes, ", ")),
		}},
	}, nil
}
