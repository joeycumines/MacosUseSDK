package server

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

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
