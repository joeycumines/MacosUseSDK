// Copyright 2025 Joseph Cumines
//
// Audit logger unit tests

package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNewAuditLogger_Disabled(t *testing.T) {
	logger, err := NewAuditLogger("")
	if err != nil {
		t.Fatalf("NewAuditLogger('') error = %v", err)
	}
	if logger.IsEnabled() {
		t.Error("Expected logger to be disabled when no file path provided")
	}
}

func TestNewAuditLogger_Enabled(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	if !logger.IsEnabled() {
		t.Error("Expected logger to be enabled")
	}
}

func TestNewAuditLogger_InvalidPath(t *testing.T) {
	// Try to create log in non-existent directory without creating it
	_, err := NewAuditLogger("/nonexistent/directory/that/doesnt/exist/audit.log")
	if err == nil {
		t.Error("Expected error for invalid path")
	}
}

func TestAuditLogger_LogToolCall(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Log a tool call
	args := json.RawMessage(`{"x": 100, "y": 200}`)
	logger.LogToolCall("click", args, "success", 50*time.Millisecond)

	// Close to flush
	logger.Close()

	// Read the log file
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	logStr := string(content)
	if !strings.Contains(logStr, `"tool":"click"`) {
		t.Errorf("Log should contain tool name, got: %s", logStr)
	}
	if !strings.Contains(logStr, `"status":"success"`) {
		t.Errorf("Log should contain status, got: %s", logStr)
	}
	if !strings.Contains(logStr, `"msg":"tool_invocation"`) {
		t.Errorf("Log should contain message type, got: %s", logStr)
	}
}

func TestAuditLogger_LogToolCall_Disabled(t *testing.T) {
	logger, err := NewAuditLogger("")
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Should not panic when disabled
	args := json.RawMessage(`{"x": 100}`)
	logger.LogToolCall("click", args, "success", 50*time.Millisecond)
}

func TestAuditLogger_NilLogger(t *testing.T) {
	var logger *AuditLogger = nil

	if logger.IsEnabled() {
		t.Error("Nil logger should not be enabled")
	}

	// Should not panic
	args := json.RawMessage(`{}`)
	logger.LogToolCall("click", args, "success", 50*time.Millisecond)
}

func TestRedactArguments(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected []string // strings that should appear in output
		excluded []string // strings that should NOT appear in output
	}{
		{
			name:     "no sensitive data",
			input:    `{"x": 100, "y": 200}`,
			expected: []string{"100", "200"},
			excluded: []string{"REDACTED"},
		},
		{
			name:     "password field",
			input:    `{"username": "user", "password": "secret123"}`,
			expected: []string{"user", "REDACTED"},
			excluded: []string{"secret123"},
		},
		{
			name:     "api_key field",
			input:    `{"data": "value", "api_key": "sk-12345"}`,
			expected: []string{"value", "REDACTED"},
			excluded: []string{"sk-12345"},
		},
		{
			name:     "token field",
			input:    `{"token": "eyJhbGc...", "name": "test"}`,
			expected: []string{"test", "REDACTED"},
			excluded: []string{"eyJhbGc"},
		},
		{
			name:     "nested sensitive",
			input:    `{"config": {"secret": "hidden"}}`,
			expected: []string{"REDACTED"},
			excluded: []string{"hidden"},
		},
		{
			name:     "partial match",
			input:    `{"my_password_field": "value123"}`,
			expected: []string{"REDACTED"},
			excluded: []string{"value123"},
		},
		{
			name:     "empty args",
			input:    ``,
			expected: []string{"{}"},
			excluded: []string{},
		},
		{
			name:     "invalid json",
			input:    `{invalid}`,
			expected: []string{"unparseable"},
			excluded: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := redactArguments(json.RawMessage(tt.input))

			for _, exp := range tt.expected {
				if !strings.Contains(result, exp) {
					t.Errorf("Expected %q in result, got: %s", exp, result)
				}
			}

			for _, exc := range tt.excluded {
				if strings.Contains(result, exc) {
					t.Errorf("Should NOT contain %q, got: %s", exc, result)
				}
			}
		})
	}
}

func TestRedactMapValues_CaseInsensitive(t *testing.T) {
	m := map[string]interface{}{
		"PASSWORD":  "secret1",
		"Password":  "secret2",
		"pAsSwOrD":  "secret3",
		"safe_data": "visible",
	}

	redactMapValues(m)

	if m["PASSWORD"] != "[REDACTED]" {
		t.Errorf("PASSWORD should be redacted, got: %v", m["PASSWORD"])
	}
	if m["Password"] != "[REDACTED]" {
		t.Errorf("Password should be redacted, got: %v", m["Password"])
	}
	if m["pAsSwOrD"] != "[REDACTED]" {
		t.Errorf("pAsSwOrD should be redacted, got: %v", m["pAsSwOrD"])
	}
	if m["safe_data"] != "visible" {
		t.Errorf("safe_data should NOT be redacted, got: %v", m["safe_data"])
	}
}

func TestRedactMapValues_ArrayOfMaps(t *testing.T) {
	m := map[string]interface{}{
		"items": []interface{}{
			map[string]interface{}{
				"name":     "item1",
				"password": "secret",
			},
		},
	}

	redactMapValues(m)

	items := m["items"].([]interface{})
	item := items[0].(map[string]interface{})
	if item["password"] != "[REDACTED]" {
		t.Errorf("Nested password in array should be redacted, got: %v", item["password"])
	}
	if item["name"] != "item1" {
		t.Errorf("name should NOT be redacted, got: %v", item["name"])
	}
}
