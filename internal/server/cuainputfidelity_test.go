// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type physicalInputHandlerCase struct {
	name        string
	arguments   string
	handler     func(*MCPServer, *ToolCall) (*ToolResult, error)
	wantParent  string
	wantTarget  *pb.InputTarget
	wantAction  *pb.InputAction
	wantPosts   int32
	wantSummary []string
}

func physicalInputHandlerCases() []physicalInputHandlerCase {
	right := pb.MouseClick_CLICK_TYPE_RIGHT
	middle := pb.MouseClick_CLICK_TYPE_MIDDLE
	triple := int32(3)
	double := int32(2)
	return []physicalInputHandlerCase{
		{
			name:       "click",
			arguments:  `{"target":"applications/app-1/windows/window-1","x":10.25,"y":-20.5,"button":"right","click_count":3,"keys":["meta","shift"]}`,
			handler:    (*MCPServer).cuaHandleClick,
			wantParent: "applications/app-1",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Window{
					Window: "applications/app-1/windows/window-1",
				},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_Click{
					Click: &pb.MouseClick{
						Position:   &typepb.Point{X: 10.25, Y: -20.5},
						ClickType:  &right,
						ClickCount: &triple,
						Modifiers: []pb.KeyPress_Modifier{
							pb.KeyPress_MODIFIER_COMMAND,
							pb.KeyPress_MODIFIER_SHIFT,
						},
					},
				},
			},
			wantPosts:   6,
			wantSummary: []string{"10.25", "-20.5", "triple", "right-click"},
		},
		{
			name:       "double_click",
			arguments:  `{"target":"displays/7","x":0.25,"y":1.5,"button":"middle","keys":["option"]}`,
			handler:    (*MCPServer).handleDoubleClick,
			wantParent: "applications/-",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Display{Display: "displays/7"},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_Click{
					Click: &pb.MouseClick{
						Position:   &typepb.Point{X: 0.25, Y: 1.5},
						ClickType:  &middle,
						ClickCount: &double,
						Modifiers:  []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_OPTION},
					},
				},
			},
			wantPosts:   4,
			wantSummary: []string{"0.25", "1.5", "double middle-click"},
		},
		{
			name:       "type",
			arguments:  `{"target":"applications/editor","text":"é👨‍👩‍👧‍👦","char_delay":0.125}`,
			handler:    (*MCPServer).handleType,
			wantParent: "applications/editor",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Application{Application: "applications/editor"},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_TypeText{
					TypeText: &pb.TextInput{
						Text:      "é👨‍👩‍👧‍👦",
						CharDelay: 0.125,
					},
				},
			},
			wantPosts:   4,
			wantSummary: []string{"Typed 9 characters", "é👨‍👩‍👧‍👦"},
		},
		{
			name:       "keypress",
			arguments:  `{"target":"applications/editor/windows/document","keys":["control","é"],"hold_duration":0.375}`,
			handler:    (*MCPServer).handleKeypress,
			wantParent: "applications/editor",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Window{
					Window: "applications/editor/windows/document",
				},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:          "é",
						Modifiers:    []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_CONTROL},
						HoldDuration: 0.375,
					},
				},
			},
			wantPosts:   2,
			wantSummary: []string{"control+é"},
		},
		{
			name:       "scroll",
			arguments:  `{"target":"desktop","x":1.25,"y":2.5,"scroll_x":2.5,"scroll_y":-3.5,"duration":1.25,"keys":["fn"]}`,
			handler:    (*MCPServer).cuaHandleScroll,
			wantParent: "applications/-",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Desktop{Desktop: true},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_Scroll{
					Scroll: &pb.Scroll{
						Position:   &typepb.Point{X: 1.25, Y: 2.5},
						Horizontal: 2.5,
						Vertical:   3.5,
						Duration:   1.25,
						Modifiers:  []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_FUNCTION},
					},
				},
			},
			wantPosts:   4,
			wantSummary: []string{"scroll_x:2.5", "scroll_y:-3.5", "(1.25, 2.5)"},
		},
		{
			name:       "drag",
			arguments:  `{"target":"applications/editor/windows/document","path":[{"x":-1.25,"y":2.5},{"x":3.75,"y":4.125},{"x":8.5,"y":9.25}],"button":"right","duration":0.75,"keys":["shift"]}`,
			handler:    (*MCPServer).cuaHandleDrag,
			wantParent: "applications/editor",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Window{
					Window: "applications/editor/windows/document",
				},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_Drag{
					Drag: &pb.MouseDrag{
						StartPosition: &typepb.Point{X: -1.25, Y: 2.5},
						EndPosition:   &typepb.Point{X: 8.5, Y: 9.25},
						Duration:      0.75,
						Button:        &right,
						Modifiers:     []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_SHIFT},
						Path: []*typepb.Point{
							{X: -1.25, Y: 2.5},
							{X: 3.75, Y: 4.125},
							{X: 8.5, Y: 9.25},
						},
					},
				},
			},
			wantPosts:   4,
			wantSummary: []string{"(-1.25, 2.5)", "(8.5, 9.25)", "3 waypoint"},
		},
		{
			name:       "move",
			arguments:  `{"target":"displays/9","x":-0.25,"y":1.5,"duration":0.5,"keys":["cmd"]}`,
			handler:    (*MCPServer).handleMove,
			wantParent: "applications/-",
			wantTarget: &pb.InputTarget{
				Destination: &pb.InputTarget_Display{Display: "displays/9"},
			},
			wantAction: &pb.InputAction{
				InputType: &pb.InputAction_MoveMouse{
					MoveMouse: &pb.MouseMove{
						Position:  &typepb.Point{X: -0.25, Y: 1.5},
						Duration:  0.5,
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
			wantPosts:   20,
			wantSummary: []string{"(-0.25, 1.5)"},
		},
	}
}

func faithfulInputResponse(request *pb.CreateInputRequest, postedEventCount int32) *pb.Input {
	created := time.Unix(1_700_000_000, 123_000_000)
	return &pb.Input{
		Name:         request.GetParent() + "/inputs/" + request.GetInputId(),
		Action:       proto.Clone(request.GetInput().GetAction()).(*pb.InputAction),
		Target:       proto.Clone(request.GetInput().GetTarget()).(*pb.InputTarget),
		State:        pb.Input_STATE_COMPLETED,
		CreateTime:   timestamppb.New(created),
		CompleteTime: timestamppb.New(created.Add(time.Millisecond)),
		DeliveryResult: &pb.InputDeliveryResult{
			Commitment:             pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED,
			PostedEventCount:       postedEventCount,
			RoutedDeliveryObserved: true,
		},
	}
}

func TestPhysicalInputHandlersForwardEveryIntentAndRequireStableIdentity(t *testing.T) {
	inputIDPattern := regexp.MustCompile(`^mcp-[0-9a-f]{32}$`)
	seenInputIDs := make(map[string]struct{})
	for _, test := range physicalInputHandlerCases() {
		t.Run(test.name, func(t *testing.T) {
			var captured *pb.CreateInputRequest
			client := &mockMacosUseClient{
				createInputFunc: func(
					_ context.Context,
					request *pb.CreateInputRequest,
				) (*pb.Input, error) {
					captured = proto.Clone(request).(*pb.CreateInputRequest)
					return faithfulInputResponse(request, test.wantPosts), nil
				},
			}
			result, err := test.handler(
				newTestMCPServer(client),
				&ToolCall{
					Name:      test.name,
					Arguments: json.RawMessage(test.arguments),
				},
			)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || result.IsError {
				t.Fatalf("handler returned MCP error: %q", resultText(result))
			}
			if captured == nil {
				t.Fatal("handler did not invoke production CreateInput")
			}
			if captured.GetParent() != test.wantParent {
				t.Errorf("parent = %q, want %q", captured.GetParent(), test.wantParent)
			}
			if !proto.Equal(captured.GetInput().GetTarget(), test.wantTarget) {
				t.Errorf(
					"target = %v, want %v",
					captured.GetInput().GetTarget(),
					test.wantTarget,
				)
			}
			if !proto.Equal(captured.GetInput().GetAction(), test.wantAction) {
				t.Errorf(
					"action = %v, want %v",
					captured.GetInput().GetAction(),
					test.wantAction,
				)
			}
			inputID := captured.GetInputId()
			if !inputIDPattern.MatchString(inputID) {
				t.Errorf("input_id = %q, want stable caller-generated opaque identity", inputID)
			}
			if _, duplicate := seenInputIDs[inputID]; duplicate {
				t.Errorf("input_id %q was reused", inputID)
			}
			seenInputIDs[inputID] = struct{}{}
			for _, want := range test.wantSummary {
				if !strings.Contains(resultText(result), want) {
					t.Errorf("summary %q omits exact intent %q", resultText(result), want)
				}
			}
		})
	}
}

func TestPhysicalInputHandlersRejectMismatchedPostedEventCounts(t *testing.T) {
	for _, test := range physicalInputHandlerCases() {
		t.Run(test.name, func(t *testing.T) {
			client := &mockMacosUseClient{
				createInputFunc: func(
					_ context.Context,
					request *pb.CreateInputRequest,
				) (*pb.Input, error) {
					return faithfulInputResponse(request, test.wantPosts+1), nil
				},
			}
			result, err := test.handler(
				newTestMCPServer(client),
				&ToolCall{Name: test.name, Arguments: json.RawMessage(test.arguments)},
			)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || !result.IsError {
				t.Fatalf("mismatched receipt became MCP success: %q", resultText(result))
			}
			if !strings.Contains(resultText(result), "posted event count") {
				t.Errorf("error does not identify posted event count: %q", resultText(result))
			}
		})
	}
}

func TestPhysicalInputHandlerRejectsMalformedTerminalEvidence(t *testing.T) {
	move := physicalInputHandlerCases()[6]
	tests := []struct {
		name   string
		mutate func(*pb.Input)
		want   string
	}{
		{
			name: "completed with terminal error",
			mutate: func(input *pb.Input) {
				input.Error = "delivery warning"
			},
			want: "terminal error",
		},
		{
			name: "missing create timestamp",
			mutate: func(input *pb.Input) {
				input.CreateTime = nil
			},
			want: "create_time",
		},
		{
			name: "invalid create timestamp",
			mutate: func(input *pb.Input) {
				input.CreateTime = &timestamppb.Timestamp{Seconds: 253_402_300_800}
			},
			want: "create_time",
		},
		{
			name: "missing complete timestamp",
			mutate: func(input *pb.Input) {
				input.CompleteTime = nil
			},
			want: "complete_time",
		},
		{
			name: "invalid complete timestamp",
			mutate: func(input *pb.Input) {
				input.CompleteTime = &timestamppb.Timestamp{Nanos: -1}
			},
			want: "complete_time",
		},
		{
			name: "reversed timestamps",
			mutate: func(input *pb.Input) {
				input.CompleteTime = timestamppb.New(input.GetCreateTime().AsTime().Add(-time.Nanosecond))
			},
			want: "precedes create_time",
		},
		{
			name: "negative posted count",
			mutate: func(input *pb.Input) {
				input.DeliveryResult.PostedEventCount = -1
			},
			want: "negative posted event count",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			client := &mockMacosUseClient{
				createInputFunc: func(
					_ context.Context,
					request *pb.CreateInputRequest,
				) (*pb.Input, error) {
					response := faithfulInputResponse(request, move.wantPosts)
					test.mutate(response)
					return response, nil
				},
			}
			result, err := move.handler(
				newTestMCPServer(client),
				&ToolCall{Name: move.name, Arguments: json.RawMessage(move.arguments)},
			)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || !result.IsError ||
				!strings.Contains(resultText(result), test.want) {
				t.Fatalf(
					"result=%+v text=%q, want MCP error containing %q",
					result,
					resultText(result),
					test.want,
				)
			}
		})
	}
}

func TestPhysicalInputToolSchemasMatchActionAuthorityAndRuntimeModifiers(t *testing.T) {
	server := newTestServer()
	server.registerTools()

	for _, toolName := range []string{"click", "double_click", "scroll", "drag", "move"} {
		target := server.tools[toolName].InputSchema["properties"].(map[string]any)["target"].(map[string]any)
		if err := validateSchemaValue("target", "displays/7", target); err != nil {
			t.Errorf("%s rejects display pointer authority: %v", toolName, err)
		}
	}
	for _, toolName := range []string{"type", "keypress"} {
		target := server.tools[toolName].InputSchema["properties"].(map[string]any)["target"].(map[string]any)
		if err := validateSchemaValue("target", "displays/7", target); err == nil {
			t.Errorf("%s accepts display keyboard authority", toolName)
		}
	}

	wantModifiers := server.tools["click"].InputSchema["properties"].(map[string]any)["keys"]
	for _, toolName := range []string{"scroll", "move"} {
		got := server.tools[toolName].InputSchema["properties"].(map[string]any)["keys"]
		if !reflect.DeepEqual(got, wantModifiers) {
			t.Errorf("%s modifier schema = %#v, want exact pointer schema %#v", toolName, got, wantModifiers)
		}
	}
}

func TestKeyboardInputHandlersRejectDisplayAuthorityBeforeCreateInput(t *testing.T) {
	for _, test := range []struct {
		name      string
		arguments string
		handler   func(*MCPServer, *ToolCall) (*ToolResult, error)
	}{
		{
			name:      "type",
			arguments: `{"target":"displays/7","text":"x"}`,
			handler:   (*MCPServer).handleType,
		},
		{
			name:      "keypress",
			arguments: `{"target":"displays/7","keys":["a"]}`,
			handler:   (*MCPServer).handleKeypress,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			createCalls := 0
			client := &mockMacosUseClient{
				createInputFunc: func(
					_ context.Context,
					request *pb.CreateInputRequest,
				) (*pb.Input, error) {
					createCalls++
					return faithfulInputResponse(request, 2), nil
				},
			}
			result, err := test.handler(
				newTestMCPServer(client),
				&ToolCall{Name: test.name, Arguments: json.RawMessage(test.arguments)},
			)
			if err != nil {
				t.Fatalf("handler returned Go error: %v", err)
			}
			if result == nil || !result.IsError ||
				!strings.Contains(resultText(result), "keyboard target") {
				t.Fatalf("result=%+v text=%q, want keyboard target error", result, resultText(result))
			}
			if createCalls != 0 {
				t.Fatalf("CreateInput calls = %d, want zero", createCalls)
			}
		})
	}
}

func TestTruncateTextIsUnicodeRuneSafe(t *testing.T) {
	input := strings.Repeat("界", maxDisplayTextLen+1)
	want := strings.Repeat("界", maxDisplayTextLen) + "..."
	got := truncateText(input)
	if got != want {
		t.Fatalf("truncateText() = %q, want %q", got, want)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("truncateText() returned invalid UTF-8: %q", got)
	}
	if gotCount := utf8.RuneCountInString(got); gotCount != maxDisplayTextLen+3 {
		t.Fatalf("truncateText() rune count = %d, want %d", gotCount, maxDisplayTextLen+3)
	}
}
