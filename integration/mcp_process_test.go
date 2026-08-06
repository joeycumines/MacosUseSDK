package integration

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/joeycumines/MacosUseSDK/internal/integrationfixture"
)

const (
	goRaceWarning                   = "WARNING: DATA RACE"
	productionMCPEndpoint           = "/mcp"
	productionMCPProtocolVersion    = "2025-11-25"
	productionMCPGracefulStopMargin = 10 * time.Second
)

var productionMCPSessionIDs sync.Map

func validMCPInitializePayload(id int) string {
	return fmt.Sprintf(
		`{"jsonrpc":"2.0","id":%d,"method":"initialize","params":{"protocolVersion":"%s","capabilities":{},"clientInfo":{"name":"integration-test","version":"1"}}}`,
		id,
		productionMCPProtocolVersion,
	)
}

func validMCPInitializeRequest(id int) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "initialize",
		"params": map[string]any{
			"protocolVersion": productionMCPProtocolVersion,
			"capabilities":    map[string]any{},
			"clientInfo": map[string]any{
				"name":    "integration-test",
				"version": "1",
			},
		},
	}
}

// startMCPTestServer launches the exact production MCP executable and its real
// HTTP transport. Tests may not supply a handler, registry, or dispatcher.
func startMCPTestServer(t *testing.T, ctx context.Context, grpcAddr string) (*exec.Cmd, string, func()) {
	t.Helper()
	return startMCPTestServerWithOverrides(t, ctx, grpcAddr, nil)
}

func startMCPTestServerWithOverrides(
	t *testing.T,
	ctx context.Context,
	grpcAddr string,
	overrides map[string]string,
) (*exec.Cmd, string, func()) {
	t.Helper()

	binaryPath := filepath.Clean("../.build/debug/macos-use-mcp")
	info, err := os.Stat(binaryPath)
	if err != nil {
		t.Fatalf("production MCP test binary is unavailable at %s: %v", binaryPath, err)
	}
	if info.Mode()&0o111 == 0 {
		t.Fatalf("production MCP test binary is not executable: %s", binaryPath)
	}

	port := getAvailablePort(t)
	address := fmt.Sprintf("127.0.0.1:%d", port)
	scheme := "http"
	if overrides["MCP_TLS_CERT_FILE"] != "" && overrides["MCP_TLS_KEY_FILE"] != "" {
		scheme = "https"
	}
	baseURL := scheme + "://" + address
	availableCtx, cancelAvailable := context.WithTimeout(ctx, 5*time.Second)
	defer cancelAvailable()
	if err := waitForPortAvailable(t, availableCtx, address); err != nil {
		t.Fatalf("allocated MCP HTTP address %s was unavailable: %v", address, err)
	}

	logPath := filepath.Join(t.TempDir(), "mcp-http.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		t.Fatalf("create MCP HTTP process log: %v", err)
	}

	cmd := exec.CommandContext(ctx, "../.build/debug/macos-use-mcp")
	processEnvironment := map[string]string{
		"MACOS_USE_DEBUG":              "false",
		"MACOS_USE_SERVER_ADDR":        grpcAddr,
		"MACOS_USE_SERVER_SOCKET_PATH": "",
		"MCP_API_KEY":                  "",
		"MCP_AUDIT_LOG_FILE":           "",
		"MCP_HTTP_ADDRESS":             address,
		"MCP_HTTP_SOCKET":              "",
		"MCP_SHELL_COMMANDS_ENABLED":   "false",
		"MCP_TLS_CERT_FILE":            "",
		"MCP_TLS_KEY_FILE":             "",
		"MCP_TRANSPORT":                "streamable-http",
	}
	maps.Copy(processEnvironment, overrides)
	cmd.Env = testEnvironment(processEnvironment)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		t.Fatalf("start production MCP HTTP process: %v", err)
	}

	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			productionMCPSessionIDs.Delete(baseURL)
			// HTTPTransport has its own eight-second graceful-shutdown deadline.
			// The process observer must remain outside that deadline so scheduling
			// cannot force-kill a child that is still completing bounded cleanup.
			if err := integrationfixture.StopChildGracefully(cmd, productionMCPGracefulStopMargin); err != nil {
				t.Errorf("stop production MCP HTTP process: %v", err)
			}
			if err := logFile.Close(); err != nil {
				t.Errorf("close production MCP HTTP process log: %v", err)
			}
			logBytes, err := os.ReadFile(logPath)
			if err != nil {
				t.Errorf("read production MCP HTTP process log: %v", err)
			} else {
				if cmd.ProcessState == nil || !cmd.ProcessState.Success() {
					t.Errorf("production MCP HTTP process did not exit successfully: %v log=%q", cmd.ProcessState, logBytes)
				}
				if strings.Contains(string(logBytes), goRaceWarning) {
					t.Errorf("production MCP HTTP process emitted a Go race report: %s", logBytes)
				}
			}
			releaseCtx, cancelRelease := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancelRelease()
			if err := waitForPortAvailable(t, releaseCtx, address); err != nil {
				t.Errorf("production MCP HTTP address %s was not released: %v", address, err)
			}
		})
	}

	readyCtx, cancelReady := context.WithTimeout(ctx, 5*time.Second)
	defer cancelReady()
	client := productionMCPReadinessClient(t, overrides)
	err = PollUntilContext(readyCtx, 50*time.Millisecond, func() (bool, error) {
		request, err := http.NewRequestWithContext(readyCtx, http.MethodGet, baseURL+"/health", nil)
		if err != nil {
			return false, err
		}
		response, err := client.Do(request)
		if err != nil {
			return false, nil
		}
		defer response.Body.Close()
		return response.StatusCode == http.StatusOK, nil
	})
	if err != nil {
		cleanup()
		logBytes, readErr := os.ReadFile(logPath)
		t.Fatalf("production MCP HTTP process did not become ready: %v log=%q read_error=%v", err, logBytes, readErr)
	}

	return cmd, baseURL, cleanup
}

func productionMCPReadinessClient(t *testing.T, overrides map[string]string) *http.Client {
	t.Helper()
	client := &http.Client{Timeout: 250 * time.Millisecond}
	certPath := overrides["MCP_TLS_CERT_FILE"]
	if certPath == "" || overrides["MCP_TLS_KEY_FILE"] == "" {
		return client
	}

	certificate, err := os.ReadFile(certPath)
	if err != nil {
		t.Fatalf("read production MCP TLS certificate for readiness: %v", err)
	}
	rootCAs := x509.NewCertPool()
	if !rootCAs.AppendCertsFromPEM(certificate) {
		t.Fatalf("production MCP TLS certificate contains no trusted PEM certificate: %s", certPath)
	}
	httpTransport := &http.Transport{
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			RootCAs:    rootCAs,
		},
	}
	t.Cleanup(httpTransport.CloseIdleConnections)
	client.Transport = httpTransport
	return client
}

func newProductionMCPRequest(
	ctx context.Context,
	method string,
	baseURL string,
	body io.Reader,
) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, method, baseURL+productionMCPEndpoint, body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("MCP-Protocol-Version", productionMCPProtocolVersion)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	return request, nil
}

func postProductionMCP(ctx context.Context, baseURL string, body io.Reader) (*http.Response, error) {
	var payload []byte
	var err error
	if body != nil {
		payload, err = io.ReadAll(body)
		if err != nil {
			return nil, fmt.Errorf("read MCP request body: %w", err)
		}
	}
	initialize := isMCPInitializePayload(payload)
	request, err := newProductionMCPRequest(ctx, http.MethodPost, baseURL, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	if !initialize {
		applyDefaultMCPSession(request, baseURL)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	if initialize && response.StatusCode == http.StatusOK {
		if sessionID := response.Header.Get("MCP-Session-Id"); sessionID != "" {
			productionMCPSessionIDs.Store(baseURL, sessionID)
		}
	}
	return response, nil
}

func isMCPInitializePayload(payload []byte) bool {
	var envelope struct {
		Method string `json:"method"`
	}
	return json.Unmarshal(payload, &envelope) == nil && envelope.Method == "initialize"
}

func applyDefaultMCPSession(request *http.Request, baseURL string) {
	if sessionID, ok := productionMCPSessionIDs.Load(baseURL); ok {
		request.Header.Set("MCP-Session-Id", sessionID.(string))
	}
}

func testEnvironment(overrides map[string]string) []string {
	keys := make([]string, 0, len(overrides))
	for key := range overrides {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	environment := make([]string, 0, len(os.Environ())+len(overrides))
	for _, entry := range os.Environ() {
		name, _, found := strings.Cut(entry, "=")
		if _, replaced := overrides[name]; found && replaced {
			continue
		}
		environment = append(environment, entry)
	}
	for _, key := range keys {
		environment = append(environment, key+"="+overrides[key])
	}
	return environment
}
