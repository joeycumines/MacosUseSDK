package server

import (
	"strings"
	"testing"
)

func TestParseElementSelector(t *testing.T) {
	// Use string/pointer fields instead of struct values because ElementSelector
	// contains a sync.Mutex (protoimpl.MessageState) and go vet rejects copying it.
	tests := []struct {
		name              string
		input             string
		wantRole          string
		wantText          string
		wantTextSubstring string
		wantErr           string
		wantEmptyRole     bool
	}{
		{
			name:     "role",
			input:    "role:AXTextArea",
			wantRole: "AXTextArea",
		},
		{
			name:     "text",
			input:    "text:hello world",
			wantText: "hello world",
		},
		{
			name:              "text_substring",
			input:             "text_substring:world",
			wantTextSubstring: "world",
		},
		{
			name:    "legacy textcontains alias",
			input:   "textcontains:world",
			wantErr: "unsupported selector key",
		},
		{
			name:    "missing colon",
			input:   "AXTextArea",
			wantErr: "selector must be in the form key:value",
		},
		{
			name:          "empty value is allowed",
			input:         "role:",
			wantEmptyRole: true,
		},
		{
			name:    "unsupported key",
			input:   "foo:bar",
			wantErr: "unsupported selector key",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseElementSelector(tt.input)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tt.wantErr)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("expected error containing %q, got %q", tt.wantErr, err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantEmptyRole {
				if got.GetRole() != "" {
					t.Errorf("role = %q, want empty", got.GetRole())
				}
				return
			}
			switch {
			case tt.wantRole != "":
				if got.GetRole() != tt.wantRole {
					t.Errorf("role = %q, want %q", got.GetRole(), tt.wantRole)
				}
			case tt.wantText != "":
				if got.GetText() != tt.wantText {
					t.Errorf("text = %q, want %q", got.GetText(), tt.wantText)
				}
			case tt.wantTextSubstring != "":
				if got.GetTextSubstring() != tt.wantTextSubstring {
					t.Errorf("textSubstring = %q, want %q", got.GetTextSubstring(), tt.wantTextSubstring)
				}
			default:
				t.Fatalf("no expected criterion set for test case")
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
		{"opaque window parent", "applications/process-instance/windows/window-generation", "btn1", "applications/process-instance/elements/btn1"},
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
