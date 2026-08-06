// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestClipboardContractRequiresContentAndReturnsObservedResources(t *testing.T) {
	service := pb.File_macosusesdk_v1_macos_use_proto.Services().ByName("MacosUse")
	if service == nil {
		t.Fatal("MacosUse descriptor is missing")
	}
	write := service.Methods().ByName("WriteClipboard")
	clear := service.Methods().ByName("ClearClipboard")
	if write == nil || clear == nil {
		t.Fatal("clipboard method descriptors are missing")
	}
	content := write.Input().Fields().ByName("content")
	if content == nil {
		t.Fatal("WriteClipboardRequest.content is missing")
	}
	if !publicFieldHasBehavior(content, annotations.FieldBehavior_REQUIRED) {
		t.Error("WriteClipboardRequest.content must be REQUIRED")
	}
	const writeResponse = "macosusesdk.v1.WriteClipboardResponse"
	if got := string(write.Output().FullName()); got != writeResponse {
		t.Errorf("WriteClipboard output = %q, want %q", got, writeResponse)
	}
	const clearResponse = "macosusesdk.v1.ClearClipboardResponse"
	if got := string(clear.Output().FullName()); got != clearResponse {
		t.Errorf("ClearClipboard output = %q, want %q", got, clearResponse)
	}
	for methodName, output := range map[string]protoreflect.MessageDescriptor{
		"WriteClipboard": write.Output(),
		"ClearClipboard": clear.Output(),
	} {
		if output.Fields().Len() != 1 {
			t.Errorf("%s response fields = %d, want exact observed clipboard only", methodName, output.Fields().Len())
			continue
		}
		field := output.Fields().ByName("clipboard")
		if field == nil ||
			field.Message() == nil ||
			string(field.Message().FullName()) != "macosusesdk.v1.Clipboard" {
			t.Errorf("%s response clipboard field is missing or has the wrong type", methodName)
		} else if !publicFieldHasBehavior(field, annotations.FieldBehavior_OUTPUT_ONLY) {
			t.Errorf("%s response clipboard field must be OUTPUT_ONLY", methodName)
		}
	}
}

func TestClipboardToolDistinguishesOmittedAndDeliberateEmptyText(t *testing.T) {
	var requests []*pb.WriteClipboardRequest
	client := &clipboardTruthClient{
		writeClipboard: func(
			_ context.Context,
			request *pb.WriteClipboardRequest,
		) (*pb.WriteClipboardResponse, error) {
			requests = append(requests, request)
			return &pb.WriteClipboardResponse{
				Clipboard: clipboardTruthTextResource(request.GetContent().GetText()),
			}, nil
		},
	}
	server := newTestMCPServer(client)

	omitted, err := server.handleClipboard(&ToolCall{
		Arguments: json.RawMessage(`{"action":"set"}`),
	})
	if err != nil {
		t.Fatalf("omitted text returned transport error: %v", err)
	}
	if !resultIsError(omitted) {
		t.Fatal("omitted text must be rejected")
	}
	if len(requests) != 0 {
		t.Fatalf("omitted text reached backend %d times", len(requests))
	}

	empty, err := server.handleClipboard(&ToolCall{
		Arguments: json.RawMessage(`{"action":"set","text":""}`),
	})
	if err != nil {
		t.Fatalf("empty text returned transport error: %v", err)
	}
	if resultIsError(empty) {
		t.Fatalf("deliberate empty text was rejected: %s", resultText(empty))
	}
	if len(requests) != 1 {
		t.Fatalf("empty text backend calls = %d, want 1", len(requests))
	}
	content := requests[0].GetContent()
	if content == nil {
		t.Fatal("empty text request omitted ClipboardContent")
	}
	text, ok := content.GetContent().(*pb.ClipboardContent_Text)
	if !ok {
		t.Fatalf("empty text oneof = %T, want text", content.GetContent())
	}
	if text.Text != "" {
		t.Errorf("empty text payload = %q, want empty", text.Text)
	}
}

func TestClipboardToolHasNoInventedTextCapAndDoesNotEchoContent(t *testing.T) {
	const secret = "clipboard-secret-that-must-never-be-echoed"
	large := secret + strings.Repeat("한🙂", 400_000)
	client := &clipboardTruthClient{
		writeClipboard: func(
			_ context.Context,
			request *pb.WriteClipboardRequest,
		) (*pb.WriteClipboardResponse, error) {
			return &pb.WriteClipboardResponse{
				Clipboard: clipboardTruthTextResource(request.GetContent().GetText()),
			}, nil
		},
	}
	server := newTestMCPServer(client)
	encoded, err := json.Marshal(map[string]any{
		"action": "set",
		"text":   large,
	})
	if err != nil {
		t.Fatalf("marshal clipboard request: %v", err)
	}

	result, err := server.handleClipboard(&ToolCall{Arguments: encoded})
	if err != nil {
		t.Fatalf("large clipboard text returned transport error: %v", err)
	}
	if resultIsError(result) {
		t.Fatalf("large clipboard text was rejected: %s", resultText(result))
	}
	if strings.Contains(resultText(result), secret) {
		t.Fatalf("clipboard success echoed private content: %q", resultText(result))
	}
}

func TestClipboardToolRejectsUntruthfulMutationResponses(t *testing.T) {
	t.Run("write response substitutes content", func(t *testing.T) {
		server := newTestMCPServer(&clipboardTruthClient{
			writeClipboard: func(
				_ context.Context,
				_ *pb.WriteClipboardRequest,
			) (*pb.WriteClipboardResponse, error) {
				return &pb.WriteClipboardResponse{
					Clipboard: clipboardTruthTextResource("substituted"),
				}, nil
			},
		})

		result, err := server.handleClipboard(&ToolCall{
			Arguments: json.RawMessage(`{"action":"set","text":"truth"}`),
		})
		if err != nil {
			t.Fatalf("write returned transport error: %v", err)
		}
		if !resultIsError(result) {
			t.Fatalf("untruthful write response claimed success: %s", resultText(result))
		}
	})

	t.Run("clear response retains content", func(t *testing.T) {
		server := newTestMCPServer(&clipboardTruthClient{
			clearClipboard: func(
				_ context.Context,
				_ *pb.ClearClipboardRequest,
			) (*pb.ClearClipboardResponse, error) {
				return &pb.ClearClipboardResponse{
					Clipboard: clipboardTruthTextResource("residual"),
				}, nil
			},
		})

		result, err := server.handleClipboard(&ToolCall{
			Arguments: json.RawMessage(`{"action":"clear"}`),
		})
		if err != nil {
			t.Fatalf("clear returned transport error: %v", err)
		}
		if !resultIsError(result) {
			t.Fatalf("untruthful clear response claimed success: %s", resultText(result))
		}
	})
}

func TestClipboardResourceCurrentUsesCanonicalSingletonName(t *testing.T) {
	var captured string
	server := newTestMCPServer(&clipboardTruthClient{
		getClipboard: func(
			_ context.Context,
			request *pb.GetClipboardRequest,
		) (*pb.Clipboard, error) {
			captured = request.GetName()
			return &pb.Clipboard{Name: "clipboard"}, nil
		},
	})

	contents, err := server.readResource(context.Background(), "clipboard://current")
	if err != nil {
		t.Fatalf("read clipboard resource: %v", err)
	}
	if captured != "clipboard" {
		t.Errorf("GetClipboard name = %q, want clipboard", captured)
	}
	if len(contents) != 1 {
		t.Fatalf("clipboard resource blocks = %d, want 1", len(contents))
	}
}

func TestClipboardToolDistinguishesAbsentContentFromPresentEmptyText(t *testing.T) {
	tests := []struct {
		name      string
		clipboard *pb.Clipboard
		want      string
	}{
		{
			name:      "absent",
			clipboard: &pb.Clipboard{Name: "clipboard"},
			want:      "Clipboard is empty",
		},
		{
			name: "present empty text",
			clipboard: &pb.Clipboard{
				Name: "clipboard",
				Content: &pb.ClipboardContent{
					Type: pb.ContentType_CONTENT_TYPE_TEXT.Enum(),
					Content: &pb.ClipboardContent_Text{
						Text: "",
					},
				},
				AvailableTypes: []pb.ContentType{pb.ContentType_CONTENT_TYPE_TEXT},
			},
			want: "Clipboard text: 0 characters",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := newTestMCPServer(&clipboardTruthClient{
				getClipboard: func(
					_ context.Context,
					_ *pb.GetClipboardRequest,
				) (*pb.Clipboard, error) {
					return test.clipboard, nil
				},
			})
			result, err := server.handleClipboard(&ToolCall{
				Arguments: json.RawMessage(`{"action":"get"}`),
			})
			if err != nil {
				t.Fatalf("get returned transport error: %v", err)
			}
			if resultIsError(result) {
				t.Fatalf("get returned error result: %s", resultText(result))
			}
			if got := resultText(result); got != test.want {
				t.Errorf("get result = %q, want %q", got, test.want)
			}
		})
	}
}

type clipboardTruthClient struct {
	pb.MacosUseClient
	getClipboard func(
		context.Context,
		*pb.GetClipboardRequest,
	) (*pb.Clipboard, error)
	writeClipboard func(
		context.Context,
		*pb.WriteClipboardRequest,
	) (*pb.WriteClipboardResponse, error)
	clearClipboard func(
		context.Context,
		*pb.ClearClipboardRequest,
	) (*pb.ClearClipboardResponse, error)
}

func (c *clipboardTruthClient) GetClipboard(
	ctx context.Context,
	request *pb.GetClipboardRequest,
	_ ...grpc.CallOption,
) (*pb.Clipboard, error) {
	return c.getClipboard(ctx, request)
}

func (c *clipboardTruthClient) WriteClipboard(
	ctx context.Context,
	request *pb.WriteClipboardRequest,
	_ ...grpc.CallOption,
) (*pb.WriteClipboardResponse, error) {
	return c.writeClipboard(ctx, request)
}

func (c *clipboardTruthClient) ClearClipboard(
	ctx context.Context,
	request *pb.ClearClipboardRequest,
	_ ...grpc.CallOption,
) (*pb.ClearClipboardResponse, error) {
	return c.clearClipboard(ctx, request)
}

func clipboardTruthTextResource(text string) *pb.Clipboard {
	return &pb.Clipboard{
		Name: "clipboard",
		Content: &pb.ClipboardContent{
			Type: pb.ContentType_CONTENT_TYPE_TEXT.Enum(),
			Content: &pb.ClipboardContent_Text{
				Text: text,
			},
		},
		AvailableTypes: []pb.ContentType{pb.ContentType_CONTENT_TYPE_TEXT},
	}
}
