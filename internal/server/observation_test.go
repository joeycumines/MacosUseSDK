// Copyright 2025 Joseph Cumines
//
// Observation handler unit tests

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
	"google.golang.org/protobuf/types/known/timestamppb"
)

// mockObservationClient is a mock implementation of MacosUseClient for observation testing.
type mockObservationClient struct {
	mockMacosUseClient

	// CreateObservation mock
	createObservationFunc func(ctx context.Context, req *pb.CreateObservationRequest) (*longrunningpb.Operation, error)
	// GetObservation mock
	getObservationFunc func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error)
	// ListObservations mock
	listObservationsFunc func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error)
	// CancelObservation mock
	cancelObservationFunc func(ctx context.Context, req *pb.CancelObservationRequest) (*pb.Observation, error)
}

func (m *mockObservationClient) CreateObservation(ctx context.Context, req *pb.CreateObservationRequest, opts ...grpc.CallOption) (*longrunningpb.Operation, error) {
	if m.createObservationFunc != nil {
		return m.createObservationFunc(ctx, req)
	}
	return nil, errors.New("CreateObservation not implemented")
}

func (m *mockObservationClient) GetObservation(ctx context.Context, req *pb.GetObservationRequest, opts ...grpc.CallOption) (*pb.Observation, error) {
	if m.getObservationFunc != nil {
		return m.getObservationFunc(ctx, req)
	}
	return nil, errors.New("GetObservation not implemented")
}

func (m *mockObservationClient) ListObservations(ctx context.Context, req *pb.ListObservationsRequest, opts ...grpc.CallOption) (*pb.ListObservationsResponse, error) {
	if m.listObservationsFunc != nil {
		return m.listObservationsFunc(ctx, req)
	}
	return nil, errors.New("ListObservations not implemented")
}

func (m *mockObservationClient) CancelObservation(ctx context.Context, req *pb.CancelObservationRequest, opts ...grpc.CallOption) (*pb.Observation, error) {
	if m.cancelObservationFunc != nil {
		return m.cancelObservationFunc(ctx, req)
	}
	return nil, errors.New("CancelObservation not implemented")
}

// ============================================================================
// handleCreateObservation Tests
// ============================================================================

func TestHandleCreateObservation_Success(t *testing.T) {
	mockClient := &mockObservationClient{
		createObservationFunc: func(ctx context.Context, req *pb.CreateObservationRequest) (*longrunningpb.Operation, error) {
			if req.Parent != "applications/123" {
				t.Errorf("expected parent 'applications/123', got %q", req.Parent)
			}
			return &longrunningpb.Operation{
				Name: "operations/obs-123",
				Done: false,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_observation",
		Arguments: json.RawMessage(`{"parent": "applications/123"}`),
	}

	result, err := server.handleCreateObservation(call)

	if err != nil {
		t.Fatalf("handleCreateObservation returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "operations/obs-123") {
		t.Errorf("result text does not contain operation name: %s", text)
	}
}

func TestHandleCreateObservation_WithType(t *testing.T) {
	tests := []struct {
		typeStr      string
		expectedType pb.ObservationType
	}{
		{"element_changes", pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES},
		{"element", pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES},
		{"window_changes", pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES},
		{"window", pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES},
		{"application_changes", pb.ObservationType_OBSERVATION_TYPE_APPLICATION_CHANGES},
		{"application", pb.ObservationType_OBSERVATION_TYPE_APPLICATION_CHANGES},
		{"attribute_changes", pb.ObservationType_OBSERVATION_TYPE_ATTRIBUTE_CHANGES},
		{"attribute", pb.ObservationType_OBSERVATION_TYPE_ATTRIBUTE_CHANGES},
		{"tree_changes", pb.ObservationType_OBSERVATION_TYPE_TREE_CHANGES},
		{"tree", pb.ObservationType_OBSERVATION_TYPE_TREE_CHANGES},
	}

	for _, tt := range tests {
		t.Run(tt.typeStr, func(t *testing.T) {
			mockClient := &mockObservationClient{
				createObservationFunc: func(ctx context.Context, req *pb.CreateObservationRequest) (*longrunningpb.Operation, error) {
					if req.Observation.Type != tt.expectedType {
						t.Errorf("expected type %v, got %v", tt.expectedType, req.Observation.Type)
					}
					return &longrunningpb.Operation{Name: "operations/test", Done: false}, nil
				},
			}

			server := newTestMCPServer(mockClient)
			call := &ToolCall{
				Name:      "create_observation",
				Arguments: json.RawMessage(`{"parent": "applications/123", "type": "` + tt.typeStr + `"}`),
			}

			result, err := server.handleCreateObservation(call)

			if err != nil {
				t.Fatalf("handleCreateObservation returned error: %v", err)
			}
			if result.IsError {
				t.Errorf("result.IsError = true, want false")
			}
		})
	}
}

func TestHandleCreateObservation_WithFilter(t *testing.T) {
	mockClient := &mockObservationClient{
		createObservationFunc: func(ctx context.Context, req *pb.CreateObservationRequest) (*longrunningpb.Operation, error) {
			if req.Observation.Filter == nil {
				t.Error("expected filter to be set")
			} else {
				if !req.Observation.Filter.VisibleOnly {
					t.Error("expected visible_only to be true")
				}
				if req.Observation.Filter.PollInterval != 0.5 {
					t.Errorf("expected poll_interval 0.5, got %f", req.Observation.Filter.PollInterval)
				}
			}
			return &longrunningpb.Operation{Name: "operations/test", Done: false}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_observation",
		Arguments: json.RawMessage(`{"parent": "applications/123", "visible_only": true, "poll_interval": 0.5}`),
	}

	result, err := server.handleCreateObservation(call)

	if err != nil {
		t.Fatalf("handleCreateObservation returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleCreateObservation_MissingParent(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_observation",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleCreateObservation(call)

	if err != nil {
		t.Fatalf("handleCreateObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing parent")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "parent parameter is required") {
		t.Errorf("error text does not contain 'parent parameter is required': %s", text)
	}
}

func TestHandleCreateObservation_InvalidJSON(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_observation",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCreateObservation(call)

	if err != nil {
		t.Fatalf("handleCreateObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCreateObservation_GRPCError(t *testing.T) {
	mockClient := &mockObservationClient{
		createObservationFunc: func(ctx context.Context, req *pb.CreateObservationRequest) (*longrunningpb.Operation, error) {
			return nil, errors.New("observation limit exceeded")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "create_observation",
		Arguments: json.RawMessage(`{"parent": "applications/123"}`),
	}

	result, err := server.handleCreateObservation(call)

	if err != nil {
		t.Fatalf("handleCreateObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to create observation") {
		t.Errorf("error text does not contain 'Failed to create observation': %s", text)
	}
}

// ============================================================================
// handleGetObservation Tests
// ============================================================================

func TestHandleGetObservation_Success(t *testing.T) {
	mockClient := &mockObservationClient{
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			if req.Name != "observations/test-123" {
				t.Errorf("expected name 'observations/test-123', got %q", req.Name)
			}
			return &pb.Observation{
				Name:       "observations/test-123",
				Type:       pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
				State:      pb.Observation_STATE_ACTIVE,
				CreateTime: timestamppb.Now(),
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_observation",
		Arguments: json.RawMessage(`{"name": "observations/test-123"}`),
	}

	result, err := server.handleGetObservation(call)

	if err != nil {
		t.Fatalf("handleGetObservation returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "observations/test-123") {
		t.Errorf("result text does not contain observation name: %s", text)
	}
	if !strings.Contains(text, "OBSERVATION_TYPE_ELEMENT_CHANGES") {
		t.Errorf("result text does not contain observation type: %s", text)
	}
}

func TestHandleGetObservation_MissingName(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_observation",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleGetObservation(call)

	if err != nil {
		t.Fatalf("handleGetObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleGetObservation_InvalidJSON(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_observation",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleGetObservation(call)

	if err != nil {
		t.Fatalf("handleGetObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleGetObservation_GRPCError(t *testing.T) {
	mockClient := &mockObservationClient{
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			return nil, errors.New("observation not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "get_observation",
		Arguments: json.RawMessage(`{"name": "observations/nonexistent"}`),
	}

	result, err := server.handleGetObservation(call)

	if err != nil {
		t.Fatalf("handleGetObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get observation") {
		t.Errorf("error text does not contain 'Failed to get observation': %s", text)
	}
}

// ============================================================================
// handleListObservations Tests
// ============================================================================

func TestHandleListObservations_Success(t *testing.T) {
	mockClient := &mockObservationClient{
		listObservationsFunc: func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error) {
			return &pb.ListObservationsResponse{
				Observations: []*pb.Observation{
					{Name: "observations/1", Type: pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES, State: pb.Observation_STATE_ACTIVE},
					{Name: "observations/2", Type: pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES, State: pb.Observation_STATE_COMPLETED},
				},
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_observations",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListObservations(call)

	if err != nil {
		t.Fatalf("handleListObservations returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "observations/1") {
		t.Errorf("result text does not contain 'observations/1': %s", text)
	}
	if !strings.Contains(text, "observations/2") {
		t.Errorf("result text does not contain 'observations/2': %s", text)
	}
}

func TestHandleListObservations_WithParent(t *testing.T) {
	mockClient := &mockObservationClient{
		listObservationsFunc: func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error) {
			if req.Parent != "applications/123" {
				t.Errorf("expected parent 'applications/123', got %q", req.Parent)
			}
			return &pb.ListObservationsResponse{Observations: []*pb.Observation{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_observations",
		Arguments: json.RawMessage(`{"parent": "applications/123"}`),
	}

	result, err := server.handleListObservations(call)

	if err != nil {
		t.Fatalf("handleListObservations returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}
}

func TestHandleListObservations_Empty(t *testing.T) {
	mockClient := &mockObservationClient{
		listObservationsFunc: func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error) {
			return &pb.ListObservationsResponse{Observations: []*pb.Observation{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_observations",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListObservations(call)

	if err != nil {
		t.Fatalf("handleListObservations returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "No observations found") {
		t.Errorf("result text does not contain 'No observations found': %s", text)
	}
}

func TestHandleListObservations_InvalidJSON(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_observations",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleListObservations(call)

	if err != nil {
		t.Fatalf("handleListObservations returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleListObservations_GRPCError(t *testing.T) {
	mockClient := &mockObservationClient{
		listObservationsFunc: func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error) {
			return nil, errors.New("connection failed")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "list_observations",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleListObservations(call)

	if err != nil {
		t.Fatalf("handleListObservations returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to list observations") {
		t.Errorf("error text does not contain 'Failed to list observations': %s", text)
	}
}

// ============================================================================
// handleCancelObservation Tests
// ============================================================================

func TestHandleCancelObservation_Success(t *testing.T) {
	mockClient := &mockObservationClient{
		cancelObservationFunc: func(ctx context.Context, req *pb.CancelObservationRequest) (*pb.Observation, error) {
			if req.Name != "observations/to-cancel" {
				t.Errorf("expected name 'observations/to-cancel', got %q", req.Name)
			}
			return &pb.Observation{
				Name:  "observations/to-cancel",
				State: pb.Observation_STATE_CANCELLED,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "cancel_observation",
		Arguments: json.RawMessage(`{"name": "observations/to-cancel"}`),
	}

	result, err := server.handleCancelObservation(call)

	if err != nil {
		t.Fatalf("handleCancelObservation returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Cancelled observation") {
		t.Errorf("result text does not contain 'Cancelled observation': %s", text)
	}
	if !strings.Contains(text, "STATE_CANCELLED") {
		t.Errorf("result text does not contain 'STATE_CANCELLED': %s", text)
	}
}

func TestHandleCancelObservation_MissingName(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "cancel_observation",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleCancelObservation(call)

	if err != nil {
		t.Fatalf("handleCancelObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleCancelObservation_InvalidJSON(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "cancel_observation",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleCancelObservation(call)

	if err != nil {
		t.Fatalf("handleCancelObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleCancelObservation_GRPCError(t *testing.T) {
	mockClient := &mockObservationClient{
		cancelObservationFunc: func(ctx context.Context, req *pb.CancelObservationRequest) (*pb.Observation, error) {
			return nil, errors.New("observation already cancelled")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "cancel_observation",
		Arguments: json.RawMessage(`{"name": "observations/123"}`),
	}

	result, err := server.handleCancelObservation(call)

	if err != nil {
		t.Fatalf("handleCancelObservation returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to cancel observation") {
		t.Errorf("error text does not contain 'Failed to cancel observation': %s", text)
	}
}

// ============================================================================
// handleStreamObservations Tests
// ============================================================================

func TestHandleStreamObservations_ActiveObservation(t *testing.T) {
	mockClient := &mockObservationClient{
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			return &pb.Observation{
				Name:  req.Name,
				Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
				State: pb.Observation_STATE_ACTIVE,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "stream_observations",
		Arguments: json.RawMessage(`{"name": "observations/active-123"}`),
	}

	result, err := server.handleStreamObservations(call)

	if err != nil {
		t.Fatalf("handleStreamObservations returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "observations/active-123") {
		t.Errorf("result text does not contain observation name: %s", text)
	}
}

func TestHandleStreamObservations_CompletedObservation(t *testing.T) {
	mockClient := &mockObservationClient{
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			return &pb.Observation{
				Name:  req.Name,
				Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
				State: pb.Observation_STATE_COMPLETED,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "stream_observations",
		Arguments: json.RawMessage(`{"name": "observations/completed-123"}`),
	}

	result, err := server.handleStreamObservations(call)

	if err != nil {
		t.Fatalf("handleStreamObservations returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "already") {
		t.Errorf("result text should mention observation is already completed: %s", text)
	}
}

func TestHandleStreamObservations_CancelledObservation(t *testing.T) {
	mockClient := &mockObservationClient{
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			return &pb.Observation{
				Name:  req.Name,
				State: pb.Observation_STATE_CANCELLED,
			}, nil
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "stream_observations",
		Arguments: json.RawMessage(`{"name": "observations/cancelled"}`),
	}

	result, err := server.handleStreamObservations(call)

	if err != nil {
		t.Fatalf("handleStreamObservations returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "STATE_CANCELLED") {
		t.Errorf("result text should contain cancelled state: %s", text)
	}
}

func TestHandleStreamObservations_MissingName(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "stream_observations",
		Arguments: json.RawMessage(`{}`),
	}

	result, err := server.handleStreamObservations(call)

	if err != nil {
		t.Fatalf("handleStreamObservations returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for missing name")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "name parameter is required") {
		t.Errorf("error text does not contain 'name parameter is required': %s", text)
	}
}

func TestHandleStreamObservations_InvalidJSON(t *testing.T) {
	mockClient := &mockObservationClient{}
	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "stream_observations",
		Arguments: json.RawMessage(`{invalid}`),
	}

	result, err := server.handleStreamObservations(call)

	if err != nil {
		t.Fatalf("handleStreamObservations returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for invalid JSON")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Invalid parameters") {
		t.Errorf("error text does not contain 'Invalid parameters': %s", text)
	}
}

func TestHandleStreamObservations_GRPCError(t *testing.T) {
	mockClient := &mockObservationClient{
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			return nil, errors.New("observation not found")
		},
	}

	server := newTestMCPServer(mockClient)
	call := &ToolCall{
		Name:      "stream_observations",
		Arguments: json.RawMessage(`{"name": "observations/nonexistent"}`),
	}

	result, err := server.handleStreamObservations(call)

	if err != nil {
		t.Fatalf("handleStreamObservations returned Go error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Failed to get observation") {
		t.Errorf("error text does not contain 'Failed to get observation': %s", text)
	}
}

// ============================================================================
// Table-Driven Tests
// ============================================================================

func TestObservationHandlers_TableDriven(t *testing.T) {
	tests := []struct {
		name         string
		handler      string
		args         string
		wantIsError  bool
		wantContains []string
	}{
		{
			name:         "create_observation missing parent",
			handler:      "create_observation",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"parent parameter is required"},
		},
		{
			name:         "get_observation missing name",
			handler:      "get_observation",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "cancel_observation missing name",
			handler:      "cancel_observation",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "stream_observations missing name",
			handler:      "stream_observations",
			args:         `{}`,
			wantIsError:  true,
			wantContains: []string{"name parameter is required"},
		},
		{
			name:         "list_observations empty",
			handler:      "list_observations",
			args:         `{}`,
			wantIsError:  false,
			wantContains: []string{"No observations"},
		},
	}

	mockClient := &mockObservationClient{
		listObservationsFunc: func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error) {
			return &pb.ListObservationsResponse{Observations: []*pb.Observation{}}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	handlers := map[string]func(*ToolCall) (*ToolResult, error){
		"create_observation":  server.handleCreateObservation,
		"get_observation":     server.handleGetObservation,
		"list_observations":   server.handleListObservations,
		"cancel_observation":  server.handleCancelObservation,
		"stream_observations": server.handleStreamObservations,
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

func TestObservationHandlers_ContentTypeIsText(t *testing.T) {
	mockClient := &mockObservationClient{
		createObservationFunc: func(ctx context.Context, req *pb.CreateObservationRequest) (*longrunningpb.Operation, error) {
			return &longrunningpb.Operation{Name: "operations/test", Done: false}, nil
		},
		getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
			return &pb.Observation{Name: req.Name, CreateTime: timestamppb.Now(), State: pb.Observation_STATE_ACTIVE}, nil
		},
		listObservationsFunc: func(ctx context.Context, req *pb.ListObservationsRequest) (*pb.ListObservationsResponse, error) {
			return &pb.ListObservationsResponse{Observations: []*pb.Observation{}}, nil
		},
		cancelObservationFunc: func(ctx context.Context, req *pb.CancelObservationRequest) (*pb.Observation, error) {
			return &pb.Observation{Name: req.Name, State: pb.Observation_STATE_CANCELLED}, nil
		},
	}

	server := newTestMCPServer(mockClient)

	testCases := []struct {
		handler func(*ToolCall) (*ToolResult, error)
		args    string
	}{
		{server.handleCreateObservation, `{"parent": "applications/123"}`},
		{server.handleGetObservation, `{"name": "observations/test"}`},
		{server.handleListObservations, `{}`},
		{server.handleCancelObservation, `{"name": "observations/test"}`},
		{server.handleStreamObservations, `{"name": "observations/test"}`},
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
