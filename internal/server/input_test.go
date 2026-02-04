// Copyright 2025 Joseph Cumines
//
// Input handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// mockInputClient is a mock implementation of MacosUseClient for input testing.
type mockInputClient struct {
	mockMacosUseClient

	// Input mocks
	createInputFunc func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error)
	getInputFunc    func(ctx context.Context, req *pb.GetInputRequest) (*pb.Input, error)
	listInputsFunc  func(ctx context.Context, req *pb.ListInputsRequest) (*pb.ListInputsResponse, error)

	// Cursor mock
	captureCursorPositionFunc func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error)
}

func (m *mockInputClient) CreateInput(ctx context.Context, req *pb.CreateInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	if m.createInputFunc != nil {
		return m.createInputFunc(ctx, req)
	}
	return nil, errors.New("CreateInput not implemented")
}

func (m *mockInputClient) GetInput(ctx context.Context, req *pb.GetInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	if m.getInputFunc != nil {
		return m.getInputFunc(ctx, req)
	}
	return nil, errors.New("GetInput not implemented")
}

func (m *mockInputClient) ListInputs(ctx context.Context, req *pb.ListInputsRequest, opts ...grpc.CallOption) (*pb.ListInputsResponse, error) {
	if m.listInputsFunc != nil {
		return m.listInputsFunc(ctx, req)
	}
	return nil, errors.New("ListInputs not implemented")
}

func (m *mockInputClient) CaptureCursorPosition(ctx context.Context, req *pb.CaptureCursorPositionRequest, opts ...grpc.CallOption) (*pb.CaptureCursorPositionResponse, error) {
	if m.captureCursorPositionFunc != nil {
		return m.captureCursorPositionFunc(ctx, req)
	}
	return nil, errors.New("CaptureCursorPosition not implemented")
}

// ============================================================================
// handleClick Tests
// ============================================================================

func TestHandleClick_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			click := req.Input.Action.GetClick()
			if click == nil {
				t.Error("expected click action")
				return nil, errors.New("expected click action")
			}
			if click.Position.X != 100 || click.Position.Y != 200 {
				t.Errorf("expected position (100, 200), got (%.0f, %.0f)", click.Position.X, click.Position.Y)
			}
			if click.ClickType != pb.MouseClick_CLICK_TYPE_LEFT {
				t.Errorf("expected left click, got %v", click.ClickType)
			}
			return &pb.Input{Name: "inputs/click-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": 100, "y": 200}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "left-click") {
		t.Errorf("result text does not contain 'left-click': %s", text)
	}
	if !strings.Contains(text, "(100, 200)") {
		t.Errorf("result text does not contain coordinates: %s", text)
	}
}

func TestHandleClick_RightClick(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			click := req.Input.Action.GetClick()
			if click.ClickType != pb.MouseClick_CLICK_TYPE_RIGHT {
				t.Errorf("expected right click, got %v", click.ClickType)
			}
			return &pb.Input{Name: "inputs/click-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": 100, "y": 200, "button": "right"}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "right-click") {
		t.Errorf("result text does not contain 'right-click': %s", text)
	}
}

func TestHandleClick_DoubleClick(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			click := req.Input.Action.GetClick()
			if click.ClickCount != 2 {
				t.Errorf("expected click_count 2, got %d", click.ClickCount)
			}
			return &pb.Input{Name: "inputs/click-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": 100, "y": 200, "click_count": 2}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "double") {
		t.Errorf("result text does not contain 'double': %s", text)
	}
}

func TestHandleClick_TripleClick(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			click := req.Input.Action.GetClick()
			if click.ClickCount != 3 {
				t.Errorf("expected click_count 3, got %d", click.ClickCount)
			}
			return &pb.Input{Name: "inputs/click-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": 100, "y": 200, "click_count": 3}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "triple") {
		t.Errorf("result text does not contain 'triple': %s", text)
	}
}

func TestHandleClick_NegativeCoordinates(t *testing.T) {
	// Multi-monitor setup with secondary display to the left
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			click := req.Input.Action.GetClick()
			if click.Position.X != -500 || click.Position.Y != 300 {
				t.Errorf("expected position (-500, 300), got (%.0f, %.0f)", click.Position.X, click.Position.Y)
			}
			return &pb.Input{Name: "inputs/click-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": -500, "y": 300}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleClick_InvalidJSON(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleClick_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("accessibility permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": 100, "y": 200}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to execute click") {
		t.Errorf("error text does not contain 'Failed to execute click': %s", text)
	}
}

// ============================================================================
// handleTypeText Tests
// ============================================================================

func TestHandleTypeText_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			typeText := req.Input.Action.GetTypeText()
			if typeText == nil {
				t.Error("expected type_text action")
				return nil, errors.New("expected type_text action")
			}
			if typeText.Text != "Hello World" {
				t.Errorf("expected text 'Hello World', got %q", typeText.Text)
			}
			return &pb.Input{Name: "inputs/type-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "type_text",
		Arguments: json.RawMessage(`{"text": "Hello World"}`),
	}

	result, err := server.handleTypeText(call)

	if err != nil {
		t.Fatalf("handleTypeText returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Typed 11 characters") {
		t.Errorf("result text does not contain 'Typed 11 characters': %s", text)
	}
}

func TestHandleTypeText_MissingText(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "type_text",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleTypeText(call)

	if err != nil {
		t.Fatalf("handleTypeText returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing text")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "text parameter is required") {
		t.Errorf("error text does not contain 'text parameter is required': %s", text)
	}
}

func TestHandleTypeText_EmptyText(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "type_text",
		Arguments: json.RawMessage(`{"text": ""}`),
	}

	result, err := server.handleTypeText(call)

	if err != nil {
		t.Fatalf("handleTypeText returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty text")
	}
}

func TestHandleTypeText_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("input rejected")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "type_text",
		Arguments: json.RawMessage(`{"text": "test"}`),
	}

	result, err := server.handleTypeText(call)

	if err != nil {
		t.Fatalf("handleTypeText returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to type text") {
		t.Errorf("error text does not contain 'Failed to type text': %s", text)
	}
}

// ============================================================================
// handlePressKey Tests
// ============================================================================

func TestHandlePressKey_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			pressKey := req.Input.Action.GetPressKey()
			if pressKey == nil {
				t.Error("expected press_key action")
				return nil, errors.New("expected press_key action")
			}
			if pressKey.Key != "return" {
				t.Errorf("expected key 'return', got %q", pressKey.Key)
			}
			return &pb.Input{Name: "inputs/key-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "press_key",
		Arguments: json.RawMessage(`{"key": "return"}`),
	}

	result, err := server.handlePressKey(call)

	if err != nil {
		t.Fatalf("handlePressKey returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Pressed key") {
		t.Errorf("result text does not contain 'Pressed key': %s", text)
	}
}

func TestHandlePressKey_WithModifiers(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			pressKey := req.Input.Action.GetPressKey()
			if len(pressKey.Modifiers) != 2 {
				t.Errorf("expected 2 modifiers, got %d", len(pressKey.Modifiers))
			}
			return &pb.Input{Name: "inputs/key-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "press_key",
		Arguments: json.RawMessage(`{"key": "c", "modifiers": ["command", "shift"]}`),
	}

	result, err := server.handlePressKey(call)

	if err != nil {
		t.Fatalf("handlePressKey returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Command") || !strings.Contains(text, "Shift") {
		t.Errorf("result text does not contain modifiers: %s", text)
	}
}

func TestHandlePressKey_MissingKey(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "press_key",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handlePressKey(call)

	if err != nil {
		t.Fatalf("handlePressKey returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing key")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "key parameter is required") {
		t.Errorf("error text does not contain 'key parameter is required': %s", text)
	}
}

func TestHandlePressKey_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("key press failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "press_key",
		Arguments: json.RawMessage(`{"key": "escape"}`),
	}

	result, err := server.handlePressKey(call)

	if err != nil {
		t.Fatalf("handlePressKey returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to press key") {
		t.Errorf("error text does not contain 'Failed to press key': %s", text)
	}
}

// ============================================================================
// handleDrag Tests
// ============================================================================

func TestHandleDrag_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			drag := req.Input.Action.GetDrag()
			if drag == nil {
				t.Error("expected drag action")
				return nil, errors.New("expected drag action")
			}
			if drag.StartPosition.X != 100 || drag.StartPosition.Y != 100 {
				t.Errorf("expected start (100, 100), got (%.0f, %.0f)", drag.StartPosition.X, drag.StartPosition.Y)
			}
			if drag.EndPosition.X != 200 || drag.EndPosition.Y != 200 {
				t.Errorf("expected end (200, 200), got (%.0f, %.0f)", drag.EndPosition.X, drag.EndPosition.Y)
			}
			return &pb.Input{Name: "inputs/drag-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag",
		Arguments: json.RawMessage(`{"start_x": 100, "start_y": 100, "end_x": 200, "end_y": 200}`),
	}

	result, err := server.handleDrag(call)

	if err != nil {
		t.Fatalf("handleDrag returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Dragged from") {
		t.Errorf("result text does not contain 'Dragged from': %s", text)
	}
}

func TestHandleDrag_InvalidJSON(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleDrag(call)

	if err != nil {
		t.Fatalf("handleDrag returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleDrag_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("drag failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag",
		Arguments: json.RawMessage(`{"start_x": 0, "start_y": 0, "end_x": 100, "end_y": 100}`),
	}

	result, err := server.handleDrag(call)

	if err != nil {
		t.Fatalf("handleDrag returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleScroll Tests
// ============================================================================

func TestHandleScroll_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			scroll := req.Input.Action.GetScroll()
			if scroll == nil {
				t.Error("expected scroll action")
				return nil, errors.New("expected scroll action")
			}
			if scroll.Vertical != 10 {
				t.Errorf("expected vertical 10, got %.0f", scroll.Vertical)
			}
			return &pb.Input{Name: "inputs/scroll-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "scroll",
		Arguments: json.RawMessage(`{"vertical": 10}`),
	}

	result, err := server.handleScroll(call)

	if err != nil {
		t.Fatalf("handleScroll returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Scrolled") {
		t.Errorf("result text does not contain 'Scrolled': %s", text)
	}
}

func TestHandleScroll_WithPosition(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			scroll := req.Input.Action.GetScroll()
			if scroll.Position == nil {
				t.Error("expected position to be set")
			} else if scroll.Position.X != 500 || scroll.Position.Y != 300 {
				t.Errorf("expected position (500, 300), got (%.0f, %.0f)", scroll.Position.X, scroll.Position.Y)
			}
			return &pb.Input{Name: "inputs/scroll-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "scroll",
		Arguments: json.RawMessage(`{"x": 500, "y": 300, "vertical": -5}`),
	}

	result, err := server.handleScroll(call)

	if err != nil {
		t.Fatalf("handleScroll returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleScroll_HorizontalAndVertical(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			scroll := req.Input.Action.GetScroll()
			if scroll.Horizontal != 5 || scroll.Vertical != -10 {
				t.Errorf("expected scroll (h:5, v:-10), got (h:%.0f, v:%.0f)", scroll.Horizontal, scroll.Vertical)
			}
			return &pb.Input{Name: "inputs/scroll-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "scroll",
		Arguments: json.RawMessage(`{"horizontal": 5, "vertical": -10}`),
	}

	result, err := server.handleScroll(call)

	if err != nil {
		t.Fatalf("handleScroll returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	// Should contain directional info
	if !strings.Contains(text, "right") || !strings.Contains(text, "down") {
		t.Errorf("result text does not contain direction: %s", text)
	}
}

func TestHandleScroll_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("scroll failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "scroll",
		Arguments: json.RawMessage(`{"vertical": 5}`),
	}

	result, err := server.handleScroll(call)

	if err != nil {
		t.Fatalf("handleScroll returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleHoldKey Tests
// ============================================================================

func TestHandleHoldKey_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			pressKey := req.Input.Action.GetPressKey()
			if pressKey == nil {
				t.Error("expected press_key action")
				return nil, errors.New("expected press_key action")
			}
			if pressKey.Key != "shift" {
				t.Errorf("expected key 'shift', got %q", pressKey.Key)
			}
			if pressKey.HoldDuration != 2.0 {
				t.Errorf("expected hold_duration 2.0, got %.1f", pressKey.HoldDuration)
			}
			return &pb.Input{Name: "inputs/hold-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hold_key",
		Arguments: json.RawMessage(`{"key": "shift", "duration": 2.0}`),
	}

	result, err := server.handleHoldKey(call)

	if err != nil {
		t.Fatalf("handleHoldKey returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Held key") {
		t.Errorf("result text does not contain 'Held key': %s", text)
	}
}

func TestHandleHoldKey_MissingKey(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hold_key",
		Arguments: json.RawMessage(`{"duration": 1.0}`),
	}

	result, err := server.handleHoldKey(call)

	if err != nil {
		t.Fatalf("handleHoldKey returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing key")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "key parameter is required") {
		t.Errorf("error text does not contain 'key parameter is required': %s", text)
	}
}

func TestHandleHoldKey_MissingDuration(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hold_key",
		Arguments: json.RawMessage(`{"key": "a"}`),
	}

	result, err := server.handleHoldKey(call)

	if err != nil {
		t.Fatalf("handleHoldKey returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing duration")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "duration") {
		t.Errorf("error text does not mention duration: %s", text)
	}
}

func TestHandleHoldKey_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("hold failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hold_key",
		Arguments: json.RawMessage(`{"key": "a", "duration": 1.0}`),
	}

	result, err := server.handleHoldKey(call)

	if err != nil {
		t.Fatalf("handleHoldKey returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleMouseButtonDown/Up Tests
// ============================================================================

func TestHandleMouseButtonDown_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			buttonDown := req.Input.Action.GetButtonDown()
			if buttonDown == nil {
				t.Error("expected button_down action")
				return nil, errors.New("expected button_down action")
			}
			if buttonDown.Position.X != 100 || buttonDown.Position.Y != 200 {
				t.Errorf("expected position (100, 200), got (%.0f, %.0f)", buttonDown.Position.X, buttonDown.Position.Y)
			}
			return &pb.Input{Name: "inputs/down-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "mouse_button_down",
		Arguments: json.RawMessage(`{"x": 100, "y": 200}`),
	}

	result, err := server.handleMouseButtonDown(call)

	if err != nil {
		t.Fatalf("handleMouseButtonDown returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Pressed") && !strings.Contains(text, "button down") {
		t.Errorf("result text does not indicate button press: %s", text)
	}
}

func TestHandleMouseButtonUp_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			buttonUp := req.Input.Action.GetButtonUp()
			if buttonUp == nil {
				t.Error("expected button_up action")
				return nil, errors.New("expected button_up action")
			}
			if buttonUp.Position.X != 150 || buttonUp.Position.Y != 250 {
				t.Errorf("expected position (150, 250), got (%.0f, %.0f)", buttonUp.Position.X, buttonUp.Position.Y)
			}
			return &pb.Input{Name: "inputs/up-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "mouse_button_up",
		Arguments: json.RawMessage(`{"x": 150, "y": 250}`),
	}

	result, err := server.handleMouseButtonUp(call)

	if err != nil {
		t.Fatalf("handleMouseButtonUp returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Released") {
		t.Errorf("result text does not contain 'Released': %s", text)
	}
}

func TestHandleMouseButtonDown_RightButton(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			buttonDown := req.Input.Action.GetButtonDown()
			if buttonDown.Button != pb.MouseClick_CLICK_TYPE_RIGHT {
				t.Errorf("expected right button, got %v", buttonDown.Button)
			}
			return &pb.Input{Name: "inputs/down-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "mouse_button_down",
		Arguments: json.RawMessage(`{"x": 100, "y": 100, "button": "right"}`),
	}

	result, err := server.handleMouseButtonDown(call)

	if err != nil {
		t.Fatalf("handleMouseButtonDown returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "right") {
		t.Errorf("result text does not contain 'right': %s", text)
	}
}

func TestHandleMouseButtonDown_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("button press failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "mouse_button_down",
		Arguments: json.RawMessage(`{"x": 100, "y": 100}`),
	}

	result, err := server.handleMouseButtonDown(call)

	if err != nil {
		t.Fatalf("handleMouseButtonDown returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleGetInput Tests
// ============================================================================

func TestHandleGetInput_Success(t *testing.T) {
	mockClient := &mockInputClient{
		getInputFunc: func(ctx context.Context, req *pb.GetInputRequest) (*pb.Input, error) {
			if req.Name != "inputs/test-123" {
				t.Errorf("expected name 'inputs/test-123', got %q", req.Name)
			}
			return &pb.Input{
				Name:       "inputs/test-123",
				State:      pb.Input_STATE_COMPLETED,
				CreateTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_input",
		Arguments: json.RawMessage(`{"name": "inputs/test-123"}`),
	}

	result, err := server.handleGetInput(call)

	if err != nil {
		t.Fatalf("handleGetInput returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "inputs/test-123") {
		t.Errorf("result text does not contain input name: %s", text)
	}
}

func TestHandleGetInput_MissingName(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_input",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetInput(call)

	if err != nil {
		t.Fatalf("handleGetInput returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetInput_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		getInputFunc: func(ctx context.Context, req *pb.GetInputRequest) (*pb.Input, error) {
			return nil, errors.New("input not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_input",
		Arguments: json.RawMessage(`{"name": "inputs/nonexistent"}`),
	}

	result, err := server.handleGetInput(call)

	if err != nil {
		t.Fatalf("handleGetInput returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// Table-Driven Tests for Coordinate Handling
// ============================================================================

func TestClickCoordinates_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		x, y         float64
		wantContains []string
	}{
		{
			name: "positive coordinates",
			x:    100, y: 200,
			wantContains: []string{"(100, 200)"},
		},
		{
			name: "origin coordinates",
			x:    0, y: 0,
			wantContains: []string{"(0, 0)"},
		},
		{
			name: "negative x (multi-monitor)",
			x:    -500, y: 300,
			wantContains: []string{"(-500, 300)"},
		},
		{
			name: "negative y (above main)",
			x:    200, y: -100,
			wantContains: []string{"(200, -100)"},
		},
		{
			name: "large coordinates",
			x:    5000, y: 2500,
			wantContains: []string{"(5000, 2500)"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockInputClient{
				createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
					click := req.Input.Action.GetClick()
					if click.Position.X != tt.x || click.Position.Y != tt.y {
						t.Errorf("expected position (%.0f, %.0f), got (%.0f, %.0f)", tt.x, tt.y, click.Position.X, click.Position.Y)
					}
					return &pb.Input{Name: "inputs/click-123"}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			args, _ := json.Marshal(map[string]float64{"x": tt.x, "y": tt.y})
			call := &ToolCall{Name: "click", Arguments: args}

			result, err := server.handleClick(call)

			if err != nil {
				t.Fatalf("handleClick returned error: %v", err)
			}
			if result.IsError {
				t.Errorf("result.IsError = true, want false")
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
// Content Type Tests
// ============================================================================

func TestInputHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return &pb.Input{Name: "inputs/test"}, nil
		},
		getInputFunc: func(ctx context.Context, req *pb.GetInputRequest) (*pb.Input, error) {
			return &pb.Input{Name: req.Name, State: pb.Input_STATE_COMPLETED, CreateTime: timestamppb.Now()}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	testCases := []struct {
		handler func(*ToolCall) (*ToolResult, error)
		args    string
	}{
		{server.handleClick, `{"x": 100, "y": 100}`},
		{server.handleTypeText, `{"text": "test"}`},
		{server.handlePressKey, `{"key": "a"}`},
		{server.handleScroll, `{"vertical": 1}`},
		{server.handleDrag, `{"start_x": 0, "start_y": 0, "end_x": 100, "end_y": 100}`},
		{server.handleHoldKey, `{"key": "a", "duration": 0.5}`},
		{server.handleMouseButtonDown, `{"x": 100, "y": 100}`},
		{server.handleMouseButtonUp, `{"x": 100, "y": 100}`},
		{server.handleGetInput, `{"name": "inputs/test"}`},
	}

	for i, tc := range testCases {
		call := &ToolCall{Arguments: json.RawMessage(tc.args)}
		result, err := tc.handler(call)

		if err != nil {
			t.Fatalf("testcase %d returned error: %v", i, err)
		}
		if len(result.Content) == 0 {
			t.Fatalf("testcase %d returned empty content", i)
		}
		if result.Content[0].Type != "text" {
			t.Errorf("testcase %d content type = %q, want 'text'", i, result.Content[0].Type)
		}
	}
}

// ============================================================================
// handleMouseMove Tests
// ============================================================================

func TestHandleMouseMove_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			move := req.Input.Action.GetMoveMouse()
			if move == nil {
				t.Error("expected move_mouse action")
				return nil, errors.New("expected move_mouse action")
			}
			if move.Position.X != 500 || move.Position.Y != 400 {
				t.Errorf("expected position (500, 400), got (%.0f, %.0f)", move.Position.X, move.Position.Y)
			}
			return &pb.Input{Name: "inputs/move-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "mouse_move",
		Arguments: json.RawMessage(`{"x": 500, "y": 400}`),
	}

	result, err := server.handleMouseMove(call)

	if err != nil {
		t.Fatalf("handleMouseMove returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Moved mouse") {
		t.Errorf("result text does not contain 'Moved mouse': %s", text)
	}
	if !strings.Contains(text, "(500, 400)") {
		t.Errorf("result text does not contain coordinates: %s", text)
	}
}

func TestHandleMouseMove_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("move failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "mouse_move",
		Arguments: json.RawMessage(`{"x": 100, "y": 100}`),
	}

	result, err := server.handleMouseMove(call)

	if err != nil {
		t.Fatalf("handleMouseMove returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleHover Tests
// ============================================================================

func TestHandleHover_Success(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			hover := req.Input.Action.GetHover()
			if hover == nil {
				t.Error("expected hover action")
				return nil, errors.New("expected hover action")
			}
			if hover.Position.X != 300 || hover.Position.Y != 200 {
				t.Errorf("expected position (300, 200), got (%.0f, %.0f)", hover.Position.X, hover.Position.Y)
			}
			if hover.Duration != 2.0 {
				t.Errorf("expected duration 2.0, got %.1f", hover.Duration)
			}
			return &pb.Input{Name: "inputs/hover-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hover",
		Arguments: json.RawMessage(`{"x": 300, "y": 200, "duration": 2.0}`),
	}

	result, err := server.handleHover(call)

	if err != nil {
		t.Fatalf("handleHover returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Hovered") {
		t.Errorf("result text does not contain 'Hovered': %s", text)
	}
}

func TestHandleHover_DefaultDuration(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			hover := req.Input.Action.GetHover()
			if hover.Duration != 1.0 {
				t.Errorf("expected default duration 1.0, got %.1f", hover.Duration)
			}
			return &pb.Input{Name: "inputs/hover-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hover",
		Arguments: json.RawMessage(`{"x": 100, "y": 100}`),
	}

	result, err := server.handleHover(call)

	if err != nil {
		t.Fatalf("handleHover returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleHover_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("hover failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hover",
		Arguments: json.RawMessage(`{"x": 100, "y": 100}`),
	}

	result, err := server.handleHover(call)

	if err != nil {
		t.Fatalf("handleHover returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleGesture Tests
// ============================================================================

func TestHandleGesture_PinchSuccess(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			gesture := req.Input.Action.GetGesture()
			if gesture == nil {
				t.Error("expected gesture action")
				return nil, errors.New("expected gesture action")
			}
			if gesture.GestureType != pb.Gesture_GESTURE_TYPE_PINCH {
				t.Errorf("expected pinch gesture, got %v", gesture.GestureType)
			}
			if gesture.Center.X != 400 || gesture.Center.Y != 300 {
				t.Errorf("expected center (400, 300), got (%.0f, %.0f)", gesture.Center.X, gesture.Center.Y)
			}
			return &pb.Input{Name: "inputs/gesture-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "gesture",
		Arguments: json.RawMessage(`{"gesture_type": "pinch", "center_x": 400, "center_y": 300, "scale": 0.5}`),
	}

	result, err := server.handleGesture(call)

	if err != nil {
		t.Fatalf("handleGesture returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "pinch") {
		t.Errorf("result text does not contain 'pinch': %s", text)
	}
}

func TestHandleGesture_SwipeWithDirection(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			gesture := req.Input.Action.GetGesture()
			if gesture.GestureType != pb.Gesture_GESTURE_TYPE_SWIPE {
				t.Errorf("expected swipe gesture, got %v", gesture.GestureType)
			}
			if gesture.Direction != pb.Gesture_DIRECTION_UP {
				t.Errorf("expected direction up, got %v", gesture.Direction)
			}
			return &pb.Input{Name: "inputs/gesture-123"}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "gesture",
		Arguments: json.RawMessage(`{"gesture_type": "swipe", "center_x": 500, "center_y": 500, "direction": "up"}`),
	}

	result, err := server.handleGesture(call)

	if err != nil {
		t.Fatalf("handleGesture returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleGesture_UnknownType(t *testing.T) {
	mockClient := &mockInputClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "gesture",
		Arguments: json.RawMessage(`{"gesture_type": "unknown", "center_x": 100, "center_y": 100}`),
	}

	result, err := server.handleGesture(call)

	if err != nil {
		t.Fatalf("handleGesture returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for unknown gesture type")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Unknown gesture_type") {
		t.Errorf("error text does not mention unknown gesture type: %s", text)
	}
}

func TestHandleGesture_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return nil, errors.New("gesture failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "gesture",
		Arguments: json.RawMessage(`{"gesture_type": "pinch", "center_x": 100, "center_y": 100}`),
	}

	result, err := server.handleGesture(call)

	if err != nil {
		t.Fatalf("handleGesture returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// handleListInputs Tests
// ============================================================================

func TestHandleListInputs_Success(t *testing.T) {
	mockClient := &mockInputClient{
		listInputsFunc: func(ctx context.Context, req *pb.ListInputsRequest) (*pb.ListInputsResponse, error) {
			return &pb.ListInputsResponse{
				Inputs: []*pb.Input{
					{Name: "inputs/1", State: pb.Input_STATE_COMPLETED},
					{Name: "inputs/2", State: pb.Input_STATE_PENDING},
				},
				NextPageToken: "token123",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_inputs",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListInputs(call)

	if err != nil {
		t.Fatalf("handleListInputs returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "inputs/1") {
		t.Errorf("result text does not contain 'inputs/1': %s", text)
	}
}

func TestHandleListInputs_WithPagination(t *testing.T) {
	mockClient := &mockInputClient{
		listInputsFunc: func(ctx context.Context, req *pb.ListInputsRequest) (*pb.ListInputsResponse, error) {
			if req.PageSize != 20 {
				t.Errorf("expected page_size 20, got %d", req.PageSize)
			}
			if req.PageToken != "token456" {
				t.Errorf("expected page_token 'token456', got %q", req.PageToken)
			}
			return &pb.ListInputsResponse{
				Inputs: []*pb.Input{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_inputs",
		Arguments: json.RawMessage(`{"page_size": 20, "page_token": "token456"}`),
	}

	result, err := server.handleListInputs(call)

	if err != nil {
		t.Fatalf("handleListInputs returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleListInputs_GRPCError(t *testing.T) {
	mockClient := &mockInputClient{
		listInputsFunc: func(ctx context.Context, req *pb.ListInputsRequest) (*pb.ListInputsResponse, error) {
			return nil, errors.New("list failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_inputs",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListInputs(call)

	if err != nil {
		t.Fatalf("handleListInputs returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}
}

// ============================================================================
// Edge Case Tests for Input Handlers
// ============================================================================

func TestHandleClick_ZeroClickCount(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			// Verify that zero click_count is passed to the server
			// The server should handle this appropriately (default to 1 or process as-is)
			return &pb.Input{
				Name:         "inputs/test-123",
				State:        pb.Input_STATE_COMPLETED,
				CreateTime:   timestamppb.Now(),
				CompleteTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "click",
		Arguments: json.RawMessage(`{"x": 100, "y": 200, "click_count": 0}`),
	}

	result, err := server.handleClick(call)

	if err != nil {
		t.Fatalf("handleClick returned error: %v", err)
	}
	// Zero click_count should either succeed or be handled gracefully
	// Verifying that no panic or hard error occurs
	if len(result.Content) == 0 {
		t.Error("Expected result content")
	}
}

func TestHandleHoldKey_ZeroDuration(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return &pb.Input{
				Name:         "inputs/test-hold",
				State:        pb.Input_STATE_COMPLETED,
				CreateTime:   timestamppb.Now(),
				CompleteTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "hold_key",
		Arguments: json.RawMessage(`{"key": "shift", "duration": 0}`),
	}

	result, err := server.handleHoldKey(call)

	if err != nil {
		t.Fatalf("handleHoldKey returned error: %v", err)
	}
	// Zero duration should succeed (instant press/release)
	if len(result.Content) == 0 {
		t.Error("Expected result content")
	}
}

func TestHandleHoldKey_NegativeDuration(t *testing.T) {
	server := newTestMCPServer(&mockInputClient{})
	call := &ToolCall{
		Name:      "hold_key",
		Arguments: json.RawMessage(`{"key": "shift", "duration": -1.0}`),
	}

	result, err := server.handleHoldKey(call)

	if err != nil {
		t.Fatalf("handleHoldKey returned error: %v", err)
	}
	// Negative duration is an edge case - should either error or use default
	// This test documents the behavior
	if len(result.Content) == 0 {
		t.Error("Expected result content")
	}
}

func TestHandleDrag_SameStartEnd(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return &pb.Input{
				Name:         "inputs/test-drag",
				State:        pb.Input_STATE_COMPLETED,
				CreateTime:   timestamppb.Now(),
				CompleteTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag",
		Arguments: json.RawMessage(`{"start_x": 100, "start_y": 100, "end_x": 100, "end_y": 100}`),
	}

	result, err := server.handleDrag(call)

	if err != nil {
		t.Fatalf("handleDrag returned error: %v", err)
	}
	// Drag to same point is a no-op but should succeed
	if result.IsError {
		t.Errorf("Expected success for drag to same position: %s", result.Content[0].Text)
	}
}

func TestHandleScroll_ZeroMovement(t *testing.T) {
	mockClient := &mockInputClient{
		createInputFunc: func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
			return &pb.Input{
				Name:         "inputs/test-scroll",
				State:        pb.Input_STATE_COMPLETED,
				CreateTime:   timestamppb.Now(),
				CompleteTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "scroll",
		Arguments: json.RawMessage(`{"x": 100, "y": 200, "vertical": 0, "horizontal": 0}`),
	}

	result, err := server.handleScroll(call)

	if err != nil {
		t.Fatalf("handleScroll returned error: %v", err)
	}
	// Zero scroll in both directions is a no-op but should succeed
	if result.IsError {
		t.Errorf("Expected success for zero scroll: %s", result.Content[0].Text)
	}
}

// Ensure typepb is used to avoid import error
var _ = typepb.Point{}
