// Copyright 2025 Joseph Cumines
//
// Display handler unit tests

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
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

// mockMacosUseClient is a mock implementation of MacosUseClient for testing.
// Only the display-related methods are implemented; others panic if called.
type mockMacosUseClient struct {
	pb.MacosUseClient

	// ListDisplays mock
	listDisplaysFunc func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error)
	// GetDisplay mock
	getDisplayFunc func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error)
	// CaptureCursorPosition mock
	captureCursorPositionFunc func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error)
}

func (m *mockMacosUseClient) ListDisplays(ctx context.Context, req *pb.ListDisplaysRequest, opts ...grpc.CallOption) (*pb.ListDisplaysResponse, error) {
	if m.listDisplaysFunc != nil {
		return m.listDisplaysFunc(ctx, req)
	}
	return nil, errors.New("ListDisplays not implemented")
}

func (m *mockMacosUseClient) GetDisplay(ctx context.Context, req *pb.GetDisplayRequest, opts ...grpc.CallOption) (*pb.Display, error) {
	if m.getDisplayFunc != nil {
		return m.getDisplayFunc(ctx, req)
	}
	return nil, errors.New("GetDisplay not implemented")
}

func (m *mockMacosUseClient) CaptureCursorPosition(ctx context.Context, req *pb.CaptureCursorPositionRequest, opts ...grpc.CallOption) (*pb.CaptureCursorPositionResponse, error) {
	if m.captureCursorPositionFunc != nil {
		return m.captureCursorPositionFunc(ctx, req)
	}
	return nil, errors.New("CaptureCursorPosition not implemented")
}

// Stub implementations for other methods to satisfy the interface.
// These will panic if called, which is intentional - tests should only call display methods.

func (m *mockMacosUseClient) OpenApplication(ctx context.Context, in *pb.OpenApplicationRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	panic("OpenApplication not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetApplication(ctx context.Context, in *pb.GetApplicationRequest, opts ...grpc.CallOption) (*pb.Application, error) {
	panic("GetApplication not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListApplications(ctx context.Context, in *pb.ListApplicationsRequest, opts ...grpc.CallOption) (*pb.ListApplicationsResponse, error) {
	panic("ListApplications not expected to be called in display tests")
}

func (m *mockMacosUseClient) DeleteApplication(ctx context.Context, in *pb.DeleteApplicationRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	panic("DeleteApplication not expected to be called in display tests")
}

func (m *mockMacosUseClient) CreateInput(ctx context.Context, in *pb.CreateInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	panic("CreateInput not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetInput(ctx context.Context, in *pb.GetInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	panic("GetInput not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListInputs(ctx context.Context, in *pb.ListInputsRequest, opts ...grpc.CallOption) (*pb.ListInputsResponse, error) {
	panic("ListInputs not expected to be called in display tests")
}

func (m *mockMacosUseClient) TraverseAccessibility(ctx context.Context, in *pb.TraverseAccessibilityRequest, opts ...grpc.CallOption) (*pb.TraverseAccessibilityResponse, error) {
	panic("TraverseAccessibility not expected to be called in display tests")
}

func (m *mockMacosUseClient) WatchAccessibility(ctx context.Context, in *pb.WatchAccessibilityRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[pb.WatchAccessibilityResponse], error) {
	panic("WatchAccessibility not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetWindow(ctx context.Context, in *pb.GetWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	panic("GetWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListWindows(ctx context.Context, in *pb.ListWindowsRequest, opts ...grpc.CallOption) (*pb.ListWindowsResponse, error) {
	panic("ListWindows not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetWindowState(ctx context.Context, in *pb.GetWindowStateRequest, opts ...grpc.CallOption) (*pb.WindowState, error) {
	panic("GetWindowState not expected to be called in display tests")
}

func (m *mockMacosUseClient) FocusWindow(ctx context.Context, in *pb.FocusWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	panic("FocusWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) MoveWindow(ctx context.Context, in *pb.MoveWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	panic("MoveWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) ResizeWindow(ctx context.Context, in *pb.ResizeWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	panic("ResizeWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) MinimizeWindow(ctx context.Context, in *pb.MinimizeWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	panic("MinimizeWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) RestoreWindow(ctx context.Context, in *pb.RestoreWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	panic("RestoreWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) CloseWindow(ctx context.Context, in *pb.CloseWindowRequest, opts ...grpc.CallOption) (*pb.CloseWindowResponse, error) {
	panic("CloseWindow not expected to be called in display tests")
}

func (m *mockMacosUseClient) FindElements(ctx context.Context, in *pb.FindElementsRequest, opts ...grpc.CallOption) (*pb.FindElementsResponse, error) {
	panic("FindElements not expected to be called in display tests")
}

func (m *mockMacosUseClient) FindRegionElements(ctx context.Context, in *pb.FindRegionElementsRequest, opts ...grpc.CallOption) (*pb.FindRegionElementsResponse, error) {
	panic("FindRegionElements not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetElement(ctx context.Context, in *pb.GetElementRequest, opts ...grpc.CallOption) (*_type.Element, error) {
	panic("GetElement not expected to be called in display tests")
}

func (m *mockMacosUseClient) ClickElement(ctx context.Context, in *pb.ClickElementRequest, opts ...grpc.CallOption) (*pb.ClickElementResponse, error) {
	panic("ClickElement not expected to be called in display tests")
}

func (m *mockMacosUseClient) WriteElementValue(ctx context.Context, in *pb.WriteElementValueRequest, opts ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
	panic("WriteElementValue not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetElementActions(ctx context.Context, in *pb.GetElementActionsRequest, opts ...grpc.CallOption) (*pb.ElementActions, error) {
	panic("GetElementActions not expected to be called in display tests")
}

func (m *mockMacosUseClient) PerformElementAction(ctx context.Context, in *pb.PerformElementActionRequest, opts ...grpc.CallOption) (*pb.PerformElementActionResponse, error) {
	panic("PerformElementAction not expected to be called in display tests")
}

func (m *mockMacosUseClient) WaitElement(ctx context.Context, in *pb.WaitElementRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	panic("WaitElement not expected to be called in display tests")
}

func (m *mockMacosUseClient) WaitElementState(ctx context.Context, in *pb.WaitElementStateRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	panic("WaitElementState not expected to be called in display tests")
}

func (m *mockMacosUseClient) CreateObservation(ctx context.Context, in *pb.CreateObservationRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	panic("CreateObservation not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetObservation(ctx context.Context, in *pb.GetObservationRequest, opts ...grpc.CallOption) (*pb.Observation, error) {
	panic("GetObservation not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListObservations(ctx context.Context, in *pb.ListObservationsRequest, opts ...grpc.CallOption) (*pb.ListObservationsResponse, error) {
	panic("ListObservations not expected to be called in display tests")
}

func (m *mockMacosUseClient) CancelObservation(ctx context.Context, in *pb.CancelObservationRequest, opts ...grpc.CallOption) (*pb.Observation, error) {
	panic("CancelObservation not expected to be called in display tests")
}

func (m *mockMacosUseClient) StreamObservations(ctx context.Context, in *pb.StreamObservationsRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
	panic("StreamObservations not expected to be called in display tests")
}

func (m *mockMacosUseClient) CreateSession(ctx context.Context, in *pb.CreateSessionRequest, opts ...grpc.CallOption) (*pb.Session, error) {
	panic("CreateSession not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetSession(ctx context.Context, in *pb.GetSessionRequest, opts ...grpc.CallOption) (*pb.Session, error) {
	panic("GetSession not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListSessions(ctx context.Context, in *pb.ListSessionsRequest, opts ...grpc.CallOption) (*pb.ListSessionsResponse, error) {
	panic("ListSessions not expected to be called in display tests")
}

func (m *mockMacosUseClient) DeleteSession(ctx context.Context, in *pb.DeleteSessionRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	panic("DeleteSession not expected to be called in display tests")
}

func (m *mockMacosUseClient) BeginTransaction(ctx context.Context, in *pb.BeginTransactionRequest, opts ...grpc.CallOption) (*pb.BeginTransactionResponse, error) {
	panic("BeginTransaction not expected to be called in display tests")
}

func (m *mockMacosUseClient) CommitTransaction(ctx context.Context, in *pb.CommitTransactionRequest, opts ...grpc.CallOption) (*pb.Transaction, error) {
	panic("CommitTransaction not expected to be called in display tests")
}

func (m *mockMacosUseClient) RollbackTransaction(ctx context.Context, in *pb.RollbackTransactionRequest, opts ...grpc.CallOption) (*pb.Transaction, error) {
	panic("RollbackTransaction not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetSessionSnapshot(ctx context.Context, in *pb.GetSessionSnapshotRequest, opts ...grpc.CallOption) (*pb.SessionSnapshot, error) {
	panic("GetSessionSnapshot not expected to be called in display tests")
}

func (m *mockMacosUseClient) CaptureScreenshot(ctx context.Context, in *pb.CaptureScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureScreenshotResponse, error) {
	panic("CaptureScreenshot not expected to be called in display tests")
}

func (m *mockMacosUseClient) CaptureWindowScreenshot(ctx context.Context, in *pb.CaptureWindowScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureWindowScreenshotResponse, error) {
	panic("CaptureWindowScreenshot not expected to be called in display tests")
}

func (m *mockMacosUseClient) CaptureElementScreenshot(ctx context.Context, in *pb.CaptureElementScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureElementScreenshotResponse, error) {
	panic("CaptureElementScreenshot not expected to be called in display tests")
}

func (m *mockMacosUseClient) CaptureRegionScreenshot(ctx context.Context, in *pb.CaptureRegionScreenshotRequest, opts ...grpc.CallOption) (*pb.CaptureRegionScreenshotResponse, error) {
	panic("CaptureRegionScreenshot not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetClipboard(ctx context.Context, in *pb.GetClipboardRequest, opts ...grpc.CallOption) (*pb.Clipboard, error) {
	panic("GetClipboard not expected to be called in display tests")
}

func (m *mockMacosUseClient) WriteClipboard(ctx context.Context, in *pb.WriteClipboardRequest, opts ...grpc.CallOption) (*pb.WriteClipboardResponse, error) {
	panic("WriteClipboard not expected to be called in display tests")
}

func (m *mockMacosUseClient) ClearClipboard(ctx context.Context, in *pb.ClearClipboardRequest, opts ...grpc.CallOption) (*pb.ClearClipboardResponse, error) {
	panic("ClearClipboard not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetClipboardHistory(ctx context.Context, in *pb.GetClipboardHistoryRequest, opts ...grpc.CallOption) (*pb.ClipboardHistory, error) {
	panic("GetClipboardHistory not expected to be called in display tests")
}

func (m *mockMacosUseClient) AutomateOpenFileDialog(ctx context.Context, in *pb.AutomateOpenFileDialogRequest, opts ...grpc.CallOption) (*pb.AutomateOpenFileDialogResponse, error) {
	panic("AutomateOpenFileDialog not expected to be called in display tests")
}

func (m *mockMacosUseClient) AutomateSaveFileDialog(ctx context.Context, in *pb.AutomateSaveFileDialogRequest, opts ...grpc.CallOption) (*pb.AutomateSaveFileDialogResponse, error) {
	panic("AutomateSaveFileDialog not expected to be called in display tests")
}

func (m *mockMacosUseClient) SelectFile(ctx context.Context, in *pb.SelectFileRequest, opts ...grpc.CallOption) (*pb.SelectFileResponse, error) {
	panic("SelectFile not expected to be called in display tests")
}

func (m *mockMacosUseClient) SelectDirectory(ctx context.Context, in *pb.SelectDirectoryRequest, opts ...grpc.CallOption) (*pb.SelectDirectoryResponse, error) {
	panic("SelectDirectory not expected to be called in display tests")
}

func (m *mockMacosUseClient) DragFiles(ctx context.Context, in *pb.DragFilesRequest, opts ...grpc.CallOption) (*pb.DragFilesResponse, error) {
	panic("DragFiles not expected to be called in display tests")
}

func (m *mockMacosUseClient) CreateMacro(ctx context.Context, in *pb.CreateMacroRequest, opts ...grpc.CallOption) (*pb.Macro, error) {
	panic("CreateMacro not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetMacro(ctx context.Context, in *pb.GetMacroRequest, opts ...grpc.CallOption) (*pb.Macro, error) {
	panic("GetMacro not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListMacros(ctx context.Context, in *pb.ListMacrosRequest, opts ...grpc.CallOption) (*pb.ListMacrosResponse, error) {
	panic("ListMacros not expected to be called in display tests")
}

func (m *mockMacosUseClient) UpdateMacro(ctx context.Context, in *pb.UpdateMacroRequest, opts ...grpc.CallOption) (*pb.Macro, error) {
	panic("UpdateMacro not expected to be called in display tests")
}

func (m *mockMacosUseClient) DeleteMacro(ctx context.Context, in *pb.DeleteMacroRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	panic("DeleteMacro not expected to be called in display tests")
}

func (m *mockMacosUseClient) ExecuteMacro(ctx context.Context, in *pb.ExecuteMacroRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	panic("ExecuteMacro not expected to be called in display tests")
}

func (m *mockMacosUseClient) ExecuteAppleScript(ctx context.Context, in *pb.ExecuteAppleScriptRequest, opts ...grpc.CallOption) (*pb.ExecuteAppleScriptResponse, error) {
	panic("ExecuteAppleScript not expected to be called in display tests")
}

func (m *mockMacosUseClient) ExecuteJavaScript(ctx context.Context, in *pb.ExecuteJavaScriptRequest, opts ...grpc.CallOption) (*pb.ExecuteJavaScriptResponse, error) {
	panic("ExecuteJavaScript not expected to be called in display tests")
}

func (m *mockMacosUseClient) ExecuteShellCommand(ctx context.Context, in *pb.ExecuteShellCommandRequest, opts ...grpc.CallOption) (*pb.ExecuteShellCommandResponse, error) {
	panic("ExecuteShellCommand not expected to be called in display tests")
}

func (m *mockMacosUseClient) ValidateScript(ctx context.Context, in *pb.ValidateScriptRequest, opts ...grpc.CallOption) (*pb.ValidateScriptResponse, error) {
	panic("ValidateScript not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetScriptingDictionaries(ctx context.Context, in *pb.GetScriptingDictionariesRequest, opts ...grpc.CallOption) (*pb.ScriptingDictionaries, error) {
	panic("GetScriptingDictionaries not expected to be called in display tests")
}

// newTestMCPServer creates a minimal MCPServer for testing with the provided mock client.
func newTestMCPServer(mockClient pb.MacosUseClient) *MCPServer {
	ctx := context.Background()
	return &MCPServer{
		cfg: &config.Config{
			RequestTimeout: 30,
		},
		ctx:    ctx,
		tools:  make(map[string]*Tool),
		client: mockClient,
	}
}

// ============================================================================
// handleListDisplays Tests
// ============================================================================

func TestHandleListDisplays_Success_MultipleDisplays(t *testing.T) {
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{
						Name:      "displays/1",
						DisplayId: 1,
						Frame:     &_type.Region{X: 0, Y: 0, Width: 1920, Height: 1080},
						IsMain:    true,
						Scale:     2.0,
					},
					{
						Name:      "displays/2",
						DisplayId: 2,
						Frame:     &_type.Region{X: 1920, Y: 0, Width: 2560, Height: 1440},
						IsMain:    false,
						Scale:     1.0,
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_displays", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListDisplays(call)

	if err != nil {
		t.Fatalf("handleListDisplays returned error: %v", err)
	}
	if result == nil {
		t.Fatal("handleListDisplays returned nil result")
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
	if len(result.Content) != 1 {
		t.Fatalf("len(result.Content) = %d, want 1", len(result.Content))
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 2 displays") {
		t.Errorf("result text does not contain 'Found 2 displays': %s", text)
	}
	if !strings.Contains(text, "Display 1 (main)") {
		t.Errorf("result text does not contain 'Display 1 (main)': %s", text)
	}
	if !strings.Contains(text, "Display 2:") {
		t.Errorf("result text does not contain 'Display 2:': %s", text)
	}
	if !strings.Contains(text, "scale 2.0") {
		t.Errorf("result text does not contain 'scale 2.0': %s", text)
	}
	if !strings.Contains(text, "scale 1.0") {
		t.Errorf("result text does not contain 'scale 1.0': %s", text)
	}
}

func TestHandleListDisplays_Success_SingleDisplay(t *testing.T) {
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{
						Name:      "displays/main",
						DisplayId: 12345,
						Frame:     &_type.Region{X: 0, Y: 0, Width: 2560, Height: 1440},
						IsMain:    true,
						Scale:     2.0,
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_displays", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListDisplays(call)

	if err != nil {
		t.Fatalf("handleListDisplays returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 1 displays") {
		t.Errorf("result text does not contain 'Found 1 displays': %s", text)
	}
	if !strings.Contains(text, "Display 12345 (main)") {
		t.Errorf("result text does not contain 'Display 12345 (main)': %s", text)
	}
}

func TestHandleListDisplays_Success_NoDisplays(t *testing.T) {
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_displays", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListDisplays(call)

	if err != nil {
		t.Fatalf("handleListDisplays returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No displays found" {
		t.Errorf("result text = %q, want 'No displays found'", text)
	}
}

func TestHandleListDisplays_Success_NegativeCoordinates(t *testing.T) {
	// Test multi-monitor setup with secondary display to the left (negative X)
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{
						Name:      "displays/1",
						DisplayId: 1,
						Frame:     &_type.Region{X: 0, Y: 0, Width: 1920, Height: 1080},
						IsMain:    true,
						Scale:     2.0,
					},
					{
						Name:      "displays/2",
						DisplayId: 2,
						Frame:     &_type.Region{X: -1920, Y: 0, Width: 1920, Height: 1080},
						IsMain:    false,
						Scale:     1.0,
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_displays", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListDisplays(call)

	if err != nil {
		t.Fatalf("handleListDisplays returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	// Verify negative coordinates are properly displayed
	if !strings.Contains(text, "-1920") {
		t.Errorf("result text does not contain negative coordinate '-1920': %s", text)
	}
}

func TestHandleListDisplays_GRPCError(t *testing.T) {
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return nil, errors.New("gRPC connection failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_displays", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListDisplays(call)

	// Handler returns error in ToolResult, not as Go error
	if err != nil {
		t.Fatalf("handleListDisplays returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to list displays") {
		t.Errorf("error text does not contain 'Failed to list displays': %s", text)
	}
	if !strings.Contains(text, "gRPC connection failed") {
		t.Errorf("error text does not contain original error message: %s", text)
	}
}

// ============================================================================
// handleGetDisplay Tests
// ============================================================================

func TestHandleGetDisplay_Success(t *testing.T) {
	mockClient := &mockMacosUseClient{
		getDisplayFunc: func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error) {
			if req.Name != "displays/12345" {
				t.Errorf("GetDisplay called with wrong name: %q, want 'displays/12345'", req.Name)
			}
			return &pb.Display{
				Name:         "displays/12345",
				DisplayId:    12345,
				Frame:        &_type.Region{X: 0, Y: 0, Width: 2560, Height: 1440},
				VisibleFrame: &_type.Region{X: 0, Y: 25, Width: 2560, Height: 1340},
				IsMain:       true,
				Scale:        2.0,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{"name": "displays/12345"}`),
	}

	result, err := server.handleGetDisplay(call)

	if err != nil {
		t.Fatalf("handleGetDisplay returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Display: displays/12345") {
		t.Errorf("result text does not contain 'Display: displays/12345': %s", text)
	}
	if !strings.Contains(text, "Display ID: 12345 (main)") {
		t.Errorf("result text does not contain 'Display ID: 12345 (main)': %s", text)
	}
	if !strings.Contains(text, "Scale: 2.0") {
		t.Errorf("result text does not contain 'Scale: 2.0': %s", text)
	}
}

func TestHandleGetDisplay_SecondaryDisplay(t *testing.T) {
	mockClient := &mockMacosUseClient{
		getDisplayFunc: func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error) {
			return &pb.Display{
				Name:         "displays/67890",
				DisplayId:    67890,
				Frame:        &_type.Region{X: 2560, Y: 0, Width: 1920, Height: 1080},
				VisibleFrame: &_type.Region{X: 2560, Y: 0, Width: 1920, Height: 1080},
				IsMain:       false,
				Scale:        1.0,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{"name": "displays/67890"}`),
	}

	result, err := server.handleGetDisplay(call)

	if err != nil {
		t.Fatalf("handleGetDisplay returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	// Should NOT contain "(main)" for secondary display
	if strings.Contains(text, "(main)") {
		t.Errorf("result text contains '(main)' for secondary display: %s", text)
	}
	if !strings.Contains(text, "Display ID: 67890") {
		t.Errorf("result text does not contain 'Display ID: 67890': %s", text)
	}
}

func TestHandleGetDisplay_MissingName(t *testing.T) {
	mockClient := &mockMacosUseClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetDisplay(call)

	if err != nil {
		t.Fatalf("handleGetDisplay returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetDisplay_EmptyName(t *testing.T) {
	mockClient := &mockMacosUseClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{"name": ""}`),
	}

	result, err := server.handleGetDisplay(call)

	if err != nil {
		t.Fatalf("handleGetDisplay returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetDisplay_InvalidJSON(t *testing.T) {
	mockClient := &mockMacosUseClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{invalid json}`),
	}

	result, err := server.handleGetDisplay(call)

	if err != nil {
		t.Fatalf("handleGetDisplay returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleGetDisplay_GRPCError(t *testing.T) {
	mockClient := &mockMacosUseClient{
		getDisplayFunc: func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error) {
			return nil, errors.New("display not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_display",
		Arguments: json.RawMessage(`{"name": "displays/nonexistent"}`),
	}

	result, err := server.handleGetDisplay(call)

	if err != nil {
		t.Fatalf("handleGetDisplay returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get display") {
		t.Errorf("error text does not contain 'Failed to get display': %s", text)
	}
	if !strings.Contains(text, "display not found") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// handleCursorPosition Tests
// ============================================================================

func TestHandleCursorPosition_Success(t *testing.T) {
	mockClient := &mockMacosUseClient{
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{
				X:       512.0,
				Y:       384.0,
				Display: "displays/1",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "cursor_position", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCursorPosition(call)

	if err != nil {
		t.Fatalf("handleCursorPosition returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Cursor position: (512, 384)") {
		t.Errorf("result text does not contain expected cursor position: %s", text)
	}
	if !strings.Contains(text, "on displays/1") {
		t.Errorf("result text does not contain display name: %s", text)
	}
}

func TestHandleCursorPosition_OriginCoordinates(t *testing.T) {
	mockClient := &mockMacosUseClient{
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{
				X:       0.0,
				Y:       0.0,
				Display: "displays/main",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "cursor_position", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCursorPosition(call)

	if err != nil {
		t.Fatalf("handleCursorPosition returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "(0, 0)") {
		t.Errorf("result text does not contain origin coordinates: %s", text)
	}
}

func TestHandleCursorPosition_NegativeCoordinates(t *testing.T) {
	// Test cursor on secondary display with negative coordinates (left of main)
	mockClient := &mockMacosUseClient{
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{
				X:       -500.0,
				Y:       300.0,
				Display: "displays/2",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "cursor_position", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCursorPosition(call)

	if err != nil {
		t.Fatalf("handleCursorPosition returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "(-500, 300)") {
		t.Errorf("result text does not contain negative coordinates: %s", text)
	}
	if !strings.Contains(text, "on displays/2") {
		t.Errorf("result text does not contain display name: %s", text)
	}
}

func TestHandleCursorPosition_LargeCoordinates(t *testing.T) {
	// Test cursor on a large/high-resolution display
	mockClient := &mockMacosUseClient{
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{
				X:       5000.0,
				Y:       2500.0,
				Display: "displays/ultrawide",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "cursor_position", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCursorPosition(call)

	if err != nil {
		t.Fatalf("handleCursorPosition returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "(5000, 2500)") {
		t.Errorf("result text does not contain large coordinates: %s", text)
	}
}

func TestHandleCursorPosition_GRPCError(t *testing.T) {
	mockClient := &mockMacosUseClient{
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return nil, errors.New("accessibility permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "cursor_position", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleCursorPosition(call)

	if err != nil {
		t.Fatalf("handleCursorPosition returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get cursor position") {
		t.Errorf("error text does not contain 'Failed to get cursor position': %s", text)
	}
	if !strings.Contains(text, "accessibility permission denied") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

// ============================================================================
// Table-Driven Tests for Edge Cases
// ============================================================================

func TestHandleListDisplays_TableDriven(t *testing.T) {
	tests := []struct {
		name           string
		displays       []*pb.Display
		grpcErr        error
		wantIsError    bool
		wantContains   []string
		wantNotContain []string
	}{
		{
			name: "single main display",
			displays: []*pb.Display{
				{DisplayId: 1, IsMain: true, Frame: &_type.Region{Width: 1920, Height: 1080}, Scale: 2.0},
			},
			wantIsError:  false,
			wantContains: []string{"Found 1 displays", "Display 1 (main)", "scale 2.0"},
		},
		{
			name: "multiple displays with secondary",
			displays: []*pb.Display{
				{DisplayId: 1, IsMain: true, Frame: &_type.Region{Width: 1920, Height: 1080}, Scale: 2.0},
				{DisplayId: 2, IsMain: false, Frame: &_type.Region{X: 1920, Width: 1920, Height: 1080}, Scale: 1.0},
			},
			wantIsError:    false,
			wantContains:   []string{"Found 2 displays", "Display 1 (main)", "Display 2:"},
			wantNotContain: []string{"Display 2 (main)"},
		},
		{
			name:         "empty display list",
			displays:     []*pb.Display{},
			wantIsError:  false,
			wantContains: []string{"No displays found"},
		},
		{
			name:         "nil display list",
			displays:     nil,
			wantIsError:  false,
			wantContains: []string{"No displays found"},
		},
		{
			name:         "gRPC error",
			grpcErr:      errors.New("connection timeout"),
			wantIsError:  true,
			wantContains: []string{"Failed to list displays", "connection timeout"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockMacosUseClient{
				listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.ListDisplaysResponse{Displays: tt.displays}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "list_displays", Arguments: json.RawMessage(`{}`)}

			result, err := server.handleListDisplays(call)

			if err != nil {
				t.Fatalf("handleListDisplays returned Go error: %v", err)
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
			for _, notWant := range tt.wantNotContain {
				if strings.Contains(text, notWant) {
					t.Errorf("result text should not contain %q: %s", notWant, text)
				}
			}
		})
	}
}

func TestHandleCursorPosition_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		x, y         float64
		display      string
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "origin position",
			x:            0, y: 0,
			display:      "displays/main",
			wantIsError:  false,
			wantContains: []string{"(0, 0)", "displays/main"},
		},
		{
			name:         "fractional coordinates rounded",
			x:            100.4, y: 200.6,
			display:      "displays/1",
			wantIsError:  false,
			wantContains: []string{"(100, 201)", "displays/1"},
		},
		{
			name:         "negative coordinates",
			x:            -1920, y: -100,
			display:      "displays/secondary",
			wantIsError:  false,
			wantContains: []string{"(-1920, -100)", "displays/secondary"},
		},
		{
			name:        "gRPC error",
			grpcErr:     errors.New("server unavailable"),
			wantIsError: true,
			wantContains: []string{"Failed to get cursor position", "server unavailable"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockMacosUseClient{
				captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.CaptureCursorPositionResponse{X: tt.x, Y: tt.y, Display: tt.display}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "cursor_position", Arguments: json.RawMessage(`{}`)}

			result, err := server.handleCursorPosition(call)

			if err != nil {
				t.Fatalf("handleCursorPosition returned Go error: %v", err)
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

func TestHandleGetDisplay_TableDriven(t *testing.T) {
	tests := []struct {
		name           string
		args           string
		display        *pb.Display
		grpcErr        error
		wantIsError    bool
		wantContains   []string
		wantNotContain []string
	}{
		{
			name: "main display",
			args: `{"name": "displays/1"}`,
			display: &pb.Display{
				Name:         "displays/1",
				DisplayId:    1,
				Frame:        &_type.Region{X: 0, Y: 0, Width: 2560, Height: 1440},
				VisibleFrame: &_type.Region{X: 0, Y: 25, Width: 2560, Height: 1415},
				IsMain:       true,
				Scale:        2.0,
			},
			wantIsError:  false,
			wantContains: []string{"Display: displays/1", "Display ID: 1 (main)", "Scale: 2.0"},
		},
		{
			name: "secondary display",
			args: `{"name": "displays/2"}`,
			display: &pb.Display{
				Name:         "displays/2",
				DisplayId:    2,
				Frame:        &_type.Region{X: 2560, Y: 0, Width: 1920, Height: 1080},
				VisibleFrame: &_type.Region{X: 2560, Y: 0, Width: 1920, Height: 1080},
				IsMain:       false,
				Scale:        1.0,
			},
			wantIsError:    false,
			wantContains:   []string{"Display: displays/2", "Display ID: 2"},
			wantNotContain: []string{"(main)"},
		},
		{
			name:         "missing name parameter",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "empty name parameter",
			args:         `{"name": ""}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "invalid JSON",
			args:         `{invalid}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC not found error",
			args:         `{"name": "displays/999"}`,
			grpcErr:      errors.New("not found"),
			wantIsError:  true,
			wantContains: []string{"Failed to get display", "not found"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockMacosUseClient{
				getDisplayFunc: func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.display, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "get_display", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleGetDisplay(call)

			if err != nil {
				t.Fatalf("handleGetDisplay returned Go error: %v", err)
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
			for _, notWant := range tt.wantNotContain {
				if strings.Contains(text, notWant) {
					t.Errorf("result text should not contain %q: %s", notWant, text)
				}
			}
		})
	}
}

// ============================================================================
// Integration-Like Tests (still unit tests, but verify complete flow)
// ============================================================================

func TestDisplayHandlers_ContentTypeIsText(t *testing.T) {
	// Verify all display handlers return content with type "text"
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{Displays: []*pb.Display{{DisplayId: 1, IsMain: true, Scale: 1.0}}}, nil
		},
		getDisplayFunc: func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error) {
			return &pb.Display{Name: "displays/1", DisplayId: 1, Scale: 1.0}, nil
		},
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{X: 100, Y: 200, Display: "displays/1"}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]func(*ToolCall) (*ToolResult, error){
		"list_displays":   server.handleListDisplays,
		"get_display":     server.handleGetDisplay,
		"cursor_position": server.handleCursorPosition,
	}

	args := map[string]string{
		"list_displays":   `{}`,
		"get_display":     `{"name": "displays/1"}`,
		"cursor_position": `{}`,
	}

	for name, handler := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(args[name])}
			result, err := handler(call)

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

func TestDisplayHandlers_SingleContentItem(t *testing.T) {
	// Verify all display handlers return exactly one content item
	mockClient := &mockMacosUseClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{Displays: []*pb.Display{{DisplayId: 1, Scale: 1.0}}}, nil
		},
		getDisplayFunc: func(ctx context.Context, req *pb.GetDisplayRequest) (*pb.Display, error) {
			return &pb.Display{Name: "displays/1", DisplayId: 1, Scale: 1.0}, nil
		},
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{X: 0, Y: 0, Display: "displays/1"}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]func(*ToolCall) (*ToolResult, error){
		"list_displays":   server.handleListDisplays,
		"get_display":     server.handleGetDisplay,
		"cursor_position": server.handleCursorPosition,
	}

	args := map[string]string{
		"list_displays":   `{}`,
		"get_display":     `{"name": "displays/1"}`,
		"cursor_position": `{}`,
	}

	for name, handler := range handlers {
		t.Run(name, func(t *testing.T) {
			call := &ToolCall{Name: name, Arguments: json.RawMessage(args[name])}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("%s returned error: %v", name, err)
			}
			if len(result.Content) != 1 {
				t.Errorf("%s returned %d content items, want 1", name, len(result.Content))
			}
		})
	}
}
