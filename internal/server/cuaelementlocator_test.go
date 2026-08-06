package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
)

func TestFindElementsUsesOneCanonicalSelector(t *testing.T) {
	var request *pb.FindElementsRequest
	server := newTestMCPServer(&mockMacosUseClient{
		findElementsFunc: func(_ context.Context, incoming *pb.FindElementsRequest) (*pb.FindElementsResponse, error) {
			request = incoming
			return &pb.FindElementsResponse{
				Elements: []*pb.Element{{ElementId: "stable-id", Role: "AXButton"}},
			}, nil
		},
	})

	result, err := server.cuaHandleFindElements(&ToolCall{
		Name:      "find_elements",
		Arguments: json.RawMessage(`{"parent":"applications/exact/windows/window-a","selector":"text_contains:Save","force_refresh":true,"page_size":7}`),
	})
	if err != nil {
		t.Fatalf("cuaHandleFindElements returned error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("cuaHandleFindElements returned tool error: %s", resultText(result))
	}
	if request == nil {
		t.Fatal("FindElements was not called")
	}
	if request.GetParent() != "applications/exact/windows/window-a" || !request.GetForceRefresh() || request.GetPageSize() != 7 {
		t.Fatalf("FindElements request metadata mismatch: %+v", request)
	}
	want := &typepb.ElementSelector_TextContains{TextContains: "Save"}
	if got, ok := request.GetSelector().GetCriteria().(*typepb.ElementSelector_TextContains); !ok || got.TextContains != want.TextContains {
		t.Fatalf("FindElements selector = %#v, want %#v", request.GetSelector().GetCriteria(), want)
	}
}

func TestFindElementsRejectsMissingOrLegacyCriteriaBeforeGRPC(t *testing.T) {
	server := newTestServer()
	for _, arguments := range []string{
		`{"parent":"applications/exact"}`,
		`{"parent":"applications/exact","role":"AXButton"}`,
		`{"parent":"applications/exact","text":"Save"}`,
		`{"parent":"applications/exact","text_contains":"Save"}`,
	} {
		result, err := server.cuaHandleFindElements(&ToolCall{
			Name:      "find_elements",
			Arguments: json.RawMessage(arguments),
		})
		if err != nil {
			t.Fatalf("cuaHandleFindElements(%s) returned error: %v", arguments, err)
		}
		if !resultIsError(result) {
			t.Fatalf("cuaHandleFindElements(%s) = %#v, want tool error", arguments, result)
		}
	}
}

func TestFindElementsSchemaAdvertisesOnlyCanonicalSelector(t *testing.T) {
	server := newTestMCPServer(&mockMacosUseClient{})
	server.registerTools()
	tool, ok := server.tools["find_elements"]
	if !ok {
		t.Fatal("find_elements is not registered")
	}
	properties, ok := tool.InputSchema["properties"].(map[string]any)
	if !ok {
		t.Fatalf("find_elements properties = %#v", tool.InputSchema["properties"])
	}
	if _, ok := properties["selector"]; !ok {
		t.Fatal("find_elements schema does not advertise selector")
	}
	for _, removed := range []string{"role", "text", "text_contains"} {
		if _, ok := properties[removed]; ok {
			t.Fatalf("find_elements schema retains ignored field %q", removed)
		}
	}
}

func TestElementGuidanceMatchesCanonicalSelectorAndScopeBoundHandles(t *testing.T) {
	server := newTestMCPServer(&mockMacosUseClient{})
	server.registerTools()

	prompts := server.listPrompts()
	if len(prompts) == 0 {
		t.Fatal("listPrompts returned no prompts")
	}
	arguments, ok := prompts[0]["arguments"].([]map[string]any)
	if !ok || len(arguments) != 1 {
		t.Fatalf("navigate_to_element arguments = %#v", prompts[0]["arguments"])
	}
	description, _ := arguments[0]["description"].(string)
	if !strings.Contains(description, "key:value") {
		t.Fatalf("selector argument description = %q, want canonical key:value form", description)
	}

	prompt, err := server.getPrompt("navigate_to_element", map[string]any{"selector": "role:AXButton"})
	if err != nil {
		t.Fatalf("getPrompt returned error: %v", err)
	}
	messages, ok := prompt["messages"].([]map[string]any)
	if !ok || len(messages) != 1 {
		t.Fatalf("navigate_to_element messages = %#v", prompt["messages"])
	}
	content, _ := messages[0]["content"].(map[string]any)
	text, _ := content["text"].(string)
	for _, required := range []string{
		`"selector": "role:AXButton"`,
		"exact parent and AX identity",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("navigate_to_element prompt missing %q:\n%s", required, text)
		}
	}
	if strings.Contains(text, `"role": "button"`) || strings.Contains(text, "flat top-level fields") {
		t.Fatalf("navigate_to_element prompt retains legacy flat locator guidance:\n%s", text)
	}

	for _, toolName := range []string{"click_element", "type_element"} {
		tool := server.tools[toolName]
		if tool == nil {
			t.Fatalf("%s is not registered", toolName)
		}
		if strings.Contains(tool.Description, "ephemeral") || !strings.Contains(tool.Description, "parent-bound AX identity") {
			t.Fatalf("%s description is not scope-bound: %q", toolName, tool.Description)
		}
	}
}

func TestReadElementCanonicalizesOpaqueWindowParent(t *testing.T) {
	var elementName string
	var actionsName string
	server := newTestMCPServer(&mockMacosUseClient{
		getElementFunc: func(_ context.Context, request *pb.GetElementRequest) (*pb.Element, error) {
			elementName = request.GetName()
			return &pb.Element{
				Name:      request.GetName(),
				ElementId: "exact-handle",
				Role:      "AXButton",
			}, nil
		},
		getElementActionsFunc: func(
			_ context.Context,
			request *pb.GetElementActionsRequest,
			_ ...grpc.CallOption,
		) (*pb.ElementActions, error) {
			actionsName = request.GetName()
			return &pb.ElementActions{}, nil
		},
	})

	result, err := server.handleReadElement(&ToolCall{
		Name:      "read_element",
		Arguments: json.RawMessage(`{"parent":"applications/process-instance/windows/window-generation","element":"exact-handle"}`),
	})
	if err != nil {
		t.Fatalf("handleReadElement returned error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("handleReadElement returned tool error: %s", resultText(result))
	}
	const want = "applications/process-instance/elements/exact-handle"
	if elementName != want || actionsName != want {
		t.Fatalf("element requests = (%q, %q), want (%q, %q)", elementName, actionsName, want, want)
	}
}

func TestApplicationParentResourcePreservesOpaqueProcessIdentity(t *testing.T) {
	for _, test := range []struct {
		parent string
		want   string
		ok     bool
	}{
		{"applications/process-instance", "applications/process-instance", true},
		{"applications/process-instance/windows/window-generation", "applications/process-instance", true},
		{" applications/process-instance/windows/window-generation ", "applications/process-instance", true},
		{"windows/window-generation", "", false},
		{"applications//windows/window-generation", "", false},
	} {
		got, ok := applicationParentResource(test.parent)
		if got != test.want || ok != test.ok {
			t.Fatalf("applicationParentResource(%q) = (%q, %t), want (%q, %t)", test.parent, got, ok, test.want, test.ok)
		}
	}
}
