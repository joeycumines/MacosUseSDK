// Copyright 2025 Joseph Cumines
//
// Audit logger unit tests

package server

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
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
	m := map[string]any{
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
	m := map[string]any{
		"items": []any{
			map[string]any{
				"name":     "item1",
				"password": "secret",
			},
		},
	}

	redactMapValues(m)

	items := m["items"].([]any)
	item := items[0].(map[string]any)
	if item["password"] != "[REDACTED]" {
		t.Errorf("Nested password in array should be redacted, got: %v", item["password"])
	}
	if item["name"] != "item1" {
		t.Errorf("name should NOT be redacted, got: %v", item["name"])
	}
}

// TestAuditLogger_ConcurrentWrites verifies that multiple goroutines can write
// to the audit logger concurrently without causing data corruption or races.
func TestAuditLogger_ConcurrentWrites(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "concurrent_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	const numGoroutines = 10
	const writesPerGoroutine = 50

	var wg sync.WaitGroup
	wg.Add(numGoroutines)

	for i := range numGoroutines {
		go func(goroutineID int) {
			defer wg.Done()
			for j := range writesPerGoroutine {
				args := json.RawMessage(`{"goroutine":` + string(rune('0'+goroutineID%10)) + `}`)
				logger.LogToolCall("concurrent_test", args, "success", time.Duration(j)*time.Millisecond)
			}
		}(i)
	}

	wg.Wait()

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	// Verify all lines are valid JSON and count them
	file, err := os.Open(logPath)
	if err != nil {
		t.Fatalf("Open error = %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineCount := 0
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		lineCount++

		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d is not valid JSON: %v\nContent: %s", lineCount, err, line)
		}
	}

	if err := scanner.Err(); err != nil {
		t.Fatalf("Scanner error = %v", err)
	}

	expectedLines := numGoroutines * writesPerGoroutine
	if lineCount != expectedLines {
		t.Errorf("Expected %d log lines, got %d", expectedLines, lineCount)
	}
}

// TestAuditLogger_JSONFormatValidation verifies that each line in the audit log
// is valid JSON and can be parsed.
func TestAuditLogger_JSONFormatValidation(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "json_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Write various tool calls with different argument structures
	testCases := []struct {
		tool   string
		args   string
		status string
	}{
		{"click", `{"x": 100, "y": 200}`, "success"},
		{"type_text", `{"text": "hello world"}`, "success"},
		{"screenshot", `{}`, "error"},
		{"move_window", `{"window_id": 123, "x": 0, "y": 0}`, "success"},
		{"complex_args", `{"nested": {"a": 1, "b": [1,2,3]}, "array": ["x","y"]}`, "success"},
	}

	for _, tc := range testCases {
		logger.LogToolCall(tc.tool, json.RawMessage(tc.args), tc.status, 100*time.Millisecond)
	}

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	// Read and validate each line
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != len(testCases) {
		t.Fatalf("Expected %d log lines, got %d", len(testCases), len(lines))
	}

	for i, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d is not valid JSON: %v\nContent: %s", i+1, err, line)
			continue
		}

		// Verify it has the expected tool name
		if tool, ok := entry["tool"].(string); !ok || tool != testCases[i].tool {
			t.Errorf("Line %d: expected tool=%q, got %v", i+1, testCases[i].tool, entry["tool"])
		}
	}
}

// TestAuditLogger_CloseIdempotency verifies that calling Close() multiple times
// does not panic or return unexpected errors (except for "already closed" which is acceptable).
func TestAuditLogger_CloseIdempotency(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "idempotent_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Write something
	args := json.RawMessage(`{"test": true}`)
	logger.LogToolCall("test_tool", args, "success", 10*time.Millisecond)

	// First close should succeed
	err1 := logger.Close()
	if err1 != nil {
		t.Errorf("First Close() error = %v", err1)
	}

	// Second close should not panic
	// It may return an error (e.g., "file already closed") but should not panic
	err2 := logger.Close()
	// We don't assert on err2 value because behavior may vary,
	// but we verify no panic occurred by reaching this line
	_ = err2

	// Third close for good measure
	err3 := logger.Close()
	_ = err3

	// Verify file content is intact
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}
	if !strings.Contains(string(content), "test_tool") {
		t.Error("Log file should contain test_tool entry")
	}
}

// TestAuditLogger_CloseIdempotency_Disabled verifies Close() on disabled logger is safe.
func TestAuditLogger_CloseIdempotency_Disabled(t *testing.T) {
	logger, err := NewAuditLogger("")
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Close on disabled logger should be safe
	if err := logger.Close(); err != nil {
		t.Errorf("Close on disabled logger error = %v", err)
	}

	// Multiple closes should be safe
	if err := logger.Close(); err != nil {
		t.Errorf("Second Close on disabled logger error = %v", err)
	}
}

// TestAuditLogger_LogEntryFields verifies that each log entry contains all required fields.
func TestAuditLogger_LogEntryFields(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "fields_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	args := json.RawMessage(`{"x": 100, "y": 200}`)
	logger.LogToolCall("click", args, "success", 150*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("JSON unmarshal error = %v", err)
	}

	// Required fields per slog.JSONHandler output
	requiredFields := []string{
		"time",             // slog adds this automatically
		"level",            // slog adds this automatically
		"msg",              // the message ("tool_invocation")
		"tool",             // tool name
		"arguments",        // redacted arguments
		"status",           // success/error
		"duration_seconds", // duration in seconds
		"timestamp",        // explicit timestamp we add
	}

	for _, field := range requiredFields {
		if _, exists := entry[field]; !exists {
			t.Errorf("Missing required field: %s\nEntry: %v", field, entry)
		}
	}

	// Verify specific field values
	if msg, ok := entry["msg"].(string); !ok || msg != "tool_invocation" {
		t.Errorf("Expected msg='tool_invocation', got %v", entry["msg"])
	}

	if tool, ok := entry["tool"].(string); !ok || tool != "click" {
		t.Errorf("Expected tool='click', got %v", entry["tool"])
	}

	if status, ok := entry["status"].(string); !ok || status != "success" {
		t.Errorf("Expected status='success', got %v", entry["status"])
	}

	// Verify duration is approximately correct (0.15 seconds)
	if dur, ok := entry["duration_seconds"].(float64); !ok || dur < 0.14 || dur > 0.16 {
		t.Errorf("Expected duration_seconds ~0.15, got %v", entry["duration_seconds"])
	}

	// Verify arguments are present (should contain the JSON)
	if args, ok := entry["arguments"].(string); !ok || !strings.Contains(args, "100") {
		t.Errorf("Expected arguments to contain '100', got %v", entry["arguments"])
	}
}

// TestAuditLogger_WriteAfterClose verifies behavior when writing after close.
func TestAuditLogger_WriteAfterClose(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "write_after_close.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Write before close
	args := json.RawMessage(`{"before": true}`)
	logger.LogToolCall("before", args, "success", 10*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	// Write after close - should not panic
	// The logger may silently fail or error, but should not panic
	args2 := json.RawMessage(`{"after": true}`)
	logger.LogToolCall("after", args2, "success", 10*time.Millisecond)

	// Verify file exists and has the "before" entry
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	if !strings.Contains(string(content), "before") {
		t.Error("Log should contain 'before' entry")
	}
}

// TestAuditLogger_WriteFailure_ReadOnlyFile tests behavior when the log file
// becomes unwritable (simulating disk full or permission issues).
func TestAuditLogger_WriteFailure_ReadOnlyFile(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "readonly_audit.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Write one entry successfully
	args := json.RawMessage(`{"first": true}`)
	logger.LogToolCall("first", args, "success", 10*time.Millisecond)

	// Make the file read-only
	if err := os.Chmod(logPath, 0444); err != nil {
		t.Fatalf("Chmod error = %v", err)
	}
	// Restore permissions for cleanup
	defer os.Chmod(logPath, 0644)

	// Attempt to write - the logger uses slog which may buffer or silently fail
	// We mainly want to ensure no panic occurs
	args2 := json.RawMessage(`{"second": true}`)
	logger.LogToolCall("second", args2, "success", 10*time.Millisecond)

	// The test passes if we reach here without panic
}

// TestAuditLogger_InvalidPath_PermissionDenied tests error handling for permission denied.
func TestAuditLogger_InvalidPath_PermissionDenied(t *testing.T) {
	// Skip on systems where we can't create restricted directories
	tmpDir := t.TempDir()
	restrictedDir := filepath.Join(tmpDir, "restricted")

	if err := os.Mkdir(restrictedDir, 0000); err != nil {
		t.Fatalf("Mkdir error = %v", err)
	}
	defer os.Chmod(restrictedDir, 0755) // Restore for cleanup

	logPath := filepath.Join(restrictedDir, "audit.log")
	_, err := NewAuditLogger(logPath)
	if err == nil {
		t.Error("Expected permission denied error")
	}
}

// TestAuditLogger_LargeArgumentRedaction tests redaction of large argument payloads.
func TestAuditLogger_LargeArgumentRedaction(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "large_args.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Create a large argument with a secret somewhere in the middle
	largeData := make(map[string]any)
	for i := range 100 {
		largeData[string(rune('a'+i%26))+string(rune('0'+i/26))] = i
	}
	largeData["deeply_nested_password"] = "super_secret_value"
	largeData["normal_field"] = strings.Repeat("x", 1000)

	argsBytes, _ := json.Marshal(largeData)
	logger.LogToolCall("large_tool", json.RawMessage(argsBytes), "success", 100*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	logStr := string(content)

	// Should not contain the secret
	if strings.Contains(logStr, "super_secret_value") {
		t.Error("Log should NOT contain 'super_secret_value'")
	}

	// Should contain REDACTED indicator
	if !strings.Contains(logStr, "REDACTED") {
		t.Error("Log should contain REDACTED for password field")
	}

	// Should contain normal data
	if !strings.Contains(logStr, strings.Repeat("x", 100)) {
		t.Error("Log should contain normal_field data")
	}
}

// TestAuditLogger_EmptyToolName tests handling of empty tool names.
func TestAuditLogger_EmptyToolName(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "empty_tool.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}
	defer logger.Close()

	// Empty tool name should still work
	args := json.RawMessage(`{}`)
	logger.LogToolCall("", args, "success", 10*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("JSON unmarshal error = %v", err)
	}

	if entry["tool"] != "" {
		t.Errorf("Expected empty tool name, got %v", entry["tool"])
	}
}

// TestAuditLogger_SpecialCharactersInArguments tests JSON escaping of special characters.
func TestAuditLogger_SpecialCharactersInArguments(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "special_chars.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	// Arguments with special characters that need JSON escaping
	args := json.RawMessage(`{"text": "line1\nline2\ttab", "quote": "say \"hello\"", "unicode": "日本語"}`)
	logger.LogToolCall("special", args, "success", 10*time.Millisecond)

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	// Should be valid JSON
	var entry map[string]any
	if err := json.Unmarshal(content, &entry); err != nil {
		t.Fatalf("JSON unmarshal error = %v\nContent: %s", err, content)
	}

	// Verify tool was logged
	if entry["tool"] != "special" {
		t.Errorf("Expected tool='special', got %v", entry["tool"])
	}
}

// TestAuditLogger_DurationEdgeCases tests logging with various duration values.
func TestAuditLogger_DurationEdgeCases(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "duration_edge.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	testCases := []struct {
		name     string
		duration time.Duration
	}{
		{"zero", 0},
		{"nanosecond", time.Nanosecond},
		{"microsecond", time.Microsecond},
		{"millisecond", time.Millisecond},
		{"second", time.Second},
		{"minute", time.Minute},
		{"large", 24 * time.Hour},
	}

	for _, tc := range testCases {
		args := json.RawMessage(`{}`)
		logger.LogToolCall(tc.name, args, "success", tc.duration)
	}

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != len(testCases) {
		t.Fatalf("Expected %d lines, got %d", len(testCases), len(lines))
	}

	for i, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d (%s) is not valid JSON: %v", i+1, testCases[i].name, err)
			continue
		}

		dur, ok := entry["duration_seconds"].(float64)
		if !ok {
			t.Errorf("Line %d (%s): duration_seconds not a float64", i+1, testCases[i].name)
			continue
		}

		expectedDur := testCases[i].duration.Seconds()
		if dur != expectedDur {
			t.Errorf("Line %d (%s): expected duration_seconds=%v, got %v", i+1, testCases[i].name, expectedDur, dur)
		}
	}
}

// TestAuditLogger_StatusValues tests various status string values.
func TestAuditLogger_StatusValues(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "status_values.log")

	logger, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger error = %v", err)
	}

	statuses := []string{"success", "error", "timeout", "cancelled", "", "UNKNOWN", "partial_success"}

	for _, status := range statuses {
		args := json.RawMessage(`{}`)
		logger.LogToolCall("status_test", args, status, 10*time.Millisecond)
	}

	if err := logger.Close(); err != nil {
		t.Fatalf("Close error = %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != len(statuses) {
		t.Fatalf("Expected %d lines, got %d", len(statuses), len(lines))
	}

	for i, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Errorf("Line %d is not valid JSON: %v", i+1, err)
			continue
		}

		if entry["status"] != statuses[i] {
			t.Errorf("Line %d: expected status=%q, got %v", i+1, statuses[i], entry["status"])
		}
	}
}

// TestAuditLogger_FileAppendBehavior verifies that logs are appended, not overwritten.
func TestAuditLogger_FileAppendBehavior(t *testing.T) {
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "append_test.log")

	// First logger session
	logger1, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger (1) error = %v", err)
	}

	args := json.RawMessage(`{}`)
	logger1.LogToolCall("session1", args, "success", 10*time.Millisecond)

	if err := logger1.Close(); err != nil {
		t.Fatalf("Close (1) error = %v", err)
	}

	// Second logger session
	logger2, err := NewAuditLogger(logPath)
	if err != nil {
		t.Fatalf("NewAuditLogger (2) error = %v", err)
	}

	logger2.LogToolCall("session2", args, "success", 10*time.Millisecond)

	if err := logger2.Close(); err != nil {
		t.Fatalf("Close (2) error = %v", err)
	}

	// Verify both entries exist
	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != 2 {
		t.Fatalf("Expected 2 lines (append behavior), got %d", len(lines))
	}

	if !strings.Contains(lines[0], "session1") {
		t.Error("First line should contain 'session1'")
	}
	if !strings.Contains(lines[1], "session2") {
		t.Error("Second line should contain 'session2'")
	}
}
