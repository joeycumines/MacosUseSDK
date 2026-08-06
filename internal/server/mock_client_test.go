// Copyright 2025 Joseph Cumines
//
// Shared mock gRPC client used by the server package tests.
// The legacy display_test.go used to define this; it was extracted here so other
// legacy handler tests can keep using it after display.go/display_test.go were removed.

package server

import (
	"context"
	"errors"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func completedInputResponse(request *pb.CreateInputRequest) *pb.Input {
	if request == nil || request.GetInput() == nil {
		panic("completedInputResponse requires an exact CreateInput request")
	}
	postedEventCount, err := expectedInputPostedEventCount(request.GetInput().GetAction())
	if err != nil {
		panic("completedInputResponse requires a valid physical action: " + err.Error())
	}
	created := time.Unix(1_700_000_000, 0)
	return &pb.Input{
		Name:         request.GetParent() + "/inputs/" + request.GetInputId(),
		Action:       proto.Clone(request.GetInput().GetAction()).(*pb.InputAction),
		Target:       proto.Clone(request.GetInput().GetTarget()).(*pb.InputTarget),
		State:        pb.Input_STATE_COMPLETED,
		CreateTime:   timestamppb.New(created),
		CompleteTime: timestamppb.New(created.Add(time.Millisecond)),
		DeliveryResult: &pb.InputDeliveryResult{
			Commitment:             pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED,
			PostedEventCount:       postedEventCount,
			RoutedDeliveryObserved: true,
		},
	}
}

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
	// ExecuteShellCommand mock
	executeShellCommandFunc func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error)
	// FindElements mock
	findElementsFunc func(ctx context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error)
	// FocusWindow mock
	focusWindowFunc func(ctx context.Context, req *pb.FocusWindowRequest) (*pb.Window, error)
	// ListWindows mock
	listWindowsFunc func(ctx context.Context, req *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error)
	// CreateInput mock
	createInputFunc func(ctx context.Context, req *pb.CreateInputRequest) (*pb.Input, error)
	// GetElement mock
	getElementFunc func(ctx context.Context, req *pb.GetElementRequest) (*pb.Element, error)
	// GetElementActions mock
	getElementActionsFunc func(ctx context.Context, req *pb.GetElementActionsRequest, opts ...grpc.CallOption) (*pb.ElementActions, error)
	// WriteElementValue mock
	writeElementValueFunc func(ctx context.Context, req *pb.WriteElementValueRequest, opts ...grpc.CallOption) (*pb.WriteElementValueResponse, error)
	// ClickElement mock
	clickElementFunc func(ctx context.Context, req *pb.ClickElementRequest, opts ...grpc.CallOption) (*pb.ClickElementResponse, error)
	// OpenApplication mock
	openApplicationFunc func(ctx context.Context, req *pb.OpenApplicationRequest) (*pb.OpenApplicationResponse, error)
	// GetApplicationBundle mock
	getApplicationBundleFunc func(ctx context.Context, req *pb.GetApplicationBundleRequest) (*pb.ApplicationBundle, error)
	// ListApplicationBundles mock
	listApplicationBundlesFunc func(ctx context.Context, req *pb.ListApplicationBundlesRequest) (*pb.ListApplicationBundlesResponse, error)
	// ListApplications mock
	listApplicationsFunc func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error)
	// ActivateApplication mock
	activateApplicationFunc func(ctx context.Context, req *pb.ActivateApplicationRequest) (*pb.ActivateApplicationResponse, error)
	// CloseApplication mock
	closeApplicationFunc func(ctx context.Context, req *pb.CloseApplicationRequest) (*pb.CloseApplicationResponse, error)
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

func (m *mockMacosUseClient) OpenApplication(ctx context.Context, in *pb.OpenApplicationRequest, opts ...grpc.CallOption) (*pb.OpenApplicationResponse, error) {
	if m.openApplicationFunc != nil {
		return m.openApplicationFunc(ctx, in)
	}
	panic("OpenApplication not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetApplicationBundle(ctx context.Context, in *pb.GetApplicationBundleRequest, opts ...grpc.CallOption) (*pb.ApplicationBundle, error) {
	if m.getApplicationBundleFunc != nil {
		return m.getApplicationBundleFunc(ctx, in)
	}
	panic("GetApplicationBundle not expected to be called")
}

func (m *mockMacosUseClient) ListApplicationBundles(ctx context.Context, in *pb.ListApplicationBundlesRequest, opts ...grpc.CallOption) (*pb.ListApplicationBundlesResponse, error) {
	if m.listApplicationBundlesFunc != nil {
		return m.listApplicationBundlesFunc(ctx, in)
	}
	panic("ListApplicationBundles not expected to be called")
}

func (m *mockMacosUseClient) GetApplication(ctx context.Context, in *pb.GetApplicationRequest, opts ...grpc.CallOption) (*pb.Application, error) {
	panic("GetApplication not expected to be called in display tests")
}

func (m *mockMacosUseClient) ListApplications(ctx context.Context, in *pb.ListApplicationsRequest, opts ...grpc.CallOption) (*pb.ListApplicationsResponse, error) {
	if m.listApplicationsFunc != nil {
		return m.listApplicationsFunc(ctx, in)
	}
	panic("ListApplications not expected to be called in display tests")
}

func (m *mockMacosUseClient) ActivateApplication(ctx context.Context, in *pb.ActivateApplicationRequest, opts ...grpc.CallOption) (*pb.ActivateApplicationResponse, error) {
	if m.activateApplicationFunc != nil {
		return m.activateApplicationFunc(ctx, in)
	}
	panic("ActivateApplication not expected to be called")
}

func (m *mockMacosUseClient) CloseApplication(ctx context.Context, in *pb.CloseApplicationRequest, opts ...grpc.CallOption) (*pb.CloseApplicationResponse, error) {
	if m.closeApplicationFunc != nil {
		return m.closeApplicationFunc(ctx, in)
	}
	panic("CloseApplication not expected to be called in display tests")
}

func (m *mockMacosUseClient) CreateInput(ctx context.Context, in *pb.CreateInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	if m.createInputFunc != nil {
		return m.createInputFunc(ctx, in)
	}
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
	if m.listWindowsFunc != nil {
		return m.listWindowsFunc(ctx, in)
	}
	panic("ListWindows not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetWindowState(ctx context.Context, in *pb.GetWindowStateRequest, opts ...grpc.CallOption) (*pb.WindowState, error) {
	panic("GetWindowState not expected to be called in display tests")
}

func (m *mockMacosUseClient) FocusWindow(ctx context.Context, in *pb.FocusWindowRequest, opts ...grpc.CallOption) (*pb.Window, error) {
	if m.focusWindowFunc != nil {
		return m.focusWindowFunc(ctx, in)
	}
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
	if m.findElementsFunc != nil {
		return m.findElementsFunc(ctx, in)
	}
	panic("FindElements not expected to be called in display tests")
}

func (m *mockMacosUseClient) FindRegionElements(ctx context.Context, in *pb.FindRegionElementsRequest, opts ...grpc.CallOption) (*pb.FindRegionElementsResponse, error) {
	panic("FindRegionElements not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetElement(ctx context.Context, in *pb.GetElementRequest, opts ...grpc.CallOption) (*pb.Element, error) {
	if m.getElementFunc != nil {
		return m.getElementFunc(ctx, in)
	}
	panic("GetElement not expected to be called in display tests")
}

func (m *mockMacosUseClient) ClickElement(ctx context.Context, in *pb.ClickElementRequest, opts ...grpc.CallOption) (*pb.ClickElementResponse, error) {
	if m.clickElementFunc != nil {
		return m.clickElementFunc(ctx, in)
	}
	panic("ClickElement not expected to be called in display tests")
}

func (m *mockMacosUseClient) WriteElementValue(ctx context.Context, in *pb.WriteElementValueRequest, opts ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
	if m.writeElementValueFunc != nil {
		return m.writeElementValueFunc(ctx, in)
	}
	panic("WriteElementValue not expected to be called in display tests")
}

func (m *mockMacosUseClient) GetElementActions(ctx context.Context, in *pb.GetElementActionsRequest, opts ...grpc.CallOption) (*pb.ElementActions, error) {
	if m.getElementActionsFunc != nil {
		return m.getElementActionsFunc(ctx, in)
	}
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
	if m.executeShellCommandFunc != nil {
		return m.executeShellCommandFunc(ctx, in)
	}
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
