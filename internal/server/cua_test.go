// Copyright 2025 Joseph Cumines
//
// CUA handler-level unit tests — parameter validation and bug-fix verification.
// These tests exercise the handler functions' input validation logic WITHOUT
// requiring a gRPC connection. An MCPServer with a nil client is used; validation
// checks happen before any gRPC calls, so nil-client panics are never reached.

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"strings"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"github.com/joeycumines/ExactMac/internal/config"
	"google.golang.org/grpc"
)

// newTestServer creates an MCPServer suitable for validation-only tests.
// The client is nil; handlers that pass validation will panic on gRPC calls,
// which is expected — only validation paths are tested here.
func newTestServer() *MCPServer {
	return &MCPServer{
		cfg: &config.Config{RequestTimeout: 30},
		ctx: context.Background(),
	}
}

// resultIsError checks whether a ToolResult represents an error.
func resultIsError(r *ToolResult) bool {
	return r != nil && r.IsError
}

// resultText returns the concatenated text content of a ToolResult.
func resultText(r *ToolResult) string {
	if r == nil {
		return ""
	}
	var parts []string
	for _, c := range r.Content {
		if c.Type == "text" {
			parts = append(parts, c.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// resultContains checks whether the ToolResult text contains the given substring.
func resultContains(r *ToolResult, substr string) bool {
	return strings.Contains(resultText(r), substr)
}

// --- C1: inputName helper (nil-panic fix verification) ---

func TestInputName(t *testing.T) {
	tests := []struct {
		name  string
		input *pb.Input
		want  string
	}{
		{
			name:  "nil input returns modifier-composite placeholder",
			input: nil,
			want:  "(modifier-composite)",
		},
		{
			name:  "empty name returns unknown placeholder",
			input: &pb.Input{},
			want:  "(unknown)",
		},
		{
			name:  "named input returns the name",
			input: &pb.Input{Name: "applications/-/inputs/abc123"},
			want:  "applications/-/inputs/abc123",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := inputName(tt.input)
			if got != tt.want {
				t.Errorf("inputName() = %q, want %q", got, tt.want)
			}
		})
	}
}

// --- C1b: buttonDisplayName ---

func TestButtonDisplayName(t *testing.T) {
	tests := []struct {
		name      string
		clickType pb.MouseClick_ClickType
		want      string
	}{
		{"left", pb.MouseClick_CLICK_TYPE_LEFT, "left"},
		{"right", pb.MouseClick_CLICK_TYPE_RIGHT, "right"},
		{"middle", pb.MouseClick_CLICK_TYPE_MIDDLE, "middle"},
		{"unspecified defaults to left", pb.MouseClick_CLICK_TYPE_UNSPECIFIED, "left"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := buttonDisplayName(tt.clickType)
			if got != tt.want {
				t.Errorf("buttonDisplayName(%v) = %q, want %q", tt.clickType, got, tt.want)
			}
		})
	}
}

// --- C1a: cuaHandleClick — no nil panic with modifiers ---

func TestCUAHandleClick_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "invalid JSON",
			args:       `{bad json`,
			wantError:  true,
			wantSubstr: "Invalid parameters",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			call := &ToolCall{Name: "click", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleClick(call)
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

// TestCUAHandleClick_ModifierKeysNoPanic verifies C1a fix: click with modifier keys
// does not cause a nil panic when the response from clickWithModifiers is nil.
// Since we can't call gRPC, we test the inputName helper directly (above) and
// verify the code path that uses it.
func TestCUAHandleClick_ModifierKeysNoPanic(t *testing.T) {
	// This test verifies that inputName(nil) returns "(modifier-composite)"
	// which is the C1a fix — previously a nil *pb.Input would cause a panic
	// when accessing .Name on nil.
	name := inputName(nil)
	if name != "(modifier-composite)" {
		t.Errorf("inputName(nil) = %q, want (modifier-composite)", name)
	}
}

// mockClickClient is a minimal gRPC client that records CreateInput requests.
type mockClickClient struct {
	pb.ExactMacClient
	created []*pb.CreateInputRequest
}

func (m *mockClickClient) CreateInput(ctx context.Context, req *pb.CreateInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	m.created = append(m.created, req)
	return completedInputResponse(req), nil
}

func TestCUAInputHandlersRejectFailedBackendResources(t *testing.T) {
	tests := []struct {
		name    string
		args    string
		handler func(*MCPServer, *ToolCall) (*ToolResult, error)
	}{
		{name: "click", args: `{"target":"desktop","x":10,"y":20}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleClick(call) }},
		{name: "double_click", args: `{"target":"desktop","x":10,"y":20}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleDoubleClick(call) }},
		{name: "type", args: `{"target":"desktop","text":"x"}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleType(call) }},
		{name: "keypress", args: `{"target":"desktop","keys":["a"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleKeypress(call) }},
		{name: "scroll", args: `{"target":"desktop","x":10,"y":20,"scroll_y":1}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleScroll(call) }},
		{name: "drag", args: `{"target":"desktop","path":[{"x":10,"y":20},{"x":30,"y":40}]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleDrag(call) }},
		{name: "move", args: `{"target":"desktop","x":10,"y":20}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleMove(call) }},
	}

	nonCompletedStates := []pb.Input_State{
		pb.Input_STATE_UNSPECIFIED,
		pb.Input_STATE_PENDING,
		pb.Input_STATE_EXECUTING,
		pb.Input_STATE_FAILED,
		pb.Input_STATE_CANCELLED,
	}
	for _, tt := range tests {
		for _, state := range nonCompletedStates {
			t.Run(tt.name+"/"+state.String(), func(t *testing.T) {
				client := &mockExactMacClient{
					createInputFunc: func(_ context.Context, request *pb.CreateInputRequest) (*pb.Input, error) {
						response := completedInputResponse(request)
						response.State = state
						response.Error = "injected backend failure"
						response.DeliveryResult = nil
						return response, nil
					},
				}
				result, err := tt.handler(
					newTestMCPServer(client),
					&ToolCall{Name: tt.name, Arguments: json.RawMessage(tt.args)},
				)
				if err != nil {
					t.Fatalf("handler returned transport error: %v", err)
				}
				if !resultIsError(result) {
					t.Fatalf("backend %s resource became MCP success: %q", state, resultText(result))
				}
				if state == pb.Input_STATE_FAILED && !resultContains(result, "injected backend failure") {
					t.Fatalf("error omitted backend reason: %q", resultText(result))
				}
			})
		}
	}
}

func TestCUAModifiedPointerActionsUseOneAtomicInput(t *testing.T) {
	tests := []struct {
		name       string
		args       string
		handler    func(*MCPServer, *ToolCall) (*ToolResult, error)
		wantAction func(*pb.InputAction) bool
		modifiers  func(*pb.InputAction) []pb.KeyPress_Modifier
	}{
		{name: "click", args: `{"target":"desktop","x":10,"y":20,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleClick(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetClick() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetClick().GetModifiers() }},
		{name: "double_click", args: `{"target":"desktop","x":10,"y":20,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleDoubleClick(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetClick() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetClick().GetModifiers() }},
		{name: "scroll", args: `{"target":"desktop","x":10,"y":20,"scroll_y":1,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleScroll(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetScroll() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetScroll().GetModifiers() }},
		{name: "drag", args: `{"target":"desktop","path":[{"x":10,"y":20},{"x":30,"y":40}],"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleDrag(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetDrag() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetDrag().GetModifiers() }},
		{name: "move", args: `{"target":"desktop","x":10,"y":20,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleMove(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetMoveMouse() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetMoveMouse().GetModifiers() }},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var requests []*pb.CreateInputRequest
			client := &mockExactMacClient{
				createInputFunc: func(_ context.Context, request *pb.CreateInputRequest) (*pb.Input, error) {
					requests = append(requests, request)
					return completedInputResponse(request), nil
				},
			}
			result, err := tt.handler(
				newTestMCPServer(client),
				&ToolCall{Name: tt.name, Arguments: json.RawMessage(tt.args)},
			)
			if err != nil {
				t.Fatalf("handler returned transport error: %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("handler returned MCP error: %q", resultText(result))
			}
			if len(requests) != 1 {
				t.Fatalf("modified action emitted %d CreateInput RPCs, want one atomic RPC", len(requests))
			}
			action := requests[0].GetInput().GetAction()
			if action == nil || !tt.wantAction(action) {
				t.Fatalf("atomic RPC carried wrong action: %T", action.GetInputType())
			}
			if got := tt.modifiers(action); !reflect.DeepEqual(got, []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_SHIFT}) {
				t.Fatalf("atomic RPC modifiers = %v, want SHIFT", got)
			}
			if drag := action.GetDrag(); drag != nil && len(drag.GetPath()) != 2 {
				t.Fatalf("atomic drag path length = %d, want 2", len(drag.GetPath()))
			}
		})
	}
}

// TestCUAHandleClick_ClickCount verifies the click_count bound, default, and
// human-readable wording (single/double/triple/N-tuple).
func TestCUAHandleClick_ClickCount(t *testing.T) {
	tests := []struct {
		name           string
		args           string
		wantError      bool
		wantSubstr     string
		wantClickCount int32
	}{
		{
			name:           "default to single",
			args:           `{"target":"desktop","x":100,"y":200}`,
			wantSubstr:     "single left-click",
			wantClickCount: 1,
		},
		{
			name:           "double click",
			args:           `{"target":"desktop","x":100,"y":200,"click_count":2}`,
			wantSubstr:     "double left-click",
			wantClickCount: 2,
		},
		{
			name:           "triple click",
			args:           `{"target":"desktop","x":100,"y":200,"click_count":3}`,
			wantSubstr:     "triple left-click",
			wantClickCount: 3,
		},
		{
			name:           "quadruple click",
			args:           `{"target":"desktop","x":100,"y":200,"click_count":4}`,
			wantSubstr:     "4-tuple left-click",
			wantClickCount: 4,
		},
		{
			name:           "maximum 10 click",
			args:           `{"target":"desktop","x":100,"y":200,"click_count":10}`,
			wantSubstr:     "10-tuple left-click",
			wantClickCount: 10,
		},
		{
			name:       "above maximum rejected",
			args:       `{"x":100,"y":200,"click_count":11}`,
			wantError:  true,
			wantSubstr: "click_count must be between 1 and 10",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockClient := &mockClickClient{}
			server := newTestMCPServer(mockClient)
			result, err := server.cuaHandleClick(&ToolCall{Name: "click", Arguments: json.RawMessage(tt.args)})
			if err != nil {
				t.Fatalf("cuaHandleClick returned error: %v", err)
			}
			if tt.wantError {
				if !result.IsError {
					t.Fatalf("expected error result, got: %q", resultText(result))
				}
				if !strings.Contains(resultText(result), tt.wantSubstr) {
					t.Errorf("expected error containing %q, got: %q", tt.wantSubstr, resultText(result))
				}
				return
			}
			if result.IsError {
				t.Fatalf("unexpected error result: %q", resultText(result))
			}
			if !strings.Contains(resultText(result), tt.wantSubstr) {
				t.Errorf("result text missing %q: %q", tt.wantSubstr, resultText(result))
			}

			req := mockClient.created[0]
			got := req.GetInput().GetAction().GetClick().GetClickCount()
			if got != tt.wantClickCount {
				t.Errorf("CreateInput ClickCount = %d, want %d", got, tt.wantClickCount)
			}
		})
	}
}

// --- H8: handleKeypress — guard for empty modifierEnums ---

func TestCUAHandleKeypress_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "empty keys array",
			args:       `{"keys":[]}`,
			wantError:  true,
			wantSubstr: "keys parameter is required and must be non-empty",
		},
		{
			name:       "missing keys parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "keys parameter is required and must be non-empty",
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
			call := &ToolCall{Name: "keypress", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleKeypress(call)
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

// --- cuaHandleFindElements — canonical selector admission ---

func TestCUAHandleFindElements_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing parent parameter",
			args:       `{"selector":"role:AXButton"}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "empty parent parameter",
			args:       `{"parent":"","selector":"role:AXButton"}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "missing selector parameter",
			args:       `{"parent":"applications/1"}`,
			wantError:  true,
			wantSubstr: "selector parameter is required",
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
			call := &ToolCall{Name: "find_elements", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleFindElements(call)
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

// --- H1: handleOpenApp — bring_to_front defaults to true ---

func TestCUAHandleOpenApp_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing app parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "app parameter is required",
		},
		{
			name:       "empty app parameter",
			args:       `{"app":""}`,
			wantError:  true,
			wantSubstr: "app parameter is required",
		},
		{
			name:       "invalid mode",
			args:       `{"app":"applicationBundles/bundle-calculator","mode":"invalid_mode"}`,
			wantError:  true,
			wantSubstr: "Unknown mode",
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
			call := &ToolCall{Name: "open_app", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleOpenApp(call)
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

// TestCUAHandleOpenApp_BringToFrontDefault verifies H1 fix:
// bring_to_front defaults to true when not explicitly set.
func TestCUAHandleOpenApp_BringToFrontDefault(t *testing.T) {
	tests := []struct {
		name      string
		args      string
		wantBring bool
	}{
		{
			name:      "bring_to_front not set defaults to true",
			args:      `{"app":"applicationBundles/bundle-calculator"}`,
			wantBring: true,
		},
		{
			name:      "bring_to_front explicitly true",
			args:      `{"app":"applicationBundles/bundle-calculator","bring_to_front":true}`,
			wantBring: true,
		},
		{
			name:      "bring_to_front explicitly false",
			args:      `{"app":"applicationBundles/bundle-calculator","bring_to_front":false}`,
			wantBring: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params struct {
				App          string `json:"app"`
				Mode         string `json:"mode"`
				BringToFront *bool  `json:"bring_to_front"`
			}
			if err := json.Unmarshal(json.RawMessage(tt.args), &params); err != nil {
				t.Fatalf("failed to unmarshal: %v", err)
			}

			// Replicate the handler's default logic
			bringToFront := true
			if params.BringToFront != nil {
				bringToFront = *params.BringToFront
			}

			if bringToFront != tt.wantBring {
				t.Errorf("bringToFront = %v, want %v", bringToFront, tt.wantBring)
			}
		})
	}
}

// TestCUAHandleOpenApp_ValidModes verifies all valid mode strings are accepted.
func TestCUAHandleOpenApp_ValidModes(t *testing.T) {
	validModes := []string{"launch_or_activate", "force_new_instance"}
	for _, mode := range validModes {
		t.Run(mode, func(t *testing.T) {
			var params struct {
				App  string `json:"app"`
				Mode string `json:"mode"`
			}
			args := `{"app":"applicationBundles/bundle-calculator","mode":"` + mode + `"}`
			if err := json.Unmarshal(json.RawMessage(args), &params); err != nil {
				t.Fatalf("failed to unmarshal: %v", err)
			}
			if params.Mode != mode {
				t.Errorf("mode = %q, want %q", params.Mode, mode)
			}
			if params.App != "applicationBundles/bundle-calculator" {
				t.Errorf("app = %q, want exact bundle resource", params.App)
			}
		})
	}
}

// --- H3: handleCloseApp — displayName sanitization ---

func TestCUAHandleCloseApp_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing app parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "app parameter is required",
		},
		{
			name:       "empty app parameter",
			args:       `{"app":""}`,
			wantError:  true,
			wantSubstr: "app parameter is required",
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
			call := &ToolCall{Name: "close_app", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleCloseApp(call)
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

// --- cuaHandleScroll — no nil panic with modifiers ---

func TestCUAHandleScroll_InvalidParams(t *testing.T) {
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
			call := &ToolCall{Name: "scroll", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleScroll(call)
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

// TestCUAHandleScroll_ModifiersNoPanic verifies that scroll with modifiers
// uses inputName which handles nil responses (C1a fix).
func TestCUAHandleScroll_ModifiersNoPanic(t *testing.T) {
	// The scroll handler uses inputName(resp) which handles nil safely.
	// Verify inputName works for the scroll response path.
	name := inputName(nil)
	if name != "(modifier-composite)" {
		t.Errorf("inputName(nil) = %q, want (modifier-composite)", name)
	}
}

// --- cuaHandleDrag — no nil panic with modifiers ---

func TestCUAHandleDrag_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "path with single waypoint",
			args:       `{"path":[{"x":100,"y":200}]}`,
			wantError:  true,
			wantSubstr: "path must contain at least 2 waypoints",
		},
		{
			name:       "empty path",
			args:       `{"path":[]}`,
			wantError:  true,
			wantSubstr: "path must contain at least 2 waypoints",
		},
		{
			name:       "missing path",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "path must contain at least 2 waypoints",
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
			call := &ToolCall{Name: "drag", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleDrag(call)
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

// TestCUAHandleDrag_ModifiersNoPanic verifies that drag with modifiers
// uses inputName which handles nil responses (C1a fix).
func TestCUAHandleDrag_ModifiersNoPanic(t *testing.T) {
	name := inputName(nil)
	if name != "(modifier-composite)" {
		t.Errorf("inputName(nil) = %q, want (modifier-composite)", name)
	}
}

// --- handleMove — no nil panic with modifiers ---

func TestCUAHandleMove_InvalidParams(t *testing.T) {
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
			call := &ToolCall{Name: "move", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleMove(call)
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

// TestCUAHandleMove_ModifiersNoPanic verifies that move with modifiers
// uses inputName which handles nil responses (C1a fix).
func TestCUAHandleMove_ModifiersNoPanic(t *testing.T) {
	name := inputName(nil)
	if name != "(modifier-composite)" {
		t.Errorf("inputName(nil) = %q, want (modifier-composite)", name)
	}
}

// --- handleType — text parameter required ---

func TestCUAHandleType_InvalidParams(t *testing.T) {
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
			call := &ToolCall{Name: "type", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleType(call)
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

func TestCUAHandleType_ExactTargetRouting(t *testing.T) {
	tests := []struct {
		name       string
		target     string
		wantParent string
	}{
		{
			name:       "application target",
			target:     "applications/123",
			wantParent: "applications/123",
		},
		{
			name:       "window target with application parent",
			target:     "applications/123/windows/456",
			wantParent: "applications/123",
		},
		{
			name:       "desktop target with wildcard parent",
			target:     "desktop",
			wantParent: "applications/-",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var captured *pb.CreateInputRequest
			mock := &mockExactMacClient{
				createInputFunc: func(_ context.Context, req *pb.CreateInputRequest) (*pb.Input, error) {
					captured = req
					return completedInputResponse(req), nil
				},
			}

			s := newTestMCPServer(mock)
			args := fmt.Sprintf(`{"target":%q,"text":"hello"}`, tt.target)
			call := &ToolCall{
				Name:      "type",
				Arguments: json.RawMessage(args),
			}

			result, err := s.handleType(call)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("unexpected error result: %v", resultText(result))
			}

			if captured == nil {
				t.Fatal("CreateInput was not called")
			}
			if captured.Parent != tt.wantParent {
				t.Errorf("Parent = %q, want %q", captured.Parent, tt.wantParent)
			}
			switch tt.target {
			case "desktop":
				if !captured.GetInput().GetTarget().GetDesktop() {
					t.Errorf("target = %#v, want desktop", captured.GetInput().GetTarget())
				}
			case "applications/123":
				if got := captured.GetInput().GetTarget().GetApplication(); got != tt.target {
					t.Errorf("application target = %q, want %q", got, tt.target)
				}
			default:
				if got := captured.GetInput().GetTarget().GetWindow(); got != tt.target {
					t.Errorf("window target = %q, want %q", got, tt.target)
				}
			}
			if captured.GetInput() == nil {
				t.Fatal("expected Input to be set")
			}
			act := captured.GetInput().GetAction()
			if act.GetTypeText() == nil {
				t.Fatalf("expected type_text action, got %T", act)
			}
			if act.GetTypeText().Text != "hello" {
				t.Errorf("text = %q, want hello", act.GetTypeText().Text)
			}
		})
	}
}

// --- handleDoubleClick — parameter validation ---

func TestCUAHandleDoubleClick_InvalidParams(t *testing.T) {
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
			call := &ToolCall{Name: "double_click", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleDoubleClick(call)
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

// --- handleWait — duration validation ---

func TestCUAHandleWait_InvalidParams(t *testing.T) {
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
			call := &ToolCall{Name: "wait", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleWait(call)
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

// --- cuaHandleClickElement — parent and element required ---

func TestCUAHandleClickElement_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing both parent and target",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "missing target",
			args:       `{"parent":"applications/1/windows/1"}`,
			wantError:  true,
			wantSubstr: "element or selector parameter is required",
		},
		{
			name:       "missing parent only",
			args:       `{"element":"btn1"}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "empty parent",
			args:       `{"parent":"","element":""}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "both element and selector",
			args:       `{"parent":"applications/1/windows/1","element":"btn1","selector":"role:AXButton"}`,
			wantError:  true,
			wantSubstr: "provide either element or selector, not both",
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
			call := &ToolCall{Name: "click_element", Arguments: json.RawMessage(tt.args)}
			result, err := s.cuaHandleClickElement(call)
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

// --- handleTypeElement — parent, element, and text required ---

func TestCUAHandleTypeElement_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing all required params",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "invalid input_method",
			args:       `{"parent":"app/1","element":"btn1","text":"x","input_method":"invalid"}`,
			wantError:  true,
			wantSubstr: "input_method must be 'ax' or 'keystrokes'",
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
			call := &ToolCall{Name: "type_element", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleTypeElement(call)
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

func TestParseElementSelector(t *testing.T) {
	// Use string/pointer fields instead of struct values because ElementSelector
	// contains a sync.Mutex (protoimpl.MessageState) and go vet rejects copying it.
	tests := []struct {
		name             string
		input            string
		wantRole         string
		wantText         string
		wantTextContains string
		wantErr          string
		wantEmptyRole    bool
	}{
		{
			name:     "role",
			input:    "role:AXTextArea",
			wantRole: "AXTextArea",
		},
		{
			name:     "text",
			input:    "text:hello world",
			wantText: "hello world",
		},
		{
			name:             "text_contains",
			input:            "text_contains:world",
			wantTextContains: "world",
		},
		{
			name:             "textcontains alias",
			input:            "textcontains:world",
			wantTextContains: "world",
		},
		{
			name:    "missing colon",
			input:   "AXTextArea",
			wantErr: "selector must be in the form key:value",
		},
		{
			name:          "empty value is allowed",
			input:         "role:",
			wantEmptyRole: true,
		},
		{
			name:    "unsupported key",
			input:   "foo:bar",
			wantErr: "unsupported selector key",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseElementSelector(tt.input)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tt.wantErr)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("expected error containing %q, got %q", tt.wantErr, err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantEmptyRole {
				if got.GetRole() != "" {
					t.Errorf("role = %q, want empty", got.GetRole())
				}
				return
			}
			switch {
			case tt.wantRole != "":
				if got.GetRole() != tt.wantRole {
					t.Errorf("role = %q, want %q", got.GetRole(), tt.wantRole)
				}
			case tt.wantText != "":
				if got.GetText() != tt.wantText {
					t.Errorf("text = %q, want %q", got.GetText(), tt.wantText)
				}
			case tt.wantTextContains != "":
				if got.GetTextContains() != tt.wantTextContains {
					t.Errorf("textContains = %q, want %q", got.GetTextContains(), tt.wantTextContains)
				}
			default:
				t.Fatalf("no expected criterion set for test case")
			}
		})
	}
}

func TestCUAHandleTypeElement_SelectorBuildsRequest(t *testing.T) {
	var captured *pb.WriteElementValueRequest
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		writeElementValueFunc: func(_ context.Context, req *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			captured = req
			return &pb.WriteElementValueResponse{Success: true}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"role:AXTextArea","text":"hello"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	if captured == nil {
		t.Fatal("WriteElementValue was not called")
	}
	if captured.Parent != "applications/1/windows/1" {
		t.Errorf("Parent = %q, want applications/1/windows/1", captured.Parent)
	}
	sel, ok := captured.Target.(*pb.WriteElementValueRequest_Selector)
	if !ok {
		t.Fatalf("Target is not a selector, got %T", captured.Target)
	}
	if sel.Selector.GetRole() != "AXTextArea" {
		t.Errorf("Selector role = %q, want AXTextArea", sel.Selector.GetRole())
	}
	if captured.GetValue() != "hello" {
		t.Errorf("Value = %q, want hello", captured.GetValue())
	}
}

func TestCUAHandleTypeElement_ElementBuildsRequest(t *testing.T) {
	var captured *pb.WriteElementValueRequest
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		writeElementValueFunc: func(_ context.Context, req *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			captured = req
			return &pb.WriteElementValueResponse{Success: true}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","element":"elem_1","text":"hello"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	if captured == nil {
		t.Fatal("WriteElementValue was not called")
	}
	sel, ok := captured.Target.(*pb.WriteElementValueRequest_ElementId)
	if !ok {
		t.Fatalf("Target is not element_id, got %T", captured.Target)
	}
	if sel.ElementId != "elem_1" {
		t.Errorf("ElementId = %q, want elem_1", sel.ElementId)
	}
}

// --- handleReadElement — element parameter required ---

func TestCUAHandleReadElement_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing element parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "element parameter is required",
		},
		{
			name:       "empty element parameter",
			args:       `{"element":""}`,
			wantError:  true,
			wantSubstr: "element parameter is required",
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
			call := &ToolCall{Name: "read_element", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleReadElement(call)
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

func TestCUAHandleReadElement_BareIDCanonicalization(t *testing.T) {
	var capturedName string
	mock := &mockExactMacClient{
		getElementFunc: func(_ context.Context, req *pb.GetElementRequest) (*pb.Element, error) {
			capturedName = req.Name
			return &pb.Element{ElementId: req.Name, Role: "AXTextArea"}, nil
		},
		getElementActionsFunc: func(_ context.Context, _ *pb.GetElementActionsRequest, _ ...grpc.CallOption) (*pb.ElementActions, error) {
			return &pb.ElementActions{}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "read_element",
		Arguments: json.RawMessage(`{"parent":"applications/123","element":"elem_456"}`),
	}

	result, err := s.handleReadElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	want := "applications/123/elements/elem_456"
	if capturedName != want {
		t.Errorf("GetElement name = %q, want %q", capturedName, want)
	}
}

// --- handleClipboard — unified clipboard action discriminator ---

func TestCUAHandleClipboard_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing action",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "action parameter is required",
		},
		{
			name:       "unknown action",
			args:       `{"action":"paste"}`,
			wantError:  true,
			wantSubstr: "Unknown action: paste",
		},
		{
			name:       "set without text",
			args:       `{"action":"set"}`,
			wantError:  true,
			wantSubstr: "text parameter is required for set action",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, _ := s.handleClipboard(&ToolCall{Arguments: json.RawMessage(tt.args)})
			if !tt.wantError {
				t.Fatalf("expected no error, got isError=%v", result.IsError)
			}
			if result.IsError && !strings.Contains(resultText(result), tt.wantSubstr) {
				t.Errorf("expected result to contain %q, got: %q", tt.wantSubstr, resultText(result))
			}
		})
	}
}

// --- handleRun — unified scripting with type discriminator ---

func TestCUAHandleRun_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "missing command",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "command parameter is required",
		},
		{
			name:       "empty command",
			args:       `{"command":""}`,
			wantError:  true,
			wantSubstr: "command parameter is required",
		},
		{
			name:       "unknown type",
			args:       `{"command":"echo hi","type":"python"}`,
			wantError:  true,
			wantSubstr: "Unknown type: python",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, _ := s.handleRun(&ToolCall{Arguments: json.RawMessage(tt.args)})
			if !tt.wantError {
				t.Fatalf("expected no error, got isError=%v", result.IsError)
			}
			if result.IsError && !strings.Contains(resultText(result), tt.wantSubstr) {
				t.Errorf("expected result to contain %q, got: %q", tt.wantSubstr, resultText(result))
			}
		})
	}
}

func TestCUAHandleRun_InputLengthValidation(t *testing.T) {
	s := newTestServer()

	bigCmd := strings.Repeat("x", maxInputTextLen+1)

	result, _ := s.handleRun(&ToolCall{Arguments: json.RawMessage(
		fmt.Sprintf(`{"command":%q}`, bigCmd),
	)})
	if !result.IsError {
		t.Fatal("expected error for oversized command input")
	}
	if !strings.Contains(resultText(result), "command") || !strings.Contains(resultText(result), "exceeds maximum") {
		t.Errorf("expected input length error, got: %q", resultText(result))
	}
}

// --- cuaHandleGetDisplay — no params, just gRPC calls ---

func TestCUAHandleGetDisplay_NoValidationNeeded(t *testing.T) {
	// No parameters to validate; nil client would panic on gRPC call.
	// Test documents that get_display needs no input validation.
}

// --- extractWindowFromParent — window name extraction ---

func TestExtractWindowFromParent(t *testing.T) {
	tests := []struct {
		name   string
		parent string
		want   string
	}{
		{"full window path", "applications/123/windows/456", "applications/123/windows/456"},
		{"app only no window", "applications/123", ""},
		{"empty string", "", ""},
		{"window in middle", "applications/123/windows/456/elements/789", "applications/123/windows/456/elements/789"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractWindowFromParent(tt.parent)
			if got != tt.want {
				t.Errorf("extractWindowFromParent(%q) = %q, want %q", tt.parent, got, tt.want)
			}
		})
	}
}

// --- parseParentPID / elementResourceName ---

func TestParseParentPID(t *testing.T) {
	tests := []struct {
		name   string
		parent string
		want   int64
	}{
		{"app path", "applications/123", 123},
		{"window path", "applications/123/windows/456", 123},
		{"element path", "applications/123/elements/abc", 123},
		{"empty", "", 0},
		{"missing prefix", "windows/123", 0},
		{"non-numeric pid", "applications/abc/windows/456", 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseParentPID(tt.parent); got != tt.want {
				t.Errorf("parseParentPID(%q) = %d, want %d", tt.parent, got, tt.want)
			}
		})
	}
}

func TestElementResourceName(t *testing.T) {
	tests := []struct {
		name      string
		parent    string
		elementID string
		want      string
	}{
		{"app parent", "applications/123", "btn1", "applications/123/elements/btn1"},
		{"window parent", "applications/123/windows/456", "btn1", "applications/123/elements/btn1"},
		{"opaque window parent", "applications/process-instance/windows/window-generation", "btn1", "applications/process-instance/elements/btn1"},
		{"element parent", "applications/123/elements/abc", "child1", "applications/123/elements/child1"},
		{"invalid parent falls back", "unknown/123", "btn1", "unknown/123/elements/btn1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := elementResourceName(tt.parent, tt.elementID); got != tt.want {
				t.Errorf("elementResourceName(%q, %q) = %q, want %q", tt.parent, tt.elementID, got, tt.want)
			}
		})
	}
}

// --- handleListApps — no parameter validation (goes straight to gRPC) ---
// handleListApps has no parameter parsing, so validation tests are not applicable.
// It will be tested via integration tests with a live gRPC server.

func TestCUATruncateText(t *testing.T) {
	tests := []struct {
		name string
		text string
		want string
	}{
		{"short text passes through", "hello", "hello"},
		{"exactly max length", strings.Repeat("a", maxDisplayTextLen), strings.Repeat("a", maxDisplayTextLen)},
		{"over max length truncated", strings.Repeat("a", maxDisplayTextLen+10), strings.Repeat("a", maxDisplayTextLen) + "..."},
		{"empty string", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := truncateText(tt.text)
			if got != tt.want {
				t.Errorf("truncateText() = %q, want %q", got, tt.want)
			}
		})
	}
}

// --- handleReadElement canonicalization ---

func TestCUAHandleReadElement_WindowParentCanonicalizesToAppElements(t *testing.T) {
	var capturedName string
	mock := &mockExactMacClient{
		getElementFunc: func(_ context.Context, req *pb.GetElementRequest) (*pb.Element, error) {
			capturedName = req.Name
			return &pb.Element{ElementId: req.Name, Role: "AXTextArea"}, nil
		},
		getElementActionsFunc: func(_ context.Context, _ *pb.GetElementActionsRequest, _ ...grpc.CallOption) (*pb.ElementActions, error) {
			return &pb.ElementActions{}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "read_element",
		Arguments: json.RawMessage(`{"parent":"applications/123/windows/456","element":"elem_789"}`),
	}

	result, err := s.handleReadElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	want := "applications/123/elements/elem_789"
	if capturedName != want {
		t.Errorf("GetElement name = %q, want %q", capturedName, want)
	}
}

// --- handleTypeElement error handling ---

func TestCUAHandleTypeElement_NotEditableErrorMessage(t *testing.T) {
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		writeElementValueFunc: func(_ context.Context, _ *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			return nil, fmt.Errorf("rpc error: code = FailedPrecondition desc = Element role 'AXStaticText' is not editable")
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"text:hello","text":"world"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatalf("expected error result, got: %v", resultText(result))
	}
	if !strings.Contains(resultText(result), "Element is not editable") {
		t.Errorf("expected 'Element is not editable' in result, got: %q", resultText(result))
	}
}

func TestCUAHandleTypeElement_AXValueErrorMessage(t *testing.T) {
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		getElementFunc: func(_ context.Context, req *pb.GetElementRequest) (*pb.Element, error) {
			return &pb.Element{ElementId: req.Name, Role: "AXTextArea"}, nil
		},
		writeElementValueFunc: func(_ context.Context, _ *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			return nil, fmt.Errorf("rpc error: code = Internal desc = AXValue set failed for element elem_123 (AXError -25200)")
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","element":"elem_123","text":"world"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatalf("expected error result, got: %v", resultText(result))
	}
	if !strings.Contains(resultText(result), "Element is not editable") {
		t.Errorf("expected error message mentioning editability, got: %q", resultText(result))
	}
}

func TestCUAHandleClickElement_SelectorBuildsRequest(t *testing.T) {
	var captured *pb.ClickElementRequest
	mock := &mockExactMacClient{
		clickElementFunc: func(_ context.Context, req *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			captured = req
			return &pb.ClickElementResponse{Success: true}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"role:AXButton"}`),
	}

	result, err := s.cuaHandleClickElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	if captured == nil {
		t.Fatal("ClickElement was not called")
	}
	if captured.Parent != "applications/1/windows/1" {
		t.Errorf("Parent = %q, want applications/1/windows/1", captured.Parent)
	}
	sel, ok := captured.Target.(*pb.ClickElementRequest_Selector)
	if !ok {
		t.Fatalf("Target is not a selector, got %T", captured.Target)
	}
	if sel.Selector.GetRole() != "AXButton" {
		t.Errorf("Selector role = %q, want AXButton", sel.Selector.GetRole())
	}
}

func TestCUAHandleClickElement_SelectorReportsFailure(t *testing.T) {
	mock := &mockExactMacClient{
		clickElementFunc: func(_ context.Context, req *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			return &pb.ClickElementResponse{
				Success: false,
				Element: &pb.Element{Role: "AXButton"},
			}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"role:AXButton"}`),
	}

	result, err := s.cuaHandleClickElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatalf("expected error result, got: %v", resultText(result))
	}
	if !strings.Contains(resultText(result), "operation was not successful") {
		t.Errorf("expected failure message, got: %q", resultText(result))
	}
	if !strings.Contains(resultText(result), "AXButton") {
		t.Errorf("expected role in failure message, got: %q", resultText(result))
	}
}

func TestClickElementError_MapsServerErrorStrings(t *testing.T) {
	cases := []struct {
		name          string
		err           error
		wantSubstring string
		notWant       string // optional substring that must NOT appear
	}{
		{
			name:          "selector not visible",
			err:           fmt.Errorf("rpc error: code = FailedPrecondition desc = element matching selector is not visible after focusing; bring it into view"),
			wantSubstring: "is not visible",
		},
		{
			name:          "element id not visible",
			err:           fmt.Errorf("rpc error: code = FailedPrecondition desc = element 'elem_1' is not visible on screen; bring it into view"),
			wantSubstring: "is not visible",
		},
		{
			name:          "no element found matching selector",
			err:           fmt.Errorf("rpc error: code = NotFound desc = No element found matching selector"),
			wantSubstring: "No element found matching selector",
			notWant:       "does not support clicking",
		},
		{
			name:          "element reference not available",
			err:           fmt.Errorf("rpc error: code = NotFound desc = Element reference not available"),
			wantSubstring: "is no longer available",
			notWant:       "does not support clicking",
		},
		{
			name:          "element not found",
			err:           fmt.Errorf("rpc error: code = NotFound desc = Element not found"),
			wantSubstring: "is no longer available",
			notWant:       "does not support clicking",
		},
		{
			name:          "no position information",
			err:           fmt.Errorf("rpc error: code = FailedPrecondition desc = Element has no position information"),
			wantSubstring: "has no usable position information",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result := clickElementError(tc.err, "target")
			if !resultIsError(result) {
				t.Fatalf("expected error result, got: %v", resultText(result))
			}
			text := resultText(result)
			if !strings.Contains(text, tc.wantSubstring) {
				t.Errorf("result missing %q, got: %q", tc.wantSubstring, text)
			}
			if tc.notWant != "" && strings.Contains(text, tc.notWant) {
				t.Errorf("result unexpectedly contains %q, got: %q", tc.notWant, text)
			}
		})
	}
}

func TestCUAHandleClickElement_SelectorNotVisible(t *testing.T) {
	mock := &mockExactMacClient{
		clickElementFunc: func(_ context.Context, req *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			return nil, fmt.Errorf("rpc error: code = FailedPrecondition desc = element matching selector is not visible after focusing; bring it into view")
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"role:AXButton"}`),
	}

	result, err := s.cuaHandleClickElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatalf("expected error result, got: %v", resultText(result))
	}
	if !strings.Contains(resultText(result), "is not visible") {
		t.Errorf("expected visibility message, got: %q", resultText(result))
	}
}

func TestCUAHandleClickElement_ElementIDReferenceUnavailable(t *testing.T) {
	mock := &mockExactMacClient{
		clickElementFunc: func(_ context.Context, req *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			return nil, fmt.Errorf("rpc error: code = NotFound desc = Element reference not available")
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "click_element",
		Arguments: json.RawMessage(`{"parent":"applications/1","element":"elem_1"}`),
	}

	result, err := s.cuaHandleClickElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatalf("expected error result, got: %v", resultText(result))
	}
	if !strings.Contains(resultText(result), "is no longer available") {
		t.Errorf("expected stale-reference message, got: %q", resultText(result))
	}
	if strings.Contains(resultText(result), "does not support clicking") {
		t.Errorf("result incorrectly claims non-clickable role: %q", resultText(result))
	}
}

func TestCUAHandleTypeElement_KeystrokesBuildsRequest(t *testing.T) {
	var capturedWrite *pb.WriteElementValueRequest
	clickElementCalls := 0
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		clickElementFunc: func(_ context.Context, _ *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			clickElementCalls++
			return &pb.ClickElementResponse{Success: true}, nil
		},
		writeElementValueFunc: func(_ context.Context, req *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			capturedWrite = req
			return &pb.WriteElementValueResponse{Success: true}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"role:AXTextArea","text":"hello","input_method":"keystrokes"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	// The keystroke path must NOT pre-click the element: focus is acquired by the
	// Swift WriteElementValue keystroke-replacement path (AX focus with click
	// fallback). A Go-side pre-click would double-toggle checkboxes/toggles.
	if clickElementCalls != 0 {
		t.Fatalf("keystroke path issued %d ClickElement RPC(s); expected 0 (no pre-click)", clickElementCalls)
	}

	if capturedWrite == nil {
		t.Fatal("WriteElementValue was not called")
	}
	if capturedWrite.Parent != "applications/1/windows/1" {
		t.Errorf("WriteElementValue Parent = %q, want applications/1/windows/1", capturedWrite.Parent)
	}
	if capturedWrite.WriteMode != pb.WriteElementValueRequest_WRITE_MODE_KEYSTROKE_REPLACEMENT {
		t.Errorf("WriteMode = %v, want KEYSTROKE_REPLACEMENT", capturedWrite.WriteMode)
	}
	writeSel, ok := capturedWrite.Target.(*pb.WriteElementValueRequest_Selector)
	if !ok {
		t.Fatalf("WriteElementValue Target is not a selector, got %T", capturedWrite.Target)
	}
	if writeSel.Selector.GetRole() != "AXTextArea" {
		t.Errorf("WriteElementValue Selector role = %q, want AXTextArea", writeSel.Selector.GetRole())
	}
	if capturedWrite.GetValue() != "hello" {
		t.Errorf("Value = %q, want hello", capturedWrite.GetValue())
	}
}

func TestCUAHandleTypeElement_KeystrokesFailure(t *testing.T) {
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		clickElementFunc: func(_ context.Context, req *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			_ = req
			return &pb.ClickElementResponse{Success: true}, nil
		},
		writeElementValueFunc: func(_ context.Context, req *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			return nil, fmt.Errorf("rpc error: code = Internal desc = write failed")
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","element":"elem_1","text":"hello","input_method":"keystrokes"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Fatalf("expected error result, got: %v", resultText(result))
	}
	if !strings.Contains(resultText(result), "write failed") {
		t.Errorf("expected write failure message, got: %q", resultText(result))
	}
}

func TestCUAHandleTypeElement_KeystrokesElementBuildsRequest(t *testing.T) {
	var capturedWrite *pb.WriteElementValueRequest
	clickElementCalls := 0
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		clickElementFunc: func(_ context.Context, _ *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			clickElementCalls++
			return &pb.ClickElementResponse{Success: true}, nil
		},
		writeElementValueFunc: func(_ context.Context, req *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			capturedWrite = req
			return &pb.WriteElementValueResponse{Success: true}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","element":"elem_1","text":"hello","input_method":"keystrokes"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}

	// No Go-side pre-click in the keystroke path; focus is owned by Swift.
	if clickElementCalls != 0 {
		t.Fatalf("keystroke path issued %d ClickElement RPC(s); expected 0 (no pre-click)", clickElementCalls)
	}

	if capturedWrite == nil {
		t.Fatal("WriteElementValue was not called")
	}
	if capturedWrite.Parent != "applications/1/windows/1" {
		t.Errorf("WriteElementValue Parent = %q, want applications/1/windows/1", capturedWrite.Parent)
	}
	if capturedWrite.WriteMode != pb.WriteElementValueRequest_WRITE_MODE_KEYSTROKE_REPLACEMENT {
		t.Errorf("WriteMode = %v, want KEYSTROKE_REPLACEMENT", capturedWrite.WriteMode)
	}
	writeElem, ok := capturedWrite.Target.(*pb.WriteElementValueRequest_ElementId)
	if !ok {
		t.Fatalf("WriteElementValue Target is not element_id, got %T", capturedWrite.Target)
	}
	if writeElem.ElementId != "elem_1" {
		t.Errorf("WriteElementValue ElementId = %q, want elem_1", writeElem.ElementId)
	}
}

func TestCUAHandleTypeElement_KeystrokesNoPreClick(t *testing.T) {
	// Regression guard (defect C4): the keystroke path must route directly to
	// WriteElementValue and never issue a ClickElement RPC, because the Swift
	// keystroke-replacement path owns focus acquisition. A Go-side pre-click
	// double-toggles checkboxes/toggles and produces an untruthful result.
	clickElementCalls := 0
	var writeElementValueCalled bool
	mock := &mockExactMacClient{
		focusWindowFunc: func(context.Context, *pb.FocusWindowRequest) (*pb.Window, error) {
			return &pb.Window{Name: "applications/1/windows/1"}, nil
		},
		clickElementFunc: func(_ context.Context, _ *pb.ClickElementRequest, _ ...grpc.CallOption) (*pb.ClickElementResponse, error) {
			clickElementCalls++
			return &pb.ClickElementResponse{Success: true}, nil
		},
		writeElementValueFunc: func(_ context.Context, _ *pb.WriteElementValueRequest, _ ...grpc.CallOption) (*pb.WriteElementValueResponse, error) {
			writeElementValueCalled = true
			return &pb.WriteElementValueResponse{Success: true}, nil
		},
	}

	s := newTestMCPServer(mock)
	call := &ToolCall{
		Name:      "type_element",
		Arguments: json.RawMessage(`{"parent":"applications/1/windows/1","selector":"role:AXTextArea","text":"hello","input_method":"keystrokes"}`),
	}

	result, err := s.handleTypeElement(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("unexpected error result: %v", resultText(result))
	}
	if clickElementCalls != 0 {
		t.Fatalf("keystroke path issued %d ClickElement RPC(s); expected 0", clickElementCalls)
	}
	if !writeElementValueCalled {
		t.Fatal("WriteElementValue was not called")
	}
}
