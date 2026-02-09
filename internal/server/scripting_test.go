// Copyright 2025 Joseph Cumines
//
// Scripting tools unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/durationpb"
)

// mockScriptingClient implements a minimal mock for scripting-related gRPC calls
type mockScriptingClient struct {
	pb.MacosUseClient

	executeAppleScriptFn       func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error)
	executeJavaScriptFn        func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error)
	executeShellCommandFn      func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error)
	validateScriptFn           func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error)
	getScriptingDictionariesFn func(ctx context.Context, req *pb.GetScriptingDictionariesRequest) (*pb.ScriptingDictionaries, error)
}

func (m *mockScriptingClient) ExecuteAppleScript(ctx context.Context, req *pb.ExecuteAppleScriptRequest, opts ...grpc.CallOption) (*pb.ExecuteAppleScriptResponse, error) {
	if m.executeAppleScriptFn != nil {
		return m.executeAppleScriptFn(ctx, req)
	}
	return nil, errors.New("mock not configured")
}

func (m *mockScriptingClient) ExecuteJavaScript(ctx context.Context, req *pb.ExecuteJavaScriptRequest, opts ...grpc.CallOption) (*pb.ExecuteJavaScriptResponse, error) {
	if m.executeJavaScriptFn != nil {
		return m.executeJavaScriptFn(ctx, req)
	}
	return nil, errors.New("mock not configured")
}

func (m *mockScriptingClient) ExecuteShellCommand(ctx context.Context, req *pb.ExecuteShellCommandRequest, opts ...grpc.CallOption) (*pb.ExecuteShellCommandResponse, error) {
	if m.executeShellCommandFn != nil {
		return m.executeShellCommandFn(ctx, req)
	}
	return nil, errors.New("mock not configured")
}

func (m *mockScriptingClient) ValidateScript(ctx context.Context, req *pb.ValidateScriptRequest, opts ...grpc.CallOption) (*pb.ValidateScriptResponse, error) {
	if m.validateScriptFn != nil {
		return m.validateScriptFn(ctx, req)
	}
	return nil, errors.New("mock not configured")
}

func (m *mockScriptingClient) GetScriptingDictionaries(ctx context.Context, req *pb.GetScriptingDictionariesRequest, opts ...grpc.CallOption) (*pb.ScriptingDictionaries, error) {
	if m.getScriptingDictionariesFn != nil {
		return m.getScriptingDictionariesFn(ctx, req)
	}
	return nil, errors.New("mock not configured")
}

// createTestScriptingServer creates an MCPServer with a mock client for scripting tests
func createTestScriptingServer(mock *mockScriptingClient) *MCPServer {
	ctx := context.Background()
	return &MCPServer{
		cfg:    &config.Config{RequestTimeout: 30, ShellCommandsEnabled: true},
		tools:  make(map[string]*Tool),
		ctx:    ctx,
		client: mock,
	}
}

// ============================================================================
// handleExecuteAppleScript Tests
// ============================================================================

func TestHandleExecuteAppleScript_Success(t *testing.T) {
	mock := &mockScriptingClient{
		executeAppleScriptFn: func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
			if req.Script != `tell application "Finder" to get name of desktop` {
				t.Errorf("unexpected script: %q", req.Script)
			}
			return &pb.ExecuteAppleScriptResponse{
				Success: true,
				Output:  "desktop",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{"script": "tell application \"Finder\" to get name of desktop"}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if len(result.Content) != 1 || result.Content[0].Text != "AppleScript result: desktop" {
		t.Errorf("unexpected result: %v", result.Content)
	}
}

func TestHandleExecuteAppleScript_SuccessNoOutput(t *testing.T) {
	mock := &mockScriptingClient{
		executeAppleScriptFn: func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
			return &pb.ExecuteAppleScriptResponse{
				Success: true,
				Output:  "",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{"script": "do shell script \"echo\"", "timeout": 10}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if len(result.Content) != 1 || result.Content[0].Text != "Script executed (no output)" {
		t.Errorf("unexpected result: %v", result.Content)
	}
}

func TestHandleExecuteAppleScript_ScriptError(t *testing.T) {
	mock := &mockScriptingClient{
		executeAppleScriptFn: func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
			return &pb.ExecuteAppleScriptResponse{
				Success: false,
				Error:   "syntax error: expected end of line but found identifier",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{"script": "invalid script content"}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result")
	}
	if len(result.Content) < 1 || result.Content[0].Text == "" {
		t.Errorf("expected error message in result: %v", result.Content)
	}
}

func TestHandleExecuteAppleScript_GRPCError(t *testing.T) {
	mock := &mockScriptingClient{
		executeAppleScriptFn: func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
			return nil, errors.New("grpc: connection refused")
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{"script": "display dialog \"Hello\""}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for gRPC failure")
	}
}

func TestHandleExecuteAppleScript_MissingScript(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for missing script")
	}
	if result.Content[0].Text != "script parameter is required" {
		t.Errorf("unexpected error message: %s", result.Content[0].Text)
	}
}

func TestHandleExecuteAppleScript_InvalidJSON(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{invalid json}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for invalid JSON")
	}
}

func TestHandleExecuteAppleScript_CustomTimeout(t *testing.T) {
	var capturedTimeout int32
	mock := &mockScriptingClient{
		executeAppleScriptFn: func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
			if req.Timeout != nil {
				capturedTimeout = int32(req.Timeout.Seconds)
			}
			return &pb.ExecuteAppleScriptResponse{Success: true, Output: "OK"}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{"script": "return 1", "timeout": 60}`),
	}

	result, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("unexpected error: %v", result.Content)
	}
	if capturedTimeout != 60 {
		t.Errorf("expected timeout 60, got %d", capturedTimeout)
	}
}

// ============================================================================
// handleExecuteJavaScript Tests
// ============================================================================

func TestHandleExecuteJavaScript_Success(t *testing.T) {
	mock := &mockScriptingClient{
		executeJavaScriptFn: func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
			if req.Script != `Application("Finder").name()` {
				t.Errorf("unexpected script: %q", req.Script)
			}
			return &pb.ExecuteJavaScriptResponse{
				Success: true,
				Output:  "Finder",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`{"script": "Application(\"Finder\").name()"}`),
	}

	result, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if len(result.Content) != 1 || result.Content[0].Text != "JavaScript result: Finder" {
		t.Errorf("unexpected result: %v", result.Content)
	}
}

func TestHandleExecuteJavaScript_SuccessNoOutput(t *testing.T) {
	mock := &mockScriptingClient{
		executeJavaScriptFn: func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
			return &pb.ExecuteJavaScriptResponse{
				Success: true,
				Output:  "",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`{"script": "const x = 1"}`),
	}

	result, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if len(result.Content) != 1 || result.Content[0].Text != "Script executed (no output)" {
		t.Errorf("unexpected result: %v", result.Content)
	}
}

func TestHandleExecuteJavaScript_ScriptError(t *testing.T) {
	mock := &mockScriptingClient{
		executeJavaScriptFn: func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
			return &pb.ExecuteJavaScriptResponse{
				Success: false,
				Error:   "SyntaxError: unexpected token 'invalid'",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`{"script": "invalid javascript"}`),
	}

	result, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result")
	}
}

func TestHandleExecuteJavaScript_GRPCError(t *testing.T) {
	mock := &mockScriptingClient{
		executeJavaScriptFn: func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
			return nil, errors.New("grpc: unavailable")
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`{"script": "1 + 1"}`),
	}

	result, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for gRPC failure")
	}
}

func TestHandleExecuteJavaScript_MissingScript(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`{"timeout": 10}`),
	}

	result, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for missing script")
	}
	if result.Content[0].Text != "script parameter is required" {
		t.Errorf("unexpected error message: %s", result.Content[0].Text)
	}
}

func TestHandleExecuteJavaScript_InvalidJSON(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`not json`),
	}

	result, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for invalid JSON")
	}
}

// ============================================================================
// handleExecuteShellCommand Tests
// ============================================================================

func TestHandleExecuteShellCommand_Success(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			if req.Command != "echo" {
				t.Errorf("unexpected command: %q", req.Command)
			}
			return &pb.ExecuteShellCommandResponse{
				Stdout:   "hello world\n",
				Stderr:   "",
				ExitCode: 0,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "echo", "args": ["hello", "world"]}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if len(result.Content) != 1 || result.Content[0].Text != "hello world\n" {
		t.Errorf("unexpected result: %v", result.Content)
	}
}

func TestHandleExecuteShellCommand_SuccessNoOutput(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			return &pb.ExecuteShellCommandResponse{
				Stdout:   "",
				Stderr:   "",
				ExitCode: 0,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "true"}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if len(result.Content) != 1 || result.Content[0].Text != "Command executed (no output)" {
		t.Errorf("unexpected result: %v", result.Content)
	}
}

func TestHandleExecuteShellCommand_NonZeroExit(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			return &pb.ExecuteShellCommandResponse{
				Stdout:   "",
				Stderr:   "file not found\n",
				ExitCode: 1,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "cat", "args": ["/nonexistent"]}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for non-zero exit")
	}
}

func TestHandleExecuteShellCommand_WithStdoutAndStderr(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			return &pb.ExecuteShellCommandResponse{
				Stdout:   "output line\n",
				Stderr:   "warning: deprecated\n",
				ExitCode: 0,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "some-cmd"}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	// Should contain both stdout and stderr
	text := result.Content[0].Text
	if text != "output line\n\n\nSTDERR:\nwarning: deprecated\n" {
		t.Errorf("unexpected combined output: %q", text)
	}
}

func TestHandleExecuteShellCommand_StderrOnly(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			return &pb.ExecuteShellCommandResponse{
				Stdout:   "",
				Stderr:   "some warning\n",
				ExitCode: 0,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "warn-cmd"}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	text := result.Content[0].Text
	if text != "STDERR:\nsome warning\n" {
		t.Errorf("unexpected stderr-only output: %q", text)
	}
}

func TestHandleExecuteShellCommand_ExecutionError(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			return &pb.ExecuteShellCommandResponse{
				Error: "command not found: nonexistent-binary",
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "nonexistent-binary"}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for execution error")
	}
}

func TestHandleExecuteShellCommand_GRPCError(t *testing.T) {
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			return nil, errors.New("grpc: deadline exceeded")
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "sleep", "args": ["100"]}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for gRPC failure")
	}
}

func TestHandleExecuteShellCommand_MissingCommand(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"args": ["test"]}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for missing command")
	}
	if result.Content[0].Text != "command parameter is required" {
		t.Errorf("unexpected error message: %s", result.Content[0].Text)
	}
}

func TestHandleExecuteShellCommand_InvalidJSON(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{broken`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for invalid JSON")
	}
}

func TestHandleExecuteShellCommand_Disabled(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	s.cfg.ShellCommandsEnabled = false // Disable shell commands

	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "echo", "args": ["test"]}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result when shell commands disabled")
	}
	if result.Content[0].Text != "Shell command execution is disabled. Set MCP_SHELL_COMMANDS_ENABLED=true to enable." {
		t.Errorf("unexpected error message: %s", result.Content[0].Text)
	}
}

func TestHandleExecuteShellCommand_WithWorkingDirectory(t *testing.T) {
	var capturedWorkdir string
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			capturedWorkdir = req.WorkingDirectory
			return &pb.ExecuteShellCommandResponse{
				Stdout:   "/tmp\n",
				ExitCode: 0,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "pwd", "working_directory": "/tmp"}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("unexpected error: %v", result.Content)
	}
	if capturedWorkdir != "/tmp" {
		t.Errorf("expected working directory /tmp, got %q", capturedWorkdir)
	}
}

// ============================================================================
// handleValidateScript Tests
// ============================================================================

func TestHandleValidateScript_AppleScriptValid(t *testing.T) {
	mock := &mockScriptingClient{
		validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
			if req.Type != pb.ScriptType_SCRIPT_TYPE_APPLESCRIPT {
				t.Errorf("expected applescript type, got %v", req.Type)
			}
			return &pb.ValidateScriptResponse{
				Valid:  true,
				Errors: nil,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "applescript", "script": "display dialog \"Hello\""}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
	if result.Content[0].Text != "Script validation successful (applescript)" {
		t.Errorf("unexpected success message: %s", result.Content[0].Text)
	}
}

func TestHandleValidateScript_JavaScriptValid(t *testing.T) {
	mock := &mockScriptingClient{
		validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
			if req.Type != pb.ScriptType_SCRIPT_TYPE_JXA {
				t.Errorf("expected JXA type, got %v", req.Type)
			}
			return &pb.ValidateScriptResponse{
				Valid:  true,
				Errors: nil,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "javascript", "script": "const x = 1"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
}

func TestHandleValidateScript_ShellValid(t *testing.T) {
	mock := &mockScriptingClient{
		validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
			if req.Type != pb.ScriptType_SCRIPT_TYPE_SHELL {
				t.Errorf("expected shell type, got %v", req.Type)
			}
			return &pb.ValidateScriptResponse{
				Valid:  true,
				Errors: nil,
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "shell", "script": "echo hello"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}
}

func TestHandleValidateScript_Invalid(t *testing.T) {
	mock := &mockScriptingClient{
		validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
			return &pb.ValidateScriptResponse{
				Valid:  false,
				Errors: []string{"syntax error: unexpected end of file", "line 1:5: missing closing quote"},
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "applescript", "script": "tell application"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for invalid script")
	}
}

func TestHandleValidateScript_UnknownType(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "python", "script": "print('hi')"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for unknown script type")
	}
	if result.Content[0].Text != "Unknown script type: python. Valid: applescript, javascript, shell" {
		t.Errorf("unexpected error message: %s", result.Content[0].Text)
	}
}

func TestHandleValidateScript_MissingType(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"script": "echo hello"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for missing type")
	}
	if result.Content[0].Text != "type and script parameters are required" {
		t.Errorf("unexpected error message: %s", result.Content[0].Text)
	}
}

func TestHandleValidateScript_MissingScript(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "shell"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for missing script")
	}
}

func TestHandleValidateScript_GRPCError(t *testing.T) {
	mock := &mockScriptingClient{
		validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
			return nil, errors.New("grpc: internal error")
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{"type": "shell", "script": "echo test"}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for gRPC failure")
	}
}

func TestHandleValidateScript_InvalidJSON(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "validate_script",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := s.handleValidateScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for invalid JSON")
	}
}

// ============================================================================
// handleGetScriptingDictionaries Tests
// ============================================================================

func TestHandleGetScriptingDictionaries_Success(t *testing.T) {
	mock := &mockScriptingClient{
		getScriptingDictionariesFn: func(ctx context.Context, req *pb.GetScriptingDictionariesRequest) (*pb.ScriptingDictionaries, error) {
			return &pb.ScriptingDictionaries{
				Dictionaries: []*pb.ScriptingDictionary{
					{
						Application: "Finder",
						BundleId:    "com.apple.finder",
						Commands:    []string{"open"},
					},
					{
						Application: "Safari",
						BundleId:    "com.apple.Safari",
						Commands:    []string{"make", "open"},
					},
				},
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "get_scripting_dictionaries",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := s.handleGetScriptingDictionaries(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}

	// Verify response contains expected data
	var response map[string]interface{}
	if err := json.Unmarshal([]byte(result.Content[0].Text), &response); err != nil {
		t.Fatalf("failed to parse response JSON: %v", err)
	}

	if response["total"].(float64) != 2 {
		t.Errorf("expected total 2, got %v", response["total"])
	}

	dicts := response["dictionaries"].([]interface{})
	if len(dicts) != 2 {
		t.Errorf("expected 2 dictionaries, got %d", len(dicts))
	}
}

func TestHandleGetScriptingDictionaries_Empty(t *testing.T) {
	mock := &mockScriptingClient{
		getScriptingDictionariesFn: func(ctx context.Context, req *pb.GetScriptingDictionariesRequest) (*pb.ScriptingDictionaries, error) {
			return &pb.ScriptingDictionaries{
				Dictionaries: []*pb.ScriptingDictionary{},
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "get_scripting_dictionaries",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := s.handleGetScriptingDictionaries(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsError {
		t.Errorf("expected success, got error: %v", result.Content)
	}

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(result.Content[0].Text), &response); err != nil {
		t.Fatalf("failed to parse response JSON: %v", err)
	}

	if response["total"].(float64) != 0 {
		t.Errorf("expected total 0, got %v", response["total"])
	}
}

func TestHandleGetScriptingDictionaries_WithName(t *testing.T) {
	var capturedName string
	mock := &mockScriptingClient{
		getScriptingDictionariesFn: func(ctx context.Context, req *pb.GetScriptingDictionariesRequest) (*pb.ScriptingDictionaries, error) {
			capturedName = req.Name
			return &pb.ScriptingDictionaries{
				Dictionaries: []*pb.ScriptingDictionary{},
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "get_scripting_dictionaries",
		Arguments: json.RawMessage(`{"name": "customName"}`),
	}

	_, err := s.handleGetScriptingDictionaries(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if capturedName != "customName" {
		t.Errorf("expected name 'customName', got %q", capturedName)
	}
}

func TestHandleGetScriptingDictionaries_DefaultName(t *testing.T) {
	var capturedName string
	mock := &mockScriptingClient{
		getScriptingDictionariesFn: func(ctx context.Context, req *pb.GetScriptingDictionariesRequest) (*pb.ScriptingDictionaries, error) {
			capturedName = req.Name
			return &pb.ScriptingDictionaries{
				Dictionaries: []*pb.ScriptingDictionary{},
			}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "get_scripting_dictionaries",
		Arguments: json.RawMessage(`{}`),
	}

	_, err := s.handleGetScriptingDictionaries(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if capturedName != "scriptingDictionaries" {
		t.Errorf("expected default name 'scriptingDictionaries', got %q", capturedName)
	}
}

func TestHandleGetScriptingDictionaries_GRPCError(t *testing.T) {
	mock := &mockScriptingClient{
		getScriptingDictionariesFn: func(ctx context.Context, req *pb.GetScriptingDictionariesRequest) (*pb.ScriptingDictionaries, error) {
			return nil, errors.New("grpc: not found")
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "get_scripting_dictionaries",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := s.handleGetScriptingDictionaries(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for gRPC failure")
	}
}

func TestHandleGetScriptingDictionaries_InvalidJSON(t *testing.T) {
	mock := &mockScriptingClient{}
	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "get_scripting_dictionaries",
		Arguments: json.RawMessage(`{broken`),
	}

	result, err := s.handleGetScriptingDictionaries(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.IsError {
		t.Error("expected error result for invalid JSON")
	}
}

// ============================================================================
// Edge Cases and Timeout Tests
// ============================================================================

func TestDefaultScriptTimeout_Value(t *testing.T) {
	if defaultScriptTimeout != 30 {
		t.Errorf("defaultScriptTimeout = %d, want 30", defaultScriptTimeout)
	}
}

func TestAppleScript_DefaultTimeout(t *testing.T) {
	var capturedTimeout int32
	mock := &mockScriptingClient{
		executeAppleScriptFn: func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
			if req.Timeout != nil {
				capturedTimeout = int32(req.Timeout.Seconds)
			}
			return &pb.ExecuteAppleScriptResponse{Success: true, Output: "OK"}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_apple_script",
		Arguments: json.RawMessage(`{"script": "return 1"}`), // No timeout specified
	}

	_, err := s.handleExecuteAppleScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if capturedTimeout != 30 {
		t.Errorf("expected default timeout 30, got %d", capturedTimeout)
	}
}

func TestJavaScript_DefaultTimeout(t *testing.T) {
	var capturedTimeout int32
	mock := &mockScriptingClient{
		executeJavaScriptFn: func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
			if req.Timeout != nil {
				capturedTimeout = int32(req.Timeout.Seconds)
			}
			return &pb.ExecuteJavaScriptResponse{Success: true, Output: "OK"}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_javascript",
		Arguments: json.RawMessage(`{"script": "1 + 1"}`), // No timeout specified
	}

	_, err := s.handleExecuteJavaScript(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if capturedTimeout != 30 {
		t.Errorf("expected default timeout 30, got %d", capturedTimeout)
	}
}

func TestShellCommand_DefaultTimeout(t *testing.T) {
	var capturedTimeout int32
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			if req.Timeout != nil {
				capturedTimeout = int32(req.Timeout.Seconds)
			}
			return &pb.ExecuteShellCommandResponse{Stdout: "OK", ExitCode: 0}, nil
		},
	}

	s := createTestScriptingServer(mock)
	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "echo"}`), // No timeout specified
	}

	_, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if capturedTimeout != 30 {
		t.Errorf("expected default timeout 30, got %d", capturedTimeout)
	}
}

// Verify durationpb import is actually used
func TestDurationpb_Usage(t *testing.T) {
	d := durationpb.New(30 * 1e9) // 30 seconds in nanoseconds
	if d.Seconds != 30 {
		t.Errorf("durationpb.New(30s) = %v, want 30 seconds", d.Seconds)
	}
}

// ============================================================================
// Security-Focused Tests (Task 49)
// ============================================================================

// TestShellCommand_SecurityToggle verifies shell commands are correctly
// blocked or allowed based on the ShellCommandsEnabled config flag.
func TestShellCommand_SecurityToggle(t *testing.T) {
	tests := []struct {
		name                 string
		shellCommandsEnabled bool
		wantError            bool
		wantErrorMsg         string
	}{
		{
			name:                 "shell_commands_disabled_blocks_execution",
			shellCommandsEnabled: false,
			wantError:            true,
			wantErrorMsg:         "Shell command execution is disabled. Set MCP_SHELL_COMMANDS_ENABLED=true to enable.",
		},
		{
			name:                 "shell_commands_enabled_allows_execution",
			shellCommandsEnabled: true,
			wantError:            false,
			wantErrorMsg:         "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mock := &mockScriptingClient{
				executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
					return &pb.ExecuteShellCommandResponse{
						Stdout:   "success\n",
						ExitCode: 0,
					}, nil
				},
			}

			s := createTestScriptingServer(mock)
			s.cfg.ShellCommandsEnabled = tt.shellCommandsEnabled

			call := &ToolCall{
				Name:      "execute_shell_command",
				Arguments: json.RawMessage(`{"command": "echo", "args": ["test"]}`),
			}

			result, err := s.handleExecuteShellCommand(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if result.IsError != tt.wantError {
				t.Errorf("IsError = %v, want %v", result.IsError, tt.wantError)
			}

			if tt.wantError && result.Content[0].Text != tt.wantErrorMsg {
				t.Errorf("error message = %q, want %q", result.Content[0].Text, tt.wantErrorMsg)
			}
		})
	}
}

// TestShellCommand_ExitCodePropagation verifies that exit codes are correctly
// propagated in the response for various exit code values.
func TestShellCommand_ExitCodePropagation(t *testing.T) {
	tests := []struct {
		name         string
		exitCode     int32
		stdout       string
		stderr       string
		wantIsError  bool
		wantContains string
	}{
		{
			name:         "exit_code_0_success",
			exitCode:     0,
			stdout:       "output",
			stderr:       "",
			wantIsError:  false,
			wantContains: "output",
		},
		{
			name:         "exit_code_1_failure",
			exitCode:     1,
			stdout:       "",
			stderr:       "error occurred",
			wantIsError:  true,
			wantContains: "Command exited with code 1",
		},
		{
			name:         "exit_code_2_misuse",
			exitCode:     2,
			stdout:       "",
			stderr:       "misuse of shell command",
			wantIsError:  true,
			wantContains: "Command exited with code 2",
		},
		{
			name:         "exit_code_126_not_executable",
			exitCode:     126,
			stdout:       "",
			stderr:       "permission denied",
			wantIsError:  true,
			wantContains: "Command exited with code 126",
		},
		{
			name:         "exit_code_127_not_found",
			exitCode:     127,
			stdout:       "",
			stderr:       "command not found",
			wantIsError:  true,
			wantContains: "Command exited with code 127",
		},
		{
			name:         "exit_code_128_invalid_exit_arg",
			exitCode:     128,
			stdout:       "",
			stderr:       "",
			wantIsError:  true,
			wantContains: "Command exited with code 128",
		},
		{
			name:         "exit_code_130_terminated_by_ctrl_c",
			exitCode:     130,
			stdout:       "",
			stderr:       "interrupted",
			wantIsError:  true,
			wantContains: "Command exited with code 130",
		},
		{
			name:         "exit_code_137_killed_sigkill",
			exitCode:     137,
			stdout:       "partial output",
			stderr:       "killed",
			wantIsError:  true,
			wantContains: "Command exited with code 137",
		},
		{
			name:         "exit_code_143_term_signal",
			exitCode:     143,
			stdout:       "",
			stderr:       "terminated",
			wantIsError:  true,
			wantContains: "Command exited with code 143",
		},
		{
			name:         "exit_code_255_out_of_range",
			exitCode:     255,
			stdout:       "",
			stderr:       "invalid",
			wantIsError:  true,
			wantContains: "Command exited with code 255",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mock := &mockScriptingClient{
				executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
					return &pb.ExecuteShellCommandResponse{
						Stdout:   tt.stdout,
						Stderr:   tt.stderr,
						ExitCode: tt.exitCode,
					}, nil
				},
			}

			s := createTestScriptingServer(mock)
			call := &ToolCall{
				Name:      "execute_shell_command",
				Arguments: json.RawMessage(`{"command": "test-cmd"}`),
			}

			result, err := s.handleExecuteShellCommand(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if result.IsError != tt.wantIsError {
				t.Errorf("IsError = %v, want %v", result.IsError, tt.wantIsError)
			}

			if len(result.Content) == 0 {
				t.Fatal("expected content in result")
			}

			if !strings.Contains(result.Content[0].Text, tt.wantContains) {
				t.Errorf("result text = %q, want to contain %q", result.Content[0].Text, tt.wantContains)
			}
		})
	}
}

// TestValidateScript_TypeMapping verifies that all script type strings are
// correctly mapped to their proto enum values.
func TestValidateScript_TypeMapping(t *testing.T) {
	tests := []struct {
		name             string
		typeStr          string
		wantProtoType    pb.ScriptType
		wantError        bool
		wantErrorContain string
	}{
		{
			name:          "applescript_maps_correctly",
			typeStr:       "applescript",
			wantProtoType: pb.ScriptType_SCRIPT_TYPE_APPLESCRIPT,
			wantError:     false,
		},
		{
			name:          "javascript_maps_to_jxa",
			typeStr:       "javascript",
			wantProtoType: pb.ScriptType_SCRIPT_TYPE_JXA,
			wantError:     false,
		},
		{
			name:          "shell_maps_correctly",
			typeStr:       "shell",
			wantProtoType: pb.ScriptType_SCRIPT_TYPE_SHELL,
			wantError:     false,
		},
		{
			name:             "python_invalid_type",
			typeStr:          "python",
			wantError:        true,
			wantErrorContain: "Unknown script type: python",
		},
		{
			name:             "bash_invalid_type",
			typeStr:          "bash",
			wantError:        true,
			wantErrorContain: "Unknown script type: bash",
		},
		{
			name:             "js_invalid_abbreviated",
			typeStr:          "js",
			wantError:        true,
			wantErrorContain: "Unknown script type: js",
		},
		{
			name:             "osascript_invalid",
			typeStr:          "osascript",
			wantError:        true,
			wantErrorContain: "Unknown script type: osascript",
		},
		{
			name:             "empty_type_requires_type_param",
			typeStr:          "",
			wantError:        true,
			wantErrorContain: "type and script parameters are required",
		},
		{
			name:             "AppleScript_case_sensitive",
			typeStr:          "AppleScript",
			wantError:        true,
			wantErrorContain: "Unknown script type: AppleScript",
		},
		{
			name:             "SHELL_case_sensitive",
			typeStr:          "SHELL",
			wantError:        true,
			wantErrorContain: "Unknown script type: SHELL",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var capturedType pb.ScriptType
			mock := &mockScriptingClient{
				validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
					capturedType = req.Type
					return &pb.ValidateScriptResponse{Valid: true}, nil
				},
			}

			s := createTestScriptingServer(mock)
			call := &ToolCall{
				Name:      "validate_script",
				Arguments: json.RawMessage(fmt.Sprintf(`{"type": "%s", "script": "test script"}`, tt.typeStr)),
			}

			result, err := s.handleValidateScript(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if result.IsError != tt.wantError {
				t.Errorf("IsError = %v, want %v (content: %v)", result.IsError, tt.wantError, result.Content)
			}

			if tt.wantError {
				if !strings.Contains(result.Content[0].Text, tt.wantErrorContain) {
					t.Errorf("error text = %q, want to contain %q", result.Content[0].Text, tt.wantErrorContain)
				}
			} else {
				if capturedType != tt.wantProtoType {
					t.Errorf("captured type = %v, want %v", capturedType, tt.wantProtoType)
				}
			}
		})
	}
}

// TestScript_TimeoutForwarding verifies that timeout parameters are correctly
// forwarded to the gRPC request for all script types.
func TestScript_TimeoutForwarding(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		inputTimeout int32
		wantTimeout  int32
		setupMock    func(*mockScriptingClient, *int32)
		callFunc     func(*MCPServer, *ToolCall) (*ToolResult, error)
	}{
		{
			name:         "applescript_custom_timeout",
			handler:      "applescript",
			inputTimeout: 120,
			wantTimeout:  120,
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeAppleScriptFn = func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteAppleScriptResponse{Success: true, Output: "OK"}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteAppleScript(call)
			},
		},
		{
			name:         "applescript_default_timeout",
			handler:      "applescript",
			inputTimeout: 0,
			wantTimeout:  30, // default
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeAppleScriptFn = func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteAppleScriptResponse{Success: true, Output: "OK"}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteAppleScript(call)
			},
		},
		{
			name:         "applescript_negative_timeout_uses_default",
			handler:      "applescript",
			inputTimeout: -5,
			wantTimeout:  30, // default
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeAppleScriptFn = func(ctx context.Context, req *pb.ExecuteAppleScriptRequest) (*pb.ExecuteAppleScriptResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteAppleScriptResponse{Success: true, Output: "OK"}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteAppleScript(call)
			},
		},
		{
			name:         "javascript_custom_timeout",
			handler:      "javascript",
			inputTimeout: 90,
			wantTimeout:  90,
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeJavaScriptFn = func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteJavaScriptResponse{Success: true, Output: "OK"}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteJavaScript(call)
			},
		},
		{
			name:         "javascript_default_timeout",
			handler:      "javascript",
			inputTimeout: 0,
			wantTimeout:  30, // default
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeJavaScriptFn = func(ctx context.Context, req *pb.ExecuteJavaScriptRequest) (*pb.ExecuteJavaScriptResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteJavaScriptResponse{Success: true, Output: "OK"}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteJavaScript(call)
			},
		},
		{
			name:         "shell_custom_timeout",
			handler:      "shell",
			inputTimeout: 180,
			wantTimeout:  180,
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeShellCommandFn = func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteShellCommandResponse{Stdout: "OK", ExitCode: 0}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteShellCommand(call)
			},
		},
		{
			name:         "shell_default_timeout",
			handler:      "shell",
			inputTimeout: 0,
			wantTimeout:  30, // default
			setupMock: func(m *mockScriptingClient, captured *int32) {
				m.executeShellCommandFn = func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
					if req.Timeout != nil {
						*captured = int32(req.Timeout.Seconds)
					}
					return &pb.ExecuteShellCommandResponse{Stdout: "OK", ExitCode: 0}, nil
				}
			},
			callFunc: func(s *MCPServer, call *ToolCall) (*ToolResult, error) {
				return s.handleExecuteShellCommand(call)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var capturedTimeout int32
			mock := &mockScriptingClient{}
			tt.setupMock(mock, &capturedTimeout)

			s := createTestScriptingServer(mock)

			var argsJSON string
			switch tt.handler {
			case "applescript":
				argsJSON = fmt.Sprintf(`{"script": "return 1", "timeout": %d}`, tt.inputTimeout)
			case "javascript":
				argsJSON = fmt.Sprintf(`{"script": "1 + 1", "timeout": %d}`, tt.inputTimeout)
			case "shell":
				argsJSON = fmt.Sprintf(`{"command": "echo", "timeout": %d}`, tt.inputTimeout)
			}

			call := &ToolCall{
				Name:      tt.handler,
				Arguments: json.RawMessage(argsJSON),
			}

			result, err := tt.callFunc(s, call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result.IsError {
				t.Errorf("unexpected error result: %v", result.Content)
			}

			if capturedTimeout != tt.wantTimeout {
				t.Errorf("captured timeout = %d, want %d", capturedTimeout, tt.wantTimeout)
			}
		})
	}
}

// TestShellCommand_SecurityDisabledDoesNotCallGRPC verifies that when shell
// commands are disabled, no gRPC call is made to the backend.
func TestShellCommand_SecurityDisabledDoesNotCallGRPC(t *testing.T) {
	grpcCalled := false
	mock := &mockScriptingClient{
		executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
			grpcCalled = true
			return &pb.ExecuteShellCommandResponse{Stdout: "success", ExitCode: 0}, nil
		},
	}

	s := createTestScriptingServer(mock)
	s.cfg.ShellCommandsEnabled = false

	call := &ToolCall{
		Name:      "execute_shell_command",
		Arguments: json.RawMessage(`{"command": "echo", "args": ["test"]}`),
	}

	result, err := s.handleExecuteShellCommand(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !result.IsError {
		t.Error("expected error when shell commands disabled")
	}

	if grpcCalled {
		t.Error("gRPC should not be called when shell commands are disabled")
	}
}

// TestValidateScript_AllTypesValidScripts verifies script validation works
// for all valid script types end-to-end.
func TestValidateScript_AllTypesValidScripts(t *testing.T) {
	tests := []struct {
		name       string
		typeStr    string
		script     string
		wantResult string
	}{
		{
			name:       "applescript_valid",
			typeStr:    "applescript",
			script:     `tell application "Finder" to get name`,
			wantResult: "Script validation successful (applescript)",
		},
		{
			name:       "javascript_valid",
			typeStr:    "javascript",
			script:     `Application("System Events").name()`,
			wantResult: "Script validation successful (javascript)",
		},
		{
			name:       "shell_valid",
			typeStr:    "shell",
			script:     "#!/bin/bash\necho hello",
			wantResult: "Script validation successful (shell)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mock := &mockScriptingClient{
				validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
					return &pb.ValidateScriptResponse{Valid: true}, nil
				},
			}

			s := createTestScriptingServer(mock)

			// Use proper JSON encoding for arguments to handle special characters
			argsMap := map[string]string{"type": tt.typeStr, "script": tt.script}
			argsJSON, _ := json.Marshal(argsMap)
			call := &ToolCall{
				Name:      "validate_script",
				Arguments: json.RawMessage(argsJSON),
			}

			result, err := s.handleValidateScript(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if result.IsError {
				t.Errorf("expected success, got error: %v", result.Content)
			}

			if result.Content[0].Text != tt.wantResult {
				t.Errorf("result = %q, want %q", result.Content[0].Text, tt.wantResult)
			}
		})
	}
}

// TestValidateScript_InvalidScriptContent verifies that invalid scripts
// return proper error information from the validation response.
func TestValidateScript_InvalidScriptContent(t *testing.T) {
	tests := []struct {
		name       string
		typeStr    string
		script     string
		errors     []string
		wantJoined string
	}{
		{
			name:       "single_error",
			typeStr:    "applescript",
			script:     "tell application",
			errors:     []string{"expected end of line"},
			wantJoined: "expected end of line",
		},
		{
			name:       "multiple_errors",
			typeStr:    "javascript",
			script:     "function( {",
			errors:     []string{"unexpected token", "missing closing brace"},
			wantJoined: "unexpected token; missing closing brace",
		},
		{
			name:       "shell_syntax_error",
			typeStr:    "shell",
			script:     "if [ then",
			errors:     []string{"syntax error near unexpected token"},
			wantJoined: "syntax error near unexpected token",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mock := &mockScriptingClient{
				validateScriptFn: func(ctx context.Context, req *pb.ValidateScriptRequest) (*pb.ValidateScriptResponse, error) {
					return &pb.ValidateScriptResponse{
						Valid:  false,
						Errors: tt.errors,
					}, nil
				},
			}

			s := createTestScriptingServer(mock)
			call := &ToolCall{
				Name:      "validate_script",
				Arguments: json.RawMessage(fmt.Sprintf(`{"type": "%s", "script": "%s"}`, tt.typeStr, tt.script)),
			}

			result, err := s.handleValidateScript(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if !result.IsError {
				t.Error("expected error for invalid script")
			}

			if !strings.Contains(result.Content[0].Text, tt.wantJoined) {
				t.Errorf("error = %q, want to contain %q", result.Content[0].Text, tt.wantJoined)
			}
		})
	}
}

// TestShellCommand_ArgsForwarding verifies that command arguments are correctly
// forwarded to the gRPC request.
func TestShellCommand_ArgsForwarding(t *testing.T) {
	tests := []struct {
		name     string
		args     []string
		wantArgs []string
	}{
		{
			name:     "single_arg",
			args:     []string{"test"},
			wantArgs: []string{"test"},
		},
		{
			name:     "multiple_args",
			args:     []string{"-l", "-a", "/tmp"},
			wantArgs: []string{"-l", "-a", "/tmp"},
		},
		{
			name:     "no_args",
			args:     nil,
			wantArgs: nil,
		},
		{
			name:     "empty_args_array",
			args:     []string{},
			wantArgs: []string{},
		},
		{
			name:     "args_with_spaces",
			args:     []string{"hello world", "foo bar"},
			wantArgs: []string{"hello world", "foo bar"},
		},
		{
			name:     "args_with_special_chars",
			args:     []string{"--flag=value", "$HOME", "|grep"},
			wantArgs: []string{"--flag=value", "$HOME", "|grep"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var capturedArgs []string
			mock := &mockScriptingClient{
				executeShellCommandFn: func(ctx context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
					capturedArgs = req.Args
					return &pb.ExecuteShellCommandResponse{Stdout: "OK", ExitCode: 0}, nil
				},
			}

			s := createTestScriptingServer(mock)

			argsJSON, _ := json.Marshal(tt.args)
			call := &ToolCall{
				Name:      "execute_shell_command",
				Arguments: json.RawMessage(fmt.Sprintf(`{"command": "test", "args": %s}`, argsJSON)),
			}

			result, err := s.handleExecuteShellCommand(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if result.IsError {
				t.Errorf("unexpected error: %v", result.Content)
			}

			if len(capturedArgs) != len(tt.wantArgs) {
				t.Errorf("args length = %d, want %d", len(capturedArgs), len(tt.wantArgs))
				return
			}

			for i := range tt.wantArgs {
				if capturedArgs[i] != tt.wantArgs[i] {
					t.Errorf("args[%d] = %q, want %q", i, capturedArgs[i], tt.wantArgs[i])
				}
			}
		})
	}
}
