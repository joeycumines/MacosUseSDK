// Copyright 2025 Joseph Cumines
//
// Audit logging for MCP tool invocations

package server

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// AuditLogger provides structured audit logging for tool invocations.
// It logs only non-content metadata: tool name, result status, and duration.
type AuditLogger struct {
	file    *os.File
	enabled bool
	mu      sync.RWMutex
}

type auditEntry struct {
	Time            time.Time `json:"time"`
	Timestamp       time.Time `json:"timestamp"`
	Level           string    `json:"level"`
	Message         string    `json:"msg"`
	Tool            string    `json:"tool"`
	Status          string    `json:"status"`
	DurationSeconds float64   `json:"duration_seconds"`
}

// NewAuditLogger creates a new audit logger that writes to the specified file.
// If filePath is empty, audit logging is disabled. Returns an error if the
// path is not an owner-private, singly linked regular file.
func NewAuditLogger(filePath string) (*AuditLogger, error) {
	if filePath == "" {
		return &AuditLogger{enabled: false}, nil
	}

	file, err := openAuditFile(filePath)
	if err != nil {
		return nil, err
	}

	return &AuditLogger{
		file:    file,
		enabled: true,
	}, nil
}

func openAuditFile(filePath string) (*os.File, error) {
	flags := unix.O_APPEND | unix.O_CLOEXEC | unix.O_CREAT | unix.O_NOFOLLOW | unix.O_NONBLOCK | unix.O_WRONLY
	fd, err := unix.Open(filePath, flags, 0600)
	if err != nil {
		return nil, fmt.Errorf("open audit log %q: %w", filePath, err)
	}
	file := os.NewFile(uintptr(fd), filePath)
	if file == nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("open audit log %q: invalid file descriptor", filePath)
	}

	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("inspect audit log %q: %w", filePath, err)
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFREG {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q is not a regular file", filePath)
	}
	if stat.Nlink != 1 {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q has %d hard links; want exactly one", filePath, stat.Nlink)
	}
	if stat.Uid != uint32(os.Geteuid()) {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q is owned by uid %d; want %d", filePath, stat.Uid, os.Geteuid())
	}
	if permissions := os.FileMode(stat.Mode & 0777); permissions != 0600 {
		_ = file.Close()
		return nil, fmt.Errorf("audit log %q permissions are %#o; want 0600", filePath, permissions)
	}

	return file, nil
}

// Close closes the audit log file if it is open.
// Safe to call multiple times. Returns any error from closing the file.
func (a *AuditLogger) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.file != nil {
		err := a.file.Close()
		a.file = nil
		a.enabled = false
		return err
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

// LogToolCall logs only non-content invocation metadata. Arguments are accepted
// for call-site compatibility but are deliberately never parsed or persisted.
func (a *AuditLogger) LogToolCall(tool string, _ json.RawMessage, status string, duration time.Duration) error {
	if a == nil {
		return nil
	}

	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.enabled || a.file == nil {
		return nil
	}

	now := time.Now().UTC()
	if err := json.NewEncoder(a.file).Encode(auditEntry{
		Time:            now,
		Level:           "INFO",
		Message:         "tool_invocation",
		Tool:            tool,
		Status:          status,
		DurationSeconds: duration.Seconds(),
		Timestamp:       now,
	}); err != nil {
		return fmt.Errorf("write audit metadata: %w", err)
	}
	return nil
}
