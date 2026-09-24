package server

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	pb "github.com/joeycumines/ExactMac/gen/go/exactmac/v1"
	"google.golang.org/grpc"
)

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
