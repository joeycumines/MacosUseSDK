// Copyright 2025 Joseph Cumines
//
// Tests for the redesigned get_display tool handler (cuaHandleGetDisplay).

package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"google.golang.org/grpc"
)

// mockCUADisplayClient implements only the gRPC methods used by cuaHandleGetDisplay.
// All other methods are promoted from the embedded pb.MacosUseClient interface; they
// will panic at runtime if called, which is acceptable for these focused unit tests.
type mockCUADisplayClient struct {
	pb.MacosUseClient

	listDisplaysFunc          func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error)
	captureCursorPositionFunc func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error)
}

func (m *mockCUADisplayClient) ListDisplays(ctx context.Context, req *pb.ListDisplaysRequest, opts ...grpc.CallOption) (*pb.ListDisplaysResponse, error) {
	if m.listDisplaysFunc != nil {
		return m.listDisplaysFunc(ctx, req)
	}
	return nil, errors.New("ListDisplays not implemented")
}

func (m *mockCUADisplayClient) CaptureCursorPosition(ctx context.Context, req *pb.CaptureCursorPositionRequest, opts ...grpc.CallOption) (*pb.CaptureCursorPositionResponse, error) {
	if m.captureCursorPositionFunc != nil {
		return m.captureCursorPositionFunc(ctx, req)
	}
	return nil, errors.New("CaptureCursorPosition not implemented")
}

func newTestMCPServerWithDisplayClient(client pb.MacosUseClient) *MCPServer {
	return &MCPServer{
		cfg:    &config.Config{RequestTimeout: 30},
		ctx:    context.Background(),
		client: client,
	}
}

func TestCUAHandleGetDisplay_MultipleDisplays(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{
						Name:         "displays/1",
						DisplayId:    1,
						Frame:        &typepb.Region{X: 0, Y: 0, Width: 1920, Height: 1080},
						VisibleFrame: &typepb.Region{X: 0, Y: 25, Width: 1920, Height: 1055},
						IsMain:       true,
						Scale:        2.0,
					},
					{
						Name:         "displays/2",
						DisplayId:    2,
						Frame:        &typepb.Region{X: 1920, Y: 0, Width: 2560, Height: 1440},
						VisibleFrame: &typepb.Region{X: 1920, Y: 0, Width: 2560, Height: 1440},
						IsMain:       false,
						Scale:        1.0,
					},
				},
			}, nil
		},
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return &pb.CaptureCursorPositionResponse{X: 100, Y: 200, Display: "displays/1"}, nil
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if result == nil {
		t.Fatal("cuaHandleGetDisplay returned nil result")
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	wantContains := []string{
		"Displays (2):",
		"Display 1 (main):",
		"Display 2:",
		"scale 2.0",
		"scale 1.0",
		"Cursor position: (100, 200) on displays/1",
	}
	for _, want := range wantContains {
		if !strings.Contains(text, want) {
			t.Errorf("result text missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "Display 2 (main)") {
		t.Errorf("result text incorrectly marks Display 2 as main:\n%s", text)
	}
}

func TestCUAHandleGetDisplay_SingleDisplay(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{
						Name:         "displays/main",
						DisplayId:    42,
						Frame:        &typepb.Region{X: 0, Y: 0, Width: 2560, Height: 1440},
						VisibleFrame: &typepb.Region{X: 0, Y: 25, Width: 2560, Height: 1415},
						IsMain:       true,
						Scale:        2.0,
					},
				},
			}, nil
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	wantContains := []string{"Displays (1):", "Display 42 (main):", "scale 2.0"}
	for _, want := range wantContains {
		if !strings.Contains(text, want) {
			t.Errorf("result text missing %q:\n%s", want, text)
		}
	}
}

func TestCUAHandleGetDisplay_NoDisplays(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{Displays: []*pb.Display{}}, nil
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "Displays (0):") {
		t.Errorf("result text missing 'Displays (0):':\n%s", text)
	}
}

func TestCUAHandleGetDisplay_NegativeCoordinates(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{
						Name:         "displays/2",
						DisplayId:    2,
						Frame:        &typepb.Region{X: -1920, Y: 0, Width: 1920, Height: 1080},
						VisibleFrame: &typepb.Region{X: -1920, Y: 0, Width: 1920, Height: 1080},
						IsMain:       false,
						Scale:        1.0,
					},
				},
			}, nil
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	if !strings.Contains(result.Content[0].Text, "-1920") {
		t.Errorf("result text does not contain negative coordinate '-1920': %s", result.Content[0].Text)
	}
}

func TestCUAHandleGetDisplay_CursorErrorIgnored(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{
				Displays: []*pb.Display{
					{Name: "displays/1", DisplayId: 1, IsMain: true, Scale: 1.0},
				},
			}, nil
		},
		captureCursorPositionFunc: func(ctx context.Context, req *pb.CaptureCursorPositionRequest) (*pb.CaptureCursorPositionResponse, error) {
			return nil, errors.New("accessibility permission denied")
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if result.IsError {
		t.Errorf("result.IsError = true, want false")
	}

	if strings.Contains(result.Content[0].Text, "Cursor position") {
		t.Errorf("cursor error should be silently omitted; got %q", result.Content[0].Text)
	}
}

func TestCUAHandleGetDisplay_ListError(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return nil, errors.New("gRPC connection failed")
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if !result.IsError {
		t.Error("result.IsError = false, want true for gRPC error")
	}

	text := result.Content[0].Text
	if !strings.Contains(text, "get_display") {
		t.Errorf("error text should mention tool name; got %q", text)
	}
}

func TestCUAHandleGetDisplay_ContentTypeIsText(t *testing.T) {
	mockClient := &mockCUADisplayClient{
		listDisplaysFunc: func(ctx context.Context, req *pb.ListDisplaysRequest) (*pb.ListDisplaysResponse, error) {
			return &pb.ListDisplaysResponse{Displays: []*pb.Display{{DisplayId: 1, IsMain: true, Scale: 1.0}}}, nil
		},
	}

	server := newTestMCPServerWithDisplayClient(mockClient)
	result, err := server.cuaHandleGetDisplay(&ToolCall{Name: "get_display", Arguments: json.RawMessage(`{}`)})

	if err != nil {
		t.Fatalf("cuaHandleGetDisplay returned error: %v", err)
	}
	if len(result.Content) != 1 {
		t.Fatalf("len(result.Content) = %d, want 1", len(result.Content))
	}
	if result.Content[0].Type != "text" {
		t.Errorf("content type = %q, want 'text'", result.Content[0].Type)
	}
}
