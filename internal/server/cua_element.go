// Copyright 2025 Joseph Cumines
//
// Element tool handlers — find_elements, click_element, type_element, read_element

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// handleFindElements handles the find_elements tool — find UI elements by criteria.
// Uses flat parameters (role, text, text_contains) instead of nested selector object.
func (s *MCPServer) cuaHandleFindElements(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent       string `json:"parent"`
		Role         string `json:"role"`
		Text         string `json:"text"`
		TextContains string `json:"text_contains"`
		ForceRefresh bool   `json:"force_refresh"`
		PageSize     int32  `json:"page_size"`
		PageToken    string `json:"page_token"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Parent == "" {
		return errorResult("parent parameter is required"), nil
	}
	if params.PageSize < 0 {
		return errorResult("page_size must be non-negative"), nil
	}

	// Build selector from flat params — selector uses oneof, so we set one criterion
	var selector *typepb.ElementSelector
	if params.Role != "" || params.Text != "" || params.TextContains != "" {
		selector = &typepb.ElementSelector{}
		switch {
		case params.Role != "":
			selector.Criteria = &typepb.ElementSelector_Role{Role: params.Role}
		case params.Text != "":
			selector.Criteria = &typepb.ElementSelector_Text{Text: params.Text}
		case params.TextContains != "":
			selector.Criteria = &typepb.ElementSelector_TextContains{TextContains: params.TextContains}
		}
	}

	// Warn if multiple criteria were provided (only one is actually used due to oneof)
	providedCriteria := 0
	if params.Role != "" {
		providedCriteria++
	}
	if params.Text != "" {
		providedCriteria++
	}
	if params.TextContains != "" {
		providedCriteria++
	}
	var criteriaWarning string
	if providedCriteria > 1 {
		// Match the selector priority: role > text > text_contains
		criteriaName := "role"
		if params.Role == "" && params.Text != "" {
			criteriaName = "text"
		} else if params.Role == "" && params.Text == "" && params.TextContains != "" {
			criteriaName = "text_contains"
		}
		criteriaWarning = fmt.Sprintf("\n\nNote: Only one search criterion is supported at a time. Using %s. Other criteria were ignored.", criteriaName)
	}

	resp, err := s.client.FindElements(ctx, &pb.FindElementsRequest{
		Parent:       params.Parent,
		Selector:     selector,
		ForceRefresh: params.ForceRefresh,
		PageSize:     params.PageSize,
		PageToken:    params.PageToken,
	})
	if err != nil {
		return grpcErrorResult(err, "find_elements"), nil
	}

	if len(resp.Elements) == 0 {
		return textResult("No elements found matching criteria"), nil
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

	result := fmt.Sprintf("Found %d elements:\n%s", len(resp.Elements), strings.Join(lines, "\n"))
	if criteriaWarning != "" {
		result += criteriaWarning
	}
	if resp.NextPageToken != "" {
		result += fmt.Sprintf("\n\nMore results available. Use page_token: %s", resp.NextPageToken)
	}
	return textResult(result), nil
}

// handleClickElement handles the click_element tool — click a UI element via accessibility APIs.
// Reliability improvements built into handler (NOT parameters):
//  1. Center-click: Always clicks geometric center of element bounds
//  2. Auto focus acquisition: Brings element's window forward before clicking
func (s *MCPServer) cuaHandleClickElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent  string `json:"parent"`
		Element string `json:"element"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Parent == "" || params.Element == "" {
		return errorResult("parent and element parameters are required"), nil
	}

	// Step 1: Get element details to find bounds for center-click.
	// Element resource names are canonical (applications/{pid}/elements/{id}),
	// even if the parent is a window path.
	elemName := elementResourceName(params.Parent, params.Element)
	elem, err := s.client.GetElement(ctx, &pb.GetElementRequest{Name: elemName})
	if err != nil {
		// Fall back to AX click if we can't get bounds
		return s.clickElementFallback(ctx, params.Parent, params.Element)
	}

	// Step 2: Calculate center point from element bounds
	centerX, centerY, hasBounds := elementCenter(elem)
	if !hasBounds {
		// No bounds available — fall back to AX click
		return s.clickElementFallback(ctx, params.Parent, params.Element)
	}

	// Step 3: Focus acquisition — bring the element's window forward
	// Extract window name from parent (e.g., "applications/123/windows/456")
	if windowName := extractWindowFromParent(params.Parent); windowName != "" {
		_, _ = s.client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: windowName})
		// Ignore focus errors — best-effort focus acquisition
	}

	// Step 4: Click at element center using coordinate-based click
	_, clickErr := s.client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: defaultApplicationParent,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_Click{
					Click: &pb.MouseClick{
						Position:   &typepb.Point{X: centerX, Y: centerY},
						ClickType:  pb.MouseClick_CLICK_TYPE_LEFT,
						ClickCount: 1,
					},
				},
			},
		},
	})
	if clickErr != nil {
		// Coordinate click failed — fall back to AX click
		return s.clickElementFallback(ctx, params.Parent, params.Element)
	}

	elemInfo := params.Element
	if elem.Role != "" {
		elemInfo = fmt.Sprintf("%s (%s)", params.Element, elem.Role)
	}

	return textResultf("Clicked element at center (%.0f, %.0f): %s", centerX, centerY, elemInfo), nil
}

// clickElementFallback falls back to AX-based ClickElement RPC with structured error messages.
func (s *MCPServer) clickElementFallback(ctx context.Context, parent, elementID string) (*ToolResult, error) {
	resp, err := s.client.ClickElement(ctx, &pb.ClickElementRequest{
		Parent: parent,
		Target: &pb.ClickElementRequest_ElementId{ElementId: elementID},
	})
	if err != nil {
		errMsg := err.Error()
		if strings.Contains(errMsg, "AXPress") || strings.Contains(errMsg, "not available") {
			role := getElementRole(ctx, s, parent, elementID)
			return errorResultf("Element does not support clicking. Role: %s. Use find_elements to discover clickable elements.", role), nil
		}
		if strings.Contains(errMsg, "AX error") || strings.Contains(errMsg, "cannot complete") {
			return errorResultf("Element belongs to unfocused application. Try focus_window first, then retry. Error: %s", errMsg), nil
		}
		return grpcErrorResult(err, "click_element"), nil
	}

	if !resp.Success {
		role := "(unknown)"
		if resp.Element != nil && resp.Element.Role != "" {
			role = resp.Element.Role
		}
		return errorResultf("click_element: operation was not successful. Element role: %s. Use find_elements to discover clickable elements.", role), nil
	}

	elemInfo := elementID
	if resp.Element != nil {
		elemInfo = fmt.Sprintf("%s (%s)", resp.Element.ElementId, resp.Element.Role)
	}

	return textResultf("Clicked element (AX fallback): %s", elemInfo), nil
}

// elementCenter calculates the geometric center of an element from its bounds.
func elementCenter(elem *typepb.Element) (x, y float64, ok bool) {
	ex := elem.GetX()
	ey := elem.GetY()
	ew := elem.GetWidth()
	eh := elem.GetHeight()

	if ew <= 0 || eh <= 0 {
		return 0, 0, false
	}

	return ex + ew/2, ey + eh/2, true
}

// getElementRole attempts to fetch an element's role for error context.
func getElementRole(ctx context.Context, s *MCPServer, parent, elementID string) string {
	elemName := elementResourceName(parent, elementID)
	elem, err := s.client.GetElement(ctx, &pb.GetElementRequest{Name: elemName})
	if err != nil || elem.Role == "" {
		return "(unknown)"
	}
	return elem.Role
}

// extractWindowFromParent extracts a window resource name from a parent string.
// e.g., "applications/123/windows/456" → "applications/123/windows/456"
// e.g., "applications/123" → ""
func extractWindowFromParent(parent string) string {
	if strings.Contains(parent, "/windows/") {
		return parent
	}
	return ""
}

// parseParentPID extracts the application PID from a resource-name parent string.
// Both "applications/123" and "applications/123/windows/456" return pid 123.
// Returns 0 if the parent does not start with a valid application resource name.
func parseParentPID(parent string) int64 {
	parts := strings.Split(parent, "/")
	if len(parts) < 2 || parts[0] != "applications" {
		return 0
	}
	pid, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0
	}
	return pid
}

// elementResourceName builds a canonical element resource name from a parent
// (application or window) and the element id. Window-scoped parents use the
// application PID because element resources are always scoped per application.
func elementResourceName(parent, elementID string) string {
	if pid := parseParentPID(parent); pid != 0 {
		return fmt.Sprintf("applications/%d/elements/%s", pid, elementID)
	}
	return fmt.Sprintf("%s/elements/%s", parent, elementID)
}

// handleTypeElement handles the type_element tool — set value of a UI element with auto-focus.
func (s *MCPServer) handleTypeElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent  string `json:"parent"`
		Element string `json:"element"`
		Text    string `json:"text"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Parent == "" || params.Element == "" {
		return errorResult("parent and element parameters are required"), nil
	}

	if params.Text == "" {
		return errorResult("text parameter is required"), nil
	}

	if errResult := validateInputLen(params.Text, maxInputTextLen, "text"); errResult != nil {
		return errResult, nil
	}

	// Auto-focus: bring the element's window forward before typing
	if windowName := extractWindowFromParent(params.Parent); windowName != "" {
		_, _ = s.client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: windowName})
		// Best-effort focus acquisition
	}

	resp, err := s.client.WriteElementValue(ctx, &pb.WriteElementValueRequest{
		Parent: params.Parent,
		Target: &pb.WriteElementValueRequest_ElementId{ElementId: params.Element},
		Value:  params.Text,
	})
	if err != nil {
		errMsg := err.Error()
		if strings.Contains(errMsg, "not editable") || strings.Contains(errMsg, "AXValue") {
			role := getElementRole(ctx, s, params.Parent, params.Element)
			return errorResultf("Element is not editable. Role: %s. Find an AXTextField or AXTextArea element instead.", role), nil
		}
		return grpcErrorResult(err, "type_element"), nil
	}

	if !resp.Success {
		role := getElementRole(ctx, s, params.Parent, params.Element)
		return errorResultf("type_element: operation was not successful. Element may not be editable. Role: %s. Find an AXTextField or AXTextArea element instead.", role), nil
	}

	return textResultf("Typed into element %s: %d characters", params.Element, len(params.Text)), nil
}

// handleReadElement handles the read_element tool — get detailed element info.
// Combines GetElement + GetElementActions into a single response.
func (s *MCPServer) handleReadElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Element string `json:"element"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Element == "" {
		return errorResult("element parameter is required"), nil
	}

	// Get element details
	elem, err := s.client.GetElement(ctx, &pb.GetElementRequest{Name: params.Element})
	if err != nil {
		return grpcErrorResult(err, "read_element"), nil
	}

	// Get element actions
	actionsResp, actionsErr := s.client.GetElementActions(ctx, &pb.GetElementActionsRequest{
		Name: params.Element,
	})

	// Build result
	boundsStr := "unknown"
	if elem.GetWidth() > 0 || elem.GetHeight() > 0 {
		boundsStr = fmt.Sprintf("(%.0f, %.0f) %.0fx%.0f",
			elem.GetX(), elem.GetY(), elem.GetWidth(), elem.GetHeight())
	}

	actionsStr := "none"
	if actionsErr == nil && len(actionsResp.Actions) > 0 {
		actionsStr = strings.Join(actionsResp.Actions, ", ")
	}

	return textResultf(`Element: %s
  Role: %s
  Text: %s
  Bounds: %s
  Enabled: %v
  Focused: %v
  Actions: %s`,
		elem.ElementId, elem.Role, elem.GetText(),
		boundsStr,
		elem.GetEnabled(), elem.GetFocused(), actionsStr), nil
}
