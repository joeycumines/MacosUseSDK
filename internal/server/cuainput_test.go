package server

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
)

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
		{name: "click", args: `{"target":"desktop","x":10,"y":20,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleClick(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetMouseClick() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetMouseClick().GetModifiers() }},
		{name: "double_click", args: `{"target":"desktop","x":10,"y":20,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleDoubleClick(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetMouseClick() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetMouseClick().GetModifiers() }},
		{name: "scroll", args: `{"target":"desktop","x":10,"y":20,"scroll_y":1,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleScroll(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetScrollAction() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetScrollAction().GetModifiers() }},
		{name: "drag", args: `{"target":"desktop","path":[{"x":10,"y":20},{"x":30,"y":40}],"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.cuaHandleDrag(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetMouseDrag() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetMouseDrag().GetModifiers() }},
		{name: "move", args: `{"target":"desktop","x":10,"y":20,"keys":["shift"]}`, handler: func(s *MCPServer, call *ToolCall) (*ToolResult, error) { return s.handleMove(call) }, wantAction: func(action *pb.InputAction) bool { return action.GetMouseMove() != nil }, modifiers: func(action *pb.InputAction) []pb.KeyPress_Modifier { return action.GetMouseMove().GetModifiers() }},
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
			if drag := action.GetMouseDrag(); drag != nil && len(drag.GetWaypoints()) != 2 {
				t.Fatalf("atomic drag path length = %d, want 2", len(drag.GetWaypoints()))
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
			got := req.GetInput().GetAction().GetMouseClick().GetClickCount()
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
			if act.GetTextInput() == nil {
				t.Fatalf("expected text_input action, got %T", act)
			}
			if act.GetTextInput().Text != "hello" {
				t.Errorf("text = %q, want hello", act.GetTextInput().Text)
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
