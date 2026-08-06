// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/joeycumines/MacosUseSDK/internal/transport"
)

func TestPhysicalInputScheduleRejectsExactDeadlineBeforeCreateInput(t *testing.T) {
	tests := []struct {
		name    string
		handler func(*MCPServer, *ToolCall) (*ToolResult, error)
		args    string
	}{
		{
			name:    "type",
			handler: (*MCPServer).handleType,
			args:    `{"target":"desktop","text":"ab","char_delay":1}`,
		},
		{
			name:    "keypress",
			handler: (*MCPServer).handleKeypress,
			args:    `{"target":"desktop","keys":["a"],"hold_duration":1}`,
		},
		{
			name:    "scroll",
			handler: (*MCPServer).cuaHandleScroll,
			args:    `{"target":"desktop","x":1,"y":2,"scroll_y":1,"duration":1}`,
		},
		{
			name:    "drag",
			handler: (*MCPServer).cuaHandleDrag,
			args:    `{"target":"desktop","path":[{"x":1,"y":2},{"x":3,"y":4}],"duration":1}`,
		},
		{
			name:    "move",
			handler: (*MCPServer).handleMove,
			args:    `{"target":"desktop","x":1,"y":2,"duration":1}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server, requests := newInputAdmissionRecordingServer()
			server.cfg.RequestTimeout = 1
			result, err := test.handler(server, &ToolCall{
				Name:      test.name,
				Arguments: json.RawMessage(test.args),
			})
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || !result.IsError ||
				!strings.Contains(resultText(result), "schedule must be less than configured request timeout") {
				t.Fatalf("result=%+v text=%q, want strict schedule rejection", result, resultText(result))
			}
			if len(*requests) != 0 {
				t.Fatalf("deadline-equal schedule reached %d CreateInput calls", len(*requests))
			}
		})
	}
}

func TestPhysicalInputScheduleUsesExtendedGraphemesAndSwiftNanoseconds(t *testing.T) {
	for _, text := range []string{
		"e\u0301x",
		"👨‍👩‍👧‍👦x",
		"🇦🇺x",
	} {
		t.Run(text, func(t *testing.T) {
			server, requests := newInputAdmissionRecordingServer()
			server.cfg.RequestTimeout = 1
			arguments, err := json.Marshal(map[string]any{
				"target":     "desktop",
				"text":       text,
				"char_delay": 1,
			})
			if err != nil {
				t.Fatalf("marshal type arguments: %v", err)
			}
			result, handlerErr := server.handleType(&ToolCall{
				Name:      "type",
				Arguments: arguments,
			})
			if handlerErr != nil || result == nil || !result.IsError {
				t.Fatalf("result=%+v error=%v, want exact-deadline rejection", result, handlerErr)
			}
			if len(*requests) != 0 {
				t.Fatalf("extended-grapheme deadline reached %d CreateInput calls", len(*requests))
			}
		})
	}

	server, requests := newInputAdmissionRecordingServer()
	server.cfg.RequestTimeout = 1
	result, err := server.handleType(&ToolCall{
		Name: "type",
		Arguments: json.RawMessage(
			`{"target":"desktop","text":"abcd","char_delay":0.3333333333333333}`,
		),
	})
	if err != nil || result == nil || result.IsError {
		t.Fatalf("999,999,999ns schedule result=%+v error=%v, want success", result, err)
	}
	if len(*requests) != 1 {
		t.Fatalf("999,999,999ns schedule reached %d CreateInput calls, want 1", len(*requests))
	}
}

func TestPhysicalInputScheduleAcceptsEveryZeroSchedule(t *testing.T) {
	tests := []struct {
		name    string
		handler func(*MCPServer, *ToolCall) (*ToolResult, error)
		args    string
	}{
		{
			name:    "click",
			handler: (*MCPServer).cuaHandleClick,
			args:    `{"target":"desktop","x":1,"y":2}`,
		},
		{
			name:    "double_click",
			handler: (*MCPServer).handleDoubleClick,
			args:    `{"target":"desktop","x":1,"y":2}`,
		},
		{
			name:    "single_grapheme_type",
			handler: (*MCPServer).handleType,
			args:    `{"target":"desktop","text":"👨‍👩‍👧‍👦","char_delay":60}`,
		},
		{
			name:    "zero_hold",
			handler: (*MCPServer).handleKeypress,
			args:    `{"target":"desktop","keys":["a"],"hold_duration":0}`,
		},
		{
			name:    "zero_scroll",
			handler: (*MCPServer).cuaHandleScroll,
			args:    `{"target":"desktop","x":1,"y":2,"scroll_y":1,"duration":0}`,
		},
		{
			name:    "zero_drag",
			handler: (*MCPServer).cuaHandleDrag,
			args:    `{"target":"desktop","path":[{"x":1,"y":2},{"x":3,"y":4}],"duration":0}`,
		},
		{
			name:    "zero_move",
			handler: (*MCPServer).handleMove,
			args:    `{"target":"desktop","x":1,"y":2,"duration":0}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server, requests := newInputAdmissionRecordingServer()
			server.cfg.RequestTimeout = 1
			result, err := test.handler(server, &ToolCall{
				Name:      test.name,
				Arguments: json.RawMessage(test.args),
			})
			if err != nil || result == nil || result.IsError {
				t.Fatalf("result=%+v error=%v, want success", result, err)
			}
			if len(*requests) != 1 {
				t.Fatalf("zero schedule reached %d CreateInput calls, want 1", len(*requests))
			}
		})
	}
}

func TestPhysicalInputScheduleRejectsInvalidTimeoutConfiguration(t *testing.T) {
	const maximumDurationSeconds = int64((1<<63 - 1) / int64(time.Second))
	configurations := []struct {
		name string
		cfg  *config.Config
	}{
		{name: "nil", cfg: nil},
		{name: "zero", cfg: &config.Config{}},
		{name: "negative", cfg: &config.Config{RequestTimeout: -1}},
		{
			name: "overflow",
			cfg:  &config.Config{RequestTimeout: int(maximumDurationSeconds) + 1},
		},
	}
	handlers := []struct {
		name    string
		handler func(*MCPServer, *ToolCall) (*ToolResult, error)
		args    string
	}{
		{name: "click", handler: (*MCPServer).cuaHandleClick, args: `{"target":"desktop","x":1,"y":2}`},
		{name: "double_click", handler: (*MCPServer).handleDoubleClick, args: `{"target":"desktop","x":1,"y":2}`},
		{name: "type", handler: (*MCPServer).handleType, args: `{"target":"desktop","text":"x"}`},
		{name: "keypress", handler: (*MCPServer).handleKeypress, args: `{"target":"desktop","keys":["a"]}`},
		{name: "scroll", handler: (*MCPServer).cuaHandleScroll, args: `{"target":"desktop","x":1,"y":2}`},
		{name: "drag", handler: (*MCPServer).cuaHandleDrag, args: `{"target":"desktop","path":[{"x":1,"y":2},{"x":3,"y":4}]}`},
		{name: "move", handler: (*MCPServer).handleMove, args: `{"target":"desktop","x":1,"y":2}`},
	}
	for _, configuration := range configurations {
		for _, handler := range handlers {
			t.Run(configuration.name+"/"+handler.name, func(t *testing.T) {
				server, requests := newInputAdmissionRecordingServer()
				server.cfg = configuration.cfg
				result, err := handler.handler(server, &ToolCall{
					Name:      handler.name,
					Arguments: json.RawMessage(handler.args),
				})
				if err != nil {
					t.Fatalf("handler returned Go error: %v", err)
				}
				if result == nil || !result.IsError ||
					!strings.Contains(resultText(result), "request timeout configuration") {
					t.Fatalf("result=%+v text=%q, want configuration rejection", result, resultText(result))
				}
				if len(*requests) != 0 {
					t.Fatalf("invalid timeout reached %d CreateInput calls", len(*requests))
				}
			})
		}
	}
}

func TestPhysicalInputScheduleSchemasAreStrictAndComposite(t *testing.T) {
	server := &MCPServer{
		cfg:   &config.Config{RequestTimeout: 1},
		tools: make(map[string]*Tool),
	}
	server.registerTools()
	for _, test := range []struct {
		tool  string
		field string
	}{
		{tool: "keypress", field: "hold_duration"},
		{tool: "scroll", field: "duration"},
		{tool: "drag", field: "duration"},
		{tool: "move", field: "duration"},
	} {
		field := physicalSchemaField(t, server.tools[test.tool], test.field)
		if field["exclusiveMaximum"] != 1 || field["minimum"] != 0 {
			t.Errorf("%s.%s schema=%#v, want [0,1)", test.tool, test.field, field)
		}
		if _, exists := field["maximum"]; exists {
			t.Errorf("%s.%s retains inclusive maximum at timeout boundary: %#v", test.tool, test.field, field)
		}
	}
	typeTool := server.tools["type"]
	text := physicalSchemaField(t, typeTool, "text")
	if text["minLength"] != 1 {
		t.Errorf("type.text schema=%#v, want minLength=1", text)
	}
	charDelay := physicalSchemaField(t, typeTool, "char_delay")
	if charDelay["minimum"] != 0 || charDelay["maximum"] != 60 {
		t.Errorf("type.char_delay schema=%#v, want native [0,60]", charDelay)
	}
	if typeTool.ValidateInput == nil {
		t.Fatal("type omitted composite schedule admission")
	}
	if err := typeTool.ValidateInput(map[string]any{
		"text":       "e\u0301x",
		"char_delay": float64(1),
	}); err == nil {
		t.Error("type composite admission accepted a deadline-equal extended-grapheme schedule")
	}
	if err := typeTool.ValidateInput(map[string]any{
		"text":       "👨‍👩‍👧‍👦",
		"char_delay": float64(60),
	}); err != nil {
		t.Errorf("type composite admission rejected a one-grapheme zero schedule: %v", err)
	}

	native := &MCPServer{
		cfg:   &config.Config{RequestTimeout: 3601},
		tools: make(map[string]*Tool),
	}
	native.registerTools()
	if field := physicalSchemaField(t, native.tools["keypress"], "hold_duration"); field["maximum"] != 3600 {
		t.Errorf("keypress native schema=%#v, want inclusive maximum 3600", field)
	}
	if field := physicalSchemaField(t, native.tools["move"], "duration"); field["maximum"] != 60 {
		t.Errorf("move native schema=%#v, want inclusive maximum 60", field)
	}
}

func TestPhysicalInputScheduleCompositeDispatchRejectsBeforeMutationOwner(t *testing.T) {
	server, requests := newInputAdmissionRecordingServer()
	server.cfg.RequestTimeout = 1
	server.tools = make(map[string]*Tool)
	server.registerTools()
	response, err := server.handleHTTPMessage(&transport.Message{
		Context: context.Background(),
		JSONRPC: "2.0",
		ID:      json.RawMessage(`1`),
		Method:  "tools/call",
		Params: json.RawMessage(
			`{"name":"type","arguments":{"target":"desktop","text":"ab","char_delay":1}}`,
		),
	})
	if err != nil {
		t.Fatalf("dispatch returned Go error: %v", err)
	}
	if response == nil || response.Error == nil ||
		response.Error.Code != transport.ErrCodeInvalidParams {
		t.Fatalf("response=%+v, want invalid params", response)
	}
	if len(*requests) != 0 {
		t.Fatalf("composite rejection reached %d CreateInput calls", len(*requests))
	}
	if server.mutationGate != nil {
		t.Fatal("composite rejection created the physical mutation owner")
	}
}

func TestPhysicalInputScheduleNewServerRejectsInvalidManualConfiguration(t *testing.T) {
	const maximumDurationSeconds = int64((1<<63 - 1) / int64(time.Second))
	for _, timeout := range []int{0, -1, int(maximumDurationSeconds) + 1} {
		t.Run(time.Duration(timeout).String(), func(t *testing.T) {
			server, err := NewMCPServer(&config.Config{
				ServerAddr:     "127.0.0.1:1",
				RequestTimeout: timeout,
			})
			if server != nil {
				server.cancel()
				t.Fatalf("NewMCPServer returned a server for timeout %d", timeout)
			}
			if err == nil || !strings.Contains(err.Error(), "request timeout configuration") {
				t.Fatalf("NewMCPServer error=%v, want timeout configuration rejection", err)
			}
		})
	}
}

func physicalSchemaField(t *testing.T, tool *Tool, name string) map[string]any {
	t.Helper()
	if tool == nil {
		t.Fatal("tool is nil")
	}
	properties, ok := tool.InputSchema["properties"].(map[string]any)
	if !ok {
		t.Fatalf("%s properties=%T, want map", tool.Name, tool.InputSchema["properties"])
	}
	field, ok := properties[name].(map[string]any)
	if !ok {
		t.Fatalf("%s.%s schema=%T, want map", tool.Name, name, properties[name])
	}
	return field
}
