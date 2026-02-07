// Copyright 2025 Joseph Cumines
//
// Application handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/emptypb"
)

// mockApplicationClient is a mock implementation of MacosUseClient for application testing.
type mockApplicationClient struct {
	mockMacosUseClient

	// OpenApplication mock
	openApplicationFunc func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error)
	// ListApplications mock
	listApplicationsFunc func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error)
	// GetApplication mock
	getApplicationFunc func(ctx context.Context, req *pb.GetApplicationRequest) (*pb.Application, error)
	// DeleteApplication mock
	deleteApplicationFunc func(ctx context.Context, req *pb.DeleteApplicationRequest) (*emptypb.Empty, error)
}

func (m *mockApplicationClient) OpenApplication(ctx context.Context, req *pb.OpenApplicationRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	if m.openApplicationFunc != nil {
		return m.openApplicationFunc(ctx, req)
	}
	return nil, errors.New("OpenApplication not implemented")
}

func (m *mockApplicationClient) ListApplications(ctx context.Context, req *pb.ListApplicationsRequest, opts ...grpc.CallOption) (*pb.ListApplicationsResponse, error) {
	if m.listApplicationsFunc != nil {
		return m.listApplicationsFunc(ctx, req)
	}
	return nil, errors.New("ListApplications not implemented")
}

func (m *mockApplicationClient) GetApplication(ctx context.Context, req *pb.GetApplicationRequest, opts ...grpc.CallOption) (*pb.Application, error) {
	if m.getApplicationFunc != nil {
		return m.getApplicationFunc(ctx, req)
	}
	return nil, errors.New("GetApplication not implemented")
}

func (m *mockApplicationClient) DeleteApplication(ctx context.Context, req *pb.DeleteApplicationRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	if m.deleteApplicationFunc != nil {
		return m.deleteApplicationFunc(ctx, req)
	}
	return nil, errors.New("DeleteApplication not implemented")
}

// ============================================================================
// handleOpenApplication Tests
// ============================================================================

func TestHandleOpenApplication_Success_ImmediateCompletion(t *testing.T) {
	openResp := &pb.OpenApplicationResponse{
		Application: &pb.Application{
			Name:        "applications/12345",
			DisplayName: "Calculator",
			Pid:         12345,
		},
	}
	respAny, err := anypb.New(openResp)
	if err != nil {
		t.Fatalf("failed to create Any: %v", err)
	}

	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			if req.Id != "Calculator" {
				t.Errorf("expected id 'Calculator', got %q", req.Id)
			}
			return &longrunningpb.Operation{
				Name:   "operations/open-calc",
				Done:   true,
				Result: &longrunningpb.Operation_Response{Response: respAny},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": "Calculator"}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Application opened:") {
		t.Errorf("result text does not contain 'Application opened:': %s", text)
	}
	if !strings.Contains(text, "Calculator") {
		t.Errorf("result text does not contain 'Calculator': %s", text)
	}
	if !strings.Contains(text, "PID: 12345") {
		t.Errorf("result text does not contain 'PID: 12345': %s", text)
	}
}

func TestHandleOpenApplication_Success_BundleID(t *testing.T) {
	openResp := &pb.OpenApplicationResponse{
		Application: &pb.Application{
			Name:        "applications/9999",
			DisplayName: "Calculator",
			Pid:         9999,
		},
	}
	respAny, _ := anypb.New(openResp)

	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			if req.Id != "com.apple.calculator" {
				t.Errorf("expected id 'com.apple.calculator', got %q", req.Id)
			}
			return &longrunningpb.Operation{
				Name:   "operations/open",
				Done:   true,
				Result: &longrunningpb.Operation_Response{Response: respAny},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": "com.apple.calculator"}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleOpenApplication_Success_Path(t *testing.T) {
	openResp := &pb.OpenApplicationResponse{
		Application: &pb.Application{
			Name:        "applications/8888",
			DisplayName: "Calculator",
			Pid:         8888,
		},
	}
	respAny, _ := anypb.New(openResp)

	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			if req.Id != "/Applications/Calculator.app" {
				t.Errorf("expected path, got %q", req.Id)
			}
			return &longrunningpb.Operation{
				Name:   "operations/open",
				Done:   true,
				Result: &longrunningpb.Operation_Response{Response: respAny},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": "/Applications/Calculator.app"}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleOpenApplication_Success_NilApplication(t *testing.T) {
	// Test when response has no application details
	openResp := &pb.OpenApplicationResponse{
		Application: nil,
	}
	respAny, _ := anypb.New(openResp)

	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{
				Name:   "operations/open",
				Done:   true,
				Result: &longrunningpb.Operation_Response{Response: respAny},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": "SomeApp"}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Application opened: SomeApp") {
		t.Errorf("result text = %q, want to contain 'Application opened: SomeApp'", text)
	}
}

func TestHandleOpenApplication_MissingID(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing id")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "id parameter is required") {
		t.Errorf("error text does not contain 'id parameter is required': %s", text)
	}
}

func TestHandleOpenApplication_EmptyID(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": ""}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty id")
	}
}

func TestHandleOpenApplication_InvalidJSON(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleOpenApplication_GRPCError(t *testing.T) {
	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			return nil, errors.New("application not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": "NonExistentApp"}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to open application") {
		t.Errorf("error text does not contain 'Failed to open application': %s", text)
	}
	if !strings.Contains(text, "application not found") {
		t.Errorf("error text does not contain original error: %s", text)
	}
}

func TestHandleOpenApplication_OperationError(t *testing.T) {
	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{
				Name: "operations/open-err",
				Done: true,
				Result: &longrunningpb.Operation_Error{
					Error: &status.Status{
						Code:    13, // INTERNAL
						Message: "failed to launch application",
					},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "open_application",
		Arguments: json.RawMessage(`{"id": "BadApp"}`),
	}

	result, err := server.handleOpenApplication(call)

	if err != nil {
		t.Fatalf("handleOpenApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Application open failed") {
		t.Errorf("error text does not contain 'Application open failed': %s", text)
	}
}

// ============================================================================
// handleListApplications Tests
// ============================================================================

func TestHandleListApplications_Success(t *testing.T) {
	mockClient := &mockApplicationClient{
		listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			return &pb.ListApplicationsResponse{
				Applications: []*pb.Application{
					{Name: "applications/1", DisplayName: "Finder", Pid: 100},
					{Name: "applications/2", DisplayName: "Calculator", Pid: 200},
					{Name: "applications/3", DisplayName: "TextEdit", Pid: 300},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_applications", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListApplications(call)

	if err != nil {
		t.Fatalf("handleListApplications returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Found 3 applications") {
		t.Errorf("result text does not contain 'Found 3 applications': %s", text)
	}
	if !strings.Contains(text, "Finder") {
		t.Errorf("result text does not contain 'Finder': %s", text)
	}
	if !strings.Contains(text, "Calculator") {
		t.Errorf("result text does not contain 'Calculator': %s", text)
	}
	if !strings.Contains(text, "PID: 100") {
		t.Errorf("result text does not contain 'PID: 100': %s", text)
	}
}

func TestHandleListApplications_EmptyList(t *testing.T) {
	mockClient := &mockApplicationClient{
		listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			return &pb.ListApplicationsResponse{
				Applications: []*pb.Application{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_applications", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListApplications(call)

	if err != nil {
		t.Fatalf("handleListApplications returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if text != "No applications currently tracked" {
		t.Errorf("result text = %q, want 'No applications currently tracked'", text)
	}
}

func TestHandleListApplications_WithPagination(t *testing.T) {
	mockClient := &mockApplicationClient{
		listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			if req.PageSize != 10 {
				t.Errorf("expected page_size 10, got %d", req.PageSize)
			}
			if req.PageToken != "token123" {
				t.Errorf("expected page_token 'token123', got %q", req.PageToken)
			}
			return &pb.ListApplicationsResponse{
				Applications: []*pb.Application{
					{Name: "applications/1", DisplayName: "App1", Pid: 1},
				},
				NextPageToken: "next-token",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_applications",
		Arguments: json.RawMessage(`{"page_size": 10, "page_token": "token123"}`),
	}

	result, err := server.handleListApplications(call)

	if err != nil {
		t.Fatalf("handleListApplications returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "More results available") {
		t.Errorf("result text does not contain 'More results available': %s", text)
	}
	if !strings.Contains(text, "next-token") {
		t.Errorf("result text does not contain next page token: %s", text)
	}
}

func TestHandleListApplications_NegativePageSize(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_applications",
		Arguments: json.RawMessage(`{"page_size": -1}`),
	}

	result, err := server.handleListApplications(call)

	if err != nil {
		t.Fatalf("handleListApplications returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for negative page_size")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "page_size must be non-negative") {
		t.Errorf("error text does not contain 'page_size must be non-negative': %s", text)
	}
}

func TestHandleListApplications_InvalidJSON(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_applications",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleListApplications(call)

	if err != nil {
		t.Fatalf("handleListApplications returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleListApplications_GRPCError(t *testing.T) {
	mockClient := &mockApplicationClient{
		listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			return nil, errors.New("server unavailable")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{Name: "list_applications", Arguments: json.RawMessage(`{}`)}

	result, err := server.handleListApplications(call)

	if err != nil {
		t.Fatalf("handleListApplications returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to list applications") {
		t.Errorf("error text does not contain 'Failed to list applications': %s", text)
	}
}

// ============================================================================
// handleGetApplication Tests
// ============================================================================

func TestHandleGetApplication_Success(t *testing.T) {
	mockClient := &mockApplicationClient{
		getApplicationFunc: func(ctx context.Context, req *pb.GetApplicationRequest) (*pb.Application, error) {
			if req.Name != "applications/12345" {
				t.Errorf("expected name 'applications/12345', got %q", req.Name)
			}
			return &pb.Application{
				Name:        "applications/12345",
				DisplayName: "Calculator",
				Pid:         12345,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_application",
		Arguments: json.RawMessage(`{"name": "applications/12345"}`),
	}

	result, err := server.handleGetApplication(call)

	if err != nil {
		t.Fatalf("handleGetApplication returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Application:") {
		t.Errorf("result text does not contain 'Application:': %s", text)
	}
	if !strings.Contains(text, "Name: applications/12345") {
		t.Errorf("result text does not contain 'Name: applications/12345': %s", text)
	}
	if !strings.Contains(text, "Display Name: Calculator") {
		t.Errorf("result text does not contain 'Display Name: Calculator': %s", text)
	}
	if !strings.Contains(text, "PID: 12345") {
		t.Errorf("result text does not contain 'PID: 12345': %s", text)
	}
}

func TestHandleGetApplication_MissingName(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_application",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetApplication(call)

	if err != nil {
		t.Fatalf("handleGetApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetApplication_EmptyName(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_application",
		Arguments: json.RawMessage(`{"name": ""}`),
	}

	result, err := server.handleGetApplication(call)

	if err != nil {
		t.Fatalf("handleGetApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty name")
	}
}

func TestHandleGetApplication_InvalidJSON(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_application",
		Arguments: json.RawMessage(`{bad}`),
	}

	result, err := server.handleGetApplication(call)

	if err != nil {
		t.Fatalf("handleGetApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleGetApplication_GRPCError(t *testing.T) {
	mockClient := &mockApplicationClient{
		getApplicationFunc: func(ctx context.Context, req *pb.GetApplicationRequest) (*pb.Application, error) {
			return nil, errors.New("application not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_application",
		Arguments: json.RawMessage(`{"name": "applications/999"}`),
	}

	result, err := server.handleGetApplication(call)

	if err != nil {
		t.Fatalf("handleGetApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get application") {
		t.Errorf("error text does not contain 'Failed to get application': %s", text)
	}
}

// ============================================================================
// handleDeleteApplication Tests
// ============================================================================

func TestHandleDeleteApplication_Success(t *testing.T) {
	mockClient := &mockApplicationClient{
		deleteApplicationFunc: func(ctx context.Context, req *pb.DeleteApplicationRequest) (*emptypb.Empty, error) {
			if req.Name != "applications/12345" {
				t.Errorf("expected name 'applications/12345', got %q", req.Name)
			}
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_application",
		Arguments: json.RawMessage(`{"name": "applications/12345"}`),
	}

	result, err := server.handleDeleteApplication(call)

	if err != nil {
		t.Fatalf("handleDeleteApplication returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Application applications/12345 deleted") {
		t.Errorf("result text does not contain expected message: %s", text)
	}
	if !strings.Contains(text, "stopped tracking") {
		t.Errorf("result text does not contain 'stopped tracking': %s", text)
	}
}

func TestHandleDeleteApplication_MissingName(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_application",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleDeleteApplication(call)

	if err != nil {
		t.Fatalf("handleDeleteApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleDeleteApplication_EmptyName(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_application",
		Arguments: json.RawMessage(`{"name": ""}`),
	}

	result, err := server.handleDeleteApplication(call)

	if err != nil {
		t.Fatalf("handleDeleteApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty name")
	}
}

func TestHandleDeleteApplication_InvalidJSON(t *testing.T) {
	mockClient := &mockApplicationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_application",
		Arguments: json.RawMessage(`{not valid}`),
	}

	result, err := server.handleDeleteApplication(call)

	if err != nil {
		t.Fatalf("handleDeleteApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}
}

func TestHandleDeleteApplication_GRPCError(t *testing.T) {
	mockClient := &mockApplicationClient{
		deleteApplicationFunc: func(ctx context.Context, req *pb.DeleteApplicationRequest) (*emptypb.Empty, error) {
			return nil, errors.New("delete failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_application",
		Arguments: json.RawMessage(`{"name": "applications/999"}`),
	}

	result, err := server.handleDeleteApplication(call)

	if err != nil {
		t.Fatalf("handleDeleteApplication returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to delete application") {
		t.Errorf("error text does not contain 'Failed to delete application': %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestHandleListApplications_TableDriven(t *testing.T) {
	tests := []struct {
		name           string
		args           string
		apps           []*pb.Application
		nextToken      string
		grpcErr        error
		wantIsError    bool
		wantContains   []string
		wantNotContain []string
	}{
		{
			name: "multiple apps",
			args: `{}`,
			apps: []*pb.Application{
				{Name: "applications/1", DisplayName: "App1", Pid: 1},
				{Name: "applications/2", DisplayName: "App2", Pid: 2},
			},
			wantIsError:  false,
			wantContains: []string{"Found 2 applications", "App1", "App2", "PID: 1", "PID: 2"},
		},
		{
			name:         "empty list",
			args:         `{}`,
			apps:         []*pb.Application{},
			wantIsError:  false,
			wantContains: []string{"No applications currently tracked"},
		},
		{
			name: "with next page token",
			args: `{"page_size": 1}`,
			apps: []*pb.Application{
				{Name: "applications/1", DisplayName: "App1", Pid: 1},
			},
			nextToken:    "next-page",
			wantIsError:  false,
			wantContains: []string{"More results available", "next-page"},
		},
		{
			name:         "invalid JSON",
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "negative page size",
			args:         `{"page_size": -5}`,
			wantIsError:  true,
			wantContains: []string{"page_size must be non-negative"},
		},
		{
			name:         "gRPC error",
			args:         `{}`,
			grpcErr:      errors.New("connection refused"),
			wantIsError:  true,
			wantContains: []string{"Failed to list applications", "connection refused"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockApplicationClient{
				listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &pb.ListApplicationsResponse{
						Applications:  tt.apps,
						NextPageToken: tt.nextToken,
					}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "list_applications", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleListApplications(call)

			if err != nil {
				t.Fatalf("handleListApplications returned Go error: %v", err)
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

func TestHandleGetApplication_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		app          *pb.Application
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "success",
			args:         `{"name": "applications/123"}`,
			app:          &pb.Application{Name: "applications/123", DisplayName: "TestApp", Pid: 123},
			wantIsError:  false,
			wantContains: []string{"Application:", "TestApp", "PID: 123"},
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
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"name": "applications/999"}`,
			grpcErr:      errors.New("not found"),
			wantIsError:  true,
			wantContains: []string{"Failed to get application", "not found"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockApplicationClient{
				getApplicationFunc: func(ctx context.Context, req *pb.GetApplicationRequest) (*pb.Application, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return tt.app, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "get_application", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleGetApplication(call)

			if err != nil {
				t.Fatalf("handleGetApplication returned Go error: %v", err)
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

func TestHandleDeleteApplication_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		args         string
		grpcErr      error
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "success",
			args:         `{"name": "applications/123"}`,
			wantIsError:  false,
			wantContains: []string{"Application applications/123 deleted", "stopped tracking"},
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
			args:         `{bad}`,
			wantIsError:  true,
			wantContains: []string{"Invalid parameters"},
		},
		{
			name:         "gRPC error",
			args:         `{"name": "applications/999"}`,
			grpcErr:      errors.New("permission denied"),
			wantIsError:  true,
			wantContains: []string{"Failed to delete application", "permission denied"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockApplicationClient{
				deleteApplicationFunc: func(ctx context.Context, req *pb.DeleteApplicationRequest) (*emptypb.Empty, error) {
					if tt.grpcErr != nil {
						return nil, tt.grpcErr
					}
					return &emptypb.Empty{}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{Name: "delete_application", Arguments: json.RawMessage(tt.args)}

			result, err := server.handleDeleteApplication(call)

			if err != nil {
				t.Fatalf("handleDeleteApplication returned Go error: %v", err)
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

func TestApplicationHandlers_ContentTypeIsText(t *testing.T) {
	openResp := &pb.OpenApplicationResponse{Application: &pb.Application{Name: "applications/1", DisplayName: "App", Pid: 1}}
	respAny, _ := anypb.New(openResp)

	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{Name: "op", Done: true, Result: &longrunningpb.Operation_Response{Response: respAny}}, nil
		},
		listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			return &pb.ListApplicationsResponse{Applications: []*pb.Application{{Name: "applications/1", DisplayName: "App", Pid: 1}}}, nil
		},
		getApplicationFunc: func(ctx context.Context, req *pb.GetApplicationRequest) (*pb.Application, error) {
			return &pb.Application{Name: "applications/1", DisplayName: "App", Pid: 1}, nil
		},
		deleteApplicationFunc: func(ctx context.Context, req *pb.DeleteApplicationRequest) (*emptypb.Empty, error) {
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"open_application":   {server.handleOpenApplication, `{"id": "App"}`},
		"list_applications":  {server.handleListApplications, `{}`},
		"get_application":    {server.handleGetApplication, `{"name": "applications/1"}`},
		"delete_application": {server.handleDeleteApplication, `{"name": "applications/1"}`},
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

func TestApplicationHandlers_SingleContentItem(t *testing.T) {
	openResp := &pb.OpenApplicationResponse{Application: &pb.Application{Name: "applications/1", DisplayName: "App", Pid: 1}}
	respAny, _ := anypb.New(openResp)

	mockClient := &mockApplicationClient{
		openApplicationFunc: func(ctx context.Context, req *pb.OpenApplicationRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{Name: "op", Done: true, Result: &longrunningpb.Operation_Response{Response: respAny}}, nil
		},
		listApplicationsFunc: func(ctx context.Context, req *pb.ListApplicationsRequest) (*pb.ListApplicationsResponse, error) {
			return &pb.ListApplicationsResponse{Applications: []*pb.Application{}}, nil
		},
		getApplicationFunc: func(ctx context.Context, req *pb.GetApplicationRequest) (*pb.Application, error) {
			return &pb.Application{Name: "applications/1", DisplayName: "App", Pid: 1}, nil
		},
		deleteApplicationFunc: func(ctx context.Context, req *pb.DeleteApplicationRequest) (*emptypb.Empty, error) {
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]struct {
		fn   func(*ToolCall) (*ToolResult, error)
		args string
	}{
		"open_application":   {server.handleOpenApplication, `{"id": "App"}`},
		"list_applications":  {server.handleListApplications, `{}`},
		"get_application":    {server.handleGetApplication, `{"name": "applications/1"}`},
		"delete_application": {server.handleDeleteApplication, `{"name": "applications/1"}`},
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
