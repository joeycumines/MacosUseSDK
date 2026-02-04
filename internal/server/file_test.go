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
