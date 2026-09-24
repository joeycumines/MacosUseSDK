package server

import (
	"encoding/json"
	"testing"
)

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
