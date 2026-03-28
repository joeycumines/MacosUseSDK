// Copyright 2025 Joseph Cumines
//
// Observation handler unit tests

package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	grpcMetadata "google.golang.org/grpc/metadata"
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

// =============================================================================
// SSE Streaming Tests - Added for Task 49
// =============================================================================

// mockHTTPTransport implements the minimal interface needed for testing
// startObservationStream.
type mockHTTPTransport struct {
	events        []mockSSEEvent
	shutdownCh    chan struct{}
	closed        bool
	mu            sync.Mutex
	eventCond     *sync.Cond
	eventWaiter   chan struct{}
	streamStarted chan struct{} // Signals when stream goroutine calls BroadcastEvent or ShutdownChan
}

type mockSSEEvent struct {
	EventType string
	Data      string
}

func newMockHTTPTransport() *mockHTTPTransport {
	m := &mockHTTPTransport{
		shutdownCh:    make(chan struct{}),
		eventWaiter:   make(chan struct{}, 100),
		streamStarted: make(chan struct{}),
	}
	m.eventCond = sync.NewCond(&m.mu)
	return m
}

func (m *mockHTTPTransport) BroadcastEvent(eventType string, data string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.events = append(m.events, mockSSEEvent{EventType: eventType, Data: data})
	m.eventCond.Broadcast()
	// Signal that an event was added
	select {
	case m.eventWaiter <- struct{}{}:
	default:
	}
}

func (m *mockHTTPTransport) ShutdownChan() <-chan struct{} {
	// Signal that the stream has started reading from shutdown channel
	select {
	case m.streamStarted <- struct{}{}:
	default:
	}
	return m.shutdownCh
}

func (m *mockHTTPTransport) IsClosed() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.closed
}

func (m *mockHTTPTransport) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.closed {
		m.closed = true
		close(m.shutdownCh)
	}
}

func (m *mockHTTPTransport) GetEvents() []mockSSEEvent {
	m.mu.Lock()
	defer m.mu.Unlock()
	result := make([]mockSSEEvent, len(m.events))
	copy(result, m.events)
	return result
}

// WaitForEvents waits for at least n events with timeout.
func (m *mockHTTPTransport) WaitForEvents(n int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		m.mu.Lock()
		if len(m.events) >= n {
			m.mu.Unlock()
			return true
		}
		m.mu.Unlock()

		if time.Now().After(deadline) {
			return false
		}

		select {
		case <-m.eventWaiter:
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// WaitForStreamStart waits for the stream goroutine to call ShutdownChan.
func (m *mockHTTPTransport) WaitForStreamStart(timeout time.Duration) bool {
	select {
	case <-m.streamStarted:
		return true
	case <-time.After(timeout):
		return false
	}
}

// mockStreamingClient implements grpc.ServerStreamingClient for testing.
type mockStreamingClient struct {
	responses []*pb.StreamObservationsResponse
	index     int
	err       error
	mu        sync.Mutex
	closeCh   chan struct{}
}

func newMockStreamingClient(responses []*pb.StreamObservationsResponse, err error) *mockStreamingClient {
	return &mockStreamingClient{
		responses: responses,
		err:       err,
		closeCh:   make(chan struct{}),
	}
}

func (m *mockStreamingClient) Recv() (*pb.StreamObservationsResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.index < len(m.responses) {
		resp := m.responses[m.index]
		m.index++
		return resp, nil
	}

	if m.err != nil {
		return nil, m.err
	}

	// Block until closed
	<-m.closeCh
	return nil, io.EOF
}

func (m *mockStreamingClient) Header() (grpcMetadata.MD, error) {
	return nil, nil
}

func (m *mockStreamingClient) Trailer() grpcMetadata.MD {
	return nil
}

func (m *mockStreamingClient) CloseSend() error {
	close(m.closeCh)
	return nil
}

func (m *mockStreamingClient) Context() context.Context {
	return context.Background()
}

func (m *mockStreamingClient) RecvMsg(msg any) error {
	return nil
}

func (m *mockStreamingClient) SendMsg(msg any) error {
	return nil
}

// mockStreamableObservationClient extends mockObservationClient with StreamObservations support.
type mockStreamableObservationClient struct {
	mockObservationClient
	streamObservationsFunc func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error)
}

func (m *mockStreamableObservationClient) StreamObservations(ctx context.Context, req *pb.StreamObservationsRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
	if m.streamObservationsFunc != nil {
		return m.streamObservationsFunc(ctx, req)
	}
	return nil, errors.New("StreamObservations not implemented")
}

// TestStartObservationStream_EventDelivery verifies that events from the gRPC
// stream are broadcast via SSE.
func TestStartObservationStream_EventDelivery(t *testing.T) {
	event := &pb.ObservationEvent{
		Observation: "observations/test",
		EventTime:   timestamppb.Now(),
		Sequence:    1,
	}
	responses := []*pb.StreamObservationsResponse{
		{Event: event},
	}
	streamClient := newMockStreamingClient(responses, io.EOF)

	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return streamClient, nil
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	result, err := server.startObservationStream("observations/test", obs, httpTransport)

	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false: %s", result.Content[0].Text)
	}

	// Wait for events to be broadcast (goroutine-based)
	if !httpTransport.WaitForEvents(2, 500*time.Millisecond) {
		t.Fatal("Timed out waiting for events")
	}

	events := httpTransport.GetEvents()
	// Check that we receive both an observation event and stream_end
	var foundObservation, foundStreamEnd bool
	for _, e := range events {
		if e.EventType == "observation" {
			foundObservation = true
		}
		if e.EventType == "observation_stream_end" {
			foundStreamEnd = true
		}
	}

	if !foundObservation {
		t.Error("Expected 'observation' event to be broadcast")
	}
	if !foundStreamEnd {
		t.Error("Expected 'observation_stream_end' event to be broadcast")
	}
}

// TestStartObservationStream_GRPCError verifies that gRPC errors are broadcast
// as observation_error events.
func TestStartObservationStream_GRPCError(t *testing.T) {
	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return nil, errors.New("connection refused")
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	result, err := server.startObservationStream("observations/test", obs, httpTransport)

	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	// Wait for error event
	if !httpTransport.WaitForEvents(1, 500*time.Millisecond) {
		t.Fatal("Timed out waiting for error event")
	}

	events := httpTransport.GetEvents()
	found := false
	for _, e := range events {
		if e.EventType == "observation_error" {
			found = true
			if !strings.Contains(e.Data, "connection refused") {
				t.Errorf("Error event should contain error message, got: %s", e.Data)
			}
			if !strings.Contains(e.Data, "reconnection_hint") {
				t.Errorf("Error event should contain reconnection hint, got: %s", e.Data)
			}
		}
	}
	if !found {
		t.Error("Expected 'observation_error' event")
	}
}

// TestStartObservationStream_GracefulShutdown verifies that shutdown during
// active streaming broadcasts the shutdown event.
func TestStartObservationStream_GracefulShutdown(t *testing.T) {
	// Create a stream that blocks until closed
	streamClient := newMockStreamingClient(nil, nil)

	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return streamClient, nil
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	_, err := server.startObservationStream("observations/test", obs, httpTransport)
	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}

	// Wait for the goroutine to start (poll instead of time.Sleep)
	if !httpTransport.WaitForStreamStart(500 * time.Millisecond) {
		t.Fatal("Timed out waiting for stream to start")
	}

	// Trigger shutdown
	httpTransport.Close()

	// Wait for shutdown event
	if !httpTransport.WaitForEvents(1, 500*time.Millisecond) {
		t.Fatal("Timed out waiting for shutdown event")
	}

	events := httpTransport.GetEvents()
	found := false
	for _, e := range events {
		if e.EventType == "observation_shutdown" {
			found = true
			if !strings.Contains(e.Data, "server_shutdown") {
				t.Errorf("Shutdown event should indicate reason, got: %s", e.Data)
			}
			if !strings.Contains(e.Data, "reconnection_hint") {
				t.Errorf("Shutdown event should contain reconnection hint, got: %s", e.Data)
			}
		}
	}
	if !found {
		t.Error("Expected 'observation_shutdown' event")
	}
}

// TestStartObservationStream_StreamError verifies that stream Recv errors
// broadcast the stream_end event.
func TestStartObservationStream_StreamError(t *testing.T) {
	// Create a stream that returns an error
	streamClient := newMockStreamingClient(nil, errors.New("stream terminated"))

	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return streamClient, nil
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	_, err := server.startObservationStream("observations/test", obs, httpTransport)
	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}

	// Wait for stream end event
	if !httpTransport.WaitForEvents(1, 500*time.Millisecond) {
		t.Fatal("Timed out waiting for stream end event")
	}

	events := httpTransport.GetEvents()
	found := false
	for _, e := range events {
		if e.EventType == "observation_stream_end" {
			found = true
			if !strings.Contains(e.Data, "stream_ended") {
				t.Errorf("Stream end event should indicate reason, got: %s", e.Data)
			}
		}
	}
	if !found {
		t.Error("Expected 'observation_stream_end' event")
	}
}

// TestStartObservationStream_MultipleEvents verifies that multiple events
// are broadcast correctly.
func TestStartObservationStream_MultipleEvents(t *testing.T) {
	responses := []*pb.StreamObservationsResponse{
		{Event: &pb.ObservationEvent{Observation: "observations/test", Sequence: 1}},
		{Event: &pb.ObservationEvent{Observation: "observations/test", Sequence: 2}},
		{Event: &pb.ObservationEvent{Observation: "observations/test", Sequence: 3}},
	}
	streamClient := newMockStreamingClient(responses, io.EOF)

	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return streamClient, nil
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	_, err := server.startObservationStream("observations/test", obs, httpTransport)
	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}

	// Wait for all events (3 observation events + 1 stream_end)
	if !httpTransport.WaitForEvents(4, 500*time.Millisecond) {
		t.Fatal("Timed out waiting for events")
	}

	events := httpTransport.GetEvents()
	observationCount := 0
	for _, e := range events {
		if e.EventType == "observation" {
			observationCount++
		}
	}

	if observationCount != 3 {
		t.Errorf("Expected 3 observation events, got %d", observationCount)
	}
}

// TestStartObservationStream_ResponseText verifies the response text contains
// expected information.
func TestStartObservationStream_ResponseText(t *testing.T) {
	streamClient := newMockStreamingClient(nil, io.EOF)

	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return streamClient, nil
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/window-test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	result, err := server.startObservationStream("observations/window-test", obs, httpTransport)
	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}

	text := result.Content[0].Text

	// Verify response contains expected information
	expectedContents := []string{
		"observations/window-test",
		"OBSERVATION_TYPE_WINDOW_CHANGES",
		"STATE_ACTIVE",
		"SSE Event Types",
		"observation",
		"Reconnection",
		"Heartbeats",
	}

	for _, expected := range expectedContents {
		if !strings.Contains(text, expected) {
			t.Errorf("Response should contain %q, got:\n%s", expected, text)
		}
	}
}

// TestStartObservationStream_ConnectionTeardownOnCancel verifies that when
// the observation is cancelled (stream returns EOF/error), proper cleanup
// events are broadcast via SSE.
func TestStartObservationStream_ConnectionTeardownOnCancel(t *testing.T) {
	// Create a stream that returns EOF (simulating cancel)
	streamClient := newMockStreamingClient(nil, io.EOF)

	mockClient := &mockStreamableObservationClient{
		mockObservationClient: mockObservationClient{
			getObservationFunc: func(ctx context.Context, req *pb.GetObservationRequest) (*pb.Observation, error) {
				return &pb.Observation{
					Name:  req.Name,
					Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
					State: pb.Observation_STATE_ACTIVE,
				}, nil
			},
		},
		streamObservationsFunc: func(ctx context.Context, req *pb.StreamObservationsRequest) (grpc.ServerStreamingClient[pb.StreamObservationsResponse], error) {
			return streamClient, nil
		},
	}

	server := newTestMCPServer(mockClient)
	httpTransport := newMockHTTPTransport()

	obs := &pb.Observation{
		Name:  "observations/cancel-test",
		Type:  pb.ObservationType_OBSERVATION_TYPE_ELEMENT_CHANGES,
		State: pb.Observation_STATE_ACTIVE,
	}

	result, err := server.startObservationStream("observations/cancel-test", obs, httpTransport)
	if err != nil {
		t.Fatalf("startObservationStream returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	// Wait for teardown event (stream_end when EOF received)
	if !httpTransport.WaitForEvents(1, 500*time.Millisecond) {
		t.Fatal("Timed out waiting for teardown event")
	}

	events := httpTransport.GetEvents()
	found := false
	for _, e := range events {
		if e.EventType == "observation_stream_end" {
			found = true
			// Verify the event contains observation name for client reconnection
			if !strings.Contains(e.Data, "observations/cancel-test") {
				t.Errorf("Stream end event should contain observation name, got: %s", e.Data)
			}
			// Verify reconnection hint is present
			if !strings.Contains(e.Data, "reconnection_hint") {
				t.Errorf("Stream end event should contain reconnection hint, got: %s", e.Data)
			}
		}
	}
	if !found {
		t.Error("Expected 'observation_stream_end' event when stream terminates (connection teardown)")
	}
}
