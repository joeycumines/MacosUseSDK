package integration

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

type mcpProcessResources struct {
	goroutines int
	openFDs    int
}

func TestMCPProductionProcessResourcesRemainBounded_HTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)
	mcpCmd, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
	defer cleanup()

	initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(1))
	if initialize.Error != nil {
		t.Fatalf("initialize returned error: %+v", initialize.Error)
	}

	runMCPPingWave(t, ctx, baseURL, 1000, 64)
	closeDefaultHTTPIdleConnections()
	baseline := waitForStableMCPProcessResources(t, ctx, baseURL, mcpCmd.Process.Pid)
	t.Logf("production MCP resource baseline: goroutines=%d open_fds=%d", baseline.goroutines, baseline.openFDs)

	for wave := range 8 {
		runMCPPingWave(t, ctx, baseURL, 2000+wave*128, 128)
	}
	closeDefaultHTTPIdleConnections()

	limit := mcpProcessResources{
		goroutines: baseline.goroutines + 3,
		openFDs:    baseline.openFDs + 2,
	}
	settleCtx, cancelSettle := context.WithTimeout(ctx, 10*time.Second)
	defer cancelSettle()
	var observed mcpProcessResources
	if err := PollUntilContext(settleCtx, 50*time.Millisecond, func() (bool, error) {
		var err error
		observed, err = readMCPProcessResources(settleCtx, baseURL, mcpCmd.Process.Pid)
		if err != nil {
			return false, nil
		}
		return observed.goroutines <= limit.goroutines && observed.openFDs <= limit.openFDs, nil
	}); err != nil {
		t.Fatalf(
			"production MCP resources did not return to their bounded baseline: baseline=%+v observed=%+v limit=%+v error=%v",
			baseline,
			observed,
			limit,
			err,
		)
	}
	t.Logf("production MCP settled resources after 1024 requests: goroutines=%d open_fds=%d", observed.goroutines, observed.openFDs)

	final := postMCPRequest(t, baseURL, `{"jsonrpc":"2.0","id":9999,"method":"tools/list","params":{}}`)
	if final.Error != nil || len(final.Result) == 0 {
		t.Fatalf("tools/list after resource stress returned %+v", final)
	}
}

func TestMCPProductionProcessRepeatedLifecycle_HTTP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	for iteration := range 5 {
		mcpCmd, baseURL, cleanup := startMCPTestServer(t, ctx, serverAddr)
		initialize := postMCPRequest(t, baseURL, validMCPInitializePayload(iteration+1))
		if initialize.Error != nil {
			cleanup()
			t.Fatalf("iteration %d initialize returned error: %+v", iteration, initialize.Error)
		}
		runMCPPingWave(t, ctx, baseURL, 10_000+iteration*32, 32)
		closeDefaultHTTPIdleConnections()
		cleanup()

		if mcpCmd.ProcessState == nil {
			t.Fatalf("iteration %d production MCP process was not reaped", iteration)
		}
		if err := mcpCmd.Process.Signal(syscall.Signal(0)); !errors.Is(err, os.ErrProcessDone) {
			t.Fatalf("iteration %d reaped production MCP signal error=%v, want os.ErrProcessDone", iteration, err)
		}
		t.Logf("production MCP lifecycle %d reaped exact PID %d", iteration+1, mcpCmd.Process.Pid)
	}
}

func runMCPPingWave(t *testing.T, ctx context.Context, baseURL string, firstID, count int) {
	t.Helper()
	results := make(chan error, count)
	for offset := range count {
		id := firstID + offset
		go func() {
			method := "ping"
			if id%16 == 0 {
				method = "tools/list"
			}
			payload := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":%q,"params":{}}`, id, method)
			response, err := requestMCPHTTP(ctx, baseURL, payload)
			if err == nil && (response.Error != nil || string(response.ID) != strconv.Itoa(id)) {
				err = fmt.Errorf("response=%+v", response)
			}
			results <- err
		}()
	}
	for range count {
		if err := <-results; err != nil {
			t.Fatalf("production MCP stress request failed: %v", err)
		}
	}
}

func waitForStableMCPProcessResources(
	t *testing.T,
	ctx context.Context,
	baseURL string,
	pid int,
) mcpProcessResources {
	t.Helper()
	stableCtx, cancelStable := context.WithTimeout(ctx, 5*time.Second)
	defer cancelStable()
	var previous, observed mcpProcessResources
	consecutive := 0
	err := PollUntilContext(stableCtx, 50*time.Millisecond, func() (bool, error) {
		var err error
		observed, err = readMCPProcessResources(stableCtx, baseURL, pid)
		if err != nil {
			return false, nil
		}
		if observed == previous {
			consecutive++
		} else {
			previous = observed
			consecutive = 1
		}
		return consecutive >= 3, nil
	})
	if err != nil {
		t.Fatalf("production MCP resources did not establish a stable baseline: observed=%+v error=%v", observed, err)
	}
	return observed
}

func readMCPProcessResources(
	ctx context.Context,
	baseURL string,
	pid int,
) (mcpProcessResources, error) {
	goroutines, err := readMCPGoroutineMetric(ctx, baseURL)
	if err != nil {
		return mcpProcessResources{}, err
	}
	openFDs, err := countProcessOpenFDs(ctx, pid)
	if err != nil {
		return mcpProcessResources{}, err
	}
	return mcpProcessResources{goroutines: goroutines, openFDs: openFDs}, nil
}

func readMCPGoroutineMetric(ctx context.Context, baseURL string) (int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/metrics", nil)
	if err != nil {
		return 0, fmt.Errorf("create metrics request: %w", err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0, fmt.Errorf("request metrics: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("metrics status=%d", response.StatusCode)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return 0, fmt.Errorf("read metrics: %w", err)
	}
	for line := range strings.SplitSeq(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "go_goroutines" {
			value, err := strconv.Atoi(fields[1])
			if err != nil || value <= 0 {
				return 0, fmt.Errorf("invalid go_goroutines metric %q", line)
			}
			return value, nil
		}
	}
	return 0, errors.New("metrics omitted go_goroutines")
}

func countProcessOpenFDs(ctx context.Context, pid int) (int, error) {
	output, err := exec.CommandContext(
		ctx,
		"/usr/sbin/lsof",
		"-nP",
		"-a",
		"-p",
		strconv.Itoa(pid),
		"-Ff",
	).Output()
	if err != nil {
		return 0, fmt.Errorf("lsof production MCP PID %d: %w", pid, err)
	}
	count := 0
	for line := range strings.SplitSeq(string(output), "\n") {
		if len(line) < 2 || line[0] != 'f' {
			continue
		}
		end := 1
		for end < len(line) && line[end] >= '0' && line[end] <= '9' {
			end++
		}
		if end > 1 {
			count++
		}
	}
	if count == 0 {
		return 0, fmt.Errorf("lsof reported no open descriptors for live production MCP PID %d", pid)
	}
	return count, nil
}

func closeDefaultHTTPIdleConnections() {
	if transport, ok := http.DefaultTransport.(*http.Transport); ok {
		transport.CloseIdleConnections()
	}
}
