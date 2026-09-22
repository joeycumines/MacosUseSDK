// Copyright 2026 Joseph Cumines

package integration

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
)

// --- Helper types and functions ---

// stdioResponse represents a JSON-RPC 2.0 response
type stdioResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data,omitempty"`
	} `json:"error,omitempty"`
}

type stdioResponseRead struct {
	line string
	err  error
}

// stdioResponsePump is the sole owner of stdout reads for one stdio child.
// Caller timeouts abandon only their wait; they never manufacture another
// reader or leave a blocked per-request goroutine behind.
type stdioResponsePump struct {
	reads chan stdioResponseRead
	done  chan struct{}
}

func newStdioResponsePump(reader *bufio.Reader) *stdioResponsePump {
	pump := &stdioResponsePump{
		reads: make(chan stdioResponseRead, 1024),
		done:  make(chan struct{}),
	}
	go func() {
		defer close(pump.done)
		defer close(pump.reads)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				pump.reads <- stdioResponseRead{
					err: fmt.Errorf("failed to read response: %w", err),
				}
				return
			}
			pump.reads <- stdioResponseRead{line: line}
		}
	}()
	return pump
}

func (p *stdioResponsePump) read(ctx context.Context) (*stdioResponse, error) {
	if p == nil {
		return nil, errors.New("stdio response pump is required")
	}
	if ctx == nil {
		return nil, errors.New("stdio response context is required")
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case result, ok := <-p.reads:
		if !ok {
			return nil, io.EOF
		}
		if result.err != nil {
			return nil, result.err
		}
		line := strings.TrimSpace(result.line)
		if line == "" {
			return nil, errors.New("empty response received")
		}
		var response stdioResponse
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			return nil, fmt.Errorf("failed to parse response: %w (line: %s)", err, line)
		}
		return &response, nil
	}
}

// startMCPStdioProcess starts the exactmac CLI in MCP stdio mode (`exactmac mcp`).
// Returns the command, stdin writer, sole stdout response pump, and cleanup
// function that joins both output owners.
func startMCPStdioProcess(
	t *testing.T,
	ctx context.Context,
	grpcAddr string,
) (*exec.Cmd, io.WriteCloser, *stdioResponsePump, func()) {
	t.Helper()
	return startMCPStdioProcessWithOverrides(t, ctx, grpcAddr, nil)
}

func startMCPStdioProcessWithOverrides(
	t *testing.T,
	ctx context.Context,
	grpcAddr string,
	overrides map[string]string,
) (*exec.Cmd, io.WriteCloser, *stdioResponsePump, func()) {
	t.Helper()

	builtBinary := "../.build/debug/exactmac"
	info, err := os.Stat(builtBinary)
	if err != nil {
		t.Fatalf("production MCP test binary is unavailable at %s: %v", builtBinary, err)
	}
	if info.Mode()&0o111 == 0 {
		t.Fatalf("production MCP test binary is not executable: %s", builtBinary)
	}
	cmd := exec.CommandContext(ctx, "../.build/debug/exactmac", "mcp")

	// Configure environment for stdio transport
	processEnvironment := map[string]string{
		"EXACTMAC_DEBUG":              "false",
		"EXACTMAC_SERVER_ADDR":        grpcAddr,
		"EXACTMAC_SERVER_SOCKET_PATH": "",
		"MCP_AUDIT_LOG_FILE":          "",
	}
	maps.Copy(processEnvironment, overrides)
	cmd.Env = testEnvironment(processEnvironment)

	// Set up pipes
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("Failed to create stdin pipe: %v", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("Failed to create stdout pipe: %v", err)
	}

	// Capture stderr for debugging
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		t.Fatalf("Failed to create stderr pipe: %v", err)
	}

	// Start the process
	t.Log("Starting MCP process in stdio mode...")
	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start MCP process: %v", err)
	}
	t.Logf("MCP process started (PID: %d)", cmd.Process.Pid)

	// Read stderr in background for debugging
	var stderrMu sync.Mutex
	var stderrBuf strings.Builder
	var stderrReadErr error
	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		scanner := bufio.NewScanner(stderrPipe)
		for scanner.Scan() {
			stderrMu.Lock()
			stderrBuf.WriteString(scanner.Text())
			stderrBuf.WriteString("\n")
			stderrMu.Unlock()
		}
		stderrMu.Lock()
		stderrReadErr = scanner.Err()
		stderrMu.Unlock()
	}()

	responsePump := newStdioResponsePump(bufio.NewReader(stdout))

	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			t.Log("Cleaning up MCP process...")

			// Close stdin to signal EOF
			if err := stdin.Close(); err != nil {
				t.Errorf("close production MCP stdin: %v", err)
			}

			// Wait for process to exit with timeout
			done := make(chan error, 1)
			go func() {
				done <- cmd.Wait()
			}()

			select {
			case err := <-done:
				if err != nil {
					stderrMu.Lock()
					stderr := stderrBuf.String()
					stderrMu.Unlock()
					t.Errorf("production MCP process did not exit cleanly on stdin EOF: %v stderr=%q", err, stderr)
				}
				t.Logf("MCP process exited: %v", err)
			case <-time.After(5 * time.Second):
				t.Errorf("production MCP process did not exit within 5s after stdin EOF; forcing exact-PID cleanup")
				_ = cmd.Process.Kill()
				<-done
			}

			joinCtx, cancelJoin := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancelJoin()
			select {
			case <-responsePump.done:
			case <-joinCtx.Done():
				t.Errorf("production MCP stdout response pump did not join: %v", joinCtx.Err())
			}
			select {
			case <-stderrDone:
			case <-joinCtx.Done():
				t.Errorf("production MCP stderr scanner did not join: %v", joinCtx.Err())
			}
			stderrMu.Lock()
			stderr := stderrBuf.String()
			stderrErr := stderrReadErr
			stderrMu.Unlock()
			if stderrErr != nil {
				t.Errorf("production MCP stderr scanner failed: %v", stderrErr)
			}
			if strings.Contains(stderr, goRaceWarning) {
				t.Errorf("production MCP stdio process emitted a Go race report: %s", stderr)
			}
		})
	}

	return cmd, stdin, responsePump, cleanup
}

// writeStdioMessage writes a JSON-RPC message to stdin
func writeStdioMessage(stdin io.Writer, msg map[string]any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}

	// Write message followed by newline
	if _, err := stdin.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("failed to write message: %w", err)
	}

	return nil
}

// readStdioResponse reads a JSON-RPC response from stdout with timeout
func readStdioResponse(ctx context.Context, pump *stdioResponsePump) (*stdioResponse, error) {
	return pump.read(ctx)
}

// sendStdioRequest sends a JSON-RPC request and waits for the response
func sendStdioRequest(
	ctx context.Context,
	stdin io.Writer,
	stdout *stdioResponsePump,
	req map[string]any,
) (*stdioResponse, error) {
	// Create a timeout context for this request
	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	// Write the request
	if err := writeStdioMessage(stdin, req); err != nil {
		return nil, err
	}

	// Read the response
	return readStdioResponse(reqCtx, stdout)
}
