package server

import (
	"context"
	"encoding/json"
	"math"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
)

// --- M2: cuaHandleMoveWindow — NaN/Infinity rejection ---

func TestCUAHandleMoveWindow_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing window parameter",
			args:       `{"x":100,"y":200}`,
			wantError:  true,
			wantSubstr: "window parameter is required",
		},
		{
			name:       "empty window parameter",
			args:       `{"window":"","x":100,"y":200}`,
			wantError:  true,
			wantSubstr: "window parameter is required",
		},
		{
			name:       "NaN x coordinate",
			args:       `{"window":"applications/1/windows/1","x":"NaN","y":200}`,
			wantError:  true,
			wantSubstr: "Invalid parameters",
		},
		{
			name:       "invalid JSON",
			args:       `{bad`,
			wantError:  true,
			wantSubstr: "Invalid parameters",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			call := &ToolCall{Name: "move_window", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleMoveWindow(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantError && !resultIsError(result) {
				t.Errorf("expected error result, got: %+v", result)
			}
			if tt.wantSubstr != "" && !resultContains(result, tt.wantSubstr) {
				t.Errorf("expected result to contain %q, got: %q", tt.wantSubstr, resultText(result))
			}
		})
	}
}

// TestCUAHandleMoveWindow_NaNInfinityRejection verifies M2 fix:
// NaN and Infinity values for x/y are rejected before the gRPC call.
func TestCUAHandleMoveWindow_NaNInfinityRejection(t *testing.T) {
	tests := []struct {
		name string
		x    float64
		y    float64
		want bool // true = should be rejected
	}{
		{"normal values", 100.0, 200.0, false},
		{"zero values", 0.0, 0.0, false},
		{"negative values", -100.0, -200.0, false},
		{"NaN x", math.NaN(), 200.0, true},
		{"NaN y", 100.0, math.NaN(), true},
		{"NaN both", math.NaN(), math.NaN(), true},
		{"Inf x positive", math.Inf(1), 200.0, true},
		{"Inf x negative", math.Inf(-1), 200.0, true},
		{"Inf y positive", 100.0, math.Inf(1), true},
		{"Inf y negative", 100.0, math.Inf(-1), true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rejected := math.IsNaN(tt.x) || math.IsInf(tt.x, 0) || math.IsNaN(tt.y) || math.IsInf(tt.y, 0)
			if rejected != tt.want {
				t.Errorf("NaN/Inf check for x=%v y=%v = %v, want %v", tt.x, tt.y, rejected, tt.want)
			}
		})
	}
}

// --- cuaHandleListWindows — pagination params accepted ---

func TestCUAHandleListWindows_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "invalid JSON",
			args:       `{bad`,
			wantError:  true,
			wantSubstr: "Invalid parameters",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			call := &ToolCall{Name: "list_windows", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleListWindows(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantError && !resultIsError(result) {
				t.Errorf("expected error result, got: %+v", result)
			}
			if tt.wantSubstr != "" && !resultContains(result, tt.wantSubstr) {
				t.Errorf("expected result to contain %q, got: %q", tt.wantSubstr, resultText(result))
			}
		})
	}
}

func TestCUAHandleListWindowsForwardsCompleteQueryAndValidatesResponse(t *testing.T) {
	var request *pb.ListWindowsRequest
	server := newTestServer()
	server.client = &mockExactMacClient{
		listWindowsFunc: func(_ context.Context, got *pb.ListWindowsRequest) (*pb.ListWindowsResponse, error) {
			request = got
			return &pb.ListWindowsResponse{
				Windows: []*pb.Window{{
					Name:    "applications/app-1/windows/window-1",
					Title:   "Document",
					Bounds:  &pb.Bounds{X: 10.25, Y: -20.5, Width: 640.5, Height: 480.25},
					Visible: true,
					Layer:   7,
				}},
				NextPageToken: "opaque-next",
			}, nil
		},
	}

	result, err := server.cuaHandleListWindows(&ToolCall{
		Name: "list_windows",
		Arguments: json.RawMessage(
			`{"app":"applications/app-1","page_size":10,"page_token":"opaque","filter":"title=\"Document\"","order_by":"layer desc"}`,
		),
	})
	if err != nil || resultIsError(result) {
		t.Fatalf("cuaHandleListWindows() error=%v result=%q", err, resultText(result))
	}
	if request == nil ||
		request.Parent != "applications/app-1" ||
		request.PageSize != 10 ||
		request.PageToken != "opaque" ||
		request.Filter != `title="Document"` ||
		request.OrderBy != "layer desc" {
		t.Fatalf("ListWindows request = %+v", request)
	}
	for _, want := range []string{
		"applications/app-1/windows/window-1",
		"(10.25, -20.5) 640.5x480.25",
		"compositing layer 7",
		"opaque-next",
	} {
		if !resultContains(result, want) {
			t.Fatalf("result %q does not contain %q", resultText(result), want)
		}
	}
}

// --- cuaHandleFocusWindow — window parameter required ---

func TestCUAHandleFocusWindow_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing window parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "window parameter is required",
		},
		{
			name:       "empty window parameter",
			args:       `{"window":""}`,
			wantError:  true,
			wantSubstr: "window parameter is required",
		},
		{
			name:       "invalid JSON",
			args:       `{bad`,
			wantError:  true,
			wantSubstr: "Invalid parameters",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			call := &ToolCall{Name: "focus_window", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleFocusWindow(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantError && !resultIsError(result) {
				t.Errorf("expected error result, got: %+v", result)
			}
			if tt.wantSubstr != "" && !resultContains(result, tt.wantSubstr) {
				t.Errorf("expected result to contain %q, got: %q", tt.wantSubstr, resultText(result))
			}
		})
	}
}

// --- cuaHandleResizeWindow — width/height validation ---

func TestCUAHandleResizeWindow_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing window parameter",
			args:       `{"width":800,"height":600}`,
			wantError:  true,
			wantSubstr: "window parameter is required",
		},
		{
			name:       "zero width",
			args:       `{"window":"applications/1/windows/1","width":0,"height":600}`,
			wantError:  true,
			wantSubstr: "width and height must be positive",
		},
		{
			name:       "zero height",
			args:       `{"window":"applications/1/windows/1","width":800,"height":0}`,
			wantError:  true,
			wantSubstr: "width and height must be positive",
		},
		{
			name:       "negative width",
			args:       `{"window":"applications/1/windows/1","width":-100,"height":600}`,
			wantError:  true,
			wantSubstr: "width and height must be positive",
		},
		{
			name:       "negative height",
			args:       `{"window":"applications/1/windows/1","width":800,"height":-100}`,
			wantError:  true,
			wantSubstr: "width and height must be positive",
		},
		{
			name:       "invalid JSON",
			args:       `{bad`,
			wantError:  true,
			wantSubstr: "Invalid parameters",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			call := &ToolCall{Name: "resize_window", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleResizeWindow(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantError && !resultIsError(result) {
				t.Errorf("expected error result, got: %+v", result)
			}
			if tt.wantSubstr != "" && !resultContains(result, tt.wantSubstr) {
				t.Errorf("expected result to contain %q, got: %q", tt.wantSubstr, resultText(result))
			}
		})
	}
}
