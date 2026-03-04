// Copyright 2025 Joseph Cumines
//
// Session and macro handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// mockSessionClient is a mock implementation of MacosUseClient for session testing.
type mockSessionClient struct {
	mockMacosUseClient

	// Session mocks
	createSessionFunc       func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error)
	getSessionFunc          func(ctx context.Context, req *pb.GetSessionRequest) (*pb.Session, error)
	listSessionsFunc        func(ctx context.Context, req *pb.ListSessionsRequest) (*pb.ListSessionsResponse, error)
	deleteSessionFunc       func(ctx context.Context, req *pb.DeleteSessionRequest) (*emptypb.Empty, error)
	getSessionSnapshotFunc  func(ctx context.Context, req *pb.GetSessionSnapshotRequest) (*pb.SessionSnapshot, error)
	beginTransactionFunc    func(ctx context.Context, req *pb.BeginTransactionRequest) (*pb.BeginTransactionResponse, error)
	commitTransactionFunc   func(ctx context.Context, req *pb.CommitTransactionRequest) (*pb.Transaction, error)
	rollbackTransactionFunc func(ctx context.Context, req *pb.RollbackTransactionRequest) (*pb.Transaction, error)

	// Macro mocks
	createMacroFunc  func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error)
	getMacroFunc     func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error)
	listMacrosFunc   func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error)
	deleteMacroFunc  func(ctx context.Context, req *pb.DeleteMacroRequest) (*emptypb.Empty, error)
	updateMacroFunc  func(ctx context.Context, req *pb.UpdateMacroRequest) (*pb.Macro, error)
	executeMacroFunc func(ctx context.Context, req *pb.ExecuteMacroRequest) (*longrunningpb.Operation, error)
}

func (m *mockSessionClient) CreateSession(ctx context.Context, req *pb.CreateSessionRequest, opts ...grpc.CallOption) (*pb.Session, error) {
	if m.createSessionFunc != nil {
		return m.createSessionFunc(ctx, req)
	}
	return nil, errors.New("CreateSession not implemented")
}

func (m *mockSessionClient) GetSession(ctx context.Context, req *pb.GetSessionRequest, opts ...grpc.CallOption) (*pb.Session, error) {
	if m.getSessionFunc != nil {
		return m.getSessionFunc(ctx, req)
	}
	return nil, errors.New("GetSession not implemented")
}

func (m *mockSessionClient) ListSessions(ctx context.Context, req *pb.ListSessionsRequest, opts ...grpc.CallOption) (*pb.ListSessionsResponse, error) {
	if m.listSessionsFunc != nil {
		return m.listSessionsFunc(ctx, req)
	}
	return nil, errors.New("ListSessions not implemented")
}

func (m *mockSessionClient) DeleteSession(ctx context.Context, req *pb.DeleteSessionRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	if m.deleteSessionFunc != nil {
		return m.deleteSessionFunc(ctx, req)
	}
	return nil, errors.New("DeleteSession not implemented")
}

func (m *mockSessionClient) GetSessionSnapshot(ctx context.Context, req *pb.GetSessionSnapshotRequest, opts ...grpc.CallOption) (*pb.SessionSnapshot, error) {
	if m.getSessionSnapshotFunc != nil {
		return m.getSessionSnapshotFunc(ctx, req)
	}
	return nil, errors.New("GetSessionSnapshot not implemented")
}

func (m *mockSessionClient) BeginTransaction(ctx context.Context, req *pb.BeginTransactionRequest, opts ...grpc.CallOption) (*pb.BeginTransactionResponse, error) {
	if m.beginTransactionFunc != nil {
		return m.beginTransactionFunc(ctx, req)
	}
	return nil, errors.New("BeginTransaction not implemented")
}

func (m *mockSessionClient) CommitTransaction(ctx context.Context, req *pb.CommitTransactionRequest, opts ...grpc.CallOption) (*pb.Transaction, error) {
	if m.commitTransactionFunc != nil {
		return m.commitTransactionFunc(ctx, req)
	}
	return nil, errors.New("CommitTransaction not implemented")
}

func (m *mockSessionClient) RollbackTransaction(ctx context.Context, req *pb.RollbackTransactionRequest, opts ...grpc.CallOption) (*pb.Transaction, error) {
	if m.rollbackTransactionFunc != nil {
		return m.rollbackTransactionFunc(ctx, req)
	}
	return nil, errors.New("RollbackTransaction not implemented")
}

func (m *mockSessionClient) CreateMacro(ctx context.Context, req *pb.CreateMacroRequest, opts ...grpc.CallOption) (*pb.Macro, error) {
	if m.createMacroFunc != nil {
		return m.createMacroFunc(ctx, req)
	}
	return nil, errors.New("CreateMacro not implemented")
}

func (m *mockSessionClient) GetMacro(ctx context.Context, req *pb.GetMacroRequest, opts ...grpc.CallOption) (*pb.Macro, error) {
	if m.getMacroFunc != nil {
		return m.getMacroFunc(ctx, req)
	}
	return nil, errors.New("GetMacro not implemented")
}

func (m *mockSessionClient) ListMacros(ctx context.Context, req *pb.ListMacrosRequest, opts ...grpc.CallOption) (*pb.ListMacrosResponse, error) {
	if m.listMacrosFunc != nil {
		return m.listMacrosFunc(ctx, req)
	}
	return nil, errors.New("ListMacros not implemented")
}

func (m *mockSessionClient) DeleteMacro(ctx context.Context, req *pb.DeleteMacroRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	if m.deleteMacroFunc != nil {
		return m.deleteMacroFunc(ctx, req)
	}
	return nil, errors.New("DeleteMacro not implemented")
}

func (m *mockSessionClient) UpdateMacro(ctx context.Context, req *pb.UpdateMacroRequest, opts ...grpc.CallOption) (*pb.Macro, error) {
	if m.updateMacroFunc != nil {
		return m.updateMacroFunc(ctx, req)
	}
	return nil, errors.New("UpdateMacro not implemented")
}

func (m *mockSessionClient) ExecuteMacro(ctx context.Context, req *pb.ExecuteMacroRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	if m.executeMacroFunc != nil {
		return m.executeMacroFunc(ctx, req)
	}
	return nil, errors.New("ExecuteMacro not implemented")
}

// ============================================================================
// handleCreateSession Tests
// ============================================================================

func TestHandleCreateSession_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		createSessionFunc: func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error) {
			if req.Session.DisplayName != "Test Session" {
				t.Errorf("expected display_name 'Test Session', got %q", req.Session.DisplayName)
			}
			return &pb.Session{
				Name:        "sessions/test-123",
				DisplayName: "Test Session",
				State:       pb.Session_STATE_ACTIVE,
				CreateTime:  timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_session",
		Arguments: json.RawMessage(`{"display_name": "Test Session"}`),
	}

	result, err := server.handleCreateSession(call)

	if err != nil {
		t.Fatalf("handleCreateSession returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "sessions/test-123") {
		t.Errorf("result text does not contain session name: %s", text)
	}
}

func TestHandleCreateSession_WithSessionID(t *testing.T) {
	mockClient := &mockSessionClient{
		createSessionFunc: func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error) {
			if req.SessionId != "custom-id" {
				t.Errorf("expected session_id 'custom-id', got %q", req.SessionId)
			}
			return &pb.Session{
				Name:        "sessions/custom-id",
				DisplayName: "Custom Session",
				State:       pb.Session_STATE_ACTIVE,
				CreateTime:  timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_session",
		Arguments: json.RawMessage(`{"session_id": "custom-id", "display_name": "Custom Session"}`),
	}

	result, err := server.handleCreateSession(call)

	if err != nil {
		t.Fatalf("handleCreateSession returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCreateSession_WithMetadata(t *testing.T) {
	mockClient := &mockSessionClient{
		createSessionFunc: func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error) {
			if req.Session.Metadata == nil {
				t.Error("expected metadata to be set")
			}
			if req.Session.Metadata["key"] != "value" {
				t.Errorf("expected metadata[key] = 'value', got %q", req.Session.Metadata["key"])
			}
			return &pb.Session{
				Name:       "sessions/123",
				State:      pb.Session_STATE_ACTIVE,
				CreateTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_session",
		Arguments: json.RawMessage(`{"metadata": {"key": "value"}}`),
	}

	result, err := server.handleCreateSession(call)

	if err != nil {
		t.Fatalf("handleCreateSession returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCreateSession_InvalidJSON(t *testing.T) {
	mockClient := &mockSessionClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_session",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCreateSession(call)

	if err != nil {
		t.Fatalf("handleCreateSession returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCreateSession_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		createSessionFunc: func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error) {
			return nil, errors.New("session limit exceeded")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_session",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleCreateSession(call)

	if err != nil {
		t.Fatalf("handleCreateSession returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to create session") {
		t.Errorf("error text does not contain 'Failed to create session': %s", text)
	}
}

// ============================================================================
// handleGetSession Tests
// ============================================================================

func TestHandleGetSession_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		getSessionFunc: func(ctx context.Context, req *pb.GetSessionRequest) (*pb.Session, error) {
			if req.Name != "sessions/test-123" {
				t.Errorf("expected name 'sessions/test-123', got %q", req.Name)
			}
			return &pb.Session{
				Name:           "sessions/test-123",
				DisplayName:    "Test Session",
				State:          pb.Session_STATE_ACTIVE,
				CreateTime:     timestamppb.Now(),
				LastAccessTime: timestamppb.Now(),
				TransactionId:  "tx-456",
				Metadata:       map[string]string{"key": "value"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_session",
		Arguments: json.RawMessage(`{"name": "sessions/test-123"}`),
	}

	result, err := server.handleGetSession(call)

	if err != nil {
		t.Fatalf("handleGetSession returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "sessions/test-123") {
		t.Errorf("result text does not contain session name: %s", text)
	}
}

func TestHandleGetSession_MissingName(t *testing.T) {
	mockClient := &mockSessionClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_session",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetSession(call)

	if err != nil {
		t.Fatalf("handleGetSession returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetSession_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		getSessionFunc: func(ctx context.Context, req *pb.GetSessionRequest) (*pb.Session, error) {
			return nil, errors.New("session not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_session",
		Arguments: json.RawMessage(`{"name": "sessions/nonexistent"}`),
	}

	result, err := server.handleGetSession(call)

	if err != nil {
		t.Fatalf("handleGetSession returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get session") {
		t.Errorf("error text does not contain 'Failed to get session': %s", text)
	}
}

// ============================================================================
// handleListSessions Tests
// ============================================================================

func TestHandleListSessions_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		listSessionsFunc: func(ctx context.Context, req *pb.ListSessionsRequest) (*pb.ListSessionsResponse, error) {
			return &pb.ListSessionsResponse{
				Sessions: []*pb.Session{
					{Name: "sessions/1", DisplayName: "Session 1", State: pb.Session_STATE_ACTIVE},
					{Name: "sessions/2", DisplayName: "Session 2", State: pb.Session_STATE_ACTIVE},
				},
				NextPageToken: "token123",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_sessions",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListSessions(call)

	if err != nil {
		t.Fatalf("handleListSessions returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "sessions/1") {
		t.Errorf("result text does not contain 'sessions/1': %s", text)
	}
}

func TestHandleListSessions_WithPagination(t *testing.T) {
	mockClient := &mockSessionClient{
		listSessionsFunc: func(ctx context.Context, req *pb.ListSessionsRequest) (*pb.ListSessionsResponse, error) {
			if req.PageSize != 10 {
				t.Errorf("expected page_size 10, got %d", req.PageSize)
			}
			if req.PageToken != "token123" {
				t.Errorf("expected page_token 'token123', got %q", req.PageToken)
			}
			return &pb.ListSessionsResponse{
				Sessions: []*pb.Session{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_sessions",
		Arguments: json.RawMessage(`{"page_size": 10, "page_token": "token123"}`),
	}

	result, err := server.handleListSessions(call)

	if err != nil {
		t.Fatalf("handleListSessions returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleListSessions_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		listSessionsFunc: func(ctx context.Context, req *pb.ListSessionsRequest) (*pb.ListSessionsResponse, error) {
			return nil, errors.New("connection failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_sessions",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListSessions(call)

	if err != nil {
		t.Fatalf("handleListSessions returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to list sessions") {
		t.Errorf("error text does not contain 'Failed to list sessions': %s", text)
	}
}

// ============================================================================
// handleDeleteSession Tests
// ============================================================================

func TestHandleDeleteSession_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		deleteSessionFunc: func(ctx context.Context, req *pb.DeleteSessionRequest) (*emptypb.Empty, error) {
			if req.Name != "sessions/to-delete" {
				t.Errorf("expected name 'sessions/to-delete', got %q", req.Name)
			}
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_session",
		Arguments: json.RawMessage(`{"name": "sessions/to-delete"}`),
	}

	result, err := server.handleDeleteSession(call)

	if err != nil {
		t.Fatalf("handleDeleteSession returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Deleted session") {
		t.Errorf("result text does not contain 'Deleted session': %s", text)
	}
}

func TestHandleDeleteSession_WithForce(t *testing.T) {
	mockClient := &mockSessionClient{
		deleteSessionFunc: func(ctx context.Context, req *pb.DeleteSessionRequest) (*emptypb.Empty, error) {
			if !req.Force {
				t.Error("expected force = true")
			}
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_session",
		Arguments: json.RawMessage(`{"name": "sessions/123", "force": true}`),
	}

	result, err := server.handleDeleteSession(call)

	if err != nil {
		t.Fatalf("handleDeleteSession returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleDeleteSession_MissingName(t *testing.T) {
	mockClient := &mockSessionClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_session",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleDeleteSession(call)

	if err != nil {
		t.Fatalf("handleDeleteSession returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleDeleteSession_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		deleteSessionFunc: func(ctx context.Context, req *pb.DeleteSessionRequest) (*emptypb.Empty, error) {
			return nil, errors.New("permission denied")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_session",
		Arguments: json.RawMessage(`{"name": "sessions/123"}`),
	}

	result, err := server.handleDeleteSession(call)

	if err != nil {
		t.Fatalf("handleDeleteSession returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to delete session") {
		t.Errorf("error text does not contain 'Failed to delete session': %s", text)
	}
}

// ============================================================================
// handleCreateMacro Tests
// ============================================================================

func TestHandleCreateMacro_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			if req.Macro.DisplayName != "Test Macro" {
				t.Errorf("expected display_name 'Test Macro', got %q", req.Macro.DisplayName)
			}
			return &pb.Macro{
				Name:        "macros/test-macro",
				DisplayName: "Test Macro",
				Description: "A test macro",
				CreateTime:  timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_macro",
		Arguments: json.RawMessage(`{"display_name": "Test Macro", "description": "A test macro"}`),
	}

	result, err := server.handleCreateMacro(call)

	if err != nil {
		t.Fatalf("handleCreateMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "macros/test-macro") {
		t.Errorf("result text does not contain macro name: %s", text)
	}
}

func TestHandleCreateMacro_WithTags(t *testing.T) {
	mockClient := &mockSessionClient{
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			if len(req.Macro.Tags) != 2 {
				t.Errorf("expected 2 tags, got %d", len(req.Macro.Tags))
			}
			return &pb.Macro{
				Name:       "macros/123",
				Tags:       req.Macro.Tags,
				CreateTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_macro",
		Arguments: json.RawMessage(`{"display_name": "Tagged Macro", "tags": ["automation", "test"]}`),
	}

	result, err := server.handleCreateMacro(call)

	if err != nil {
		t.Fatalf("handleCreateMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCreateMacro_MissingDisplayName(t *testing.T) {
	mockClient := &mockSessionClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_macro",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleCreateMacro(call)

	if err != nil {
		t.Fatalf("handleCreateMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing display_name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "display_name parameter is required") {
		t.Errorf("error text does not contain 'display_name parameter is required': %s", text)
	}
}

func TestHandleCreateMacro_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			return nil, errors.New("macro already exists")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_macro",
		Arguments: json.RawMessage(`{"display_name": "Duplicate"}`),
	}

	result, err := server.handleCreateMacro(call)

	if err != nil {
		t.Fatalf("handleCreateMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to create macro") {
		t.Errorf("error text does not contain 'Failed to create macro': %s", text)
	}
}

// ============================================================================
// handleGetMacro Tests
// ============================================================================

func TestHandleGetMacro_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		getMacroFunc: func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error) {
			if req.Name != "macros/test" {
				t.Errorf("expected name 'macros/test', got %q", req.Name)
			}
			return &pb.Macro{
				Name:           "macros/test",
				DisplayName:    "Test Macro",
				Description:    "Description",
				Tags:           []string{"tag1"},
				ExecutionCount: 42,
				Actions: []*pb.MacroAction{
					{Description: "Click button"},
					{Description: "Type text"},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_macro",
		Arguments: json.RawMessage(`{"name": "macros/test"}`),
	}

	result, err := server.handleGetMacro(call)

	if err != nil {
		t.Fatalf("handleGetMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "macros/test") {
		t.Errorf("result text does not contain macro name: %s", text)
	}
}

func TestHandleGetMacro_MissingName(t *testing.T) {
	mockClient := &mockSessionClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_macro",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetMacro(call)

	if err != nil {
		t.Fatalf("handleGetMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetMacro_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		getMacroFunc: func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error) {
			return nil, errors.New("macro not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_macro",
		Arguments: json.RawMessage(`{"name": "macros/nonexistent"}`),
	}

	result, err := server.handleGetMacro(call)

	if err != nil {
		t.Fatalf("handleGetMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get macro") {
		t.Errorf("error text does not contain 'Failed to get macro': %s", text)
	}
}

// ============================================================================
// handleListMacros Tests
// ============================================================================

func TestHandleListMacros_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			return &pb.ListMacrosResponse{
				Macros: []*pb.Macro{
					{Name: "macros/1", DisplayName: "Macro 1", ExecutionCount: 10},
					{Name: "macros/2", DisplayName: "Macro 2", ExecutionCount: 5},
				},
				NextPageToken: "next-token",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_macros",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListMacros(call)

	if err != nil {
		t.Fatalf("handleListMacros returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "macros/1") {
		t.Errorf("result text does not contain 'macros/1': %s", text)
	}
}

func TestHandleListMacros_WithPagination(t *testing.T) {
	mockClient := &mockSessionClient{
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			if req.PageSize != 25 {
				t.Errorf("expected page_size 25, got %d", req.PageSize)
			}
			return &pb.ListMacrosResponse{
				Macros: []*pb.Macro{},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_macros",
		Arguments: json.RawMessage(`{"page_size": 25}`),
	}

	result, err := server.handleListMacros(call)

	if err != nil {
		t.Fatalf("handleListMacros returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleListMacros_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			return nil, errors.New("database error")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_macros",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListMacros(call)

	if err != nil {
		t.Fatalf("handleListMacros returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to list macros") {
		t.Errorf("error text does not contain 'Failed to list macros': %s", text)
	}
}

// ============================================================================
// handleExecuteMacro Tests
// ============================================================================

func TestHandleExecuteMacro_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		executeMacroFunc: func(ctx context.Context, req *pb.ExecuteMacroRequest) (*longrunningpb.Operation, error) {
			if req.Macro != "macros/to-run" {
				t.Errorf("expected macro 'macros/to-run', got %q", req.Macro)
			}
			return &longrunningpb.Operation{
				Name: "operations/exec-123",
				Done: false,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "execute_macro",
		Arguments: json.RawMessage(`{"macro": "macros/to-run"}`),
	}

	result, err := server.handleExecuteMacro(call)

	if err != nil {
		t.Fatalf("handleExecuteMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Macro execution started") {
		t.Errorf("result text does not contain 'Macro execution started': %s", text)
	}
}

func TestHandleExecuteMacro_WithParameters(t *testing.T) {
	mockClient := &mockSessionClient{
		executeMacroFunc: func(ctx context.Context, req *pb.ExecuteMacroRequest) (*longrunningpb.Operation, error) {
			if req.ParameterValues["param1"] != "value1" {
				t.Errorf("expected parameter_values[param1] = 'value1', got %q", req.ParameterValues["param1"])
			}
			return &longrunningpb.Operation{
				Name: "operations/123",
				Done: true,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "execute_macro",
		Arguments: json.RawMessage(`{"macro": "macros/test", "parameter_values": {"param1": "value1"}}`),
	}

	result, err := server.handleExecuteMacro(call)

	if err != nil {
		t.Fatalf("handleExecuteMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleExecuteMacro_MissingMacro(t *testing.T) {
	mockClient := &mockSessionClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "execute_macro",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleExecuteMacro(call)

	if err != nil {
		t.Fatalf("handleExecuteMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing macro")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "macro parameter is required") {
		t.Errorf("error text does not contain 'macro parameter is required': %s", text)
	}
}

func TestHandleExecuteMacro_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		executeMacroFunc: func(ctx context.Context, req *pb.ExecuteMacroRequest) (*longrunningpb.Operation, error) {
			return nil, errors.New("execution failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "execute_macro",
		Arguments: json.RawMessage(`{"macro": "macros/test"}`),
	}

	result, err := server.handleExecuteMacro(call)

	if err != nil {
		t.Fatalf("handleExecuteMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to execute macro") {
		t.Errorf("error text does not contain 'Failed to execute macro': %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestSessionHandlers_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "create_session empty args",
			handler:      "create_session",
			args:         `{}`,
			wantIsError:  false,
			wantContains: []string{"sessions/"},
		},
		{
			name:         "get_session missing name",
			handler:      "get_session",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "list_sessions empty",
			handler:      "list_sessions",
			args:         `{}`,
			wantIsError:  false,
			wantContains: []string{"sessions"},
		},
		{
			name:         "delete_session missing name",
			handler:      "delete_session",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "create_macro missing display_name",
			handler:      "create_macro",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"display_name parameter is required"},
		},
		{
			name:         "get_macro missing name",
			handler:      "get_macro",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "execute_macro missing macro",
			handler:      "execute_macro",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"macro parameter is required"},
		},
	}

	mockClient := &mockSessionClient{
		createSessionFunc: func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error) {
			return &pb.Session{Name: "sessions/test", CreateTime: timestamppb.Now(), State: pb.Session_STATE_ACTIVE}, nil
		},
		listSessionsFunc: func(ctx context.Context, req *pb.ListSessionsRequest) (*pb.ListSessionsResponse, error) {
			return &pb.ListSessionsResponse{Sessions: []*pb.Session{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]func(*ToolCall) (*ToolResult, error){
		"create_session": server.handleCreateSession,
		"get_session":    server.handleGetSession,
		"list_sessions":  server.handleListSessions,
		"delete_session": server.handleDeleteSession,
		"create_macro":   server.handleCreateMacro,
		"get_macro":      server.handleGetMacro,
		"execute_macro":  server.handleExecuteMacro,
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

func TestSessionHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockSessionClient{
		createSessionFunc: func(ctx context.Context, req *pb.CreateSessionRequest) (*pb.Session, error) {
			return &pb.Session{Name: "sessions/test", CreateTime: timestamppb.Now(), State: pb.Session_STATE_ACTIVE}, nil
		},
		getSessionFunc: func(ctx context.Context, req *pb.GetSessionRequest) (*pb.Session, error) {
			return &pb.Session{Name: req.Name, CreateTime: timestamppb.Now(), LastAccessTime: timestamppb.Now(), State: pb.Session_STATE_ACTIVE}, nil
		},
		listSessionsFunc: func(ctx context.Context, req *pb.ListSessionsRequest) (*pb.ListSessionsResponse, error) {
			return &pb.ListSessionsResponse{Sessions: []*pb.Session{}}, nil
		},
		deleteSessionFunc: func(ctx context.Context, req *pb.DeleteSessionRequest) (*emptypb.Empty, error) {
			return &emptypb.Empty{}, nil
		},
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			return &pb.Macro{Name: "macros/test", CreateTime: timestamppb.Now()}, nil
		},
		getMacroFunc: func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error) {
			return &pb.Macro{Name: req.Name}, nil
		},
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			return &pb.ListMacrosResponse{Macros: []*pb.Macro{}}, nil
		},
		executeMacroFunc: func(ctx context.Context, req *pb.ExecuteMacroRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{Name: "operations/test", Done: true}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	testCases := []struct {
		handler func(*ToolCall) (*ToolResult, error)
		args    string
	}{
		{server.handleCreateSession, `{}`},
		{server.handleGetSession, `{"name": "sessions/test"}`},
		{server.handleListSessions, `{}`},
		{server.handleDeleteSession, `{"name": "sessions/test"}`},
		{server.handleCreateMacro, `{"display_name": "test"}`},
		{server.handleGetMacro, `{"name": "macros/test"}`},
		{server.handleListMacros, `{}`},
		{server.handleExecuteMacro, `{"macro": "macros/test"}`},
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
// handleGetSessionSnapshot Tests
// ============================================================================

func TestHandleGetSessionSnapshot_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		getSessionSnapshotFunc: func(ctx context.Context, req *pb.GetSessionSnapshotRequest) (*pb.SessionSnapshot, error) {
			return &pb.SessionSnapshot{
				Session:      &pb.Session{Name: "sessions/test"},
				Applications: []string{"applications/1"},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_session_snapshot",
		Arguments: json.RawMessage(`{"name": "sessions/test"}`),
	}

	result, err := server.handleGetSessionSnapshot(call)

	if err != nil {
		t.Fatalf("handleGetSessionSnapshot returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("Expected success, got error: %s", result.Content[0].Text)
	}
}

func TestHandleGetSessionSnapshot_MissingName(t *testing.T) {
	server := newTestMCPServer(&mockSessionClient{})
	call := &ToolCall{
		Name:      "get_session_snapshot",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetSessionSnapshot(call)

	if err != nil {
		t.Fatalf("handleGetSessionSnapshot returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for missing name")
	}
	if !strings.Contains(result.Content[0].Text, "name") {
		t.Errorf("Error should mention 'name', got: %s", result.Content[0].Text)
	}
}

func TestHandleGetSessionSnapshot_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		getSessionSnapshotFunc: func(ctx context.Context, req *pb.GetSessionSnapshotRequest) (*pb.SessionSnapshot, error) {
			return nil, errors.New("connection refused")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_session_snapshot",
		Arguments: json.RawMessage(`{"name": "sessions/test"}`),
	}

	result, err := server.handleGetSessionSnapshot(call)

	if err != nil {
		t.Fatalf("handleGetSessionSnapshot returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for gRPC error")
	}
}

// ============================================================================
// handleBeginTransaction Tests
// ============================================================================

func TestHandleBeginTransaction_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		beginTransactionFunc: func(ctx context.Context, req *pb.BeginTransactionRequest) (*pb.BeginTransactionResponse, error) {
			return &pb.BeginTransactionResponse{
				TransactionId: "tx-123",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "begin_transaction",
		Arguments: json.RawMessage(`{"session": "sessions/test"}`),
	}

	result, err := server.handleBeginTransaction(call)

	if err != nil {
		t.Fatalf("handleBeginTransaction returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("Expected success, got error: %s", result.Content[0].Text)
	}
	if !strings.Contains(result.Content[0].Text, "tx-123") {
		t.Errorf("Expected transaction ID in output, got: %s", result.Content[0].Text)
	}
}

func TestHandleBeginTransaction_MissingSession(t *testing.T) {
	server := newTestMCPServer(&mockSessionClient{})
	call := &ToolCall{
		Name:      "begin_transaction",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleBeginTransaction(call)

	if err != nil {
		t.Fatalf("handleBeginTransaction returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for missing session")
	}
}

func TestHandleBeginTransaction_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		beginTransactionFunc: func(ctx context.Context, req *pb.BeginTransactionRequest) (*pb.BeginTransactionResponse, error) {
			return nil, errors.New("session not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "begin_transaction",
		Arguments: json.RawMessage(`{"session": "sessions/test"}`),
	}

	result, err := server.handleBeginTransaction(call)

	if err != nil {
		t.Fatalf("handleBeginTransaction returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for gRPC error")
	}
}

// ============================================================================
// handleCommitTransaction Tests
// ============================================================================

func TestHandleCommitTransaction_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		commitTransactionFunc: func(ctx context.Context, req *pb.CommitTransactionRequest) (*pb.Transaction, error) {
			return &pb.Transaction{
				TransactionId: "tx-123",
				Session:       "sessions/test",
				State:         pb.Transaction_STATE_COMMITTED,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "commit_transaction",
		Arguments: json.RawMessage(`{"name": "sessions/test", "transaction_id": "tx-123"}`),
	}

	result, err := server.handleCommitTransaction(call)

	if err != nil {
		t.Fatalf("handleCommitTransaction returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("Expected success, got error: %s", result.Content[0].Text)
	}
}

func TestHandleCommitTransaction_MissingName(t *testing.T) {
	server := newTestMCPServer(&mockSessionClient{})
	call := &ToolCall{
		Name:      "commit_transaction",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleCommitTransaction(call)

	if err != nil {
		t.Fatalf("handleCommitTransaction returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for missing name")
	}
}

func TestHandleCommitTransaction_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		commitTransactionFunc: func(ctx context.Context, req *pb.CommitTransactionRequest) (*pb.Transaction, error) {
			return nil, errors.New("transaction not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "commit_transaction",
		Arguments: json.RawMessage(`{"name": "sessions/test", "transaction_id": "tx-123"}`),
	}

	result, err := server.handleCommitTransaction(call)

	if err != nil {
		t.Fatalf("handleCommitTransaction returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for gRPC error")
	}
}

// ============================================================================
// handleRollbackTransaction Tests
// ============================================================================

func TestHandleRollbackTransaction_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		rollbackTransactionFunc: func(ctx context.Context, req *pb.RollbackTransactionRequest) (*pb.Transaction, error) {
			return &pb.Transaction{
				TransactionId: "tx-123",
				Session:       "sessions/test",
				State:         pb.Transaction_STATE_ROLLED_BACK,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "rollback_transaction",
		Arguments: json.RawMessage(`{"name": "sessions/test", "transaction_id": "tx-123"}`),
	}

	result, err := server.handleRollbackTransaction(call)

	if err != nil {
		t.Fatalf("handleRollbackTransaction returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("Expected success, got error: %s", result.Content[0].Text)
	}
}

func TestHandleRollbackTransaction_MissingName(t *testing.T) {
	server := newTestMCPServer(&mockSessionClient{})
	call := &ToolCall{
		Name:      "rollback_transaction",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleRollbackTransaction(call)

	if err != nil {
		t.Fatalf("handleRollbackTransaction returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for missing name")
	}
}

func TestHandleRollbackTransaction_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		rollbackTransactionFunc: func(ctx context.Context, req *pb.RollbackTransactionRequest) (*pb.Transaction, error) {
			return nil, errors.New("transaction already committed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "rollback_transaction",
		Arguments: json.RawMessage(`{"name": "sessions/test", "transaction_id": "tx-123"}`),
	}

	result, err := server.handleRollbackTransaction(call)

	if err != nil {
		t.Fatalf("handleRollbackTransaction returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for gRPC error")
	}
}

// ============================================================================
// handleDeleteMacro Tests
// ============================================================================

func TestHandleDeleteMacro_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		deleteMacroFunc: func(ctx context.Context, req *pb.DeleteMacroRequest) (*emptypb.Empty, error) {
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_macro",
		Arguments: json.RawMessage(`{"name": "macros/test"}`),
	}

	result, err := server.handleDeleteMacro(call)

	if err != nil {
		t.Fatalf("handleDeleteMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("Expected success, got error: %s", result.Content[0].Text)
	}
	if !strings.Contains(result.Content[0].Text, "Deleted") {
		t.Errorf("Expected 'Deleted' in output, got: %s", result.Content[0].Text)
	}
}

func TestHandleDeleteMacro_MissingName(t *testing.T) {
	server := newTestMCPServer(&mockSessionClient{})
	call := &ToolCall{
		Name:      "delete_macro",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleDeleteMacro(call)

	if err != nil {
		t.Fatalf("handleDeleteMacro returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for missing name")
	}
}

func TestHandleDeleteMacro_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		deleteMacroFunc: func(ctx context.Context, req *pb.DeleteMacroRequest) (*emptypb.Empty, error) {
			return nil, errors.New("macro not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "delete_macro",
		Arguments: json.RawMessage(`{"name": "macros/test"}`),
	}

	result, err := server.handleDeleteMacro(call)

	if err != nil {
		t.Fatalf("handleDeleteMacro returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for gRPC error")
	}
}

// ============================================================================
// handleUpdateMacro Tests
// ============================================================================

func TestHandleUpdateMacro_Success(t *testing.T) {
	mockClient := &mockSessionClient{
		updateMacroFunc: func(ctx context.Context, req *pb.UpdateMacroRequest) (*pb.Macro, error) {
			return &pb.Macro{
				Name:        req.Macro.Name,
				DisplayName: "Updated Name",
				UpdateTime:  timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "update_macro",
		Arguments: json.RawMessage(`{"name": "macros/test", "display_name": "Updated Name"}`),
	}

	result, err := server.handleUpdateMacro(call)

	if err != nil {
		t.Fatalf("handleUpdateMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("Expected success, got error: %s", result.Content[0].Text)
	}
}

func TestHandleUpdateMacro_MissingName(t *testing.T) {
	server := newTestMCPServer(&mockSessionClient{})
	call := &ToolCall{
		Name:      "update_macro",
		Arguments: json.RawMessage(`{"display_name": "Test"}`),
	}

	result, err := server.handleUpdateMacro(call)

	if err != nil {
		t.Fatalf("handleUpdateMacro returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for missing name")
	}
}

func TestHandleUpdateMacro_GRPCError(t *testing.T) {
	mockClient := &mockSessionClient{
		updateMacroFunc: func(ctx context.Context, req *pb.UpdateMacroRequest) (*pb.Macro, error) {
			return nil, errors.New("macro not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "update_macro",
		Arguments: json.RawMessage(`{"name": "macros/test", "display_name": "Updated"}`),
	}

	result, err := server.handleUpdateMacro(call)

	if err != nil {
		t.Fatalf("handleUpdateMacro returned error: %v", err)
	}
	if !result.IsError {
		t.Error("Expected error result for gRPC error")
	}
}

// ============================================================================
// Macro Handler Lifecycle Tests (Task 51)
// ============================================================================

func TestHandleListMacros_PageTokenFlow(t *testing.T) {
	callCount := 0
	mockClient := &mockSessionClient{
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			callCount++
			if callCount == 1 {
				// First call - no page token
				if req.PageToken != "" {
					t.Errorf("expected empty page_token on first call, got %q", req.PageToken)
				}
				return &pb.ListMacrosResponse{
					Macros: []*pb.Macro{
						{Name: "macros/1", DisplayName: "Macro 1"},
					},
					NextPageToken: "opaque-token-123",
				}, nil
			}
			// Second call - with page token
			if req.PageToken != "opaque-token-123" {
				t.Errorf("expected page_token 'opaque-token-123', got %q", req.PageToken)
			}
			return &pb.ListMacrosResponse{
				Macros: []*pb.Macro{
					{Name: "macros/2", DisplayName: "Macro 2"},
				},
				NextPageToken: "",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	// First request
	call := &ToolCall{
		Name:      "list_macros",
		Arguments: json.RawMessage(`{"page_size": 1}`),
	}
	result, err := server.handleListMacros(call)
	if err != nil {
		t.Fatalf("first handleListMacros returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("first call IsError = true, want false: %s", result.Content[0].Text)
	}
	if !strings.Contains(result.Content[0].Text, "opaque-token-123") {
		t.Errorf("first result should contain next_page_token: %s", result.Content[0].Text)
	}

	// Second request with page_token
	call = &ToolCall{
		Name:      "list_macros",
		Arguments: json.RawMessage(`{"page_token": "opaque-token-123"}`),
	}
	result, err = server.handleListMacros(call)
	if err != nil {
		t.Fatalf("second handleListMacros returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("second call IsError = true, want false: %s", result.Content[0].Text)
	}

	if callCount != 2 {
		t.Errorf("expected 2 calls to ListMacros, got %d", callCount)
	}
}

func TestHandleCreateMacro_AllFieldsReturned(t *testing.T) {
	createTime := timestamppb.Now()
	mockClient := &mockSessionClient{
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			return &pb.Macro{
				Name:        "macros/full-test",
				DisplayName: req.Macro.DisplayName,
				Description: req.Macro.Description,
				Tags:        req.Macro.Tags,
				CreateTime:  createTime,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_macro",
		Arguments: json.RawMessage(`{"display_name": "Full Test", "description": "A complete macro", "tags": ["tag1", "tag2"]}`),
	}

	result, err := server.handleCreateMacro(call)
	if err != nil {
		t.Fatalf("handleCreateMacro returned error: %v", err)
	}
	if result.IsError {
		t.Fatalf("result.IsError = true: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	// Verify all fields are present in JSON response
	requiredFields := []string{"name", "display_name", "description", "tags", "create_time"}
	for _, field := range requiredFields {
		if !strings.Contains(text, field) {
			t.Errorf("result text missing field %q: %s", field, text)
		}
	}
}

func TestHandleGetMacro_AllFieldsReturned(t *testing.T) {
	mockClient := &mockSessionClient{
		getMacroFunc: func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error) {
			return &pb.Macro{
				Name:           "macros/complete",
				DisplayName:    "Complete Macro",
				Description:    "Full description",
				Tags:           []string{"a", "b"},
				ExecutionCount: 99,
				Actions: []*pb.MacroAction{
					{Description: "Action 1"},
					{Description: "Action 2"},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_macro",
		Arguments: json.RawMessage(`{"name": "macros/complete"}`),
	}

	result, err := server.handleGetMacro(call)
	if err != nil {
		t.Fatalf("handleGetMacro returned error: %v", err)
	}
	if result.IsError {
		t.Fatalf("result.IsError = true: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	// Verify all fields are present
	requiredFields := []string{"name", "display_name", "description", "action_count", "actions", "tags", "execution_count"}
	for _, field := range requiredFields {
		if !strings.Contains(text, field) {
			t.Errorf("result text missing field %q: %s", field, text)
		}
	}
	// Verify action descriptions are included
	if !strings.Contains(text, "Action 1") || !strings.Contains(text, "Action 2") {
		t.Errorf("result should contain action descriptions: %s", text)
	}
}

func TestHandleUpdateMacro_FieldMaskBuilding(t *testing.T) {
	tests := []struct {
		name          string
		args          string
		expectedPaths []string
	}{
		{
			name:          "update display_name only",
			args:          `{"name": "macros/x", "display_name": "New Name"}`,
			expectedPaths: []string{"display_name"},
		},
		{
			name:          "update description only",
			args:          `{"name": "macros/x", "description": "New Desc"}`,
			expectedPaths: []string{"description"},
		},
		{
			name:          "update tags only",
			args:          `{"name": "macros/x", "tags": ["new"]}`,
			expectedPaths: []string{"tags"},
		},
		{
			name:          "update all fields",
			args:          `{"name": "macros/x", "display_name": "N", "description": "D", "tags": ["t"]}`,
			expectedPaths: []string{"display_name", "description", "tags"},
		},
		{
			name:          "update none (only name)",
			args:          `{"name": "macros/x"}`,
			expectedPaths: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var capturedPaths []string
			mockClient := &mockSessionClient{
				updateMacroFunc: func(ctx context.Context, req *pb.UpdateMacroRequest) (*pb.Macro, error) {
					if req.UpdateMask != nil {
						capturedPaths = req.UpdateMask.Paths
					}
					return &pb.Macro{
						Name:       req.Macro.Name,
						UpdateTime: timestamppb.Now(),
					}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "update_macro",
				Arguments: json.RawMessage(tt.args),
			}

			result, err := server.handleUpdateMacro(call)
			if err != nil {
				t.Fatalf("handleUpdateMacro returned error: %v", err)
			}
			if result.IsError {
				t.Fatalf("result.IsError = true: %s", result.Content[0].Text)
			}

			// Check paths match (order-independent)
			if len(capturedPaths) != len(tt.expectedPaths) {
				t.Errorf("expected %d paths, got %d: %v", len(tt.expectedPaths), len(capturedPaths), capturedPaths)
				return
			}
			pathSet := make(map[string]bool)
			for _, p := range capturedPaths {
				pathSet[p] = true
			}
			for _, p := range tt.expectedPaths {
				if !pathSet[p] {
					t.Errorf("expected path %q not found in %v", p, capturedPaths)
				}
			}
		})
	}
}

func TestHandleExecuteMacro_ReturnsLROName(t *testing.T) {
	mockClient := &mockSessionClient{
		executeMacroFunc: func(ctx context.Context, req *pb.ExecuteMacroRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{
				Name: "operations/macro-exec-456",
				Done: false,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "execute_macro",
		Arguments: json.RawMessage(`{"macro": "macros/run-it"}`),
	}

	result, err := server.handleExecuteMacro(call)
	if err != nil {
		t.Fatalf("handleExecuteMacro returned error: %v", err)
	}
	if result.IsError {
		t.Fatalf("result.IsError = true: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "operations/macro-exec-456") {
		t.Errorf("result should contain operation name: %s", text)
	}
	if !strings.Contains(text, "Done: false") {
		t.Errorf("result should contain Done status: %s", text)
	}
}

func TestMacroHandlers_InvalidJSON(t *testing.T) {
	tests := []struct {
		name    string
		handler string
		args    string
	}{
		{"create_macro invalid json", "create_macro", `{invalid`},
		{"get_macro invalid json", "get_macro", `not json`},
		{"list_macros invalid json", "list_macros", `{"page_size": "not a number"}`},
		{"update_macro invalid json", "update_macro", `{"name":`},
		{"delete_macro invalid json", "delete_macro", `{]}`},
		{"execute_macro invalid json", "execute_macro", `{{{`},
	}

	server := newTestMCPServer(&mockSessionClient{})

	handlers := map[string]func(*ToolCall) (*ToolResult, error){
		"create_macro":  server.handleCreateMacro,
		"get_macro":     server.handleGetMacro,
		"list_macros":   server.handleListMacros,
		"update_macro":  server.handleUpdateMacro,
		"delete_macro":  server.handleDeleteMacro,
		"execute_macro": server.handleExecuteMacro,
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler := handlers[tt.handler]
			call := &ToolCall{
				Name:      tt.handler,
				Arguments: json.RawMessage(tt.args),
			}

			result, err := handler(call)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if !result.IsError {
				t.Errorf("expected error for invalid JSON, got success: %s", result.Content[0].Text)
			}
			if !strings.Contains(result.Content[0].Text, "Invalid parameters") && !strings.Contains(result.Content[0].Text, "parameter is required") {
				t.Errorf("expected 'Invalid parameters' in error: %s", result.Content[0].Text)
			}
		})
	}
}

func TestMacroCRUDLifecycle(t *testing.T) {
	// Simulate a full CRUD lifecycle with an in-memory store
	macros := make(map[string]*pb.Macro)
	nextID := 1

	mockClient := &mockSessionClient{
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			id := req.MacroId
			if id == "" {
				id = "auto-" + string(rune('0'+nextID))
				nextID++
			}
			name := "macros/" + id
			macro := &pb.Macro{
				Name:        name,
				DisplayName: req.Macro.DisplayName,
				Description: req.Macro.Description,
				Tags:        req.Macro.Tags,
				CreateTime:  timestamppb.Now(),
			}
			macros[name] = macro
			return macro, nil
		},
		getMacroFunc: func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error) {
			if m, ok := macros[req.Name]; ok {
				return m, nil
			}
			return nil, errors.New("macro not found")
		},
		updateMacroFunc: func(ctx context.Context, req *pb.UpdateMacroRequest) (*pb.Macro, error) {
			m, ok := macros[req.Macro.Name]
			if !ok {
				return nil, errors.New("macro not found")
			}
			// Apply updates based on field mask
			if req.UpdateMask != nil {
				for _, path := range req.UpdateMask.Paths {
					switch path {
					case "display_name":
						m.DisplayName = req.Macro.DisplayName
					case "description":
						m.Description = req.Macro.Description
					case "tags":
						m.Tags = req.Macro.Tags
					}
				}
			}
			m.UpdateTime = timestamppb.Now()
			return m, nil
		},
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			var result []*pb.Macro
			for _, m := range macros {
				result = append(result, m)
			}
			return &pb.ListMacrosResponse{Macros: result}, nil
		},
		deleteMacroFunc: func(ctx context.Context, req *pb.DeleteMacroRequest) (*emptypb.Empty, error) {
			if _, ok := macros[req.Name]; !ok {
				return nil, errors.New("macro not found")
			}
			delete(macros, req.Name)
			return &emptypb.Empty{}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	// Step 1: Create macro
	t.Run("Create", func(t *testing.T) {
		call := &ToolCall{
			Name:      "create_macro",
			Arguments: json.RawMessage(`{"macro_id": "lifecycle-test", "display_name": "Lifecycle Test", "description": "Initial"}`),
		}
		result, err := server.handleCreateMacro(call)
		if err != nil {
			t.Fatalf("Create failed: %v", err)
		}
		if result.IsError {
			t.Fatalf("Create returned error: %s", result.Content[0].Text)
		}
		if !strings.Contains(result.Content[0].Text, "macros/lifecycle-test") {
			t.Errorf("Create result should contain resource name: %s", result.Content[0].Text)
		}
	})

	// Step 2: Get macro
	t.Run("Get", func(t *testing.T) {
		call := &ToolCall{
			Name:      "get_macro",
			Arguments: json.RawMessage(`{"name": "macros/lifecycle-test"}`),
		}
		result, err := server.handleGetMacro(call)
		if err != nil {
			t.Fatalf("Get failed: %v", err)
		}
		if result.IsError {
			t.Fatalf("Get returned error: %s", result.Content[0].Text)
		}
		if !strings.Contains(result.Content[0].Text, "Lifecycle Test") {
			t.Errorf("Get should return display_name: %s", result.Content[0].Text)
		}
	})

	// Step 3: Update macro
	t.Run("Update", func(t *testing.T) {
		call := &ToolCall{
			Name:      "update_macro",
			Arguments: json.RawMessage(`{"name": "macros/lifecycle-test", "display_name": "Updated Lifecycle"}`),
		}
		result, err := server.handleUpdateMacro(call)
		if err != nil {
			t.Fatalf("Update failed: %v", err)
		}
		if result.IsError {
			t.Fatalf("Update returned error: %s", result.Content[0].Text)
		}
	})

	// Step 4: Verify update via Get
	t.Run("VerifyUpdate", func(t *testing.T) {
		call := &ToolCall{
			Name:      "get_macro",
			Arguments: json.RawMessage(`{"name": "macros/lifecycle-test"}`),
		}
		result, err := server.handleGetMacro(call)
		if err != nil {
			t.Fatalf("Get after update failed: %v", err)
		}
		if result.IsError {
			t.Fatalf("Get after update returned error: %s", result.Content[0].Text)
		}
		if !strings.Contains(result.Content[0].Text, "Updated Lifecycle") {
			t.Errorf("Get should reflect updated display_name: %s", result.Content[0].Text)
		}
	})

	// Step 5: List macros
	t.Run("List", func(t *testing.T) {
		call := &ToolCall{
			Name:      "list_macros",
			Arguments: json.RawMessage(`{}`),
		}
		result, err := server.handleListMacros(call)
		if err != nil {
			t.Fatalf("List failed: %v", err)
		}
		if result.IsError {
			t.Fatalf("List returned error: %s", result.Content[0].Text)
		}
		if !strings.Contains(result.Content[0].Text, "macros/lifecycle-test") {
			t.Errorf("List should contain created macro: %s", result.Content[0].Text)
		}
	})

	// Step 6: Delete macro
	t.Run("Delete", func(t *testing.T) {
		call := &ToolCall{
			Name:      "delete_macro",
			Arguments: json.RawMessage(`{"name": "macros/lifecycle-test"}`),
		}
		result, err := server.handleDeleteMacro(call)
		if err != nil {
			t.Fatalf("Delete failed: %v", err)
		}
		if result.IsError {
			t.Fatalf("Delete returned error: %s", result.Content[0].Text)
		}
	})

	// Step 7: Verify deletion
	t.Run("VerifyDeletion", func(t *testing.T) {
		call := &ToolCall{
			Name:      "get_macro",
			Arguments: json.RawMessage(`{"name": "macros/lifecycle-test"}`),
		}
		result, err := server.handleGetMacro(call)
		if err != nil {
			t.Fatalf("Get after delete returned Go error: %v", err)
		}
		if !result.IsError {
			t.Errorf("Get after delete should return error, got: %s", result.Content[0].Text)
		}
		if !strings.Contains(result.Content[0].Text, "not found") {
			t.Errorf("Error should mention 'not found': %s", result.Content[0].Text)
		}
	})
}

func TestMacroHandlers_GetNonExistent(t *testing.T) {
	mockClient := &mockSessionClient{
		getMacroFunc: func(ctx context.Context, req *pb.GetMacroRequest) (*pb.Macro, error) {
			return nil, errors.New("macro not found: " + req.Name)
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_macro",
		Arguments: json.RawMessage(`{"name": "macros/does-not-exist"}`),
	}

	result, err := server.handleGetMacro(call)
	if err != nil {
		t.Fatalf("handleGetMacro returned Go error: %v", err)
	}
	if !result.IsError {
		t.Errorf("expected error for non-existent macro, got success: %s", result.Content[0].Text)
	}
	if !strings.Contains(result.Content[0].Text, "not found") {
		t.Errorf("error should mention 'not found': %s", result.Content[0].Text)
	}
}

func TestHandleListMacros_EmptyResult(t *testing.T) {
	mockClient := &mockSessionClient{
		listMacrosFunc: func(ctx context.Context, req *pb.ListMacrosRequest) (*pb.ListMacrosResponse, error) {
			return &pb.ListMacrosResponse{
				Macros:        []*pb.Macro{},
				NextPageToken: "",
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_macros",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListMacros(call)
	if err != nil {
		t.Fatalf("handleListMacros returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
	// Should return valid JSON with empty macros array
	if !strings.Contains(result.Content[0].Text, `"macros": []`) {
		t.Errorf("expected empty macros array in result: %s", result.Content[0].Text)
	}
}

func TestHandleCreateMacro_WithMacroID(t *testing.T) {
	mockClient := &mockSessionClient{
		createMacroFunc: func(ctx context.Context, req *pb.CreateMacroRequest) (*pb.Macro, error) {
			if req.MacroId != "custom-id" {
				t.Errorf("expected macro_id 'custom-id', got %q", req.MacroId)
			}
			return &pb.Macro{
				Name:       "macros/custom-id",
				CreateTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_macro",
		Arguments: json.RawMessage(`{"macro_id": "custom-id", "display_name": "Custom"}`),
	}

	result, err := server.handleCreateMacro(call)
	if err != nil {
		t.Fatalf("handleCreateMacro returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}
	if !strings.Contains(result.Content[0].Text, "macros/custom-id") {
		t.Errorf("result should contain custom macro ID: %s", result.Content[0].Text)
	}
}
