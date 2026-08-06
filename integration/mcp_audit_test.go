package integration

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

const productionAuditPrivateMarker = "FUNC-002-PRODUCTION-AUDIT-PRIVATE-9d942f"

func TestMCPAudit_ExactProcessRejectsSymlinkPath(t *testing.T) {
	tmpDir := t.TempDir()
	targetPath := filepath.Join(tmpDir, "target")
	const sentinel = "audit-target-must-not-change"
	if err := os.WriteFile(targetPath, []byte(sentinel), 0600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	auditPath := filepath.Join(tmpDir, "audit.log")
	if err := os.Symlink(targetPath, auditPath); err != nil {
		t.Fatalf("create audit symlink: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "../.build/debug/macos-use-mcp")
	cmd.Env = testEnvironment(map[string]string{
		"MACOS_USE_DEBUG":              "false",
		"MACOS_USE_SERVER_ADDR":        "127.0.0.1:1",
		"MACOS_USE_SERVER_SOCKET_PATH": "",
		"MCP_AUDIT_LOG_FILE":           auditPath,
		"MCP_TRANSPORT":                "stdio",
	})
	output, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("production MCP accepted audit symlink; output=%q", output)
	}
	var exitErr *exec.ExitError
	if !strings.Contains(string(output), "failed to initialize audit logger") ||
		!strings.Contains(string(output), "open audit log") ||
		!strings.Contains(err.Error(), "exit status") ||
		!errors.As(err, &exitErr) || exitErr.ExitCode() == 0 {
		t.Fatalf("production MCP symlink failure err=%v output=%q", err, output)
	}
	content, readErr := os.ReadFile(targetPath)
	if readErr != nil {
		t.Fatalf("read symlink target: %v", readErr)
	}
	if string(content) != sentinel {
		t.Fatalf("production MCP changed symlink target: %q", content)
	}
}

func TestMCPAudit_NonContentOwnerPrivateAcrossProductionTransports(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()
	client := pb.NewMacosUseClient(conn)
	application := OpenApplicationObserved(t, ctx, client, "com.apple.calculator")
	defer CleanupApplication(t, ctx, client, application)

	t.Run("streamable HTTP", func(t *testing.T) {
		auditPath := filepath.Join(t.TempDir(), "audit.log")
		_, baseURL, cleanup := startMCPTestServerWithOverrides(t, ctx, serverAddr, map[string]string{
			"MCP_AUDIT_LOG_FILE": auditPath,
		})

		initializeResponse, err := postProductionMCP(ctx, baseURL, strings.NewReader(validMCPInitializePayload(1)))
		if err != nil {
			cleanup()
			t.Fatalf("initialize production HTTP MCP: %v", err)
		}
		assertHTTPResponseConsumed(t, initializeResponse, "initialize")

		payload, err := json.Marshal(auditProbeRequest(2, application.Name))
		if err != nil {
			cleanup()
			t.Fatalf("marshal audit probe: %v", err)
		}
		response, err := postProductionMCP(ctx, baseURL, strings.NewReader(string(payload)))
		if err != nil {
			cleanup()
			t.Fatalf("call audited tool over production HTTP MCP: %v", err)
		}
		assertHTTPResponseConsumed(t, response, "audited tool")
		cleanup()

		assertProductionAuditLog(t, auditPath)
	})

	t.Run("stdio", func(t *testing.T) {
		auditPath := filepath.Join(t.TempDir(), "audit.log")
		_, stdin, stdout, cleanup := startMCPStdioProcessWithOverrides(t, ctx, serverAddr, map[string]string{
			"MCP_AUDIT_LOG_FILE": auditPath,
		})
		if _, err := sendStdioRequest(ctx, stdin, stdout, validMCPInitializeRequest(1)); err != nil {
			cleanup()
			t.Fatalf("initialize production stdio MCP: %v", err)
		}
		if _, err := sendStdioRequest(ctx, stdin, stdout, auditProbeRequest(2, application.Name)); err != nil {
			cleanup()
			t.Fatalf("call audited tool over production stdio MCP: %v", err)
		}
		cleanup()

		assertProductionAuditLog(t, auditPath)
	})
}

func auditProbeRequest(id int, parent string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "find_elements",
			"arguments": map[string]any{
				"parent":   parent,
				"selector": "text:" + productionAuditPrivateMarker,
			},
		},
	}
}

func assertHTTPResponseConsumed(t *testing.T, response *http.Response, operation string) {
	t.Helper()
	body, readErr := io.ReadAll(response.Body)
	closeErr := response.Body.Close()
	if readErr != nil {
		t.Fatalf("read %s response: %v", operation, readErr)
	}
	if closeErr != nil {
		t.Fatalf("close %s response: %v", operation, closeErr)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("%s status=%d body=%q, want 200", operation, response.StatusCode, body)
	}
	var message map[string]any
	if err := json.Unmarshal(body, &message); err != nil {
		t.Fatalf("decode %s response: %v body=%q", operation, err, body)
	}
	if message["jsonrpc"] != "2.0" || message["id"] == nil {
		t.Fatalf("invalid %s JSON-RPC response: %v", operation, message)
	}
}

func assertProductionAuditLog(t *testing.T, auditPath string) {
	t.Helper()
	info, err := os.Lstat(auditPath)
	if err != nil {
		t.Fatalf("Lstat production audit log: %v", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		t.Fatalf("production audit mode=%v, want owner-private regular file", info.Mode())
	}
	content, err := os.ReadFile(auditPath)
	if err != nil {
		t.Fatalf("read production audit log: %v", err)
	}
	if strings.Contains(string(content), productionAuditPrivateMarker) {
		t.Fatalf("production audit persisted private marker: %s", content)
	}
	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	if len(lines) != 1 {
		t.Fatalf("production audit entries=%d, want exactly one: %s", len(lines), content)
	}
	var entry map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &entry); err != nil {
		t.Fatalf("decode production audit entry: %v", err)
	}
	allowed := map[string]bool{
		"time": true, "level": true, "msg": true, "tool": true,
		"status": true, "duration_seconds": true, "timestamp": true,
	}
	for key := range entry {
		if !allowed[key] {
			t.Errorf("production audit contains unapproved field %q: %v", key, entry)
		}
	}
	if entry["tool"] != "find_elements" || entry["status"] != "ok" {
		t.Errorf("production audit metadata=%v, want successful empty find_elements query", entry)
	}
}
