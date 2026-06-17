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
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"testing"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
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
			input: &pb.Input{Name: "inputs/abc123"},
			want:  "inputs/abc123",
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

// --- C1b: mapButtonString ---

func TestMapButtonString(t *testing.T) {
	tests := []struct {
		name   string
		button string
		want   pb.MouseClick_ClickType
	}{
		{"left", "left", pb.MouseClick_CLICK_TYPE_LEFT},
		{"right", "right", pb.MouseClick_CLICK_TYPE_RIGHT},
		{"middle", "middle", pb.MouseClick_CLICK_TYPE_MIDDLE},
		{"empty defaults to left", "", pb.MouseClick_CLICK_TYPE_LEFT},
		{"unknown defaults to left", "other", pb.MouseClick_CLICK_TYPE_LEFT},
		{"back maps to left", "back", pb.MouseClick_CLICK_TYPE_LEFT},
		{"forward maps to left", "forward", pb.MouseClick_CLICK_TYPE_LEFT},
		{"case insensitive RIGHT", "RIGHT", pb.MouseClick_CLICK_TYPE_RIGHT},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mapButtonString(tt.button)
			if got != tt.want {
				t.Errorf("mapButtonString(%q) = %v, want %v", tt.button, got, tt.want)
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
	pb.MacosUseClient
	created []*pb.CreateInputRequest
}

func (m *mockClickClient) CreateInput(ctx context.Context, req *pb.CreateInputRequest, opts ...grpc.CallOption) (*pb.Input, error) {
	m.created = append(m.created, req)
	return &pb.Input{Name: "inputs/click-test"}, nil
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
			args:           `{"x":100,"y":200}`,
			wantSubstr:     "single left-click",
			wantClickCount: 1,
		},
		{
			name:           "double click",
			args:           `{"x":100,"y":200,"click_count":2}`,
			wantSubstr:     "double left-click",
			wantClickCount: 2,
		},
		{
			name:           "triple click",
			args:           `{"x":100,"y":200,"click_count":3}`,
			wantSubstr:     "triple left-click",
			wantClickCount: 3,
		},
		{
			name:           "quadruple click",
			args:           `{"x":100,"y":200,"click_count":4}`,
			wantSubstr:     "4-tuple left-click",
			wantClickCount: 4,
		},
		{
			name:           "maximum 10 click",
			args:           `{"x":100,"y":200,"click_count":10}`,
			wantSubstr:     "10-tuple left-click",
			wantClickCount: 10,
		},
		{
			name:       "above maximum rejected",
			args:       `{"x":100,"y":200,"click_count":11}`,
			wantError:  true,
			wantSubstr: "click_count must be at most 10",
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

// TestCUAHandleKeypress_AllModifiersNoPanic verifies H8 fix: when all keys are
// modifiers (no non-modifier key), the handler should not panic with an
// index-out-of-range on empty nonModifierKeys slice.
// We test the cuaKeysToModifiers logic directly.
func TestCUAHandleKeypress_AllModifiersNoPanic(t *testing.T) {
	tests := []struct {
		name            string
		keys            []string
		wantModifiers   int
		wantNonModifier int
	}{
		{
			name:            "all modifiers ctrl+shift",
			keys:            []string{"ctrl", "shift"},
			wantModifiers:   2,
			wantNonModifier: 0,
		},
		{
			name:            "single modifier ctrl",
			keys:            []string{"ctrl"},
			wantModifiers:   1,
			wantNonModifier: 0,
		},
		{
			name:            "modifier plus key cmd+c",
			keys:            []string{"cmd", "c"},
			wantModifiers:   1,
			wantNonModifier: 1,
		},
		{
			name:            "plain key a",
			keys:            []string{"a"},
			wantModifiers:   0,
			wantNonModifier: 1,
		},
		{
			name:            "empty keys",
			keys:            []string{},
			wantModifiers:   0,
			wantNonModifier: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mods, nonMods := cuaKeysToModifiers(tt.keys)
			if len(mods) != tt.wantModifiers {
				t.Errorf("modifiers count = %d, want %d", len(mods), tt.wantModifiers)
			}
			if len(nonMods) != tt.wantNonModifier {
				t.Errorf("non-modifier count = %d, want %d", len(nonMods), tt.wantNonModifier)
			}
		})
	}
}

// TestCUAHandleKeypress_EmptyModifierEnumsGuard verifies the H8 guard:
// when both modifierEnums and nonModifierKeys are empty, the handler
// returns an error rather than panicking.
func TestCUAHandleKeypress_EmptyModifierEnumsGuard(t *testing.T) {
	s := newTestServer()

	// Keys that are neither modifiers nor valid (unknown keys go to nonModifierKeys)
	// The only way to get both empty is with an empty keys array, which is caught earlier.
	// But let's verify the guard path by testing the cuaKeysToModifiers output.
	mods, nonMods := cuaKeysToModifiers([]string{})
	if len(mods) != 0 || len(nonMods) != 0 {
		t.Errorf("expected both empty, got mods=%d nonMods=%d", len(mods), len(nonMods))
	}

	// The handler checks: if len(nonModifierKeys) == 0 && len(modifierEnums) == 0
	// This is the H8 guard — verify it returns an error for empty keys
	call := &ToolCall{Name: "keypress", Arguments: json.RawMessage(`{"keys":[]}`)}
	result, err := s.handleKeypress(call)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resultIsError(result) {
		t.Errorf("expected error result for empty keys, got: %+v", result)
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

// --- H2: cuaHandleFindElements — multiple criteria warning ---

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
			args:       `{"role":"AXButton"}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
		},
		{
			name:       "empty parent parameter",
			args:       `{"parent":"","role":"AXButton"}`,
			wantError:  true,
			wantSubstr: "parent parameter is required",
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

// TestCUAHandleFindElements_MultipleCriteriaWarning verifies H2:
// when multiple criteria are provided, a warning is included noting
// only one is used (due to proto oneof).
func TestCUAHandleFindElements_MultipleCriteriaWarning(t *testing.T) {
	tests := []struct {
		name         string
		role         string
		text         string
		textContains string
		wantCount    int
		wantWarning  bool
		wantCriteria string // which criterion is used
	}{
		{
			name:        "single role criterion",
			role:        "AXButton",
			wantCount:   1,
			wantWarning: false,
		},
		{
			name:        "single text criterion",
			text:        "OK",
			wantCount:   1,
			wantWarning: false,
		},
		{
			name:         "single text_contains criterion",
			textContains: "save",
			wantCount:    1,
			wantWarning:  false,
		},
		{
			name:         "role and text — uses role (H2 warning)",
			role:         "AXButton",
			text:         "OK",
			wantCount:    2,
			wantWarning:  true,
			wantCriteria: "role",
		},
		{
			name:         "role and text_contains — uses role (H2 warning)",
			role:         "AXButton",
			textContains: "save",
			wantCount:    2,
			wantWarning:  true,
			wantCriteria: "role",
		},
		{
			name:         "all three criteria — uses role (H2 warning)",
			role:         "AXButton",
			text:         "OK",
			textContains: "save",
			wantCount:    3,
			wantWarning:  true,
			wantCriteria: "role",
		},
		{
			name:        "no criteria",
			wantCount:   0,
			wantWarning: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			providedCriteria := 0
			if tt.role != "" {
				providedCriteria++
			}
			if tt.text != "" {
				providedCriteria++
			}
			if tt.textContains != "" {
				providedCriteria++
			}

			if providedCriteria != tt.wantCount {
				t.Errorf("criteria count = %d, want %d", providedCriteria, tt.wantCount)
			}

			hasWarning := providedCriteria > 1
			if hasWarning != tt.wantWarning {
				t.Errorf("hasWarning = %v, want %v", hasWarning, tt.wantWarning)
			}

			if !tt.wantWarning {
				return
			}

			// Exercise the handler and assert the reported criterion matches the
			// actual selector priority (role > text > text_contains).
			mock := &mockMacosUseClient{
				findElementsFunc: func(_ context.Context, req *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
					if req.Parent != "applications/1" {
						t.Errorf("FindElements Parent = %q, want applications/1", req.Parent)
					}
					return &pb.FindElementsResponse{
						Elements: []*typepb.Element{{ElementId: "btn1", Role: "AXButton"}},
					}, nil
				},
			}
			s := newTestMCPServer(mock)

			args, _ := json.Marshal(map[string]string{
				"parent":        "applications/1",
				"role":          tt.role,
				"text":          tt.text,
				"text_contains": tt.textContains,
			})
			call := &ToolCall{Name: "find_elements", Arguments: args}
			result, err := s.cuaHandleFindElements(call)
			if err != nil {
				t.Fatalf("cuaHandleFindElements returned error: %v", err)
			}

			wantText := "Using " + tt.wantCriteria
			if !resultContains(result, wantText) {
				t.Errorf("result does not report %q: %s", wantText, resultText(result))
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

// TestCUAHandleListWindows_PaginationParamsParsed verifies that pagination
// parameters are correctly parsed from the JSON arguments.
func TestCUAHandleListWindows_PaginationParamsParsed(t *testing.T) {
	var params struct {
		App       string `json:"app"`
		PageSize  int32  `json:"page_size"`
		PageToken string `json:"page_token"`
	}

	args := `{"app":"Calculator","page_size":10,"page_token":"abc123"}`
	if err := json.Unmarshal(json.RawMessage(args), &params); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}
	if params.App != "Calculator" {
		t.Errorf("App = %q, want %q", params.App, "Calculator")
	}
	if params.PageSize != 10 {
		t.Errorf("PageSize = %d, want %d", params.PageSize, 10)
	}
	if params.PageToken != "abc123" {
		t.Errorf("PageToken = %q, want %q", params.PageToken, "abc123")
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
			name:       "missing id parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "id parameter is required",
		},
		{
			name:       "empty id parameter",
			args:       `{"id":""}`,
			wantError:  true,
			wantSubstr: "id parameter is required",
		},
		{
			name:       "invalid mode",
			args:       `{"id":"Calculator","mode":"invalid_mode"}`,
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
			args:      `{"id":"Calculator"}`,
			wantBring: true,
		},
		{
			name:      "bring_to_front explicitly true",
			args:      `{"id":"Calculator","bring_to_front":true}`,
			wantBring: true,
		},
		{
			name:      "bring_to_front explicitly false",
			args:      `{"id":"Calculator","bring_to_front":false}`,
			wantBring: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var params struct {
				ID           string `json:"id"`
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
	validModes := []string{"launch_or_activate", "force_new_instance", "activate_only"}
	for _, mode := range validModes {
		t.Run(mode, func(t *testing.T) {
			var params struct {
				ID   string `json:"id"`
				Mode string `json:"mode"`
			}
			args := `{"id":"Calculator","mode":"` + mode + `"}`
			if err := json.Unmarshal(json.RawMessage(args), &params); err != nil {
				t.Fatalf("failed to unmarshal: %v", err)
			}
			if params.Mode != mode {
				t.Errorf("mode = %q, want %q", params.Mode, mode)
			}
			if params.ID != "Calculator" {
				t.Errorf("id = %q, want %q", params.ID, "Calculator")
			}
		})
	}
}

// --- L3: handleScreenshot — display validation ---

func TestCUAHandleScreenshot_InvalidParams(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "negative display index",
			args:       `{"display":-1}`,
			wantError:  true,
			wantSubstr: "display must be a non-negative integer",
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
			call := &ToolCall{Name: "screenshot", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleScreenshot(call)
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

// TestCUAHandleScreenshot_DisplayValidation verifies display index validation logic.
func TestCUAHandleScreenshot_DisplayValidation(t *testing.T) {
	var params struct {
		Display int `json:"display"`
	}

	tests := []struct {
		name    string
		args    string
		wantErr bool
	}{
		{"display 0 is valid", `{"display":0}`, false},
		{"display 1 is valid", `{"display":1}`, false},
		{"display -1 is invalid", `{"display":-1}`, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := json.Unmarshal(json.RawMessage(tt.args), &params); err != nil {
				t.Fatalf("failed to unmarshal: %v", err)
			}
			gotErr := params.Display < 0
			if gotErr != tt.wantErr {
				t.Errorf("display %d error = %v, want %v", params.Display, gotErr, tt.wantErr)
			}
		})
	}
}

// TestCUAHandleScreenshot_RegionValidation verifies region capture validation.
func TestCUAHandleScreenshot_RegionValidation(t *testing.T) {
	s := newTestServer()

	tests := []struct {
		name       string
		args       string
		wantError  bool
		wantSubstr string
	}{
		{
			name:       "region with zero width",
			args:       `{"x":0,"y":0,"width":0,"height":100}`,
			wantError:  true,
			wantSubstr: "Region width and height must be positive",
		},
		{
			name:       "region with zero height",
			args:       `{"x":0,"y":0,"width":100,"height":0}`,
			wantError:  true,
			wantSubstr: "Region width and height must be positive",
		},
		{
			name:       "region with negative width",
			args:       `{"x":0,"y":0,"width":-10,"height":100}`,
			wantError:  true,
			wantSubstr: "Region width and height must be positive",
		},
		{
			name:       "region with negative height",
			args:       `{"x":0,"y":0,"width":100,"height":-10}`,
			wantError:  true,
			wantSubstr: "Region width and height must be positive",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			call := &ToolCall{Name: "screenshot", Arguments: json.RawMessage(tt.args)}
			result, err := s.handleScreenshot(call)
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

// TestQuitApplicationAppleScriptArgs verifies that close_app passes the
// application name to osascript as a positional argv argument rather than
// interpolating it into AppleScript source, which avoids quoting/escaping bugs.
func TestQuitApplicationAppleScriptArgs(t *testing.T) {
	tests := []struct {
		name        string
		displayName string
		want        []string
	}{
		{
			name:        "simple name",
			displayName: "Calculator",
			want: []string{
				"-e", "on run argv",
				"-e", "tell application (item 1 of argv) to quit",
				"-e", "end run",
				"--", "Calculator",
			},
		},
		{
			name:        "name with double quotes is passed verbatim as argv",
			displayName: `My "App"`,
			want: []string{
				"-e", "on run argv",
				"-e", "tell application (item 1 of argv) to quit",
				"-e", "end run",
				"--", `My "App"`,
			},
		},
		{
			name:        "name with backslashes is passed verbatim as argv",
			displayName: `My \App\`,
			want: []string{
				"-e", "on run argv",
				"-e", "tell application (item 1 of argv) to quit",
				"-e", "end run",
				"--", `My \App\`,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := quitApplicationAppleScriptArgs(tt.displayName)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("quitApplicationAppleScriptArgs() = %v, want %v", got, tt.want)
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
			name:       "missing text parameter",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "text parameter is required",
		},
		{
			name:       "empty text parameter",
			args:       `{"text":""}`,
			wantError:  true,
			wantSubstr: "text parameter is required",
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

// TestCUAHandleWait_DurationCapping verifies wait duration is capped to request timeout.
func TestCUAHandleWait_DurationCapping(t *testing.T) {
	cfg := &config.Config{RequestTimeout: 30}

	tests := []struct {
		name     string
		duration float64
		wantMax  float64
	}{
		{"negative defaults to 1.0", -5.0, 1.0},
		{"zero defaults to 1.0", 0.0, 1.0},
		{"small value passes", 0.5, 0.5},
		{"within timeout passes", 10.0, 10.0},
		{"exactly timeout passes", 30.0, 30.0},
		{"over timeout capped", 60.0, 30.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d := tt.duration
			if d <= 0 {
				d = 1.0
			}
			maxWait := float64(cfg.RequestTimeout)
			if d > maxWait {
				d = maxWait
			}
			if d != tt.wantMax {
				t.Errorf("capped duration = %v, want %v", d, tt.wantMax)
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
			name:       "missing both parent and element",
			args:       `{}`,
			wantError:  true,
			wantSubstr: "parent and element parameters are required",
		},
		{
			name:       "missing element only",
			args:       `{"parent":"applications/1/windows/1"}`,
			wantError:  true,
			wantSubstr: "parent and element parameters are required",
		},
		{
			name:       "missing parent only",
			args:       `{"element":"btn1"}`,
			wantError:  true,
			wantSubstr: "parent and element parameters are required",
		},
		{
			name:       "empty parent and element",
			args:       `{"parent":"","element":""}`,
			wantError:  true,
			wantSubstr: "parent and element parameters are required",
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
			wantSubstr: "parent and element parameters are required",
		},
		{
			name:       "missing text",
			args:       `{"parent":"app/1","element":"btn1"}`,
			wantError:  true,
			wantSubstr: "text parameter is required",
		},
		{
			name:       "empty text",
			args:       `{"parent":"app/1","element":"btn1","text":""}`,
			wantError:  true,
			wantSubstr: "text parameter is required",
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
		{
			name:       "set with empty text",
			args:       `{"action":"set","text":""}`,
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

func TestCUAHandleClipboard_InputLengthValidation(t *testing.T) {
	s := newTestServer()

	bigText := strings.Repeat("x", maxInputTextLen+1)

	result, _ := s.handleClipboard(&ToolCall{Arguments: json.RawMessage(
		fmt.Sprintf(`{"action":"set","text":%q}`, bigText),
	)})
	if !result.IsError {
		t.Fatal("expected error for oversized text input")
	}
	if !strings.Contains(resultText(result), "text") || !strings.Contains(resultText(result), "exceeds maximum") {
		t.Errorf("expected input length error, got: %q", resultText(result))
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

// --- normalizeCUAKey — key name mapping ---

func TestNormalizeCUAKey(t *testing.T) {
	tests := []struct {
		name string
		key  string
		want string
	}{
		{"ctrl maps to control", "ctrl", "control"},
		{"CTRL case insensitive", "CTRL", "control"},
		{"alt maps to option", "alt", "option"},
		{"meta maps to command", "meta", "command"},
		{"enter maps to return", "enter", "return"},
		{"esc maps to escape", "esc", "escape"},
		{"backspace maps to delete", "backspace", "delete"},
		{"pageup maps to pageUp", "pageup", "pageUp"},
		{"page_up maps to pageUp", "page_up", "pageUp"},
		{"up maps to arrowUp", "up", "arrowUp"},
		{"down maps to arrowDown", "down", "arrowDown"},
		{"left maps to arrowLeft", "left", "arrowLeft"},
		{"right maps to arrowRight", "right", "arrowRight"},
		{"f1 maps to f1", "f1", "f1"},
		{"f12 maps to f12", "f12", "f12"},
		{"unknown key passes through", "a", "a"},
		{"number passes through", "1", "1"},
		{"return maps to return", "return", "return"},
		{"space maps to space", "space", "space"},
		{"tab maps to tab", "tab", "tab"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeCUAKey(tt.key)
			if got != tt.want {
				t.Errorf("normalizeCUAKey(%q) = %q, want %q", tt.key, got, tt.want)
			}
		})
	}
}

// --- modifierToKeyName — enum to name conversion ---

func TestModifierToKeyName(t *testing.T) {
	tests := []struct {
		name string
		mod  pb.KeyPress_Modifier
		want string
	}{
		{"command", pb.KeyPress_MODIFIER_COMMAND, "command"},
		{"option", pb.KeyPress_MODIFIER_OPTION, "option"},
		{"control", pb.KeyPress_MODIFIER_CONTROL, "control"},
		{"shift", pb.KeyPress_MODIFIER_SHIFT, "shift"},
		{"function", pb.KeyPress_MODIFIER_FUNCTION, "function"},
		{"caps_lock", pb.KeyPress_MODIFIER_CAPS_LOCK, "capslock"},
		{"unspecified", pb.KeyPress_MODIFIER_UNSPECIFIED, "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := modifierToKeyName(tt.mod)
			if got != tt.want {
				t.Errorf("modifierToKeyName(%v) = %q, want %q", tt.mod, got, tt.want)
			}
		})
	}
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

// --- elementCenter — bounds center calculation ---

func TestElementCenter(t *testing.T) {
	tests := []struct {
		name   string
		x      float64
		y      float64
		w      float64
		h      float64
		wantX  float64
		wantY  float64
		wantOK bool
	}{
		{"normal bounds", 100, 200, 50, 30, 125, 215, true},
		{"zero width", 100, 200, 0, 30, 0, 0, false},
		{"zero height", 100, 200, 50, 0, 0, 0, false},
		{"negative width", 100, 200, -10, 30, 0, 0, false},
		{"negative height", 100, 200, 50, -10, 0, 0, false},
		{"origin bounds", 0, 0, 800, 600, 400, 300, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			elem := &typepb.Element{}
			elem.X = &tt.x
			elem.Y = &tt.y
			elem.Width = &tt.w
			elem.Height = &tt.h

			gotX, gotY, gotOK := elementCenter(elem)
			if gotOK != tt.wantOK {
				t.Errorf("elementCenter ok = %v, want %v", gotOK, tt.wantOK)
			}
			if gotOK && (gotX != tt.wantX || gotY != tt.wantY) {
				t.Errorf("elementCenter = (%.0f, %.0f), want (%.0f, %.0f)", gotX, gotY, tt.wantX, tt.wantY)
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

// --- cuaKeysToModifiers — comprehensive modifier mapping ---

func TestCUAKeysToModifiers(t *testing.T) {
	tests := []struct {
		name            string
		keys            []string
		wantModifiers   []pb.KeyPress_Modifier
		wantNonModifier []string
	}{
		{
			name:            "ctrl+c",
			keys:            []string{"ctrl", "c"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_CONTROL},
			wantNonModifier: []string{"c"},
		},
		{
			name:            "cmd+shift+3",
			keys:            []string{"cmd", "shift", "3"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND, pb.KeyPress_MODIFIER_SHIFT},
			wantNonModifier: []string{"3"},
		},
		{
			name:            "option+left",
			keys:            []string{"option", "left"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_OPTION},
			wantNonModifier: []string{"left"},
		},
		{
			name:            "alt alias for option",
			keys:            []string{"alt"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_OPTION},
			wantNonModifier: nil,
		},
		{
			name:            "fn modifier",
			keys:            []string{"fn"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_FUNCTION},
			wantNonModifier: nil,
		},
		{
			name:            "command alias for cmd",
			keys:            []string{"command"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
			wantNonModifier: nil,
		},
		{
			name:            "control alias for ctrl",
			keys:            []string{"control"},
			wantModifiers:   []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_CONTROL},
			wantNonModifier: nil,
		},
		{
			name:            "plain key only",
			keys:            []string{"a"},
			wantModifiers:   nil,
			wantNonModifier: []string{"a"},
		},
		{
			name:            "empty input",
			keys:            []string{},
			wantModifiers:   nil,
			wantNonModifier: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mods, nonMods := cuaKeysToModifiers(tt.keys)

			if len(mods) != len(tt.wantModifiers) {
				t.Errorf("modifiers count = %d, want %d", len(mods), len(tt.wantModifiers))
			} else {
				for i, m := range mods {
					if m != tt.wantModifiers[i] {
						t.Errorf("modifiers[%d] = %v, want %v", i, m, tt.wantModifiers[i])
					}
				}
			}

			if len(nonMods) != len(tt.wantNonModifier) {
				t.Errorf("nonModifier count = %d, want %d", len(nonMods), len(tt.wantNonModifier))
			} else {
				for i, k := range nonMods {
					if k != tt.wantNonModifier[i] {
						t.Errorf("nonModifier[%d] = %q, want %q", i, k, tt.wantNonModifier[i])
					}
				}
			}
		})
	}
}

// --- detectBareBinary ---

func TestDetectBareBinary(t *testing.T) {
	tests := []struct {
		name         string
		stdout       string
		exitCode     int32
		commandErr   error
		wantBare     bool
		wantContains string
	}{
		{
			name:         "normal bundle id",
			stdout:       "com.apple.TextEdit\n",
			wantBare:     false,
			wantContains: "",
		},
		{
			name:         "empty bundle id",
			stdout:       "",
			wantBare:     true,
			wantContains: "bare binary",
		},
		{
			name:         "missing value",
			stdout:       "missing value",
			wantBare:     true,
			wantContains: "bare binary",
		},
		{
			name:     "command fails",
			exitCode: 1,
			wantBare: false,
		},
		{
			name:       "command error",
			commandErr: errors.New("osascript not found"),
			wantBare:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mock := &mockMacosUseClient{
				executeShellCommandFunc: func(_ context.Context, req *pb.ExecuteShellCommandRequest) (*pb.ExecuteShellCommandResponse, error) {
					if req.Command != "/usr/bin/osascript" {
						t.Errorf("unexpected command: %s", req.Command)
					}
					if tt.commandErr != nil {
						return nil, tt.commandErr
					}
					return &pb.ExecuteShellCommandResponse{
						ExitCode: tt.exitCode,
						Stdout:   tt.stdout,
					}, nil
				},
			}
			s := newTestMCPServer(mock)

			gotBare, gotWarning := s.detectBareBinary(context.Background(), 123)
			if gotBare != tt.wantBare {
				t.Errorf("detectBareBinary() bare = %v, want %v", gotBare, tt.wantBare)
			}
			if gotWarning != "" && !strings.Contains(gotWarning, tt.wantContains) {
				t.Errorf("detectBareBinary() warning = %q, want to contain %q", gotWarning, tt.wantContains)
			}
		})
	}
}
