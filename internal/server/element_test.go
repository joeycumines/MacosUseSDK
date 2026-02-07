// Copyright 2025 Joseph Cumines
//
// Element handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	_type "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

// mockElementClient is a mock implementation of MacosUseClient for element testing.
type mockElementClient struct {
	mockMacosUseClient

	// FindElements mock
	findElementsFunc func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error)
	// GetElement mock
	getElementFunc func(ctx context.Context, req *pb.GetElementRequest) (*_type.Element, error)
	// ClickElement mock
	clickElementFunc func(ctx context.Context, req *pb.ClickElementRequest) (*pb.ClickElementResponse, error)
	// WriteElementValue mock
	writeElementValueFunc func(ctx context.Context, req *pb.WriteElementValueRequest) (*pb.WriteElementValueResponse, error)
	// PerformElementAction mock
	performElementActionFunc func(ctx context.Context, req *pb.PerformElementActionRequest) (*pb.PerformElementActionResponse, error)
	// TraverseAccessibility mock
	traverseAccessibilityFunc func(ctx context.Context, req *pb.TraverseAccessibilityRequest) (*pb.TraverseAccessibilityResponse, error)
	// FindRegionElements mock
	findRegionElementsFunc func(ctx context.Context, req *pb.FindRegionElementsRequest) (*pb.FindRegionElementsResponse, error)
	// GetElementActions mock
	getElementActionsFunc func(ctx context.Context, req *pb.GetElementActionsRequest) (*pb.ElementActions, error)
	// WaitElement mock
	waitElementFunc func(ctx context.Context, req *pb.WaitElementRequest) (*longrunningpb.Operation, error)
	// WaitElementState mock
	waitElementStateFunc func(ctx context.Context, req *pb.WaitElementStateRequest) (*longrunningpb.Operation, error)
}

func (m *mockElementClient) FindElements(ctx context.Context, req *pb.FindElementsRequest, opts ...grpc.CallOption) (*pb.FindElementsResponse, error) {
	if m.findElementsFunc != nil {
		return m.findElementsFunc(ctx, req)
	}
	return nil, errors.New("FindElements not implemented")
}

func (m *mockElementClient) GetElement(ctx context.Context, req *pb.GetElementRequest, opts ...grpc.CallOption) (*_type.Element, error) {
	if m.getElementFunc != nil {
		return m.getElementFunc(ctx, req)
	}
	return nil, errors.New("GetElement not implemented")
}

func (m *mockElementClient) ClickElement(ctx context.Context, req *pb.ClickElementRequest, opts ...grpc.CallOption) (*pb.ClickElementResponse, error) {
	if m.clickElementFunc != nil {
		return m.clickElementFunc(ctx, req)
	}
	return nil, errors.New("ClickElement not implemented")
}

func (m *mockElementClient) WriteElementValue(ctx context.Context, req *pb.WriteElementValueRequest, opts ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
	if m.writeElementValueFunc != nil {
		return m.writeElementValueFunc(ctx, req)
	}
	return nil, errors.New("WriteElementValue not implemented")
}

func (m *mockElementClient) PerformElementAction(ctx context.Context, req *pb.PerformElementActionRequest, opts ...grpc.CallOption) (*pb.PerformElementActionResponse, error) {
	if m.performElementActionFunc != nil {
		return m.performElementActionFunc(ctx, req)
	}
	return nil, errors.New("PerformElementAction not implemented")
}

func (m *mockElementClient) TraverseAccessibility(ctx context.Context, req *pb.TraverseAccessibilityRequest, opts ...grpc.CallOption) (*pb.TraverseAccessibilityResponse, error) {
	if m.traverseAccessibilityFunc != nil {
		return m.traverseAccessibilityFunc(ctx, req)
	}
	return nil, errors.New("TraverseAccessibility not implemented")
}

func (m *mockElementClient) FindRegionElements(ctx context.Context, req *pb.FindRegionElementsRequest, opts ...grpc.CallOption) (*pb.FindRegionElementsResponse, error) {
	if m.findRegionElementsFunc != nil {
		return m.findRegionElementsFunc(ctx, req)
	}
	return nil, errors.New("FindRegionElements not implemented")
}

func (m *mockElementClient) GetElementActions(ctx context.Context, req *pb.GetElementActionsRequest, opts ...grpc.CallOption) (*pb.ElementActions, error) {
	if m.getElementActionsFunc != nil {
		return m.getElementActionsFunc(ctx, req)
	}
	return nil, errors.New("GetElementActions not implemented")
}

func (m *mockElementClient) WaitElement(ctx context.Context, req *pb.WaitElementRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	if m.waitElementFunc != nil {
		return m.waitElementFunc(ctx, req)
	}
	return nil, errors.New("WaitElement not implemented")
}

func (m *mockElementClient) WaitElementState(ctx context.Context, req *pb.WaitElementStateRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	if m.waitElementStateFunc != nil {
		return m.waitElementStateFunc(ctx, req)
	}
	return nil, errors.New("WaitElementState not implemented")
}

// ============================================================================
// handleFindElements Tests
// ============================================================================

func TestHandleFindElements_Success_ByRole(t *testing.T) {
	mockClient := &mockElementClient{
		findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			// Verify request
			if req.Selector == nil {
				t.Error("expected selector to be set")
			}
			if req.Selector.GetRole() != "AXButton" {
				t.Errorf("expected role 'AXButton', got %q", req.Selector.GetRole())
			}
			return &pb.FindElementsResponse{
				Elements: []*_type.Element{
					{ElementId: "elem1", Role: "AXButton", Text: proto.String("OK")},
					{ElementId: "elem2", Role: "AXButton", Text: proto.String("Cancel")},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{"selector": {"role": "AXButton"}, "parent": "applications/1"}`),
	}

	result, err := server.handleFindElements(call)

	if err != nil {
		t.Fatalf("handleFindElements returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 2 elements") {
		t.Errorf("result text does not contain 'Found 2 elements': %s", text)
	}
	if !strings.Contains(text, "AXButton") {
		t.Errorf("result text does not contain 'AXButton': %s", text)
	}
}

func TestHandleFindElements_Success_ByText(t *testing.T) {
	mockClient := &mockElementClient{
		findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			if req.Selector.GetText() != "Submit" {
				t.Errorf("expected text 'Submit', got %q", req.Selector.GetText())
			}
			return &pb.FindElementsResponse{
				Elements: []*_type.Element{
					{ElementId: "submit-btn", Role: "AXButton", Text: proto.String("Submit")},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{"selector": {"text": "Submit"}}`),
	}

	result, err := server.handleFindElements(call)

	if err != nil {
		t.Fatalf("handleFindElements returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 1 elements") {
		t.Errorf("result text does not contain 'Found 1 elements': %s", text)
	}
}

func TestHandleFindElements_Success_ByTextContains(t *testing.T) {
	mockClient := &mockElementClient{
		findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			if req.Selector.GetTextContains() != "Save" {
				t.Errorf("expected text_contains 'Save', got %q", req.Selector.GetTextContains())
			}
			return &pb.FindElementsResponse{
				Elements: []*_type.Element{
					{ElementId: "save1", Role: "AXButton", Text: proto.String("Save As...")},
					{ElementId: "save2", Role: "AXMenuItem", Text: proto.String("Save Document")},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{"selector": {"text_contains": "Save"}}`),
	}

	result, err := server.handleFindElements(call)

	if err != nil {
		t.Fatalf("handleFindElements returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 2 elements") {
		t.Errorf("result text does not contain 'Found 2 elements': %s", text)
	}
}

func TestHandleFindElements_NoElementsFound(t *testing.T) {
	mockClient := &mockElementClient{
		findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			return &pb.FindElementsResponse{Elements: []*_type.Element{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{"selector": {"role": "AXNonExistent"}}`),
	}

	result, err := server.handleFindElements(call)

	if err != nil {
		t.Fatalf("handleFindElements returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No elements found matching selector" {
		t.Errorf("result text = %q, want 'No elements found matching selector'", text)
	}
}

func TestHandleFindElements_InvalidJSON(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{invalid json}`),
	}

	result, err := server.handleFindElements(call)

	if err != nil {
		t.Fatalf("handleFindElements returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleFindElements_GRPCError(t *testing.T) {
	mockClient := &mockElementClient{
		findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			return nil, errors.New("accessibility tree not available")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{"selector": {"role": "AXButton"}}`),
	}

	result, err := server.handleFindElements(call)

	if err != nil {
		t.Fatalf("handleFindElements returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to find elements") {
		t.Errorf("error text does not contain 'Failed to find elements': %s", text)
	}
}

// ============================================================================
// handleGetElement Tests
// ============================================================================

func TestHandleGetElement_Success(t *testing.T) {
	x := 100.0
	y := 200.0
	w := 80.0
	h := 30.0

	mockClient := &mockElementClient{
		getElementFunc: func(ctx context.Context, req *pb.GetElementRequest) (*_type.Element, error) {
			if req.Name != "elements/test-elem" {
				t.Errorf("expected name 'elements/test-elem', got %q", req.Name)
			}
			return &_type.Element{
				ElementId: "test-elem",
				Role:      "AXButton",
				Text:      proto.String("Click Me"),
				X:         &x,
				Y:         &y,
				Width:     &w,
				Height:    &h,
				Enabled:   proto.Bool(true),
				Focused:   proto.Bool(false),
				Actions:   []string{"AXPress", "AXShowMenu"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element",
		Arguments: json.RawMessage(`{"name": "elements/test-elem"}`),
	}

	result, err := server.handleGetElement(call)

	if err != nil {
		t.Fatalf("handleGetElement returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Element: test-elem") {
		t.Errorf("result text does not contain 'Element: test-elem': %s", text)
	}
	if !strings.Contains(text, "Role: AXButton") {
		t.Errorf("result text does not contain 'Role: AXButton': %s", text)
	}
	if !strings.Contains(text, "Text: Click Me") {
		t.Errorf("result text does not contain 'Text: Click Me': %s", text)
	}
	if !strings.Contains(text, "AXPress, AXShowMenu") {
		t.Errorf("result text does not contain actions: %s", text)
	}
}

func TestHandleGetElement_MissingName(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetElement(call)

	if err != nil {
		t.Fatalf("handleGetElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetElement_EmptyName(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element",
		Arguments: json.RawMessage(`{"name": ""}`),
	}

	result, err := server.handleGetElement(call)

	if err != nil {
		t.Fatalf("handleGetElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty name")
	}
}

func TestHandleGetElement_InvalidJSON(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element",
		Arguments: json.RawMessage(`{not valid}`),
	}

	result, err := server.handleGetElement(call)

	if err != nil {
		t.Fatalf("handleGetElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleGetElement_GRPCError(t *testing.T) {
	mockClient := &mockElementClient{
		getElementFunc: func(ctx context.Context, req *pb.GetElementRequest) (*_type.Element, error) {
			return nil, errors.New("element not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element",
		Arguments: json.RawMessage(`{"name": "elements/nonexistent"}`),
	}

	result, err := server.handleGetElement(call)

	if err != nil {
		t.Fatalf("handleGetElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get element") {
		t.Errorf("error text does not contain 'Failed to get element': %s", text)
	}
}

// ============================================================================
// handleClickElement Tests
// ============================================================================

func TestHandleClickElement_Success(t *testing.T) {
	mockClient := &mockElementClient{
		clickElementFunc: func(ctx context.Context, req *pb.ClickElementRequest) (*pb.ClickElementResponse, error) {
			if req.Parent != "applications/1" {
				t.Errorf("expected parent 'applications/1', got %q", req.Parent)
			}
			if req.GetElementId() != "button-123" {
				t.Errorf("expected element_id 'button-123', got %q", req.GetElementId())
			}
			return &pb.ClickElementResponse{
				Success: true,
				Element: &_type.Element{
					ElementId: "button-123",
					Role:      "AXButton",
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "button-123"}`),
	}

	result, err := server.handleClickElement(call)

	if err != nil {
		t.Fatalf("handleClickElement returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Clicked element") {
		t.Errorf("result text does not contain 'Clicked element': %s", text)
	}
	if !strings.Contains(text, "button-123") {
		t.Errorf("result text does not contain 'button-123': %s", text)
	}
}

func TestHandleClickElement_SuccessNotReturned(t *testing.T) {
	mockClient := &mockElementClient{
		clickElementFunc: func(ctx context.Context, req *pb.ClickElementRequest) (*pb.ClickElementResponse, error) {
			return &pb.ClickElementResponse{Success: false}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "elem"}`),
	}

	result, err := server.handleClickElement(call)

	if err != nil {
		t.Fatalf("handleClickElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true when success is false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "failed to click") {
		t.Errorf("error text does not contain 'failed to click': %s", text)
	}
}

func TestHandleClickElement_MissingParent(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"element_id": "button-123"}`),
	}

	result, err := server.handleClickElement(call)

	if err != nil {
		t.Fatalf("handleClickElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing parent")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "parent and element_id parameters are required") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleClickElement_MissingElementID(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent": "applications/1"}`),
	}

	result, err := server.handleClickElement(call)

	if err != nil {
		t.Fatalf("handleClickElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing element_id")
	}
}

func TestHandleClickElement_InvalidJSON(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{bad json}`),
	}

	result, err := server.handleClickElement(call)

	if err != nil {
		t.Fatalf("handleClickElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleClickElement_GRPCError(t *testing.T) {
	mockClient := &mockElementClient{
		clickElementFunc: func(ctx context.Context, req *pb.ClickElementRequest) (*pb.ClickElementResponse, error) {
			return nil, errors.New("element not clickable")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "elem"}`),
	}

	result, err := server.handleClickElement(call)

	if err != nil {
		t.Fatalf("handleClickElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to click element") {
		t.Errorf("error text does not contain 'Failed to click element': %s", text)
	}
}

// ============================================================================
// handleWriteElementValue Tests
// ============================================================================

func TestHandleWriteElementValue_Success(t *testing.T) {
	mockClient := &mockElementClient{
		writeElementValueFunc: func(ctx context.Context, req *pb.WriteElementValueRequest) (*pb.WriteElementValueResponse, error) {
			if req.Parent != "applications/TextEdit" {
				t.Errorf("expected parent 'applications/TextEdit', got %q", req.Parent)
			}
			if req.GetElementId() != "text-field" {
				t.Errorf("expected element_id 'text-field', got %q", req.GetElementId())
			}
			if req.Value != "Hello World" {
				t.Errorf("expected value 'Hello World', got %q", req.Value)
			}
			return &pb.WriteElementValueResponse{Success: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_element_value",
		Arguments: json.RawMessage(`{"parent": "applications/TextEdit", "element_id": "text-field", "value": "Hello World"}`),
	}

	result, err := server.handleWriteElementValue(call)

	if err != nil {
		t.Fatalf("handleWriteElementValue returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Set value for element") {
		t.Errorf("result text does not contain 'Set value for element': %s", text)
	}
}

func TestHandleWriteElementValue_SuccessFalse(t *testing.T) {
	mockClient := &mockElementClient{
		writeElementValueFunc: func(ctx context.Context, req *pb.WriteElementValueRequest) (*pb.WriteElementValueResponse, error) {
			return &pb.WriteElementValueResponse{Success: false}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "write_element_value",
		Arguments: json.RawMessage(`{"parent": "app", "element_id": "elem", "value": "test"}`),
	}

	result, err := server.handleWriteElementValue(call)

	if err != nil {
		t.Fatalf("handleWriteElementValue returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true when success is false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "failed to write value") {
		t.Errorf("error text does not contain 'failed to write value': %s", text)
	}
}

func TestHandleWriteElementValue_MissingParams(t *testing.T) {
	tests := []struct {
		name string
		args string
	}{
		{"missing parent", `{"element_id": "e", "value": "v"}`},
		{"missing element_id", `{"parent": "p", "value": "v"}`},
		{"missing both", `{"value": "v"}`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockElementClient{}
			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "write_element_value",
				Arguments: json.RawMessage(tt.args),
			}

			result, err := server.handleWriteElementValue(call)

			if err != nil {
				t.Fatalf("handleWriteElementValue returned Go error: %v", err)
			}
			if !result.IsError {
				t.Error("result.IsError = false, want true for missing params")
			}
		})
	}
}

// ============================================================================
// handlePerformElementAction Tests
// ============================================================================

func TestHandlePerformElementAction_Success(t *testing.T) {
	mockClient := &mockElementClient{
		performElementActionFunc: func(ctx context.Context, req *pb.PerformElementActionRequest) (*pb.PerformElementActionResponse, error) {
			if req.Parent != "applications/1" {
				t.Errorf("expected parent 'applications/1', got %q", req.Parent)
			}
			if req.GetElementId() != "menu-item" {
				t.Errorf("expected element_id 'menu-item', got %q", req.GetElementId())
			}
			if req.Action != "AXPress" {
				t.Errorf("expected action 'AXPress', got %q", req.Action)
			}
			return &pb.PerformElementActionResponse{Success: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "perform_element_action",
		Arguments: json.RawMessage(`{"parent": "applications/1", "element_id": "menu-item", "action": "AXPress"}`),
	}

	result, err := server.handlePerformElementAction(call)

	if err != nil {
		t.Fatalf("handlePerformElementAction returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Performed AXPress on element") {
		t.Errorf("result text does not contain 'Performed AXPress on element': %s", text)
	}
}

func TestHandlePerformElementAction_SuccessFalse(t *testing.T) {
	mockClient := &mockElementClient{
		performElementActionFunc: func(ctx context.Context, req *pb.PerformElementActionRequest) (*pb.PerformElementActionResponse, error) {
			return &pb.PerformElementActionResponse{Success: false}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "perform_element_action",
		Arguments: json.RawMessage(`{"parent": "app", "element_id": "elem", "action": "AXPress"}`),
	}

	result, err := server.handlePerformElementAction(call)

	if err != nil {
		t.Fatalf("handlePerformElementAction returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true when success is false")
	}
}

func TestHandlePerformElementAction_MissingAction(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "perform_element_action",
		Arguments: json.RawMessage(`{"parent": "app", "element_id": "elem"}`),
	}

	result, err := server.handlePerformElementAction(call)

	if err != nil {
		t.Fatalf("handlePerformElementAction returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing action")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "action parameter is required") {
		t.Errorf("error text does not contain 'action parameter is required': %s", text)
	}
}

// ============================================================================
// handleTraverseAccessibility Tests
// ============================================================================

func TestHandleTraverseAccessibility_Success(t *testing.T) {
	mockClient := &mockElementClient{
		traverseAccessibilityFunc: func(ctx context.Context, req *pb.TraverseAccessibilityRequest) (*pb.TraverseAccessibilityResponse, error) {
			if req.Name != "applications/Calculator" {
				t.Errorf("expected name 'applications/Calculator', got %q", req.Name)
			}
			if !req.VisibleOnly {
				t.Error("expected VisibleOnly to be true")
			}
			return &pb.TraverseAccessibilityResponse{
				App: "Calculator",
				Elements: []*_type.Element{
					{ElementId: "win1", Role: "AXWindow", Text: proto.String("Calculator")},
					{ElementId: "btn1", Role: "AXButton", Text: proto.String("1")},
					{ElementId: "btn2", Role: "AXButton", Text: proto.String("2")},
				},
				Stats: &_type.TraversalStats{
					Count:                3,
					VisibleElementsCount: 3,
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "traverse_accessibility",
		Arguments: json.RawMessage(`{"name": "applications/Calculator", "visible_only": true}`),
	}

	result, err := server.handleTraverseAccessibility(call)

	if err != nil {
		t.Fatalf("handleTraverseAccessibility returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Accessibility tree for Calculator") {
		t.Errorf("result text does not contain 'Accessibility tree for Calculator': %s", text)
	}
	if !strings.Contains(text, "3 elements") {
		t.Errorf("result text does not contain '3 elements': %s", text)
	}
}

func TestHandleTraverseAccessibility_NoElements(t *testing.T) {
	mockClient := &mockElementClient{
		traverseAccessibilityFunc: func(ctx context.Context, req *pb.TraverseAccessibilityRequest) (*pb.TraverseAccessibilityResponse, error) {
			return &pb.TraverseAccessibilityResponse{
				App:      "Empty",
				Elements: []*_type.Element{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "traverse_accessibility",
		Arguments: json.RawMessage(`{"name": "applications/Empty"}`),
	}

	result, err := server.handleTraverseAccessibility(call)

	if err != nil {
		t.Fatalf("handleTraverseAccessibility returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No elements found in accessibility tree" {
		t.Errorf("result text = %q, want 'No elements found in accessibility tree'", text)
	}
}

func TestHandleTraverseAccessibility_MissingName(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "traverse_accessibility",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleTraverseAccessibility(call)

	if err != nil {
		t.Fatalf("handleTraverseAccessibility returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}
}

func TestHandleTraverseAccessibility_TruncatesLongText(t *testing.T) {
	longText := strings.Repeat("a", 100)
	mockClient := &mockElementClient{
		traverseAccessibilityFunc: func(ctx context.Context, req *pb.TraverseAccessibilityRequest) (*pb.TraverseAccessibilityResponse, error) {
			return &pb.TraverseAccessibilityResponse{
				App: "App",
				Elements: []*_type.Element{
					{ElementId: "elem", Role: "AXStaticText", Text: proto.String(longText)},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "traverse_accessibility",
		Arguments: json.RawMessage(`{"name": "applications/1"}`),
	}

	result, err := server.handleTraverseAccessibility(call)

	if err != nil {
		t.Fatalf("handleTraverseAccessibility returned error: %v", err)
	}

	text := result.Content[0].Text
	// Text should be truncated to 50 chars + "..."
	if !strings.Contains(text, "...") {
		t.Errorf("result text should contain ellipsis for truncated text: %s", text)
	}
	// Should not contain the full 100-char string
	if strings.Contains(text, longText) {
		t.Errorf("result text should not contain full long text: %s", text)
	}
}

// ============================================================================
// handleFindRegionElements Tests
// ============================================================================

func TestHandleFindRegionElements_Success(t *testing.T) {
	mockClient := &mockElementClient{
		findRegionElementsFunc: func(ctx context.Context, req *pb.FindRegionElementsRequest) (*pb.FindRegionElementsResponse, error) {
			if req.Parent != "applications/1" {
				t.Errorf("expected parent 'applications/1', got %q", req.Parent)
			}
			if req.Region.X != 100 || req.Region.Y != 200 || req.Region.Width != 300 || req.Region.Height != 400 {
				t.Errorf("unexpected region: %+v", req.Region)
			}
			return &pb.FindRegionElementsResponse{
				Elements: []*_type.Element{
					{ElementId: "e1", Role: "AXButton", Text: proto.String("OK")},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_region_elements",
		Arguments: json.RawMessage(`{"parent": "applications/1", "x": 100, "y": 200, "width": 300, "height": 400}`),
	}

	result, err := server.handleFindRegionElements(call)

	if err != nil {
		t.Fatalf("handleFindRegionElements returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 1 elements in region") {
		t.Errorf("result text does not contain 'Found 1 elements in region': %s", text)
	}
	if !strings.Contains(text, "(100,200 300x400)") {
		t.Errorf("result text does not contain region coordinates: %s", text)
	}
}

func TestHandleFindRegionElements_MissingParent(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_region_elements",
		Arguments: json.RawMessage(`{"x": 0, "y": 0, "width": 100, "height": 100}`),
	}

	result, err := server.handleFindRegionElements(call)

	if err != nil {
		t.Fatalf("handleFindRegionElements returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing parent")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "parent parameter is required") {
		t.Errorf("error text does not contain 'parent parameter is required': %s", text)
	}
}

func TestHandleFindRegionElements_NoElements(t *testing.T) {
	mockClient := &mockElementClient{
		findRegionElementsFunc: func(ctx context.Context, req *pb.FindRegionElementsRequest) (*pb.FindRegionElementsResponse, error) {
			return &pb.FindRegionElementsResponse{Elements: []*_type.Element{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "find_region_elements",
		Arguments: json.RawMessage(`{"parent": "app", "x": 0, "y": 0, "width": 10, "height": 10}`),
	}

	result, err := server.handleFindRegionElements(call)

	if err != nil {
		t.Fatalf("handleFindRegionElements returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No elements found in region" {
		t.Errorf("result text = %q, want 'No elements found in region'", text)
	}
}

// ============================================================================
// handleGetElementActions Tests
// ============================================================================

func TestHandleGetElementActions_Success(t *testing.T) {
	mockClient := &mockElementClient{
		getElementActionsFunc: func(ctx context.Context, req *pb.GetElementActionsRequest) (*pb.ElementActions, error) {
			if req.Name != "elements/button-1" {
				t.Errorf("expected name 'elements/button-1', got %q", req.Name)
			}
			return &pb.ElementActions{
				Actions: []string{"AXPress", "AXShowMenu", "AXCancel"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element_actions",
		Arguments: json.RawMessage(`{"name": "elements/button-1"}`),
	}

	result, err := server.handleGetElementActions(call)

	if err != nil {
		t.Fatalf("handleGetElementActions returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Available actions for elements/button-1") {
		t.Errorf("result text does not contain expected header: %s", text)
	}
	if !strings.Contains(text, "AXPress, AXShowMenu, AXCancel") {
		t.Errorf("result text does not contain actions: %s", text)
	}
}

func TestHandleGetElementActions_NoActions(t *testing.T) {
	mockClient := &mockElementClient{
		getElementActionsFunc: func(ctx context.Context, req *pb.GetElementActionsRequest) (*pb.ElementActions, error) {
			return &pb.ElementActions{Actions: []string{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element_actions",
		Arguments: json.RawMessage(`{"name": "elements/static-text"}`),
	}

	result, err := server.handleGetElementActions(call)

	if err != nil {
		t.Fatalf("handleGetElementActions returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "No actions available") {
		t.Errorf("result text does not contain 'No actions available': %s", text)
	}
}

func TestHandleGetElementActions_MissingName(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_element_actions",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetElementActions(call)

	if err != nil {
		t.Fatalf("handleGetElementActions returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}
}

// ============================================================================
// handleWaitElement Tests (LRO)
// ============================================================================

func TestHandleWaitElement_Success(t *testing.T) {
	// Create a completed operation
	waitResp := &pb.WaitElementResponse{
		Element: &_type.Element{
			ElementId: "found-elem",
			Role:      "AXButton",
			Text:      proto.String("Found Button"),
		},
	}
	respAny, err := anypb.New(waitResp)
	if err != nil {
		t.Fatalf("failed to create Any: %v", err)
	}

	mockClient := &mockElementClient{
		waitElementFunc: func(ctx context.Context, req *pb.WaitElementRequest) (*longrunningpb.Operation, error) {
			if req.Parent != "applications/1" {
				t.Errorf("expected parent 'applications/1', got %q", req.Parent)
			}
			if req.Selector.GetRole() != "AXButton" {
				t.Errorf("expected role 'AXButton', got %q", req.Selector.GetRole())
			}
			if req.Timeout != 10.0 {
				t.Errorf("expected timeout 10.0, got %f", req.Timeout)
			}
			if req.PollInterval != 0.5 {
				t.Errorf("expected poll_interval 0.5, got %f", req.PollInterval)
			}
			// Return already-completed operation
			return &longrunningpb.Operation{
				Name:   "operations/wait-1",
				Done:   true,
				Result: &longrunningpb.Operation_Response{Response: respAny},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element",
		Arguments: json.RawMessage(`{"parent": "applications/1", "selector": {"role": "AXButton"}, "timeout": 10.0, "poll_interval": 0.5}`),
	}

	result, err := server.handleWaitElement(call)

	if err != nil {
		t.Fatalf("handleWaitElement returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Element found") {
		t.Errorf("result text does not contain 'Element found': %s", text)
	}
	if !strings.Contains(text, "found-elem") {
		t.Errorf("result text does not contain 'found-elem': %s", text)
	}
}

func TestHandleWaitElement_MissingParent(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element",
		Arguments: json.RawMessage(`{"selector": {"role": "AXButton"}}`),
	}

	result, err := server.handleWaitElement(call)

	if err != nil {
		t.Fatalf("handleWaitElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing parent")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "parent parameter is required") {
		t.Errorf("error text does not contain 'parent parameter is required': %s", text)
	}
}

func TestHandleWaitElement_MissingSelector(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element",
		Arguments: json.RawMessage(`{"parent": "applications/1"}`),
	}

	result, err := server.handleWaitElement(call)

	if err != nil {
		t.Fatalf("handleWaitElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing selector")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "selector with role, text, or text_contains is required") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleWaitElement_GRPCError(t *testing.T) {
	mockClient := &mockElementClient{
		waitElementFunc: func(ctx context.Context, req *pb.WaitElementRequest) (*longrunningpb.Operation, error) {
			return nil, errors.New("failed to start wait")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element",
		Arguments: json.RawMessage(`{"parent": "app", "selector": {"text": "x"}}`),
	}

	result, err := server.handleWaitElement(call)

	if err != nil {
		t.Fatalf("handleWaitElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to start wait operation") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleWaitElement_OperationError(t *testing.T) {
	mockClient := &mockElementClient{
		waitElementFunc: func(ctx context.Context, req *pb.WaitElementRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{
				Name: "operations/wait-err",
				Done: true,
				Result: &longrunningpb.Operation_Error{
					Error: &status.Status{
						Code:    5, // NOT_FOUND
						Message: "element not found within timeout",
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element",
		Arguments: json.RawMessage(`{"parent": "app", "selector": {"text": "x"}}`),
	}

	result, err := server.handleWaitElement(call)

	if err != nil {
		t.Fatalf("handleWaitElement returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Wait failed") {
		t.Errorf("error text does not contain 'Wait failed': %s", text)
	}
}

// ============================================================================
// handleWaitElementState Tests (LRO)
// ============================================================================

func TestHandleWaitElementState_Success(t *testing.T) {
	waitResp := &pb.WaitElementStateResponse{
		Element: &_type.Element{
			ElementId: "elem-1",
			Role:      "AXButton",
			Text:      proto.String("Enabled Button"),
		},
	}
	respAny, err := anypb.New(waitResp)
	if err != nil {
		t.Fatalf("failed to create Any: %v", err)
	}

	mockClient := &mockElementClient{
		waitElementStateFunc: func(ctx context.Context, req *pb.WaitElementStateRequest) (*longrunningpb.Operation, error) {
			if req.Condition.GetEnabled() != true {
				t.Error("expected enabled condition")
			}
			return &longrunningpb.Operation{
				Name:   "operations/wait-state-1",
				Done:   true,
				Result: &longrunningpb.Operation_Response{Response: respAny},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element_state",
		Arguments: json.RawMessage(`{"parent": "app", "element_id": "elem-1", "condition": "enabled"}`),
	}

	result, err := server.handleWaitElementState(call)

	if err != nil {
		t.Fatalf("handleWaitElementState returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "reached state 'enabled'") {
		t.Errorf("result text does not contain expected message: %s", text)
	}
}

func TestHandleWaitElementState_Conditions(t *testing.T) {
	tests := []struct {
		name      string
		condition string
		value     string
	}{
		{"enabled", "enabled", ""},
		{"focused", "focused", ""},
		{"text_equals", "text_equals", "Hello"},
		{"text_contains", "text_contains", "World"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			waitResp := &pb.WaitElementStateResponse{
				Element: &_type.Element{ElementId: "e", Role: "AXButton"},
			}
			respAny, _ := anypb.New(waitResp)

			mockClient := &mockElementClient{
				waitElementStateFunc: func(ctx context.Context, req *pb.WaitElementStateRequest) (*longrunningpb.Operation, error) {
					// Verify correct condition type is set
					switch tt.condition {
					case "enabled":
						if !req.Condition.GetEnabled() {
							t.Error("expected enabled condition")
						}
					case "focused":
						if !req.Condition.GetFocused() {
							t.Error("expected focused condition")
						}
					case "text_equals":
						if req.Condition.GetTextEquals() != tt.value {
							t.Errorf("expected text_equals %q", tt.value)
						}
					case "text_contains":
						if req.Condition.GetTextContains() != tt.value {
							t.Errorf("expected text_contains %q", tt.value)
						}
					}
					return &longrunningpb.Operation{
						Name:   "op",
						Done:   true,
						Result: &longrunningpb.Operation_Response{Response: respAny},
					}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			args := map[string]interface{}{
				"parent":     "app",
				"element_id": "e",
				"condition":  tt.condition,
			}
			if tt.value != "" {
				args["value"] = tt.value
			}
			argsJSON, _ := json.Marshal(args)
			call := &ToolCall{
				Name:      "wait_element_state",
				Arguments: argsJSON,
			}

			result, err := server.handleWaitElementState(call)

			if err != nil {
				t.Fatalf("handleWaitElementState returned error: %v", err)
			}
			if result.IsError {
				t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
			}
		})
	}
}

func TestHandleWaitElementState_UnknownCondition(t *testing.T) {
	mockClient := &mockElementClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "wait_element_state",
		Arguments: json.RawMessage(`{"parent": "app", "element_id": "e", "condition": "invalid_condition"}`),
	}

	result, err := server.handleWaitElementState(call)

	if err != nil {
		t.Fatalf("handleWaitElementState returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for unknown condition")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Unknown condition") {
		t.Errorf("error text does not contain 'Unknown condition': %s", text)
	}
}

func TestHandleWaitElementState_MissingParams(t *testing.T) {
	tests := []struct {
		name        string
		args        string
		wantContain string
	}{
		{"missing parent", `{"element_id": "e", "condition": "enabled"}`, "parent and element_id parameters are required"},
		{"missing element_id", `{"parent": "app", "condition": "enabled"}`, "parent and element_id parameters are required"},
		{"missing condition", `{"parent": "app", "element_id": "e"}`, "condition parameter is required"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockElementClient{}
			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "wait_element_state",
				Arguments: json.RawMessage(tt.args),
			}

			result, err := server.handleWaitElementState(call)

			if err != nil {
				t.Fatalf("handleWaitElementState returned Go error: %v", err)
			}
			if !result.IsError {
				t.Error("result.IsError = false, want true")
			}

			text := result.Content[0].Text
			if !strings.Contains(text, tt.wantContain) {
				t.Errorf("error text does not contain %q: %s", tt.wantContain, text)
			}
		})
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestHandleFindElements_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		elements     []*_type.Element
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "single element found",
			args: `{"selector": {"role": "AXButton"}}`,
			elements: []*_type.Element{
				{ElementId: "btn1", Role: "AXButton", Text: proto.String("OK")},
			},
			wantIsError:  false,
			wantContains: []string{"Found 1 elements", "btn1", "OK", "AXButton"},
		},
		{
			name:         "no elements found",
			args:         `{"selector": {"role": "AXNothing"}}`,
			elements:     []*_type.Element{},
			wantIsError:  false,
			wantContains: []string{"No elements found matching selector"},
		},
		{
			name:         "gRPC error",
			args:         `{"selector": {"role": "AXButton"}}`,
			grpcErr:      errors.New("timeout"),
			wantIsError:  true,
			wantContains: []string{"Failed to find elements", "timeout"},
		},
		{
			name:         "invalid JSON",
			args:         `{not valid}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name: "element with no text",
			args: `{"selector": {"role": "AXImage"}}`,
			elements: []*_type.Element{
				{ElementId: "img1", Role: "AXImage"},
			},
			wantIsError:  false,
			wantContains: []string{"(no text)", "AXImage"},
		},
		{
			name: "element with unknown role",
			args: `{"selector": {"text": "x"}}`,
			elements: []*_type.Element{
				{ElementId: "x", Text: proto.String("x")},
			},
			wantIsError:  false,
			wantContains: []string{"(unknown)"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockElementClient{
				findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.FindElementsResponse{Elements: tt.elements}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "find_elements", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleFindElements(call)

			if err != nil {
				t.Fatalf("handleFindElements returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			text := result.Content[0].Text
			for _, want := range tt.wantContains {
				if !strings.Contains(text, want) {
					t.Errorf("result text does not contain %q: %s", want, text)
				}
			}
		})
	}
}

func TestHandleGetElement_TableDriven(t *testing.T) {
	x, y, w, h := 10.0, 20.0, 100.0, 50.0

	tests := []struct {
		name         string
		args         string
		element      *_type.Element
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "full element info",
			args: `{"name": "elements/e1"}`,
			element: &_type.Element{
				ElementId: "e1",
				Role:      "AXButton",
				Text:      proto.String("Click"),
				X:         &x,
				Y:         &y,
				Width:     &w,
				Height:    &h,
				Enabled:   proto.Bool(true),
				Focused:   proto.Bool(false),
				Actions:   []string{"AXPress"},
			},
			wantIsError:  false,
			wantContains: []string{"Element: e1", "Role: AXButton", "Text: Click", "Enabled: true", "AXPress"},
		},
		{
			name:         "missing name",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "gRPC error",
			args:         `{"name": "elements/x"}`,
			grpcErr:      errors.New("not found"),
			wantIsError:  true,
			wantContains: []string{"Failed to get element", "not found"},
		},
		{
			name: "element without bounds",
			args: `{"name": "elements/nobounds"}`,
			element: &_type.Element{
				ElementId: "nobounds",
				Role:      "AXStaticText",
			},
			wantIsError:  false,
			wantContains: []string{"Bounds: unknown"},
		},
		{
			name: "element without actions",
			args: `{"name": "elements/noactions"}`,
			element: &_type.Element{
				ElementId: "noactions",
				Role:      "AXGroup",
				Actions:   []string{},
			},
			wantIsError:  false,
			wantContains: []string{"Actions: none"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockElementClient{
				getElementFunc: func(ctx context.Context, req *pb.GetElementRequest) (*_type.Element, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.element, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "get_element", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleGetElement(call)

			if err != nil {
				t.Fatalf("handleGetElement returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			text := result.Content[0].Text
			for _, want := range tt.wantContains {
				if !strings.Contains(text, want) {
					t.Errorf("result text does not contain %q: %s", want, text)
				}
			}
		})
	}
}

// ============================================================================
// Content Type and Structure Tests
// ============================================================================

func TestElementHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockElementClient{
		findElementsFunc: func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			return &pb.FindElementsResponse{Elements: []*_type.Element{{ElementId: "e1"}}}, nil
		},
		getElementFunc: func(ctx context.Context, req *pb.GetElementRequest) (*_type.Element, error) {
			return &_type.Element{ElementId: "e1", Role: "AXButton"}, nil
		},
		clickElementFunc: func(ctx context.Context, req *pb.ClickElementRequest) (*pb.ClickElementResponse, error) {
			return &pb.ClickElementResponse{Success: true}, nil
		},
		getElementActionsFunc: func(ctx context.Context, req *pb.GetElementActionsRequest) (*pb.ElementActions, error) {
			return &pb.ElementActions{Actions: []string{"AXPress"}}, nil
		},
		traverseAccessibilityFunc: func(ctx context.Context, req *pb.TraverseAccessibilityRequest) (*pb.TraverseAccessibilityResponse, error) {
			return &pb.TraverseAccessibilityResponse{App: "App", Elements: []*_type.Element{{ElementId: "e"}}}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"find_elements":          {server.handleFindElements, `{"selector": {"role": "AXButton"}}`},
		"get_element":            {server.handleGetElement, `{"name": "elements/e1"}`},
		"click_element":          {server.handleClickElement, `{"parent": "app", "element_id": "e1"}`},
		"get_element_actions":    {server.handleGetElementActions, `{"name": "elements/e1"}`},
		"traverse_accessibility": {server.handleTraverseAccessibility, `{"name": "applications/1"}`},
	}

	for name, h := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(h.args)}
			result, err := h.fn(call)

			if err != nil {
				t.Fatalf("%s returned error: %v", name, err)
			}
			if len(result.Content) == 0 {
				t.Fatalf("%s returned empty content", name)
			}
			if result.Content[0].Type != "text" {
				t.Errorf("%s content type = %q, want 'text'", name, result.Content[0].Type)
			}
		})
	}
}
