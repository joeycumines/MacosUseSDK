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

const typeElementDescription = "Set the value of an editable UI element (text field, text area, secure field). " +
	"Auto-focuses the exact target element before writing, then verifies the value with an Accessibility readback. " +
	"IMPORTANT: omit `text` to CLEAR the element value; an explicit empty string \"\" sets it to empty rather than clearing — so always supply `text` unless clearing is intended. " +
	"Use a find_elements handle for the exact parent-bound AX identity, or a selector that must resolve to exactly one element. " +
	"Defaults to direct AX value mutation (input_method 'ax'); use input_method 'keystrokes' for web/Electron apps that require real DOM keyboard events (it selects-all then types, replacing the current value)."

// handleFindElements handles the find_elements tool using one explicit selector.
func (s *MCPServer) cuaHandleFindElements(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent       string `json:"parent"`
		Selector     string `json:"selector"`
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
	if params.Selector == "" {
		return errorResult("selector parameter is required"), nil
	}
	if params.PageSize < 0 {
		return errorResult("page_size must be non-negative"), nil
	}
	selector, err := parseElementSelector(params.Selector)
	if err != nil {
		return errorResultf("Invalid selector: %v", err), nil
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
	if resp.NextPageToken != "" {
		result += fmt.Sprintf("\n\nMore results available. Use page_token: %s", resp.NextPageToken)
	}
	return textResult(result), nil
}

// handleClickElement handles the click_element tool — click a UI element via accessibility APIs.
// Targeting can be done by either a parent-bound element handle or one
// selector (e.g., "role:AXButton", "text:Save"). A selector is a
// rediscovery mechanism and must resolve uniquely before mutation.
func (s *MCPServer) cuaHandleClickElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent   string `json:"parent"`
		Element  string `json:"element"`
		Selector string `json:"selector"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Parent == "" {
		return errorResult("parent parameter is required"), nil
	}
	if params.Element == "" && params.Selector == "" {
		return errorResult("element or selector parameter is required"), nil
	}
	if params.Element != "" && params.Selector != "" {
		return errorResult("provide either element or selector, not both"), nil
	}

	if params.Selector != "" {
		// Resolve stable selector server-side, which also handles focus acquisition
		// and post-focus visibility verification.
		selector, err := parseElementSelector(params.Selector)
		if err != nil {
			return errorResultf("Invalid selector: %v", err), nil
		}
		resp, err := s.client.ClickElement(ctx, &pb.ClickElementRequest{
			Parent: params.Parent,
			Target: &pb.ClickElementRequest_Selector{Selector: selector},
		})
		if err != nil {
			return s.clickElementFallbackError(ctx, params.Parent, params.Selector, err), nil
		}
		if !resp.Success {
			role := "(unknown)"
			if resp.Element != nil && resp.Element.Role != "" {
				role = resp.Element.Role
			}
			return errorResultf("click_element: operation was not successful. Element role: %s. Use find_elements to discover clickable elements.", role), nil
		}
		targetDesc := params.Selector
		if resp.Element != nil {
			targetDesc = fmt.Sprintf("%s (%s)", params.Selector, resp.Element.Role)
		}
		return textResultf("Clicked element via selector: %s", targetDesc), nil
	}

	// Element ID path: let the server handle center-coordinate calculation,
	// visibility verification, and semantic fallback in one RPC. The local
	// manual coordinate path duplicated Swift-side logic and was redundant.
	return s.clickElementFallback(ctx, params.Parent, params.Element)
}

// clickElementError categorizes a ClickElement RPC error into a structured,
// actionable ToolResult. It intentionally mirrors only the strings emitted by
// the Swift clickElement method so the Go-side heuristics stay in sync.
func clickElementError(err error, targetDesc string) *ToolResult {
	// gRPC status messages are mixed-case; normalize once for reliable matching.
	msg := strings.ToLower(err.Error())

	// Visibility failures are reported as failed-precondition by the server.
	if strings.Contains(msg, "not visible") {
		return errorResultf("Element %s is not visible. Bring it into view and retry.", targetDesc)
	}

	// No selector match.
	if strings.Contains(msg, "no element found matching selector") {
		return errorResultf("No element found matching selector %s. Use find_elements to discover available elements.", targetDesc)
	}

	// Stale element reference (element was destroyed, its window closed, or the ID is unregistered).
	if strings.Contains(msg, "element reference not available") || strings.Contains(msg, "element not found") {
		return errorResultf("Element %s is no longer available. The UI may have changed; use find_elements to refresh the reference.", targetDesc)
	}

	// Element exists but lacks on-screen bounds (off-screen, hidden, or empty).
	if strings.Contains(msg, "has no position information") {
		return errorResultf("Element %s has no usable position information. It may be hidden or off-screen.", targetDesc)
	}

	return grpcErrorResult(err, "click_element")
}

// clickElementFallback handles the element-ID path for click_element.
func (s *MCPServer) clickElementFallback(ctx context.Context, parent, elementID string) (*ToolResult, error) {
	resp, err := s.client.ClickElement(ctx, &pb.ClickElementRequest{
		Parent: parent,
		Target: &pb.ClickElementRequest_ElementId{ElementId: elementID},
	})
	if err != nil {
		return clickElementError(err, fmt.Sprintf("%s/%s", parent, elementID)), nil
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

	return textResultf("Clicked element: %s", elemInfo), nil
}

// clickElementFallbackError converts a ClickElement RPC error into a structured
// ToolResult for selector-based requests.
func (s *MCPServer) clickElementFallbackError(ctx context.Context, parent, selector string, err error) *ToolResult {
	return clickElementError(err, fmt.Sprintf("matching selector %q", selector))
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

// applicationParentResource extracts the exact application prefix from an
// application or application-child resource name.
func applicationParentResource(parent string) (string, bool) {
	parts := strings.Split(strings.TrimSpace(parent), "/")
	if len(parts) < 2 || parts[0] != "applications" || parts[1] == "" {
		return "", false
	}
	return strings.Join(parts[:2], "/"), true
}

// parseParentPID extracts a legacy numeric PID from a parent resource name.
// Opaque production application identities deliberately return zero.
func parseParentPID(parent string) int64 {
	applicationParent, ok := applicationParentResource(parent)
	if !ok {
		return 0
	}
	parts := strings.Split(applicationParent, "/")
	pid, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0
	}
	return pid
}

// elementResourceName builds a canonical element resource name from a parent
// (application or window) and the element id. Element resources are children
// of the exact opaque application resource even when discovery used a window.
func elementResourceName(parent, elementID string) string {
	if applicationParent, ok := applicationParentResource(parent); ok {
		return fmt.Sprintf("%s/elements/%s", applicationParent, elementID)
	}
	return fmt.Sprintf("%s/elements/%s", parent, elementID)
}

// parseElementSelector converts a simple "key:value" selector string into a proto
// ElementSelector. Supported keys: role, text, text_contains (and textcontains).
// Example: "role:AXTextArea", "text:hello", "text_contains:world".
func parseElementSelector(selector string) (*typepb.ElementSelector, error) {
	before, after, ok := strings.Cut(selector, ":")
	if !ok {
		return nil, fmt.Errorf("selector must be in the form key:value (e.g. role:AXTextArea)")
	}
	key := strings.TrimSpace(strings.ToLower(before))
	value := strings.TrimSpace(after)
	// Empty values are intentionally allowed: locating an AXTextField whose
	// current value is empty is a valid UI state, and role:"" will simply
	// fail to match against real role strings.
	switch key {
	case "role":
		return &typepb.ElementSelector{Criteria: &typepb.ElementSelector_Role{Role: value}}, nil
	case "text":
		return &typepb.ElementSelector{Criteria: &typepb.ElementSelector_Text{Text: value}}, nil
	case "textcontains", "text_contains":
		return &typepb.ElementSelector{Criteria: &typepb.ElementSelector_TextContains{TextContains: value}}, nil
	default:
		return nil, fmt.Errorf("unsupported selector key %q; use role, text, or text_contains", key)
	}
}

// handleTypeElement handles the type_element tool — set value of a UI element with auto-focus.
// Targeting can be done by either a parent-bound element handle or one
// selector (e.g., "role:AXTextArea", "text:Save"). A selector is a
// rediscovery mechanism and must resolve uniquely before mutation.
func (s *MCPServer) handleTypeElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent      string `json:"parent"`
		Element     string `json:"element"`
		Selector    string `json:"selector"`
		Text        string `json:"text"`
		InputMethod string `json:"input_method"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Parent == "" {
		return errorResult("parent parameter is required"), nil
	}
	if params.Element == "" && params.Selector == "" {
		return errorResult("element or selector parameter is required"), nil
	}
	if params.Element != "" && params.Selector != "" {
		return errorResult("provide either element or selector, not both"), nil
	}

	if errResult := validateInputLen(params.Text, maxInputTextLen, "text"); errResult != nil {
		return errResult, nil
	}

	// Proto contract: omitted Value clears the element; explicit empty string
	// sets the value to empty.  Since Go cannot distinguish omitted from ""
	// without a *string, treat empty Text as clear (Value=nil).  Callers
	// wanting set-to-empty may pass a single space.
	var value *string
	if params.Text != "" {
		value = &params.Text
	}

	inputMethod := strings.ToLower(strings.TrimSpace(params.InputMethod))
	if inputMethod == "" {
		inputMethod = "ax"
	}
	if inputMethod != "ax" && inputMethod != "keystrokes" {
		return errorResult("input_method must be 'ax' or 'keystrokes'"), nil
	}

	// Auto-focus: bring the element's window forward before typing.
	if windowName := extractWindowFromParent(params.Parent); windowName != "" {
		_, _ = s.client.FocusWindow(ctx, &pb.FocusWindowRequest{Name: windowName})
		// Best-effort focus acquisition
	}

	// Both input_method values now route through WriteElementValue, differing
	// only in WriteMode.  This unifies readback convergence, input-resource
	// population, and correctness guarantees across the two code paths.
	writeReq := &pb.WriteElementValueRequest{
		Parent: params.Parent,
		Value:  value,
	}
	if inputMethod == "keystrokes" {
		writeReq.WriteMode = pb.WriteElementValueRequest_WRITE_MODE_KEYSTROKE_REPLACEMENT
	}

	if params.Element != "" {
		writeReq.Target = &pb.WriteElementValueRequest_ElementId{ElementId: params.Element}
	} else {
		selector, err := parseElementSelector(params.Selector)
		if err != nil {
			return errorResultf("Invalid selector: %v", err), nil
		}
		writeReq.Target = &pb.WriteElementValueRequest_Selector{Selector: selector}
	}

	resp, err := s.client.WriteElementValue(ctx, writeReq)
	if err != nil {
		errMsg := err.Error()
		if strings.Contains(errMsg, "not editable") || strings.Contains(errMsg, "AXValue") {
			role := "(unknown)"
			if params.Element != "" {
				role = getElementRole(ctx, s, params.Parent, params.Element)
			}
			return errorResultf("Element is not editable. Role: %s. Find an AXTextField or AXTextArea element instead.", role), nil
		}
		return grpcErrorResult(err, "type_element"), nil
	}

	if !resp.Success {
		role := "(unknown)"
		if params.Element != "" {
			role = getElementRole(ctx, s, params.Parent, params.Element)
		}
		return errorResultf("type_element: operation was not successful. Element may not be editable. Role: %s. Find an AXTextField or AXTextArea element instead.", role), nil
	}

	targetDesc := params.Selector
	if params.Element != "" {
		targetDesc = params.Element
	}
	return textResultf("Typed into element %s: %d characters", targetDesc, len(params.Text)), nil
}

// handleReadElement handles the read_element tool — get detailed element info.
// Combines GetElement + GetElementActions into a single response.
// Accepts either a full element resource name or an element ID returned by find_elements.
func (s *MCPServer) handleReadElement(call *ToolCall) (*ToolResult, error) {
	ctx, cancel := context.WithTimeout(s.toolCallContext(call), time.Duration(s.cfg.RequestTimeout)*time.Second)
	defer cancel()

	var params struct {
		Parent  string `json:"parent"`
		Element string `json:"element"`
	}

	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	if params.Element == "" {
		return errorResult("element parameter is required"), nil
	}

	// find_elements returns bare IDs like "elem_..." but GetElement expects
	// "applications/{pid}/elements/{id}". Build the canonical name if parent is supplied.
	elementName := params.Element
	if !strings.Contains(params.Element, "/elements/") {
		if params.Parent == "" {
			return errorResult("read_element: element ID from find_elements requires a parent (the application/window used during traversal)"), nil
		}
		// Reuse the shared canonicalization helper so window- and app-scoped parents
		// both produce "applications/{pid}/elements/{id}".
		elementName = elementResourceName(params.Parent, params.Element)
	}

	// Get element details
	elem, err := s.client.GetElement(ctx, &pb.GetElementRequest{Name: elementName})
	if err != nil {
		return grpcErrorResult(err, "read_element"), nil
	}

	// Get element actions
	actionsResp, actionsErr := s.client.GetElementActions(ctx, &pb.GetElementActionsRequest{
		Name: elementName,
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
