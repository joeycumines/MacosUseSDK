// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/config"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestInputAdmissionDescriptorSurface(t *testing.T) {
	file := pb.File_macosusesdk_v1_input_proto
	inputAction := file.Messages().ByName("InputAction")
	if inputAction == nil {
		t.Fatal("InputAction descriptor is absent")
	}

	reservedRanges := inputAction.ReservedRanges()
	if reservedRanges.Len() != 1 || reservedRanges.Get(0)[0] != 17 || reservedRanges.Get(0)[1] != 20 {
		t.Fatalf("InputAction reserved ranges = %v, want exactly [17,20)", reservedRanges)
	}
	reservedNames := inputAction.ReservedNames()
	gotNames := make([]string, 0, reservedNames.Len())
	for index := 0; index < reservedNames.Len(); index++ {
		gotNames = append(gotNames, string(reservedNames.Get(index)))
	}
	wantNames := []string{"gesture", "button_down", "button_up"}
	if !reflect.DeepEqual(gotNames, wantNames) {
		t.Fatalf("InputAction reserved names = %v, want %v", gotNames, wantNames)
	}

	for _, name := range []protoreflect.Name{"Gesture", "MouseButtonDown", "MouseButtonUp"} {
		if message := file.Messages().ByName(name); message != nil {
			t.Errorf("orphan public message %s remains in the descriptor", name)
		}
	}
	for _, field := range []struct {
		message protoreflect.Name
		field   protoreflect.Name
	}{
		{message: "MouseClick", field: "click_type"},
		{message: "MouseClick", field: "click_count"},
		{message: "MouseDrag", field: "button"},
	} {
		descriptor := file.Messages().ByName(field.message)
		if descriptor == nil {
			t.Fatalf("message %s is absent", field.message)
		}
		fieldDescriptor := descriptor.Fields().ByName(field.field)
		if fieldDescriptor == nil || !fieldDescriptor.HasPresence() {
			t.Errorf("%s.%s has no proto3 presence", field.message, field.field)
		}
	}
}

func TestInputAdmissionClickAndDragOmissionVersusSuppliedIntent(t *testing.T) {
	t.Run("omission defaults and is represented explicitly downstream", func(t *testing.T) {
		server, requests := newInputAdmissionRecordingServer()
		result, err := server.cuaHandleClick(&ToolCall{
			Name:      "click",
			Arguments: json.RawMessage(`{"target":"desktop","x":0,"y":0}`),
		})
		if err != nil || result == nil || result.IsError {
			t.Fatalf("omitted click defaults result=%+v error=%v", result, err)
		}
		if len(*requests) != 1 {
			t.Fatalf("CreateInput calls = %d, want 1", len(*requests))
		}
		click := (*requests)[0].GetInput().GetAction().GetClick()
		if click.GetClickType() != pb.MouseClick_CLICK_TYPE_LEFT || click.GetClickCount() != 1 {
			t.Fatalf("omitted click became button=%v count=%d, want left/1", click.GetClickType(), click.GetClickCount())
		}
		for _, name := range []protoreflect.Name{"click_type", "click_count"} {
			field := click.ProtoReflect().Descriptor().Fields().ByName(name)
			if field == nil || !click.ProtoReflect().Has(field) {
				t.Errorf("downstream click does not explicitly carry defaulted %s", name)
			}
		}

		server, requests = newInputAdmissionRecordingServer()
		result, err = server.cuaHandleDrag(&ToolCall{
			Name:      "drag",
			Arguments: json.RawMessage(`{"target":"desktop","path":[{"x":0,"y":0},{"x":1,"y":1}]}`),
		})
		if err != nil || result == nil || result.IsError {
			t.Fatalf("omitted drag button result=%+v error=%v", result, err)
		}
		drag := (*requests)[0].GetInput().GetAction().GetDrag()
		if drag.GetButton() != pb.MouseClick_CLICK_TYPE_LEFT {
			t.Fatalf("omitted drag button = %v, want left", drag.GetButton())
		}
		buttonField := drag.ProtoReflect().Descriptor().Fields().ByName("button")
		if buttonField == nil || !drag.ProtoReflect().Has(buttonField) {
			t.Error("downstream drag does not explicitly carry the defaulted left button")
		}
	})

	invalid := []struct {
		name    string
		handler func(*MCPServer, *ToolCall) (*ToolResult, error)
		tool    string
		args    string
		want    string
	}{
		{name: "zero click count", handler: (*MCPServer).cuaHandleClick, tool: "click", args: `{"x":1,"y":2,"click_count":0}`, want: "between 1 and 10"},
		{name: "negative click count", handler: (*MCPServer).cuaHandleClick, tool: "click", args: `{"x":1,"y":2,"click_count":-1}`, want: "between 1 and 10"},
		{name: "large click count", handler: (*MCPServer).cuaHandleClick, tool: "click", args: `{"x":1,"y":2,"click_count":11}`, want: "between 1 and 10"},
		{name: "empty click button", handler: (*MCPServer).cuaHandleClick, tool: "click", args: `{"x":1,"y":2,"button":""}`, want: "unsupported button"},
		{name: "upper-case click button", handler: (*MCPServer).cuaHandleClick, tool: "click", args: `{"x":1,"y":2,"button":"LEFT"}`, want: "unsupported button"},
		{name: "back click button", handler: (*MCPServer).cuaHandleClick, tool: "click", args: `{"x":1,"y":2,"button":"back"}`, want: "unsupported button"},
		{name: "forward double-click button", handler: (*MCPServer).handleDoubleClick, tool: "double_click", args: `{"x":1,"y":2,"button":"forward"}`, want: "unsupported button"},
		{name: "unknown drag button", handler: (*MCPServer).cuaHandleDrag, tool: "drag", args: `{"path":[{"x":0,"y":0},{"x":1,"y":1}],"button":"other"}`, want: "unsupported button"},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			server, requests := newInputAdmissionRecordingServer()
			result, err := test.handler(server, &ToolCall{Name: test.tool, Arguments: json.RawMessage(test.args)})
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || !result.IsError || !strings.Contains(resultText(result), test.want) {
				t.Fatalf("result=%+v text=%q, want error containing %q", result, resultText(result), test.want)
			}
			if len(*requests) != 0 {
				t.Fatalf("invalid intent reached %d CreateInput calls", len(*requests))
			}
		})
	}
}

func TestInputAdmissionKeyChordIsExact(t *testing.T) {
	server, requests := newInputAdmissionRecordingServer()
	result, err := server.handleKeypress(&ToolCall{
		Name:      "keypress",
		Arguments: json.RawMessage(`{"target":"desktop","keys":["meta","shift","3"]}`),
	})
	if err != nil || result == nil || result.IsError {
		t.Fatalf("valid key chord result=%+v error=%v", result, err)
	}
	key := (*requests)[0].GetInput().GetAction().GetPressKey()
	if key.GetKey() != "3" || !reflect.DeepEqual(key.GetModifiers(), []pb.KeyPress_Modifier{
		pb.KeyPress_MODIFIER_COMMAND,
		pb.KeyPress_MODIFIER_SHIFT,
	}) {
		t.Fatalf("valid chord became key=%q modifiers=%v", key.GetKey(), key.GetModifiers())
	}

	server, requests = newInputAdmissionRecordingServer()
	result, err = server.handleKeypress(&ToolCall{
		Name:      "keypress",
		Arguments: json.RawMessage(`{"target":"desktop","keys":["arrowup"]}`),
	})
	if err != nil || result == nil || result.IsError {
		t.Fatalf("valid arrow alias result=%+v error=%v", result, err)
	}
	if got := (*requests)[0].GetInput().GetAction().GetPressKey().GetKey(); got != "up" {
		t.Fatalf("arrowup normalized to %q, want backend-supported up", got)
	}

	invalid := []struct {
		name string
		args string
	}{
		{name: "all modifiers", args: `{"keys":["ctrl","shift"]}`},
		{name: "multiple primary keys", args: `{"keys":["a","b"]}`},
		{name: "duplicate semantic modifier", args: `{"keys":["meta","command","a"]}`},
		{name: "blank primary", args: `{"keys":[""]}`},
		{name: "unknown primary", args: `{"keys":["home"]}`},
		{name: "out-of-range numeric primary", args: `{"keys":["99999"]}`},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			server, requests := newInputAdmissionRecordingServer()
			result, err := server.handleKeypress(&ToolCall{Name: "keypress", Arguments: json.RawMessage(test.args)})
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || !result.IsError {
				t.Fatalf("invalid chord result=%+v, want error", result)
			}
			if len(*requests) != 0 {
				t.Fatalf("invalid chord reached %d CreateInput calls", len(*requests))
			}
		})
	}
}

func TestInputAdmissionWaitOmissionVersusSuppliedIntent(t *testing.T) {
	tests := []struct {
		name          string
		args          string
		wantCancelled bool
		wantText      string
	}{
		{name: "omitted defaults", args: `{}`, wantCancelled: true},
		{name: "zero rejects", args: `{"duration":0}`, wantText: "greater than 0"},
		{name: "negative rejects", args: `{"duration":-1}`, wantText: "greater than 0"},
		{name: "over timeout rejects", args: `{"duration":31}`, wantText: "at most 30"},
		{name: "overflow rejects", args: `{"duration":1e999}`, wantText: "Invalid parameters"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := newTestServer()
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			result, err := server.handleWait(&ToolCall{
				Context:   ctx,
				Name:      "wait",
				Arguments: json.RawMessage(test.args),
			})
			if err != nil {
				t.Fatalf("wait returned Go error: %v", err)
			}
			text := resultText(result)
			if test.wantCancelled {
				if !strings.Contains(text, "Wait cancelled") {
					t.Fatalf("omitted wait text=%q, want documented one-second default admitted before cancellation", text)
				}
				return
			}
			if result == nil || !result.IsError || !strings.Contains(text, test.wantText) {
				t.Fatalf("wait result=%+v text=%q, want error containing %q", result, text, test.wantText)
			}
		})
	}
}

func TestInputAdmissionRegisteredSchemasAndPreMutationValidation(t *testing.T) {
	server := &MCPServer{
		cfg:   &config.Config{RequestTimeout: 30},
		ctx:   context.Background(),
		tools: make(map[string]*Tool),
	}
	server.registerTools()

	assertSchemaFields(t, server.tools["click"].InputSchema, "click_count", map[string]any{
		"minimum": 1,
		"maximum": 10,
		"default": 1,
	})
	for _, toolName := range []string{"click", "double_click", "drag"} {
		assertSchemaFields(t, server.tools[toolName].InputSchema, "button", map[string]any{
			"default": "left",
		})
	}
	assertSchemaFields(t, server.tools["wait"].InputSchema, "duration", map[string]any{
		"exclusiveMinimum": 0,
		"maximum":          30,
		"default":          1.0,
	})

	rejections := []struct {
		tool string
		args map[string]any
	}{
		{tool: "click", args: map[string]any{"x": 1, "y": 2, "click_count": 0}},
		{tool: "click", args: map[string]any{"x": 1, "y": 2, "button": nil}},
		{tool: "keypress", args: map[string]any{"keys": []any{"a", "b"}}},
		{tool: "wait", args: map[string]any{"duration": 31}},
	}
	for _, rejection := range rejections {
		if result := validateToolInput(rejection.tool, rejection.args, server.tools); result == nil || result.Error == nil || result.Error.Code != -32602 {
			t.Errorf("%s args=%v validation result=%+v, want -32602 before mutation", rejection.tool, rejection.args, result)
		}
	}
}

func newInputAdmissionRecordingServer() (*MCPServer, *[]*pb.CreateInputRequest) {
	requests := make([]*pb.CreateInputRequest, 0, 1)
	client := &mockMacosUseClient{
		createInputFunc: func(_ context.Context, request *pb.CreateInputRequest) (*pb.Input, error) {
			requests = append(requests, request)
			return completedInputResponse(request), nil
		},
	}
	return newTestMCPServer(client), &requests
}

func assertSchemaFields(t *testing.T, schema map[string]any, fieldName string, want map[string]any) {
	t.Helper()
	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		t.Fatalf("schema properties = %T, want map", schema["properties"])
	}
	field, ok := properties[fieldName].(map[string]any)
	if !ok {
		t.Fatalf("schema field %s = %T, want map", fieldName, properties[fieldName])
	}
	for key, value := range want {
		if !reflect.DeepEqual(field[key], value) {
			t.Errorf("schema %s.%s = %#v, want %#v", fieldName, key, field[key], value)
		}
	}
}
