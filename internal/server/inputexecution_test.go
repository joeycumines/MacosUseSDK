// Copyright 2026 Joseph Cumines

package server

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	typepb "github.com/joeycumines/ExactMac/gen/go/exactmac/type"
	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	annotations "google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestInputExecutionDescriptorRequiresTargetAndTruthfulDelivery(t *testing.T) {
	file := pb.File_exactmac_v1_input_proto
	input := file.Messages().ByName("Input")
	if input == nil {
		t.Fatal("Input descriptor is absent")
	}

	target := input.Fields().ByName("target")
	if target == nil {
		t.Fatal("Input.target is absent")
	}
	if !publicFieldHasBehavior(target, annotations.FieldBehavior_REQUIRED) {
		t.Error("Input.target is not REQUIRED")
	}
	if target.Message() == nil || target.Message().Name() != "InputTarget" {
		t.Fatalf("Input.target type = %v, want InputTarget", target.Message())
	}

	delivery := input.Fields().ByName("delivery_result")
	if delivery == nil {
		t.Fatal("Input.delivery_result is absent")
	}
	if !publicFieldHasBehavior(delivery, annotations.FieldBehavior_OUTPUT_ONLY) {
		t.Error("Input.delivery_result is not OUTPUT_ONLY")
	}
	if delivery.Message() == nil || delivery.Message().Name() != "InputDeliveryResult" {
		t.Fatalf(
			"Input.delivery_result type = %v, want InputDeliveryResult",
			delivery.Message(),
		)
	}

	state := input.Enums().ByName("State")
	requireInputEnumValue(t, state, "STATE_CANCELLED")

	inputTarget := file.Messages().ByName("InputTarget")
	if inputTarget == nil {
		t.Fatal("InputTarget descriptor is absent")
	}
	destination := inputTarget.Oneofs().ByName("destination")
	if destination == nil {
		t.Fatal("InputTarget.destination oneof is absent")
	}
	requireInputOneofFields(
		t,
		destination,
		[]protoreflect.Name{"application", "window", "display", "desktop"},
	)

	deliveryResult := file.Messages().ByName("InputDeliveryResult")
	if deliveryResult == nil {
		t.Fatal("InputDeliveryResult descriptor is absent")
	}
	commitment := deliveryResult.Enums().ByName("Commitment")
	for _, name := range []protoreflect.Name{
		"COMMITMENT_NO_EFFECT",
		"COMMITMENT_POSSIBLY_COMMITTED",
		"COMMITMENT_COMMITTED_AND_SETTLED",
	} {
		requireInputEnumValue(t, commitment, name)
	}
	for _, name := range []protoreflect.Name{
		"commitment",
		"posted_event_count",
		"routed_delivery_observed",
	} {
		field := deliveryResult.Fields().ByName(name)
		if field == nil {
			t.Errorf("InputDeliveryResult.%s is absent", name)
			continue
		}
		if !publicFieldHasBehavior(field, annotations.FieldBehavior_OUTPUT_ONLY) {
			t.Errorf("InputDeliveryResult.%s is not OUTPUT_ONLY", name)
		}
	}
}

func TestInputExecutionMCPToolsRequireExactTarget(t *testing.T) {
	for _, name := range []string{
		"click",
		"double_click",
		"type",
		"keypress",
		"scroll",
		"drag",
		"move",
	} {
		tool := findInputExecutionTool(t, name)
		properties, ok := tool.InputSchema["properties"].(map[string]any)
		if !ok {
			t.Fatalf("%s properties type = %T", name, tool.InputSchema["properties"])
		}
		target, ok := properties["target"].(map[string]any)
		if !ok || target["type"] != "string" {
			t.Errorf("%s target schema = %#v, want required string", name, properties["target"])
		}
		if pattern, _ := target["pattern"].(string); pattern == "" {
			t.Errorf("%s target schema has no fail-closed resource pattern", name)
		}
		required, ok := tool.InputSchema["required"].([]string)
		if !ok || !containsInputString(required, "target") {
			t.Errorf("%s required = %#v, want target", name, tool.InputSchema["required"])
		}
		if _, exists := properties["parent"]; exists {
			t.Errorf("%s still exposes parent instead of exact target", name)
		}
		for _, value := range []string{
			"applications/-",
			"applications/app/windows/-",
			"displays/0",
			"displays/4294967296",
		} {
			if err := validateSchemaValue("target", value, target); err == nil {
				t.Errorf("%s target schema accepts invalid resource %q", name, value)
			}
		}
		validTargets := []string{
			"desktop",
			"applications/app",
			"applications/app/windows/window-1",
		}
		if name != "type" && name != "keypress" {
			validTargets = append(validTargets, "displays/1", "displays/4294967295")
		}
		for _, value := range validTargets {
			if err := validateSchemaValue("target", value, target); err != nil {
				t.Errorf("%s target schema rejects %q: %v", name, value, err)
			}
		}
		if name == "type" || name == "keypress" {
			if err := validateSchemaValue("target", "displays/1", target); err == nil {
				t.Errorf("%s target schema accepts display keyboard authority", name)
			}
		}
	}
	typeTool := findInputExecutionTool(t, "type")
	typeProperties := typeTool.InputSchema["properties"].(map[string]any)
	charDelay := typeProperties["char_delay"].(map[string]any)
	if charDelay["minimum"] != 0 || charDelay["maximum"] != 60 {
		t.Errorf("type char_delay schema = %#v, want [0,60]", charDelay)
	}
	dragTool := findInputExecutionTool(t, "drag")
	dragProperties := dragTool.InputSchema["properties"].(map[string]any)
	dragDuration := dragProperties["duration"].(map[string]any)
	if dragDuration["minimum"] != 0 || dragDuration["exclusiveMaximum"] != 30 {
		t.Errorf("drag duration schema = %#v, want [0,30)", dragDuration)
	}
}

func TestInputExecutionParseTargetRejectsWhitespaceAndDisplayOverflow(t *testing.T) {
	for _, target := range []string{
		" desktop",
		"desktop ",
		"\tdesktop",
		"displays/4294967296",
		"displays/18446744073709551615",
		"applications/app/windows/-",
	} {
		t.Run(target, func(t *testing.T) {
			if _, _, err := parseCUAInputTarget(target); err == nil {
				t.Fatalf("parseCUAInputTarget(%q) succeeded", target)
			}
		})
	}
	for _, target := range []string{
		"desktop",
		"displays/1",
		"displays/4294967295",
		"applications/123",
		"applications/123/windows/window-1",
	} {
		t.Run("valid_"+target, func(t *testing.T) {
			if _, _, err := parseCUAInputTarget(target); err != nil {
				t.Fatalf("parseCUAInputTarget(%q): %v", target, err)
			}
		})
	}
}

func TestInputExecutionMCPGeneratesStableOpaqueInputIDs(t *testing.T) {
	pattern := regexp.MustCompile(`^mcp-[0-9a-f]{32}$`)
	seen := make(map[string]struct{}, 64)
	for range 64 {
		request, err := buildCUAInputRequest("desktop", &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_MouseMove{
					MouseMove: &pb.MouseMove{
						Position: &typepb.Point{X: 10, Y: 20},
					},
				},
			},
		})
		if err != nil {
			t.Fatalf("buildCUAInputRequest: %v", err)
		}
		if !pattern.MatchString(request.GetInputId()) {
			t.Fatalf("input_id = %q, want mcp- plus 32 lowercase hex digits", request.GetInputId())
		}
		if _, duplicate := seen[request.GetInputId()]; duplicate {
			t.Fatalf("duplicate generated input_id %q", request.GetInputId())
		}
		seen[request.GetInputId()] = struct{}{}
		if request.GetParent() != "applications/-" {
			t.Fatalf("parent = %q, want applications/-", request.GetParent())
		}
		if !request.GetInput().GetTarget().GetDesktop() {
			t.Fatalf("target = %#v, want explicit desktop", request.GetInput().GetTarget())
		}
	}
}

func TestInputExecutionBypassProductsAreAbsent(t *testing.T) {
	root := repositoryRoot(t)
	manifest, err := os.ReadFile(filepath.Join(root, "Package.swift"))
	if err != nil {
		t.Fatalf("read Package.swift: %v", err)
	}
	manifestText := string(manifest)
	for _, name := range []string{
		"ActionTool",
		"AppOpenerTool",
		"HighlightTraversalTool",
		"InputControllerTool",
		"TraversalTool",
		"VisualInputTool",
	} {
		if strings.Contains(manifestText, `name: "`+name+`"`) {
			t.Errorf("unsupported executable product %s remains in Package.swift", name)
		}
		if _, err := os.Stat(filepath.Join(root, "Sources", name)); !os.IsNotExist(err) {
			t.Errorf("unsupported executable source Sources/%s remains", name)
		}
	}
}

func TestInputExecutionMCPRequiresExactCommittedDeliveryReceipt(t *testing.T) {
	request := &pb.CreateInputRequest{
		Parent:  "applications/-",
		InputId: "mcp-exact",
		Input: &pb.Input{
			Target: &pb.InputTarget{
				Destination: &pb.InputTarget_Desktop{Desktop: true},
			},
			Action: &pb.InputAction{
				InputType: &pb.InputAction_MouseMove{
					MouseMove: &pb.MouseMove{
						Position: &typepb.Point{X: 10, Y: 20},
					},
				},
			},
		},
	}
	valid := &pb.Input{
		Name:         "applications/-/inputs/mcp-exact",
		Action:       proto.Clone(request.GetInput().GetAction()).(*pb.InputAction),
		Target:       proto.Clone(request.GetInput().GetTarget()).(*pb.InputTarget),
		State:        pb.Input_STATE_COMPLETED,
		CreateTime:   timestamppb.New(time.Unix(1_700_000_000, 0)),
		CompleteTime: timestamppb.New(time.Unix(1_700_000_001, 0)),
		DeliveryResult: &pb.InputDeliveryResult{
			Commitment:             pb.InputDeliveryResult_COMMITMENT_COMMITTED_AND_SETTLED,
			PostedEventCount:       1,
			RoutedDeliveryObserved: true,
		},
	}
	if result := incompleteInputResult(valid, request, "move"); result != nil {
		t.Fatalf("valid receipt rejected: %s", resultText(result))
	}

	tests := []struct {
		name   string
		mutate func(*pb.Input)
		want   string
	}{
		{
			name: "name mismatch",
			mutate: func(input *pb.Input) {
				input.Name = "applications/-/inputs/other"
			},
			want: "want",
		},
		{
			name: "action mismatch",
			mutate: func(input *pb.Input) {
				input.Action = &pb.InputAction{}
			},
			want: "changed the requested action",
		},
		{
			name: "target mismatch",
			mutate: func(input *pb.Input) {
				input.Target = &pb.InputTarget{
					Destination: &pb.InputTarget_Display{Display: "displays/1"},
				}
			},
			want: "changed the requested target",
		},
		{
			name: "failed",
			mutate: func(input *pb.Input) {
				input.State = pb.Input_STATE_FAILED
				input.Error = "route vanished"
			},
			want: "route vanished",
		},
		{
			name: "cancelled",
			mutate: func(input *pb.Input) {
				input.State = pb.Input_STATE_CANCELLED
				input.Error = "caller cancelled"
			},
			want: "caller cancelled",
		},
		{
			name: "pending",
			mutate: func(input *pb.Input) {
				input.State = pb.Input_STATE_PENDING
			},
			want: "STATE_PENDING",
		},
		{
			name: "executing",
			mutate: func(input *pb.Input) {
				input.State = pb.Input_STATE_EXECUTING
			},
			want: "STATE_EXECUTING",
		},
		{
			name: "unspecified state",
			mutate: func(input *pb.Input) {
				input.State = pb.Input_STATE_UNSPECIFIED
			},
			want: "STATE_UNSPECIFIED",
		},
		{
			name: "missing receipt",
			mutate: func(input *pb.Input) {
				input.DeliveryResult = nil
			},
			want: "no delivery receipt",
		},
		{
			name: "unspecified commitment",
			mutate: func(input *pb.Input) {
				input.DeliveryResult.Commitment =
					pb.InputDeliveryResult_COMMITMENT_UNSPECIFIED
			},
			want: "delivery commitment",
		},
		{
			name: "no effect",
			mutate: func(input *pb.Input) {
				input.DeliveryResult.Commitment =
					pb.InputDeliveryResult_COMMITMENT_NO_EFFECT
			},
			want: "delivery commitment",
		},
		{
			name: "possible commitment",
			mutate: func(input *pb.Input) {
				input.DeliveryResult.Commitment =
					pb.InputDeliveryResult_COMMITMENT_POSSIBLY_COMMITTED
			},
			want: "delivery commitment",
		},
		{
			name: "zero posts",
			mutate: func(input *pb.Input) {
				input.DeliveryResult.PostedEventCount = 0
			},
			want: "no posted events",
		},
		{
			name: "unobserved route",
			mutate: func(input *pb.Input) {
				input.DeliveryResult.RoutedDeliveryObserved = false
			},
			want: "routed delivery was not observed",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := proto.Clone(valid).(*pb.Input)
			test.mutate(response)
			result := incompleteInputResult(response, request, "move")
			if result == nil || !strings.Contains(resultText(result), test.want) {
				t.Fatalf("result = %#v, want error containing %q", result, test.want)
			}
		})
	}

	for _, test := range []struct {
		name    string
		request *pb.CreateInputRequest
		want    string
	}{
		{name: "nil request", want: "lost its exact input request"},
		{
			name: "nil input",
			request: &pb.CreateInputRequest{
				Parent:  request.GetParent(),
				InputId: request.GetInputId(),
			},
			want: "lost its exact input request",
		},
		{
			name: "empty input id",
			request: &pb.CreateInputRequest{
				Parent: request.GetParent(),
				Input:  request.GetInput(),
			},
			want: "lost its exact input request",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			result := incompleteInputResult(valid, test.request, "move")
			if result == nil || !strings.Contains(resultText(result), test.want) {
				t.Fatalf("result = %#v, want error containing %q", result, test.want)
			}
		})
	}
}

func requireInputEnumValue(
	t *testing.T,
	enum protoreflect.EnumDescriptor,
	name protoreflect.Name,
) {
	t.Helper()
	if enum == nil || enum.Values().ByName(name) == nil {
		t.Errorf("enum value %s is absent", name)
	}
}

func requireInputOneofFields(
	t *testing.T,
	oneof protoreflect.OneofDescriptor,
	want []protoreflect.Name,
) {
	t.Helper()
	got := make([]protoreflect.Name, 0, oneof.Fields().Len())
	for index := 0; index < oneof.Fields().Len(); index++ {
		got = append(got, oneof.Fields().Get(index).Name())
	}
	if len(got) != len(want) {
		t.Fatalf("oneof fields = %v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("oneof fields = %v, want %v", got, want)
		}
	}
}

func containsInputString(values []string, want string) bool {
	return slices.Contains(values, want)
}

func findInputExecutionTool(t *testing.T, name string) *Tool {
	t.Helper()
	server := newTestServer()
	server.registerTools()
	tool := server.tools[name]
	if tool == nil {
		t.Fatalf("tool %s is absent", name)
	}
	return tool
}
