// Copyright 2025 Joseph Cumines
//
// Window handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
)

// mockWindowClient is a mock implementation of MacosUseClient for window testing.
type mockWindowClient struct {
	mockMacosUseClient

	// ListWindows mock
	listWindowsFunc func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error)
	// GetWindow mock
	getWindowFunc func(ctx context.Context, req *pb.GetWindowRequest) (*pb.Window, error)
	// GetWindowState mock
	getWindowStateFunc func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error)
	// FocusWindow mock
	focusWindowFunc func(ctx context.Context, req *pb.FocusWindowRequest) (*pb.Window, error)
	// MoveWindow mock
	moveWindowFunc func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error)
	// ResizeWindow mock
	resizeWindowFunc func(ctx context.Context, req *pb.ResizeWindowRequest) (*pb.Window, error)
	// MinimizeWindow mock
	minimizeWindowFunc func(ctx context.Context, req *pb.MinimizeWindowRequest) (*pb.Window, error)
	// RestoreWindow mock
	restoreWindowFunc func(ctx context.Context, req *pb.RestoreWindowRequest) (*pb.Window, error)
	// CloseWindow mock
	closeWindowFunc func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error)
}

func (m *mockWindowClient) ListWindows(ctx context.Context, req *pb.ListWindowsRequest, opts ...grpc.CallOption) (*pb.ListWindowsResponse, error) {
	if m.listWindowsFunc != nil {
		return m.listWindowsFunc(ctx, req)
	}
	return nil, errors.New("ListWindows not implemented")
}

func (m *mockWindowClient) GetWindow(ctx context.Context, req *pb.GetWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.getWindowFunc != nil {
		return m.getWindowFunc(ctx, req)
	}
	return nil, errors.New("GetWindow not implemented")
}

func (m *mockWindowClient) GetWindowState(ctx context.Context, req *pb.GetWindowStateRequest, opts ...grpc.CallOption) (*pb.WindowState, error) {
	if m.getWindowStateFunc != nil {
		return m.getWindowStateFunc(ctx, req)
	}
	return nil, errors.New("GetWindowState not implemented")
}

func (m *mockWindowClient) FocusWindow(ctx context.Context, req *pb.FocusWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.focusWindowFunc != nil {
		return m.focusWindowFunc(ctx, req)
	}
	return nil, errors.New("FocusWindow not implemented")
}

func (m *mockWindowClient) MoveWindow(ctx context.Context, req *pb.MoveWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.moveWindowFunc != nil {
		return m.moveWindowFunc(ctx, req)
	}
	return nil, errors.New("MoveWindow not implemented")
}

func (m *mockWindowClient) ResizeWindow(ctx context.Context, req *pb.ResizeWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.resizeWindowFunc != nil {
		return m.resizeWindowFunc(ctx, req)
	}
	return nil, errors.New("ResizeWindow not implemented")
}

func (m *mockWindowClient) MinimizeWindow(ctx context.Context, req *pb.MinimizeWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.minimizeWindowFunc != nil {
		return m.minimizeWindowFunc(ctx, req)
	}
	return nil, errors.New("MinimizeWindow not implemented")
}

func (m *mockWindowClient) RestoreWindow(ctx context.Context, req *pb.RestoreWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.restoreWindowFunc != nil {
		return m.restoreWindowFunc(ctx, req)
	}
	return nil, errors.New("RestoreWindow not implemented")
}

func (m *mockWindowClient) CloseWindow(ctx context.Context, req *pb.CloseWindowRequest, opts ...grpc.CallOption) (*pb.CloseWindowResponse, error) {
	if m.closeWindowFunc != nil {
		return m.closeWindowFunc(ctx, req)
	}
	return nil, errors.New("CloseWindow not implemented")
}

// ============================================================================
// handleListWindows Tests
// ============================================================================

func TestHandleListWindows_Success_MultipleWindows(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			return &pb.ListWindowsResponse{
				Windows: []*pb.Window{
					{Name: "applications/123/windows/1", Title: "Document 1", Visible: true, Bounds: &pb.Bounds{X: 0, Y: 0, Width: 800, Height: 600}},
					{Name: "applications/123/windows/2", Title: "Document 2", Visible: false, Bounds: &pb.Bounds{X: 100, Y: 100, Width: 640, Height: 480}},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 2 windows") {
		t.Errorf("result text does not contain 'Found 2 windows': %s", text)
	}
	if !strings.Contains(text, "Document 1") {
		t.Errorf("result text does not contain 'Document 1': %s", text)
	}
	if !strings.Contains(text, "[visible]") {
		t.Errorf("result text does not contain '[visible]' marker: %s", text)
	}
}

func TestHandleListWindows_Success_SingleWindow(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			return &pb.ListWindowsResponse{
				Windows: []*pb.Window{
					{Name: "applications/Calculator/windows/1", Title: "Calculator", Visible: true, Bounds: &pb.Bounds{X: 50, Y: 100, Width: 400, Height: 300}},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 1 windows") {
		t.Errorf("result text does not contain 'Found 1 windows': %s", text)
	}
	if !strings.Contains(text, "Calculator") {
		t.Errorf("result text does not contain 'Calculator': %s", text)
	}
}

func TestHandleListWindows_NoWindowsFound(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			return &pb.ListWindowsResponse{Windows: []*pb.Window{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No windows found" {
		t.Errorf("result text = %q, want 'No windows found'", text)
	}
}

func TestHandleListWindows_WithParentFilter(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			if req.Parent != "applications/TextEdit" {
				t.Errorf("expected parent 'applications/TextEdit', got %q", req.Parent)
			}
			return &pb.ListWindowsResponse{
				Windows: []*pb.Window{
					{Name: "applications/TextEdit/windows/1", Title: "Untitled.txt", Visible: true},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_windows",
		Arguments: json.RawMessage(`{"parent": "applications/TextEdit"}`),
	}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleListWindows_WithPagination(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			if req.PageSize != 10 {
				t.Errorf("expected page_size 10, got %d", req.PageSize)
			}
			if req.PageToken != "abc123" {
				t.Errorf("expected page_token 'abc123', got %q", req.PageToken)
			}
			return &pb.ListWindowsResponse{
				Windows: []*pb.Window{
					{Name: "applications/1/windows/1", Title: "Window 1", Visible: true},
				},
				NextPageToken: "next-page-xyz",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_windows",
		Arguments: json.RawMessage(`{"page_size": 10, "page_token": "abc123"}`),
	}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "next-page-xyz") {
		t.Errorf("result text does not contain next_page_token: %s", text)
	}
}

func TestHandleListWindows_NegativePageSize(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_windows",
		Arguments: json.RawMessage(`{"page_size": -5}`),
	}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for negative page_size")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "page_size must be non-negative") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleListWindows_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(`{invalid json}`)}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleListWindows_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			return nil, errors.New("connection refused")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListWindows(call)

	if err != nil {
		t.Fatalf("handleListWindows returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in list_windows") {
		t.Errorf("error text does not contain 'Error in list_windows': %s", text)
	}
}

// ============================================================================
// handleGetWindow Tests
// ============================================================================

func TestHandleGetWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		getWindowFunc: func(ctx context.Context, req *pb.GetWindowRequest) (*pb.Window, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			return &pb.Window{
				Name:     "applications/123/windows/456",
				Title:    "Test Window",
				Visible:  true,
				ZIndex:   5,
				BundleId: "com.example.app",
				Bounds:   &pb.Bounds{X: 100, Y: 200, Width: 800, Height: 600},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456"}`),
	}

	result, err := server.handleGetWindow(call)

	if err != nil {
		t.Fatalf("handleGetWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Window: applications/123/windows/456") {
		t.Errorf("result text does not contain window name: %s", text)
	}
	if !strings.Contains(text, "Title: Test Window") {
		t.Errorf("result text does not contain title: %s", text)
	}
	if !strings.Contains(text, "Visible: true") {
		t.Errorf("result text does not contain visible status: %s", text)
	}
	if !strings.Contains(text, "Z-Index: 5") {
		t.Errorf("result text does not contain z-index: %s", text)
	}
	if !strings.Contains(text, "Bundle ID: com.example.app") {
		t.Errorf("result text does not contain bundle ID: %s", text)
	}
}

func TestHandleGetWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_window", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetWindow(call)

	if err != nil {
		t.Fatalf("handleGetWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetWindow_EmptyName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_window", Arguments: json.RawMessage(`{"name": ""}`)}

	result, err := server.handleGetWindow(call)

	if err != nil {
		t.Fatalf("handleGetWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty name")
	}
}

func TestHandleGetWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_window", Arguments: json.RawMessage(`{not valid}`)}

	result, err := server.handleGetWindow(call)

	if err != nil {
		t.Fatalf("handleGetWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleGetWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		getWindowFunc: func(ctx context.Context, req *pb.GetWindowRequest) (*pb.Window, error) {
			return nil, errors.New("window not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/nonexistent"}`),
	}

	result, err := server.handleGetWindow(call)

	if err != nil {
		t.Fatalf("handleGetWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in get_window") {
		t.Errorf("error text does not contain 'Error in get_window': %s", text)
	}
}

// ============================================================================
// handleMoveWindow Tests
// ============================================================================

func TestHandleMoveWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		moveWindowFunc: func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			if req.X != 200.0 {
				t.Errorf("expected X 200.0, got %f", req.X)
			}
			if req.Y != 300.0 {
				t.Errorf("expected Y 300.0, got %f", req.Y)
			}
			return &pb.Window{
				Name:   "applications/123/windows/456",
				Title:  "Moved Window",
				Bounds: &pb.Bounds{X: 200, Y: 300, Width: 800, Height: 600},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "move_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456", "x": 200, "y": 300}`),
	}

	result, err := server.handleMoveWindow(call)

	if err != nil {
		t.Fatalf("handleMoveWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Moved window") {
		t.Errorf("result text does not contain 'Moved window': %s", text)
	}
	if !strings.Contains(text, "(200, 300)") {
		t.Errorf("result text does not contain new position: %s", text)
	}
}

func TestHandleMoveWindow_NegativeCoordinates(t *testing.T) {
	// Valid for multi-monitor setups
	mockClient := &mockWindowClient{
		moveWindowFunc: func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error) {
			if req.X != -500.0 {
				t.Errorf("expected X -500.0, got %f", req.X)
			}
			if req.Y != -100.0 {
				t.Errorf("expected Y -100.0, got %f", req.Y)
			}
			return &pb.Window{
				Title:  "Window",
				Bounds: &pb.Bounds{X: -500, Y: -100, Width: 800, Height: 600},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "move_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1", "x": -500, "y": -100}`),
	}

	result, err := server.handleMoveWindow(call)

	if err != nil {
		t.Fatalf("handleMoveWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
}

func TestHandleMoveWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "move_window",
		Arguments: json.RawMessage(`{"x": 100, "y": 200}`),
	}

	result, err := server.handleMoveWindow(call)

	if err != nil {
		t.Fatalf("handleMoveWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleMoveWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "move_window", Arguments: json.RawMessage(`{invalid}`)}

	result, err := server.handleMoveWindow(call)

	if err != nil {
		t.Fatalf("handleMoveWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleMoveWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		moveWindowFunc: func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error) {
			return nil, errors.New("window is not movable")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "move_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1", "x": 0, "y": 0}`),
	}

	result, err := server.handleMoveWindow(call)

	if err != nil {
		t.Fatalf("handleMoveWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in move_window") {
		t.Errorf("error text does not contain 'Error in move_window': %s", text)
	}
}

// ============================================================================
// handleResizeWindow Tests
// ============================================================================

func TestHandleResizeWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		resizeWindowFunc: func(ctx context.Context, req *pb.ResizeWindowRequest) (*pb.Window, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			if req.Width != 1024.0 {
				t.Errorf("expected Width 1024.0, got %f", req.Width)
			}
			if req.Height != 768.0 {
				t.Errorf("expected Height 768.0, got %f", req.Height)
			}
			return &pb.Window{
				Name:   "applications/123/windows/456",
				Title:  "Resized Window",
				Bounds: &pb.Bounds{X: 0, Y: 0, Width: 1024, Height: 768},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "resize_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456", "width": 1024, "height": 768}`),
	}

	result, err := server.handleResizeWindow(call)

	if err != nil {
		t.Fatalf("handleResizeWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Resized window") {
		t.Errorf("result text does not contain 'Resized window': %s", text)
	}
	if !strings.Contains(text, "1024x768") {
		t.Errorf("result text does not contain new size: %s", text)
	}
}

func TestHandleResizeWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "resize_window",
		Arguments: json.RawMessage(`{"width": 800, "height": 600}`),
	}

	result, err := server.handleResizeWindow(call)

	if err != nil {
		t.Fatalf("handleResizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}
}

func TestHandleResizeWindow_ZeroWidth(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "resize_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1", "width": 0, "height": 600}`),
	}

	result, err := server.handleResizeWindow(call)

	if err != nil {
		t.Fatalf("handleResizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for zero width")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "width and height must be positive") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleResizeWindow_NegativeHeight(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "resize_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1", "width": 800, "height": -100}`),
	}

	result, err := server.handleResizeWindow(call)

	if err != nil {
		t.Fatalf("handleResizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for negative height")
	}
}

func TestHandleResizeWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "resize_window", Arguments: json.RawMessage(`{broken}`)}

	result, err := server.handleResizeWindow(call)

	if err != nil {
		t.Fatalf("handleResizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleResizeWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		resizeWindowFunc: func(ctx context.Context, req *pb.ResizeWindowRequest) (*pb.Window, error) {
			return nil, errors.New("window is not resizable")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "resize_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1", "width": 800, "height": 600}`),
	}

	result, err := server.handleResizeWindow(call)

	if err != nil {
		t.Fatalf("handleResizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in resize_window") {
		t.Errorf("error text does not contain 'Error in resize_window': %s", text)
	}
}

// ============================================================================
// handleMinimizeWindow Tests
// ============================================================================

func TestHandleMinimizeWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		minimizeWindowFunc: func(ctx context.Context, req *pb.MinimizeWindowRequest) (*pb.Window, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			return &pb.Window{
				Name:  "applications/123/windows/456",
				Title: "Minimized Window",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "minimize_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456"}`),
	}

	result, err := server.handleMinimizeWindow(call)

	if err != nil {
		t.Fatalf("handleMinimizeWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Minimized window") {
		t.Errorf("result text does not contain 'Minimized window': %s", text)
	}
}

func TestHandleMinimizeWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "minimize_window", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleMinimizeWindow(call)

	if err != nil {
		t.Fatalf("handleMinimizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleMinimizeWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "minimize_window", Arguments: json.RawMessage(`{bad}`)}

	result, err := server.handleMinimizeWindow(call)

	if err != nil {
		t.Fatalf("handleMinimizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleMinimizeWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		minimizeWindowFunc: func(ctx context.Context, req *pb.MinimizeWindowRequest) (*pb.Window, error) {
			return nil, errors.New("cannot minimize modal window")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "minimize_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleMinimizeWindow(call)

	if err != nil {
		t.Fatalf("handleMinimizeWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in minimize_window") {
		t.Errorf("error text does not contain 'Error in minimize_window': %s", text)
	}
}

// ============================================================================
// handleRestoreWindow Tests
// ============================================================================

func TestHandleRestoreWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		restoreWindowFunc: func(ctx context.Context, req *pb.RestoreWindowRequest) (*pb.Window, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			return &pb.Window{
				Name:  "applications/123/windows/456",
				Title: "Restored Window",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "restore_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456"}`),
	}

	result, err := server.handleRestoreWindow(call)

	if err != nil {
		t.Fatalf("handleRestoreWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Restored window") {
		t.Errorf("result text does not contain 'Restored window': %s", text)
	}
}

func TestHandleRestoreWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "restore_window", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleRestoreWindow(call)

	if err != nil {
		t.Fatalf("handleRestoreWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}
}

func TestHandleRestoreWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "restore_window", Arguments: json.RawMessage(`{invalid}`)}

	result, err := server.handleRestoreWindow(call)

	if err != nil {
		t.Fatalf("handleRestoreWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleRestoreWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		restoreWindowFunc: func(ctx context.Context, req *pb.RestoreWindowRequest) (*pb.Window, error) {
			return nil, errors.New("window is not minimized")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "restore_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleRestoreWindow(call)

	if err != nil {
		t.Fatalf("handleRestoreWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in restore_window") {
		t.Errorf("error text does not contain 'Error in restore_window': %s", text)
	}
}

// ============================================================================
// handleCloseWindow Tests
// ============================================================================

func TestHandleCloseWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		closeWindowFunc: func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			return &pb.CloseWindowResponse{Success: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "close_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456"}`),
	}

	result, err := server.handleCloseWindow(call)

	if err != nil {
		t.Fatalf("handleCloseWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Closed window") {
		t.Errorf("result text does not contain 'Closed window': %s", text)
	}
}

func TestHandleCloseWindow_WithForce(t *testing.T) {
	mockClient := &mockWindowClient{
		closeWindowFunc: func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error) {
			if !req.Force {
				t.Error("expected force to be true")
			}
			return &pb.CloseWindowResponse{Success: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "close_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1", "force": true}`),
	}

	result, err := server.handleCloseWindow(call)

	if err != nil {
		t.Fatalf("handleCloseWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCloseWindow_SuccessFalse(t *testing.T) {
	mockClient := &mockWindowClient{
		closeWindowFunc: func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error) {
			return &pb.CloseWindowResponse{Success: false}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "close_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleCloseWindow(call)

	if err != nil {
		t.Fatalf("handleCloseWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true when success is false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in close_window") {
		t.Errorf("error text does not contain 'Error in close_window': %s", text)
	}
}

func TestHandleCloseWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "close_window", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCloseWindow(call)

	if err != nil {
		t.Fatalf("handleCloseWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}
}

func TestHandleCloseWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "close_window", Arguments: json.RawMessage(`{broken}`)}

	result, err := server.handleCloseWindow(call)

	if err != nil {
		t.Fatalf("handleCloseWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleCloseWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		closeWindowFunc: func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error) {
			return nil, errors.New("window has unsaved changes")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "close_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleCloseWindow(call)

	if err != nil {
		t.Fatalf("handleCloseWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in close_window") {
		t.Errorf("error text does not contain 'Error in close_window': %s", text)
	}
}

// ============================================================================
// handleFocusWindow Tests
// ============================================================================

func TestHandleFocusWindow_Success(t *testing.T) {
	mockClient := &mockWindowClient{
		focusWindowFunc: func(ctx context.Context, req *pb.FocusWindowRequest) (*pb.Window, error) {
			if req.Name != "applications/123/windows/456" {
				t.Errorf("expected name 'applications/123/windows/456', got %q", req.Name)
			}
			return &pb.Window{
				Name:  "applications/123/windows/456",
				Title: "Focused Window",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "focus_window",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456"}`),
	}

	result, err := server.handleFocusWindow(call)

	if err != nil {
		t.Fatalf("handleFocusWindow returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Focused window") {
		t.Errorf("result text does not contain 'Focused window': %s", text)
	}
	if !strings.Contains(text, "Focused Window") {
		t.Errorf("result text does not contain window title: %s", text)
	}
}

func TestHandleFocusWindow_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "focus_window", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleFocusWindow(call)

	if err != nil {
		t.Fatalf("handleFocusWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}
}

func TestHandleFocusWindow_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "focus_window", Arguments: json.RawMessage(`{bad}`)}

	result, err := server.handleFocusWindow(call)

	if err != nil {
		t.Fatalf("handleFocusWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleFocusWindow_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		focusWindowFunc: func(ctx context.Context, req *pb.FocusWindowRequest) (*pb.Window, error) {
			return nil, errors.New("window is hidden")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "focus_window",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleFocusWindow(call)

	if err != nil {
		t.Fatalf("handleFocusWindow returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in focus_window") {
		t.Errorf("error text does not contain 'Error in focus_window': %s", text)
	}
}

// ============================================================================
// handleGetWindowState Tests
// ============================================================================

func TestHandleGetWindowState_Success(t *testing.T) {
	fullscreen := true
	mockClient := &mockWindowClient{
		getWindowStateFunc: func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error) {
			if !strings.HasSuffix(req.Name, "/state") {
				t.Errorf("expected name to end with '/state', got %q", req.Name)
			}
			return &pb.WindowState{
				Resizable:   true,
				Minimizable: true,
				Closable:    true,
				Modal:       false,
				Floating:    false,
				AxHidden:    false,
				Minimized:   false,
				Focused:     true,
				Fullscreen:  &fullscreen,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_window_state",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456"}`),
	}

	result, err := server.handleGetWindowState(call)

	if err != nil {
		t.Fatalf("handleGetWindowState returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Window State:") {
		t.Errorf("result text does not contain 'Window State:': %s", text)
	}
	if !strings.Contains(text, "Resizable: true") {
		t.Errorf("result text does not contain 'Resizable: true': %s", text)
	}
	if !strings.Contains(text, "Focused: true") {
		t.Errorf("result text does not contain 'Focused: true': %s", text)
	}
	if !strings.Contains(text, "Fullscreen: true") {
		t.Errorf("result text does not contain 'Fullscreen: true': %s", text)
	}
}

func TestHandleGetWindowState_NameWithStateSuffix(t *testing.T) {
	mockClient := &mockWindowClient{
		getWindowStateFunc: func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error) {
			// Name should already have /state suffix
			if req.Name != "applications/123/windows/456/state" {
				t.Errorf("expected name 'applications/123/windows/456/state', got %q", req.Name)
			}
			return &pb.WindowState{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_window_state",
		Arguments: json.RawMessage(`{"name": "applications/123/windows/456/state"}`),
	}

	result, err := server.handleGetWindowState(call)

	if err != nil {
		t.Fatalf("handleGetWindowState returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleGetWindowState_NoFullscreen(t *testing.T) {
	mockClient := &mockWindowClient{
		getWindowStateFunc: func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error) {
			return &pb.WindowState{
				Resizable:  true,
				Fullscreen: nil, // not provided
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_window_state",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleGetWindowState(call)

	if err != nil {
		t.Fatalf("handleGetWindowState returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	// Should not contain Fullscreen line if nil
	if strings.Contains(text, "Fullscreen:") {
		t.Errorf("result text should not contain 'Fullscreen:' when nil: %s", text)
	}
}

func TestHandleGetWindowState_MissingName(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_window_state", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleGetWindowState(call)

	if err != nil {
		t.Fatalf("handleGetWindowState returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleGetWindowState_InvalidJSON(t *testing.T) {
	mockClient := &mockWindowClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "get_window_state", Arguments: json.RawMessage(`{broken}`)}

	result, err := server.handleGetWindowState(call)

	if err != nil {
		t.Fatalf("handleGetWindowState returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleGetWindowState_GRPCError(t *testing.T) {
	mockClient := &mockWindowClient{
		getWindowStateFunc: func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error) {
			return nil, errors.New("window state not available")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_window_state",
		Arguments: json.RawMessage(`{"name": "applications/1/windows/1"}`),
	}

	result, err := server.handleGetWindowState(call)

	if err != nil {
		t.Fatalf("handleGetWindowState returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Error in get_window_state") {
		t.Errorf("error text does not contain 'Error in get_window_state': %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestHandleListWindows_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		windows      []*pb.Window
		nextToken    string
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "multiple windows",
			args: `{}`,
			windows: []*pb.Window{
				{Name: "w1", Title: "Window 1", Visible: true, Bounds: &pb.Bounds{X: 0, Y: 0, Width: 800, Height: 600}},
				{Name: "w2", Title: "Window 2", Visible: false, Bounds: &pb.Bounds{X: 100, Y: 100, Width: 640, Height: 480}},
			},
			wantIsError:  false,
			wantContains: []string{"Found 2 windows", "Window 1", "Window 2", "[visible]"},
		},
		{
			name:         "no windows",
			args:         `{}`,
			windows:      []*pb.Window{},
			wantIsError:  false,
			wantContains: []string{"No windows found"},
		},
		{
			name:         "nil windows",
			args:         `{}`,
			windows:      nil,
			wantIsError:  false,
			wantContains: []string{"No windows found"},
		},
		{
			name: "with pagination token",
			args: `{}`,
			windows: []*pb.Window{
				{Name: "w1", Title: "Win", Visible: true},
			},
			nextToken:    "next-page-123",
			wantIsError:  false,
			wantContains: []string{"next-page-123", "More results available"},
		},
		{
			name:         "with parent filter",
			args:         `{"parent": "applications/Calculator"}`,
			windows:      []*pb.Window{{Name: "w", Title: "Calc", Visible: true}},
			wantIsError:  false,
			wantContains: []string{"Calc"},
		},
		{
			name:         "invalid JSON",
			args:         `{invalid}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "negative page_size",
			args:         `{"page_size": -1}`,
			wantIsError:  true,
			wantContains: []string{"page_size must be non-negative"},
		},
		{
			name:         "gRPC error",
			args:         `{}`,
			grpcErr:      errors.New("server unavailable"),
			wantIsError:  true,
			wantContains: []string{"Error in list_windows", "server unavailable"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockWindowClient{
				listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.ListWindowsResponse{Windows: tt.windows, NextPageToken: tt.nextToken}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleListWindows(call)

			if err != nil {
				t.Fatalf("handleListWindows returned Go error: %v", err)
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

func TestHandleGetWindow_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		window       *pb.Window
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name: "full window info",
			args: `{"name": "applications/123/windows/456"}`,
			window: &pb.Window{
				Name:     "applications/123/windows/456",
				Title:    "Test Window",
				Visible:  true,
				ZIndex:   10,
				BundleId: "com.test.app",
				Bounds:   &pb.Bounds{X: 100, Y: 200, Width: 800, Height: 600},
			},
			wantIsError:  false,
			wantContains: []string{"Window:", "Title: Test Window", "Visible: true", "Z-Index: 10", "Bundle ID: com.test.app"},
		},
		{
			name:         "missing name",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "empty name",
			args:         `{"name": ""}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{notvalid}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"name": "applications/1/windows/1"}`,
			grpcErr:      errors.New("not found"),
			wantIsError:  true,
			wantContains: []string{"Error in get_window", "not found"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockWindowClient{
				getWindowFunc: func(ctx context.Context, req *pb.GetWindowRequest) (*pb.Window, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.window, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "get_window", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleGetWindow(call)

			if err != nil {
				t.Fatalf("handleGetWindow returned Go error: %v", err)
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

func TestHandleMoveWindow_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "valid move",
			args:         `{"name": "w1", "x": 100, "y": 200}`,
			wantIsError:  false,
			wantContains: []string{"Moved window"},
		},
		{
			name:         "negative coordinates (valid)",
			args:         `{"name": "w1", "x": -500, "y": -100}`,
			wantIsError:  false,
			wantContains: []string{"Moved window"},
		},
		{
			name:         "zero coordinates",
			args:         `{"name": "w1", "x": 0, "y": 0}`,
			wantIsError:  false,
			wantContains: []string{"Moved window"},
		},
		{
			name:         "missing name",
			args:         `{"x": 100, "y": 200}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"name": "w1", "x": 0, "y": 0}`,
			grpcErr:      errors.New("permission denied"),
			wantIsError:  true,
			wantContains: []string{"Error in move_window", "permission denied"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockWindowClient{
				moveWindowFunc: func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.Window{Title: "Win", Bounds: &pb.Bounds{X: req.X, Y: req.Y, Width: 800, Height: 600}}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "move_window", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleMoveWindow(call)

			if err != nil {
				t.Fatalf("handleMoveWindow returned Go error: %v", err)
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

func TestHandleResizeWindow_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "valid resize",
			args:         `{"name": "w1", "width": 1024, "height": 768}`,
			wantIsError:  false,
			wantContains: []string{"Resized window", "1024x768"},
		},
		{
			name:         "small size",
			args:         `{"name": "w1", "width": 100, "height": 50}`,
			wantIsError:  false,
			wantContains: []string{"Resized window", "100x50"},
		},
		{
			name:         "large size",
			args:         `{"name": "w1", "width": 3840, "height": 2160}`,
			wantIsError:  false,
			wantContains: []string{"Resized window", "3840x2160"},
		},
		{
			name:         "zero width",
			args:         `{"name": "w1", "width": 0, "height": 768}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "zero height",
			args:         `{"name": "w1", "width": 1024, "height": 0}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "negative width",
			args:         `{"name": "w1", "width": -100, "height": 768}`,
			wantIsError:  true,
			wantContains: []string{"width and height must be positive"},
		},
		{
			name:         "missing name",
			args:         `{"width": 800, "height": 600}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{broken}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"name": "w1", "width": 800, "height": 600}`,
			grpcErr:      errors.New("window not resizable"),
			wantIsError:  true,
			wantContains: []string{"Error in resize_window", "window not resizable"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockWindowClient{
				resizeWindowFunc: func(ctx context.Context, req *pb.ResizeWindowRequest) (*pb.Window, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.Window{Title: "Win", Bounds: &pb.Bounds{Width: req.Width, Height: req.Height}}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "resize_window", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleResizeWindow(call)

			if err != nil {
				t.Fatalf("handleResizeWindow returned Go error: %v", err)
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

func TestWindowHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			return &pb.ListWindowsResponse{Windows: []*pb.Window{{Name: "w1", Title: "Win", Visible: true}}}, nil
		},
		getWindowFunc: func(ctx context.Context, req *pb.GetWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "w1", Title: "Win"}, nil
		},
		getWindowStateFunc: func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error) {
			return &pb.WindowState{Resizable: true}, nil
		},
		focusWindowFunc: func(ctx context.Context, req *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "w1", Title: "Win"}, nil
		},
		moveWindowFunc: func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win", Bounds: &pb.Bounds{X: 0, Y: 0, Width: 800, Height: 600}}, nil
		},
		resizeWindowFunc: func(ctx context.Context, req *pb.ResizeWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win", Bounds: &pb.Bounds{Width: 800, Height: 600}}, nil
		},
		minimizeWindowFunc: func(ctx context.Context, req *pb.MinimizeWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win"}, nil
		},
		restoreWindowFunc: func(ctx context.Context, req *pb.RestoreWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win"}, nil
		},
		closeWindowFunc: func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error) {
			return &pb.CloseWindowResponse{Success: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"list_windows":     {server.handleListWindows, `{}`},
		"get_window":       {server.handleGetWindow, `{"name": "w1"}`},
		"get_window_state": {server.handleGetWindowState, `{"name": "w1"}`},
		"focus_window":     {server.handleFocusWindow, `{"name": "w1"}`},
		"move_window":      {server.handleMoveWindow, `{"name": "w1", "x": 0, "y": 0}`},
		"resize_window":    {server.handleResizeWindow, `{"name": "w1", "width": 800, "height": 600}`},
		"minimize_window":  {server.handleMinimizeWindow, `{"name": "w1"}`},
		"restore_window":   {server.handleRestoreWindow, `{"name": "w1"}`},
		"close_window":     {server.handleCloseWindow, `{"name": "w1"}`},
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

func TestWindowHandlers_SingleContentItem(t *testing.T) {
	mockClient := &mockWindowClient{
		listWindowsFunc: func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			return &pb.ListWindowsResponse{Windows: []*pb.Window{{Name: "w1", Title: "Win", Visible: true}}}, nil
		},
		getWindowFunc: func(ctx context.Context, req *pb.GetWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "w1", Title: "Win"}, nil
		},
		getWindowStateFunc: func(ctx context.Context, req *pb.GetWindowStateRequest) (*pb.WindowState, error) {
			return &pb.WindowState{}, nil
		},
		focusWindowFunc: func(ctx context.Context, req *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "w1", Title: "Win"}, nil
		},
		moveWindowFunc: func(ctx context.Context, req *pb.MoveWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win", Bounds: &pb.Bounds{}}, nil
		},
		resizeWindowFunc: func(ctx context.Context, req *pb.ResizeWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win", Bounds: &pb.Bounds{}}, nil
		},
		minimizeWindowFunc: func(ctx context.Context, req *pb.MinimizeWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win"}, nil
		},
		restoreWindowFunc: func(ctx context.Context, req *pb.RestoreWindowRequest) (*pb.Window, error) {
			return &pb.Window{Title: "Win"}, nil
		},
		closeWindowFunc: func(ctx context.Context, req *pb.CloseWindowRequest) (*pb.CloseWindowResponse, error) {
			return &pb.CloseWindowResponse{Success: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"list_windows":     {server.handleListWindows, `{}`},
		"get_window":       {server.handleGetWindow, `{"name": "w1"}`},
		"get_window_state": {server.handleGetWindowState, `{"name": "w1"}`},
		"focus_window":     {server.handleFocusWindow, `{"name": "w1"}`},
		"move_window":      {server.handleMoveWindow, `{"name": "w1", "x": 0, "y": 0}`},
		"resize_window":    {server.handleResizeWindow, `{"name": "w1", "width": 800, "height": 600}`},
		"minimize_window":  {server.handleMinimizeWindow, `{"name": "w1"}`},
		"restore_window":   {server.handleRestoreWindow, `{"name": "w1"}`},
		"close_window":     {server.handleCloseWindow, `{"name": "w1"}`},
	}

	for name, h := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(h.args)}
			result, err := h.fn(call)

			if err != nil {
				t.Fatalf("%s returned error: %v", name, err)
			}
			if len(result.Content) != 1 {
				t.Errorf("%s returned %d content items, want 1", name, len(result.Content))
			}
		})
	}
}
