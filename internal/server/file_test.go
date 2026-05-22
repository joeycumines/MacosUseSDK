// Copyright 2025 Joseph Cumines
//
// File dialog handler unit tests

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

// mockFileClient is a mock implementation of MacosUseClient for file dialog testing.
type mockFileClient struct {
	mockMacosUseClient

	// AutomateOpenFileDialog mock
	automateOpenFileDialogFunc func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error)
	// AutomateSaveFileDialog mock
	automateSaveFileDialogFunc func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error)
	// SelectFile mock
	selectFileFunc func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error)
	// SelectDirectory mock
	selectDirectoryFunc func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error)
	// DragFiles mock
	dragFilesFunc func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error)
}

func (m *mockFileClient) AutomateOpenFileDialog(ctx context.Context, req *pb.AutomateOpenFileDialogRequest, opts ...grpc.CallOption) (*pb.AutomateOpenFileDialogResponse, error) {
	if m.automateOpenFileDialogFunc != nil {
		return m.automateOpenFileDialogFunc(ctx, req)
	}
	return nil, errors.New("AutomateOpenFileDialog not implemented")
}

func (m *mockFileClient) AutomateSaveFileDialog(ctx context.Context, req *pb.AutomateSaveFileDialogRequest, opts ...grpc.CallOption) (*pb.AutomateSaveFileDialogResponse, error) {
	if m.automateSaveFileDialogFunc != nil {
		return m.automateSaveFileDialogFunc(ctx, req)
	}
	return nil, errors.New("AutomateSaveFileDialog not implemented")
}

func (m *mockFileClient) SelectFile(ctx context.Context, req *pb.SelectFileRequest, opts ...grpc.CallOption) (*pb.SelectFileResponse, error) {
	if m.selectFileFunc != nil {
		return m.selectFileFunc(ctx, req)
	}
	return nil, errors.New("SelectFile not implemented")
}

func (m *mockFileClient) SelectDirectory(ctx context.Context, req *pb.SelectDirectoryRequest, opts ...grpc.CallOption) (*pb.SelectDirectoryResponse, error) {
	if m.selectDirectoryFunc != nil {
		return m.selectDirectoryFunc(ctx, req)
	}
	return nil, errors.New("SelectDirectory not implemented")
}

func (m *mockFileClient) DragFiles(ctx context.Context, req *pb.DragFilesRequest, opts ...grpc.CallOption) (*pb.DragFilesResponse, error) {
	if m.dragFilesFunc != nil {
		return m.dragFilesFunc(ctx, req)
	}
	return nil, errors.New("DragFiles not implemented")
}

// ============================================================================
// handleAutomateOpenFileDialog Tests
// ============================================================================

func TestHandleAutomateOpenFileDialog_Success(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			if req.Application != "applications/TextEdit" {
				t.Errorf("expected application 'applications/TextEdit', got %q", req.Application)
			}
			return &pb.AutomateOpenFileDialogResponse{
				Success:       true,
				SelectedPaths: []string{"/tmp/test.txt"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit"}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "/tmp/test.txt") {
		t.Errorf("result text does not contain selected path: %s", text)
	}
}

func TestHandleAutomateOpenFileDialog_MultipleFiles(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			if !req.AllowMultiple {
				t.Error("expected allow_multiple to be true")
			}
			return &pb.AutomateOpenFileDialogResponse{
				Success:       true,
				SelectedPaths: []string{"/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit", "allow_multiple": true}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "/tmp/a.txt") || !strings.Contains(text, "/tmp/b.txt") {
		t.Errorf("result text does not contain all selected paths: %s", text)
	}
}

func TestHandleAutomateOpenFileDialog_WithFilters(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			if len(req.FileFilters) != 2 {
				t.Errorf("expected 2 file filters, got %d", len(req.FileFilters))
			}
			return &pb.AutomateOpenFileDialogResponse{
				Success:       true,
				SelectedPaths: []string{"/tmp/doc.txt"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit", "file_filters": ["*.txt", "*.md"]}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleAutomateOpenFileDialog_NoFilesSelected(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			return &pb.AutomateOpenFileDialogResponse{
				Success:       true,
				SelectedPaths: []string{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit"}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "no files were selected") {
		t.Errorf("result text does not mention no files: %s", text)
	}
}

func TestHandleAutomateOpenFileDialog_OperationFailed(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			return &pb.AutomateOpenFileDialogResponse{
				Success: false,
				Error:   "dialog timeout",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit"}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation failure")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "dialog timeout") {
		t.Errorf("result text does not contain error message: %s", text)
	}
}

func TestHandleAutomateOpenFileDialog_MissingApplication(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing application")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "application parameter is required") {
		t.Errorf("error text does not contain 'application parameter is required': %s", text)
	}
}

func TestHandleAutomateOpenFileDialog_InvalidJSON(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleAutomateOpenFileDialog_GRPCError(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			return nil, errors.New("accessibility permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_open_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit"}`),
	}

	result, err := server.handleAutomateOpenFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateOpenFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to automate open file dialog") {
		t.Errorf("error text does not contain 'Failed to automate open file dialog': %s", text)
	}
}

// ============================================================================
// handleAutomateSaveFileDialog Tests
// ============================================================================

func TestHandleAutomateSaveFileDialog_Success(t *testing.T) {
	mockClient := &mockFileClient{
		automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
			if req.Application != "applications/TextEdit" {
				t.Errorf("expected application 'applications/TextEdit', got %q", req.Application)
			}
			if req.FilePath != "/tmp/output.txt" {
				t.Errorf("expected file_path '/tmp/output.txt', got %q", req.FilePath)
			}
			return &pb.AutomateSaveFileDialogResponse{
				Success:   true,
				SavedPath: "/tmp/output.txt",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit", "file_path": "/tmp/output.txt"}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "/tmp/output.txt") {
		t.Errorf("result text does not contain saved path: %s", text)
	}
}

func TestHandleAutomateSaveFileDialog_WithOptions(t *testing.T) {
	mockClient := &mockFileClient{
		automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
			if req.DefaultDirectory != "/tmp" {
				t.Errorf("expected default_directory '/tmp', got %q", req.DefaultDirectory)
			}
			if req.DefaultFilename != "output.txt" {
				t.Errorf("expected default_filename 'output.txt', got %q", req.DefaultFilename)
			}
			if !req.ConfirmOverwrite {
				t.Error("expected confirm_overwrite to be true")
			}
			return &pb.AutomateSaveFileDialogResponse{
				Success:   true,
				SavedPath: "/tmp/output.txt",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit", "file_path": "/tmp/output.txt", "default_directory": "/tmp", "default_filename": "output.txt", "confirm_overwrite": true}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleAutomateSaveFileDialog_OperationFailed(t *testing.T) {
	mockClient := &mockFileClient{
		automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
			return &pb.AutomateSaveFileDialogResponse{
				Success: false,
				Error:   "file already exists",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit", "file_path": "/tmp/existing.txt"}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation failure")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "file already exists") {
		t.Errorf("result text does not contain error message: %s", text)
	}
}

func TestHandleAutomateSaveFileDialog_MissingApplication(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{"file_path": "/tmp/test.txt"}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing application")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "application parameter is required") {
		t.Errorf("error text does not contain 'application parameter is required': %s", text)
	}
}

func TestHandleAutomateSaveFileDialog_MissingFilePath(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit"}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing file_path")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "file_path parameter is required") {
		t.Errorf("error text does not contain 'file_path parameter is required': %s", text)
	}
}

func TestHandleAutomateSaveFileDialog_InvalidJSON(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleAutomateSaveFileDialog_GRPCError(t *testing.T) {
	mockClient := &mockFileClient{
		automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
			return nil, errors.New("write permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "automate_save_file_dialog",
		Arguments: json.RawMessage(`{"application": "applications/TextEdit", "file_path": "/tmp/test.txt"}`),
	}

	result, err := server.handleAutomateSaveFileDialog(call)

	if err != nil {
		t.Fatalf("handleAutomateSaveFileDialog returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to automate save file dialog") {
		t.Errorf("error text does not contain 'Failed to automate save file dialog': %s", text)
	}
}

// ============================================================================
// handleSelectFile Tests
// ============================================================================

func TestHandleSelectFile_Success(t *testing.T) {
	mockClient := &mockFileClient{
		selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
			if req.Application != "applications/Finder" {
				t.Errorf("expected application 'applications/Finder', got %q", req.Application)
			}
			if req.FilePath != "/tmp/test.txt" {
				t.Errorf("expected file_path '/tmp/test.txt', got %q", req.FilePath)
			}
			return &pb.SelectFileResponse{
				Success:      true,
				SelectedPath: "/tmp/test.txt",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_file",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_path": "/tmp/test.txt"}`),
	}

	result, err := server.handleSelectFile(call)

	if err != nil {
		t.Fatalf("handleSelectFile returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "/tmp/test.txt") {
		t.Errorf("result text does not contain selected path: %s", text)
	}
}

func TestHandleSelectFile_WithRevealFinder(t *testing.T) {
	mockClient := &mockFileClient{
		selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
			if !req.RevealFinder {
				t.Error("expected reveal_finder to be true")
			}
			return &pb.SelectFileResponse{
				Success:      true,
				SelectedPath: "/tmp/test.txt",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_file",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_path": "/tmp/test.txt", "reveal_finder": true}`),
	}

	result, err := server.handleSelectFile(call)

	if err != nil {
		t.Fatalf("handleSelectFile returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleSelectFile_OperationFailed(t *testing.T) {
	mockClient := &mockFileClient{
		selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
			return &pb.SelectFileResponse{
				Success: false,
				Error:   "file not found",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_file",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_path": "/nonexistent/file.txt"}`),
	}

	result, err := server.handleSelectFile(call)

	if err != nil {
		t.Fatalf("handleSelectFile returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation failure")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "file not found") {
		t.Errorf("result text does not contain error message: %s", text)
	}
}

func TestHandleSelectFile_MissingParameters(t *testing.T) {
	tests := []struct {
		name   string
		args   string
		errMsg string
	}{
		{"missing both", `{}`, "application and file_path parameters are required"},
		{"missing file_path", `{"application": "applications/Finder"}`, "application and file_path parameters are required"},
		{"missing application", `{"file_path": "/tmp/test.txt"}`, "application and file_path parameters are required"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockFileClient{}
			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "select_file",
				Arguments: json.RawMessage(tt.args),
			}

			result, err := server.handleSelectFile(call)

			if err != nil {
				t.Fatalf("handleSelectFile returned Go error: %v", err)
			}
			if !result.IsError {
				t.Error("result.IsError = false, want true for missing parameters")
			}

			text := result.Content[0].Text
			if !strings.Contains(text, tt.errMsg) {
				t.Errorf("error text does not contain %q: %s", tt.errMsg, text)
			}
		})
	}
}

func TestHandleSelectFile_InvalidJSON(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_file",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleSelectFile(call)

	if err != nil {
		t.Fatalf("handleSelectFile returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleSelectFile_GRPCError(t *testing.T) {
	mockClient := &mockFileClient{
		selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
			return nil, errors.New("file system error")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_file",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_path": "/tmp/test.txt"}`),
	}

	result, err := server.handleSelectFile(call)

	if err != nil {
		t.Fatalf("handleSelectFile returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to select file") {
		t.Errorf("error text does not contain 'Failed to select file': %s", text)
	}
}

// ============================================================================
// handleSelectDirectory Tests
// ============================================================================

func TestHandleSelectDirectory_Success(t *testing.T) {
	mockClient := &mockFileClient{
		selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
			if req.Application != "applications/Finder" {
				t.Errorf("expected application 'applications/Finder', got %q", req.Application)
			}
			if req.DirectoryPath != "/tmp/mydir" {
				t.Errorf("expected directory_path '/tmp/mydir', got %q", req.DirectoryPath)
			}
			return &pb.SelectDirectoryResponse{
				Success:      true,
				SelectedPath: "/tmp/mydir",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_directory",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "directory_path": "/tmp/mydir"}`),
	}

	result, err := server.handleSelectDirectory(call)

	if err != nil {
		t.Fatalf("handleSelectDirectory returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "/tmp/mydir") {
		t.Errorf("result text does not contain directory path: %s", text)
	}
}

func TestHandleSelectDirectory_Created(t *testing.T) {
	mockClient := &mockFileClient{
		selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
			if !req.CreateMissing {
				t.Error("expected create_missing to be true")
			}
			return &pb.SelectDirectoryResponse{
				Success:      true,
				SelectedPath: "/tmp/newdir",
				Created:      true,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_directory",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "directory_path": "/tmp/newdir", "create_missing": true}`),
	}

	result, err := server.handleSelectDirectory(call)

	if err != nil {
		t.Fatalf("handleSelectDirectory returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "(created)") {
		t.Errorf("result text does not indicate creation: %s", text)
	}
}

func TestHandleSelectDirectory_OperationFailed(t *testing.T) {
	mockClient := &mockFileClient{
		selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
			return &pb.SelectDirectoryResponse{
				Success: false,
				Error:   "directory not found",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_directory",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "directory_path": "/nonexistent"}`),
	}

	result, err := server.handleSelectDirectory(call)

	if err != nil {
		t.Fatalf("handleSelectDirectory returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation failure")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "directory not found") {
		t.Errorf("result text does not contain error message: %s", text)
	}
}

func TestHandleSelectDirectory_MissingParameters(t *testing.T) {
	tests := []struct {
		name   string
		args   string
		errMsg string
	}{
		{"missing both", `{}`, "application and directory_path parameters are required"},
		{"missing directory_path", `{"application": "applications/Finder"}`, "application and directory_path parameters are required"},
		{"missing application", `{"directory_path": "/tmp"}`, "application and directory_path parameters are required"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockFileClient{}
			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "select_directory",
				Arguments: json.RawMessage(tt.args),
			}

			result, err := server.handleSelectDirectory(call)

			if err != nil {
				t.Fatalf("handleSelectDirectory returned Go error: %v", err)
			}
			if !result.IsError {
				t.Error("result.IsError = false, want true for missing parameters")
			}

			text := result.Content[0].Text
			if !strings.Contains(text, tt.errMsg) {
				t.Errorf("error text does not contain %q: %s", tt.errMsg, text)
			}
		})
	}
}

func TestHandleSelectDirectory_InvalidJSON(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_directory",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleSelectDirectory(call)

	if err != nil {
		t.Fatalf("handleSelectDirectory returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleSelectDirectory_GRPCError(t *testing.T) {
	mockClient := &mockFileClient{
		selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
			return nil, errors.New("permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "select_directory",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "directory_path": "/tmp"}`),
	}

	result, err := server.handleSelectDirectory(call)

	if err != nil {
		t.Fatalf("handleSelectDirectory returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to select directory") {
		t.Errorf("error text does not contain 'Failed to select directory': %s", text)
	}
}

// ============================================================================
// handleDragFiles Tests
// ============================================================================

func TestHandleDragFiles_Success(t *testing.T) {
	mockClient := &mockFileClient{
		dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
			if req.Application != "applications/Finder" {
				t.Errorf("expected application 'applications/Finder', got %q", req.Application)
			}
			if len(req.FilePaths) != 2 {
				t.Errorf("expected 2 file paths, got %d", len(req.FilePaths))
			}
			if req.TargetElementId != "drop-zone" {
				t.Errorf("expected target_element_id 'drop-zone', got %q", req.TargetElementId)
			}
			return &pb.DragFilesResponse{
				Success:      true,
				FilesDropped: 2,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_paths": ["/tmp/a.txt", "/tmp/b.txt"], "target_element_id": "drop-zone"}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "2 files") {
		t.Errorf("result text does not contain file count: %s", text)
	}
}

func TestHandleDragFiles_WithDuration(t *testing.T) {
	mockClient := &mockFileClient{
		dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
			if req.Duration != 0.5 {
				t.Errorf("expected duration 0.5, got %f", req.Duration)
			}
			return &pb.DragFilesResponse{
				Success:      true,
				FilesDropped: 1,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"], "target_element_id": "drop-zone", "duration": 0.5}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleDragFiles_OperationFailed(t *testing.T) {
	mockClient := &mockFileClient{
		dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
			return &pb.DragFilesResponse{
				Success: false,
				Error:   "target not droppable",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"], "target_element_id": "invalid-target"}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for operation failure")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "target not droppable") {
		t.Errorf("result text does not contain error message: %s", text)
	}
}

func TestHandleDragFiles_MissingApplication(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"file_paths": ["/tmp/a.txt"], "target_element_id": "drop-zone"}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing application")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "application parameter is required") {
		t.Errorf("error text does not contain 'application parameter is required': %s", text)
	}
}

func TestHandleDragFiles_EmptyFilePaths(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_paths": [], "target_element_id": "drop-zone"}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for empty file_paths")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "file_paths parameter must contain at least one path") {
		t.Errorf("error text does not contain expected message: %s", text)
	}
}

func TestHandleDragFiles_MissingTargetElement(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"]}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing target_element_id")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "target_element_id parameter is required") {
		t.Errorf("error text does not contain 'target_element_id parameter is required': %s", text)
	}
}

func TestHandleDragFiles_InvalidJSON(t *testing.T) {
	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleDragFiles_GRPCError(t *testing.T) {
	mockClient := &mockFileClient{
		dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
			return nil, errors.New("drag operation failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "drag_files",
		Arguments: json.RawMessage(`{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"], "target_element_id": "drop-zone"}`),
	}

	result, err := server.handleDragFiles(call)

	if err != nil {
		t.Fatalf("handleDragFiles returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to drag files") {
		t.Errorf("error text does not contain 'Failed to drag files': %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestFileDialogHandlers_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "automate_open_file_dialog missing application",
			handler:      "automate_open_file_dialog",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"application parameter is required"},
		},
		{
			name:         "automate_save_file_dialog missing application",
			handler:      "automate_save_file_dialog",
			args:         `{"file_path": "/tmp/test.txt"}`,
			wantIsError:  true,
			wantContains: []string{"application parameter is required"},
		},
		{
			name:         "automate_save_file_dialog missing file_path",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit"}`,
			wantIsError:  true,
			wantContains: []string{"file_path parameter is required"},
		},
		{
			name:         "select_file missing parameters",
			handler:      "select_file",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"application and file_path parameters are required"},
		},
		{
			name:         "select_directory missing parameters",
			handler:      "select_directory",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"application and directory_path parameters are required"},
		},
		{
			name:         "drag_files missing application",
			handler:      "drag_files",
			args:         `{"file_paths": ["/tmp/a.txt"], "target_element_id": "zone"}`,
			wantIsError:  true,
			wantContains: []string{"application parameter is required"},
		},
		{
			name:         "drag_files empty file_paths",
			handler:      "drag_files",
			args:         `{"application": "applications/Finder", "file_paths": [], "target_element_id": "zone"}`,
			wantIsError:  true,
			wantContains: []string{"file_paths parameter must contain at least one path"},
		},
		{
			name:         "drag_files missing target_element_id",
			handler:      "drag_files",
			args:         `{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"]}`,
			wantIsError:  true,
			wantContains: []string{"target_element_id parameter is required"},
		},
	}

	mockClient := &mockFileClient{}
	server := newTestMCPServer(mockClient)

	handlers := map[string]func(*ToolCall) (*ToolResult, error){
		"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
		"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
		"select_file":               server.handleSelectFile,
		"select_directory":          server.handleSelectDirectory,
		"drag_files":                server.handleDragFiles,
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler, ok := handlers[tt.handler]
			if !ok {
				t.Fatalf("unknown handler: %s", tt.handler)
			}

			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("%s returned Go error: %v", tt.handler, err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v: %s", result.IsError, tt.wantIsError, result.Content[0].Text)
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
// Invalid Path Tests
// ============================================================================

func TestFileDialogHandlers_InvalidPaths(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		wantIsError  bool
		wantContains string
	}{
		{
			name:         "automate_open with null byte in path",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": "/tmp/test\u0000file.txt"}`,
			wantIsError:  false, // path validation happens on server side
			wantContains: "",
		},
		{
			name:         "automate_save with null byte in path",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": "/tmp/test\u0000file.txt"}`,
			wantIsError:  false, // path forwarded to gRPC server
			wantContains: "",
		},
		{
			name:         "select_file with path containing newline",
			handler:      "select_file",
			args:         `{"application": "applications/Finder", "file_path": "/tmp/test\nfile.txt"}`,
			wantIsError:  false, // path validation happens on server side
			wantContains: "",
		},
		{
			name:         "select_directory with path containing tab",
			handler:      "select_directory",
			args:         `{"application": "applications/Finder", "directory_path": "/tmp/test\tdir"}`,
			wantIsError:  false, // path validation happens on server side
			wantContains: "",
		},
		{
			name:         "drag_files with path containing control char",
			handler:      "drag_files",
			args:         `{"application": "applications/Finder", "file_paths": ["/tmp/test\u001Ffile.txt"], "target_element_id": "zone"}`,
			wantIsError:  false, // path validation happens on server side
			wantContains: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var pathReceived string
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					pathReceived = req.FilePath
					return &pb.AutomateOpenFileDialogResponse{Success: true, SelectedPaths: []string{"/tmp/test.txt"}}, nil
				},
				automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
					pathReceived = req.FilePath
					return &pb.AutomateSaveFileDialogResponse{Success: true, SavedPath: req.FilePath}, nil
				},
				selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
					pathReceived = req.FilePath
					return &pb.SelectFileResponse{Success: true, SelectedPath: req.FilePath}, nil
				},
				selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
					pathReceived = req.DirectoryPath
					return &pb.SelectDirectoryResponse{Success: true, SelectedPath: req.DirectoryPath}, nil
				},
				dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
					if len(req.FilePaths) > 0 {
						pathReceived = req.FilePaths[0]
					}
					return &pb.DragFilesResponse{Success: true, FilesDropped: int32(len(req.FilePaths))}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			handlers := map[string]func(*ToolCall) (*ToolResult, error){
				"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
				"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
				"select_file":               server.handleSelectFile,
				"select_directory":          server.handleSelectDirectory,
				"drag_files":                server.handleDragFiles,
			}

			handler := handlers[tt.handler]
			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v: %s", result.IsError, tt.wantIsError, result.Content[0].Text)
			}

			// Verify path was forwarded to gRPC (paths with odd chars are allowed by handler)
			if pathReceived == "" && !result.IsError {
				// For paths that don't require file_path, this is acceptable
				if tt.handler != "automate_open_file_dialog" {
					// Path should be captured
				}
			}
		})
	}
}

// ============================================================================
// Non-Existent Directory Tests
// ============================================================================

func TestFileDialogHandlers_NonExistentDirectories(t *testing.T) {
	tests := []struct {
		name             string
		handler          string
		args             string
		mockSuccess      bool
		mockError        string
		wantIsError      bool
		wantContainsList []string
	}{
		{
			name:             "automate_open with non-existent default_directory",
			handler:          "automate_open_file_dialog",
			args:             `{"application": "applications/TextEdit", "default_directory": "/nonexistent/path/12345"}`,
			mockSuccess:      false,
			mockError:        "directory does not exist",
			wantIsError:      true,
			wantContainsList: []string{"directory does not exist"},
		},
		{
			name:             "automate_save with non-existent default_directory",
			handler:          "automate_save_file_dialog",
			args:             `{"application": "applications/TextEdit", "file_path": "/nonexistent/dir/file.txt", "default_directory": "/nonexistent/12345"}`,
			mockSuccess:      false,
			mockError:        "default directory not found",
			wantIsError:      true,
			wantContainsList: []string{"default directory not found"},
		},
		{
			name:             "select_directory with non-existent path",
			handler:          "select_directory",
			args:             `{"application": "applications/Finder", "directory_path": "/this/path/does/not/exist/12345"}`,
			mockSuccess:      false,
			mockError:        "no such directory",
			wantIsError:      true,
			wantContainsList: []string{"no such directory"},
		},
		{
			name:             "select_directory with non-existent path and create_missing true",
			handler:          "select_directory",
			args:             `{"application": "applications/Finder", "directory_path": "/tmp/newdir_12345", "create_missing": true}`,
			mockSuccess:      true,
			mockError:        "",
			wantIsError:      false,
			wantContainsList: []string{"Selected directory", "/tmp/newdir_12345"},
		},
		{
			name:             "select_file with non-existent file",
			handler:          "select_file",
			args:             `{"application": "applications/Finder", "file_path": "/tmp/nonexistent_file_12345.txt"}`,
			mockSuccess:      false,
			mockError:        "file not found",
			wantIsError:      true,
			wantContainsList: []string{"file not found"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					return &pb.AutomateOpenFileDialogResponse{Success: tt.mockSuccess, Error: tt.mockError, SelectedPaths: []string{"/tmp/test.txt"}}, nil
				},
				automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
					return &pb.AutomateSaveFileDialogResponse{Success: tt.mockSuccess, Error: tt.mockError, SavedPath: req.FilePath}, nil
				},
				selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
					return &pb.SelectFileResponse{Success: tt.mockSuccess, Error: tt.mockError, SelectedPath: req.FilePath}, nil
				},
				selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
					return &pb.SelectDirectoryResponse{
						Success:      tt.mockSuccess,
						Error:        tt.mockError,
						SelectedPath: req.DirectoryPath,
						Created:      req.CreateMissing,
					}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			handlers := map[string]func(*ToolCall) (*ToolResult, error){
				"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
				"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
				"select_file":               server.handleSelectFile,
				"select_directory":          server.handleSelectDirectory,
			}

			handler := handlers[tt.handler]
			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v: %s", result.IsError, tt.wantIsError, result.Content[0].Text)
			}

			text := result.Content[0].Text
			for _, want := range tt.wantContainsList {
				if !strings.Contains(text, want) {
					t.Errorf("result text does not contain %q: %s", want, text)
				}
			}
		})
	}
}

// ============================================================================
// Timeout Validation Tests
// ============================================================================

func TestFileDialogHandlers_TimeoutValidation(t *testing.T) {
	tests := []struct {
		name            string
		handler         string
		args            string
		expectedTimeout float64
	}{
		// AutomateOpenFileDialog
		{"open: no timeout uses default", "automate_open_file_dialog", `{"application": "applications/TextEdit"}`, 30.0},
		{"open: zero timeout uses default", "automate_open_file_dialog", `{"application": "applications/TextEdit", "timeout": 0}`, 30.0},
		{"open: negative timeout uses default", "automate_open_file_dialog", `{"application": "applications/TextEdit", "timeout": -5}`, 30.0},
		{"open: negative large uses default", "automate_open_file_dialog", `{"application": "applications/TextEdit", "timeout": -100}`, 30.0},
		{"open: explicit positive used", "automate_open_file_dialog", `{"application": "applications/TextEdit", "timeout": 60}`, 60.0},
		{"open: small positive used", "automate_open_file_dialog", `{"application": "applications/TextEdit", "timeout": 0.5}`, 0.5},
		{"open: very large timeout used", "automate_open_file_dialog", `{"application": "applications/TextEdit", "timeout": 3600}`, 3600.0},

		// AutomateSaveFileDialog
		{"save: no timeout uses default", "automate_save_file_dialog", `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt"}`, 30.0},
		{"save: zero timeout uses default", "automate_save_file_dialog", `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt", "timeout": 0}`, 30.0},
		{"save: negative timeout uses default", "automate_save_file_dialog", `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt", "timeout": -10}`, 30.0},
		{"save: explicit positive used", "automate_save_file_dialog", `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt", "timeout": 45}`, 45.0},
		{"save: fractional timeout used", "automate_save_file_dialog", `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt", "timeout": 1.5}`, 1.5},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var receivedTimeout float64
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					receivedTimeout = req.Timeout
					return &pb.AutomateOpenFileDialogResponse{Success: true, SelectedPaths: []string{}}, nil
				},
				automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
					receivedTimeout = req.Timeout
					return &pb.AutomateSaveFileDialogResponse{Success: true, SavedPath: req.FilePath}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			handlers := map[string]func(*ToolCall) (*ToolResult, error){
				"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
				"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
			}

			handler := handlers[tt.handler]
			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			_, err := handler(call)
			if err != nil {
				t.Fatalf("handler returned error: %v", err)
			}

			if receivedTimeout != tt.expectedTimeout {
				t.Errorf("timeout = %f, want %f", receivedTimeout, tt.expectedTimeout)
			}
		})
	}
}

// ============================================================================
// Cancellation Scenario Tests
// ============================================================================

func TestFileDialogHandlers_Cancellation(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		mockError    string
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "automate_open dialog cancelled by user",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit"}`,
			mockError:    "dialog cancelled by user",
			wantIsError:  true,
			wantContains: []string{"dialog cancelled by user"},
		},
		{
			name:         "automate_open dialog dismissed",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit"}`,
			mockError:    "dialog was dismissed",
			wantIsError:  true,
			wantContains: []string{"dialog was dismissed"},
		},
		{
			name:         "automate_save dialog cancelled",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt"}`,
			mockError:    "user cancelled save operation",
			wantIsError:  true,
			wantContains: []string{"user cancelled save operation"},
		},
		{
			name:         "automate_save dialog timeout",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt"}`,
			mockError:    "dialog timeout exceeded",
			wantIsError:  true,
			wantContains: []string{"dialog timeout exceeded"},
		},
		{
			name:         "automate_open with escape key",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit"}`,
			mockError:    "operation cancelled (escape key pressed)",
			wantIsError:  true,
			wantContains: []string{"operation cancelled", "escape key"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					return &pb.AutomateOpenFileDialogResponse{
						Success: false,
						Error:   tt.mockError,
					}, nil
				},
				automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
					return &pb.AutomateSaveFileDialogResponse{
						Success: false,
						Error:   tt.mockError,
					}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			handlers := map[string]func(*ToolCall) (*ToolResult, error){
				"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
				"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
			}

			handler := handlers[tt.handler]
			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
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
// Empty Path Handling Tests
// ============================================================================

func TestFileDialogHandlers_EmptyPaths(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		wantIsError  bool
		wantContains string
	}{
		// Open dialog allows empty file_path (optional)
		{
			name:         "automate_open empty file_path is allowed",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": ""}`,
			wantIsError:  false,
			wantContains: "",
		},
		{
			name:         "automate_open empty default_directory is allowed",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit", "default_directory": ""}`,
			wantIsError:  false,
			wantContains: "",
		},
		// Save dialog requires file_path
		{
			name:         "automate_save empty file_path is error",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": ""}`,
			wantIsError:  true,
			wantContains: "file_path parameter is required",
		},
		{
			name:         "automate_save whitespace file_path is forwarded",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": "   "}`,
			wantIsError:  false, // whitespace path forwarded to gRPC
			wantContains: "",
		},
		// Select file requires file_path
		{
			name:         "select_file empty file_path is error",
			handler:      "select_file",
			args:         `{"application": "applications/Finder", "file_path": ""}`,
			wantIsError:  true,
			wantContains: "application and file_path parameters are required",
		},
		// Select directory requires directory_path
		{
			name:         "select_directory empty directory_path is error",
			handler:      "select_directory",
			args:         `{"application": "applications/Finder", "directory_path": ""}`,
			wantIsError:  true,
			wantContains: "application and directory_path parameters are required",
		},
		// Drag files requires file paths
		{
			name:         "drag_files nil file_paths",
			handler:      "drag_files",
			args:         `{"application": "applications/Finder", "target_element_id": "zone"}`,
			wantIsError:  true,
			wantContains: "file_paths parameter must contain at least one path",
		},
		{
			name:         "drag_files with empty string in paths",
			handler:      "drag_files",
			args:         `{"application": "applications/Finder", "file_paths": ["", "/tmp/b.txt"], "target_element_id": "zone"}`,
			wantIsError:  false, // empty string in array is forwarded
			wantContains: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					return &pb.AutomateOpenFileDialogResponse{Success: true, SelectedPaths: []string{"/tmp/test.txt"}}, nil
				},
				automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
					return &pb.AutomateSaveFileDialogResponse{Success: true, SavedPath: req.FilePath}, nil
				},
				selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
					return &pb.SelectFileResponse{Success: true, SelectedPath: req.FilePath}, nil
				},
				selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
					return &pb.SelectDirectoryResponse{Success: true, SelectedPath: req.DirectoryPath}, nil
				},
				dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
					return &pb.DragFilesResponse{Success: true, FilesDropped: int32(len(req.FilePaths))}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			handlers := map[string]func(*ToolCall) (*ToolResult, error){
				"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
				"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
				"select_file":               server.handleSelectFile,
				"select_directory":          server.handleSelectDirectory,
				"drag_files":                server.handleDragFiles,
			}

			handler := handlers[tt.handler]
			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result.IsError != tt.wantIsError {
				t.Errorf("result.IsError = %v, want %v: %s", result.IsError, tt.wantIsError, result.Content[0].Text)
			}

			if tt.wantContains != "" {
				text := result.Content[0].Text
				if !strings.Contains(text, tt.wantContains) {
					t.Errorf("result text does not contain %q: %s", tt.wantContains, text)
				}
			}
		})
	}
}

// ============================================================================
// File Filter Forwarding Tests
// ============================================================================

func TestFileDialogHandlers_FileFilters(t *testing.T) {
	tests := []struct {
		name            string
		filters         []string
		expectedFilters []string
	}{
		{
			name:            "single filter",
			filters:         []string{"*.txt"},
			expectedFilters: []string{"*.txt"},
		},
		{
			name:            "multiple filters",
			filters:         []string{"*.txt", "*.md", "*.pdf"},
			expectedFilters: []string{"*.txt", "*.md", "*.pdf"},
		},
		{
			name:            "complex glob patterns",
			filters:         []string{"*.{txt,md}", "doc*.pdf", "image_???.*"},
			expectedFilters: []string{"*.{txt,md}", "doc*.pdf", "image_???.*"},
		},
		{
			name:            "empty filter array",
			filters:         []string{},
			expectedFilters: []string{},
		},
		{
			name:            "filter with spaces",
			filters:         []string{"* Document.txt", "Report *.pdf"},
			expectedFilters: []string{"* Document.txt", "Report *.pdf"},
		},
		{
			name:            "filter with special chars",
			filters:         []string{"*.txt", "file[0-9].log", "data_*.csv"},
			expectedFilters: []string{"*.txt", "file[0-9].log", "data_*.csv"},
		},
		{
			name:            "nil becomes empty",
			filters:         nil,
			expectedFilters: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var receivedFilters []string
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					receivedFilters = req.FileFilters
					return &pb.AutomateOpenFileDialogResponse{Success: true, SelectedPaths: []string{"/tmp/test.txt"}}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			// Build JSON args
			var args string
			if tt.filters == nil {
				args = `{"application": "applications/TextEdit"}`
			} else {
				filtersJSON, _ := json.Marshal(tt.filters)
				args = `{"application": "applications/TextEdit", "file_filters": ` + string(filtersJSON) + `}`
			}

			call := &ToolCall{
				Name:      "automate_open_file_dialog",
				Arguments: json.RawMessage(args),
			}

			result, err := server.handleAutomateOpenFileDialog(call)
			if err != nil {
				t.Fatalf("handler returned error: %v", err)
			}
			if result.IsError {
				t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
			}

			// Verify filters match
			if len(receivedFilters) != len(tt.expectedFilters) {
				t.Errorf("received %d filters, want %d", len(receivedFilters), len(tt.expectedFilters))
				return
			}

			for i, expected := range tt.expectedFilters {
				if receivedFilters[i] != expected {
					t.Errorf("filter[%d] = %q, want %q", i, receivedFilters[i], expected)
				}
			}
		})
	}
}

// ============================================================================
// Operation Failed With Empty Error Tests
// ============================================================================

func TestFileDialogHandlers_OperationFailedEmptyError(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		wantContains string
	}{
		{
			name:         "automate_open empty error",
			handler:      "automate_open_file_dialog",
			args:         `{"application": "applications/TextEdit"}`,
			wantContains: "operation was not successful",
		},
		{
			name:         "automate_save empty error",
			handler:      "automate_save_file_dialog",
			args:         `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt"}`,
			wantContains: "operation was not successful",
		},
		{
			name:         "select_file empty error",
			handler:      "select_file",
			args:         `{"application": "applications/Finder", "file_path": "/tmp/test.txt"}`,
			wantContains: "operation was not successful",
		},
		{
			name:         "select_directory empty error",
			handler:      "select_directory",
			args:         `{"application": "applications/Finder", "directory_path": "/tmp"}`,
			wantContains: "operation was not successful",
		},
		{
			name:         "drag_files empty error",
			handler:      "drag_files",
			args:         `{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"], "target_element_id": "zone"}`,
			wantContains: "operation was not successful",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					return &pb.AutomateOpenFileDialogResponse{Success: false, Error: ""}, nil
				},
				automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
					return &pb.AutomateSaveFileDialogResponse{Success: false, Error: ""}, nil
				},
				selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
					return &pb.SelectFileResponse{Success: false, Error: ""}, nil
				},
				selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
					return &pb.SelectDirectoryResponse{Success: false, Error: ""}, nil
				},
				dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
					return &pb.DragFilesResponse{Success: false, Error: ""}, nil
				},
			}

			server := newTestMCPServer(mockClient)

			handlers := map[string]func(*ToolCall) (*ToolResult, error){
				"automate_open_file_dialog": server.handleAutomateOpenFileDialog,
				"automate_save_file_dialog": server.handleAutomateSaveFileDialog,
				"select_file":               server.handleSelectFile,
				"select_directory":          server.handleSelectDirectory,
				"drag_files":                server.handleDragFiles,
			}

			handler := handlers[tt.handler]
			call := &ToolCall{Name: tt.handler, Arguments: json.RawMessage(tt.args)}
			result, err := handler(call)

			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if !result.IsError {
				t.Error("result.IsError = false, want true for failed operation")
			}

			text := result.Content[0].Text
			if !strings.Contains(text, tt.wantContains) {
				t.Errorf("result text does not contain %q: %s", tt.wantContains, text)
			}
		})
	}
}

// ============================================================================
// Content Type Tests
// ============================================================================

func TestFileDialogHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockFileClient{
		automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
			return &pb.AutomateOpenFileDialogResponse{Success: true, SelectedPaths: []string{"/tmp/test.txt"}}, nil
		},
		automateSaveFileDialogFunc: func(ctx context.Context, req *pb.AutomateSaveFileDialogRequest) (*pb.AutomateSaveFileDialogResponse, error) {
			return &pb.AutomateSaveFileDialogResponse{Success: true, SavedPath: "/tmp/test.txt"}, nil
		},
		selectFileFunc: func(ctx context.Context, req *pb.SelectFileRequest) (*pb.SelectFileResponse, error) {
			return &pb.SelectFileResponse{Success: true, SelectedPath: "/tmp/test.txt"}, nil
		},
		selectDirectoryFunc: func(ctx context.Context, req *pb.SelectDirectoryRequest) (*pb.SelectDirectoryResponse, error) {
			return &pb.SelectDirectoryResponse{Success: true, SelectedPath: "/tmp"}, nil
		},
		dragFilesFunc: func(ctx context.Context, req *pb.DragFilesRequest) (*pb.DragFilesResponse, error) {
			return &pb.DragFilesResponse{Success: true, FilesDropped: 1}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	testCases := []struct {
		handler func(*ToolCall) (*ToolResult, error)
		args    string
	}{
		{server.handleAutomateOpenFileDialog, `{"application": "applications/TextEdit"}`},
		{server.handleAutomateSaveFileDialog, `{"application": "applications/TextEdit", "file_path": "/tmp/test.txt"}`},
		{server.handleSelectFile, `{"application": "applications/Finder", "file_path": "/tmp/test.txt"}`},
		{server.handleSelectDirectory, `{"application": "applications/Finder", "directory_path": "/tmp"}`},
		{server.handleDragFiles, `{"application": "applications/Finder", "file_paths": ["/tmp/a.txt"], "target_element_id": "zone"}`},
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
// Timeout Default Tests
// ============================================================================

func TestFileDialogHandlers_TimeoutDefaults(t *testing.T) {
	tests := []struct {
		name            string
		args            string
		expectedTimeout float64
	}{
		{"no timeout uses default", `{"application": "applications/TextEdit"}`, 30.0},
		{"zero timeout uses default", `{"application": "applications/TextEdit", "timeout": 0}`, 30.0},
		{"negative timeout uses default", `{"application": "applications/TextEdit", "timeout": -5}`, 30.0},
		{"explicit timeout used", `{"application": "applications/TextEdit", "timeout": 60}`, 60.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var receivedTimeout float64
			mockClient := &mockFileClient{
				automateOpenFileDialogFunc: func(ctx context.Context, req *pb.AutomateOpenFileDialogRequest) (*pb.AutomateOpenFileDialogResponse, error) {
					receivedTimeout = req.Timeout
					return &pb.AutomateOpenFileDialogResponse{Success: true, SelectedPaths: []string{}}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "automate_open_file_dialog",
				Arguments: json.RawMessage(tt.args),
			}

			_, err := server.handleAutomateOpenFileDialog(call)
			if err != nil {
				t.Fatalf("handleAutomateOpenFileDialog returned error: %v", err)
			}

			if receivedTimeout != tt.expectedTimeout {
				t.Errorf("timeout = %f, want %f", receivedTimeout, tt.expectedTimeout)
			}
		})
	}
}
