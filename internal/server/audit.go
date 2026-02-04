// Copyright 2025 Joseph Cumines
//
// Audit logging for MCP tool invocations

package server

import (
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"
)

// AuditLogger provides structured audit logging for tool invocations.
// It logs tool name, redacted arguments, result status, and duration.
// Uses log/slog for structured JSON output.
type AuditLogger struct {
	logger  *slog.Logger
	file    *os.File
	enabled bool
	mu      sync.RWMutex
}

// redactedKeys is the list of argument keys that should be redacted in audit logs.
var redactedKeys = map[string]bool{
	"password":          true,
	"secret":            true,
	"token":             true,
	"api_key":           true,
	"apikey":            true,
	"credential":        true,
	"credentials":       true,
	"private_key":       true,
	"privatekey":        true,
	"access_token":      true,
	"refresh_token":     true,
	"authorization":     true,
	"auth":              true,
	"bearer":            true,
	"session_id":        true,
	"cookie":            true,
	"passphrase":        true,
	"encryption_key":    true,
	"decryption_key":    true,
}

// NewAuditLogger creates a new audit logger that writes to the specified file.
// If filePath is empty, audit logging is disabled. Returns an error if the
// file cannot be opened.
func NewAuditLogger(filePath string) (*AuditLogger, error) {
	if filePath == "" {
		return &AuditLogger{enabled: false}, nil
	}

	file, err := os.OpenFile(filePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return nil, err
	}

	handler := slog.NewJSONHandler(file, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})

	return &AuditLogger{
		logger:  slog.New(handler),
		file:    file,
		enabled: true,
	}, nil
}

// Close closes the audit log file if it is open.
// Safe to call multiple times. Returns any error from closing the file.
func (a *AuditLogger) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.file != nil {
		return a.file.Close()
	}
	return nil
}

// IsEnabled returns true if audit logging is enabled (file path was provided).
func (a *AuditLogger) IsEnabled() bool {
	if a == nil {
		return false
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.enabled
}

// LogToolCall logs a tool invocation with redacted arguments.
// Sensitive fields like passwords and tokens are automatically redacted.
func (a *AuditLogger) LogToolCall(tool string, args json.RawMessage, status string, duration time.Duration) {
	if !a.IsEnabled() {
		return
	}

	a.mu.RLock()
	logger := a.logger
	a.mu.RUnlock()

	if logger == nil {
		return
	}

	// Redact sensitive arguments
	redactedArgs := redactArguments(args)

	logger.Info("tool_invocation",
		slog.String("tool", tool),
		slog.String("arguments", redactedArgs),
		slog.String("status", status),
		slog.Float64("duration_seconds", duration.Seconds()),
		slog.Time("timestamp", time.Now().UTC()),
	)
}

// redactArguments redacts sensitive values from JSON arguments.
func redactArguments(args json.RawMessage) string {
	if len(args) == 0 {
		return "{}"
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(args, &parsed); err != nil {
		// Can't parse, return placeholder
		return "[unparseable]"
	}

	redactMapValues(parsed)

	redacted, err := json.Marshal(parsed)
	if err != nil {
		return "[error]"
	}
	return string(redacted)
}

// redactMapValues recursively redacts sensitive values in a map.
func redactMapValues(m map[string]interface{}) {
	for key, value := range m {
		lowerKey := strings.ToLower(key)
		
		// Check if key should be redacted
		if redactedKeys[lowerKey] {
			m[key] = "[REDACTED]"
			continue
		}

		// Check for partial matches
		for redactKey := range redactedKeys {
			if strings.Contains(lowerKey, redactKey) {
				m[key] = "[REDACTED]"
				break
			}
		}

		// Recurse into nested maps
		if nested, ok := value.(map[string]interface{}); ok {
			redactMapValues(nested)
		}

		// Handle arrays
		if arr, ok := value.([]interface{}); ok {
			for _, item := range arr {
				if nestedMap, ok := item.(map[string]interface{}); ok {
					redactMapValues(nestedMap)
				}
			}
		}
	}
}
