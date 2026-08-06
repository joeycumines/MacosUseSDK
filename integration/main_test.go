package integration

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"github.com/joeycumines/MacosUseSDK/internal/integrationfixture"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

func TestMain(m *testing.M) {
	// Check if we're running on macOS
	if os.Getenv("SKIP_INTEGRATION_TESTS") != "" {
		fmt.Println("Skipping integration tests (SKIP_INTEGRATION_TESTS is set)")
		os.Exit(0)
	}

	// Start log streaming to capture OSLog output
	var logCmd *exec.Cmd
	logCmd = exec.Command("/usr/bin/log", "stream",
		"--level", "debug",
		"--predicate", `subsystem == "com.macosusesdk"`,
		"--style", "compact")
	logCmd.Stdout = os.Stdout
	logCmd.Stderr = os.Stderr
	if err := logCmd.Start(); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "Warning: Failed to start log streaming: %v\n", err)
		logCmd = nil
	}

	// Pre-flight cleanup owns only the golden test applications. Server cleanup
	// is scoped to the exact child returned by startServer.
	_, _ = fmt.Fprintln(os.Stderr, "TestMain: Pre-flight cleanup - killing golden applications...")
	killGoldenApplications()

	// closure because panics bubble e.g. on timeout
	code := func() int {
		defer func() {
			if logCmd != nil && logCmd.Process != nil {
				_ = logCmd.Process.Kill()
				_ = logCmd.Wait()
			}
		}()
		// ^ Stop log streaming

		defer killGoldenApplications()
		defer func() {
			_, _ = fmt.Fprintln(os.Stderr, "TestMain: Post-suite cleanup - killing golden applications...")
		}()
		// ^ Post-suite cleanup

		return m.Run()
	}()

	os.Exit(code)
}

// getAvailablePort returns an available port number by binding to port 0
// and letting the OS assign an available port.
func getAvailablePort(t *testing.T) int {
	t.Helper()
	lAddr, err := net.ResolveTCPAddr("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to resolve TCP addr: %v", err)
	}
	l, err := net.ListenTCP("tcp", lAddr)
	if err != nil {
		t.Fatalf("Failed to listen on TCP: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// waitForPortAvailable polls until the specified port is available or timeout is reached.
// This prevents port contention between sequential test runs.
func waitForPortAvailable(t testing.TB, ctx context.Context, addr string) error {
	t.Logf("Waiting for port to be available: %s", addr)

	return PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		testConn, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err != nil {
			// Connection failed - port is available
			return true, nil
		}
		testConn.Close()
		// Connection succeeded - port still in use
		t.Logf("Port %s still in use, retrying...", addr)
		return false, nil
	})
}

func waitForServerReadiness(
	ctx context.Context,
	interval time.Duration,
	attemptTimeout time.Duration,
	probe func(context.Context) error,
) error {
	if ctx == nil {
		return errors.New("server readiness context is required")
	}
	if interval <= 0 {
		return errors.New("server readiness interval must be positive")
	}
	if attemptTimeout <= 0 {
		return errors.New("server readiness probe timeout must be positive")
	}
	if probe == nil {
		return errors.New("server readiness probe is required")
	}

	var lastProbeErr error
	waitErr := PollUntilContext(ctx, interval, func() (bool, error) {
		attemptCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
		defer cancel()

		lastProbeErr = probe(attemptCtx)
		return lastProbeErr == nil, nil
	})
	if waitErr == nil {
		return nil
	}
	if lastProbeErr == nil {
		return waitErr
	}
	return fmt.Errorf("%w; last readiness probe: %v", waitErr, lastProbeErr)
}

// killGoldenApplications forcefully terminates all golden test applications.
// Golden Applications:
// - Calculator (com.apple.calculator)
// - TextEdit (com.apple.TextEdit)
// - Finder is NOT killed to prevent system issues
func killGoldenApplications() {
	// Gracefully quit TextEdit first so its autosave state is flushed. A
	// SIGKILL while TextEdit holds an unsaved untitled document leaves the
	// autosave behind; the next launch restores it, and a restored unsaved
	// document cannot be closed via AX without answering a save dialog,
	// which breaks window-close tests on consecutive runs. The graceful
	// quit is bounded by a poll (never time.Sleep), then the force kill
	// below catches any survivor.
	_ = exec.Command("osascript", "-e", `tell application "TextEdit" to quit saving no`).Run()
	quitCtx, quitCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer quitCancel()
	_ = PollUntilContext(quitCtx, 50*time.Millisecond, func() (bool, error) {
		// pgrep exits non-zero once no TextEdit process remains.
		probe := exec.Command("pgrep", "-x", "TextEdit")
		return probe.Run() != nil, nil
	})

	commands := []*exec.Cmd{
		exec.Command("killall", "-9", "Calculator"),
		exec.Command("killall", "-9", "TextEdit"),
	}
	for _, cmd := range commands {
		_ = cmd.Run() // Ignore errors (app may not be running)
	}
}

// CleanupApplication closes the exact returned application using the
// CloseApplication RPC and verifies both state removal and process exit. Opaque
// resource names deliberately cannot be decoded back into a PID, so cleanup
// retains the original output-only PID as fixture evidence.
// This is the MANDATORY per-test cleanup pattern for Test Fixture Lifecycle (Phase 4.2).
func CleanupApplication(t *testing.T, ctx context.Context, client pb.MacosUseClient, application *pb.Application) {
	t.Helper()
	if application == nil {
		return
	}
	name := application.Name
	expectedPID := application.Pid
	if !isOpaqueApplicationResourceName(name) {
		t.Errorf("CleanupApplication: %q is not a canonical opaque application resource name", name)
		return
	}
	if expectedPID <= 1 {
		t.Errorf("CleanupApplication: refusing unsafe PID %d for %q", expectedPID, name)
		return
	}

	baseCtx := context.Background()
	if ctx != nil {
		baseCtx = context.WithoutCancel(ctx)
	}
	cleanupCtx, cancel := context.WithTimeout(baseCtx, 5*time.Second)
	defer cancel()

	// List applications to find the target
	listResp, err := client.ListApplications(cleanupCtx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Errorf("CleanupApplication: failed to list applications: %v", err)
		return
	}

	var targetApp *pb.Application
	for _, app := range listResp.Applications {
		if app.Name == name {
			targetApp = app
			break
		}
	}

	if targetApp == nil {
		// CloseApplication removes server state only after the owned process
		// identity has stopped. The PID can still exist briefly while macOS
		// finishes reaping it, so an already-untracked application must use the
		// same convergence proof as the tracked branch instead of sampling once.
		if err := PollUntilContext(cleanupCtx, 100*time.Millisecond, func() (bool, error) {
			return exactProcessGone(expectedPID)
		}); err != nil {
			t.Errorf(
				"CleanupApplication: %q is untracked but exact PID %d did not disappear: %v",
				name,
				expectedPID,
				err,
			)
			return
		}
		t.Logf("CleanupApplication: application %q is already untracked and PID is gone", name)
		return
	}

	targetPID := targetApp.Pid
	if targetPID != expectedPID {
		t.Errorf(
			"CleanupApplication: resource %q changed PID from owned %d to listed %d",
			name,
			expectedPID,
			targetPID,
		)
		return
	}

	closeResp, err := client.CloseApplication(cleanupCtx, &pb.CloseApplicationRequest{
		Name:  targetApp.Name,
		Force: true,
	})
	if err != nil {
		t.Errorf("CleanupApplication: failed to close application %q: %v", name, err)
		return
	}
	if closeResp == nil || closeResp.Application == nil ||
		closeResp.Application.Name != targetApp.Name || closeResp.Application.Pid != targetPID ||
		closeResp.Disposition == pb.ApplicationCloseDisposition_APPLICATION_CLOSE_DISPOSITION_UNSPECIFIED {
		t.Errorf("CleanupApplication: incomplete close result for %q: %+v", name, closeResp)
		return
	}

	// A truthful cleanup requires both server-state removal and exact PID death.
	err = PollUntilContext(cleanupCtx, 100*time.Millisecond, func() (bool, error) {
		listResp, err := client.ListApplications(cleanupCtx, &pb.ListApplicationsRequest{})
		if err != nil {
			return false, err
		}

		untracked := true
		for _, app := range listResp.Applications {
			if app.Name == targetApp.Name {
				untracked = false
				break
			}
		}
		processGone, err := exactProcessGone(targetPID)
		return untracked && processGone, err
	})

	if err != nil {
		t.Errorf("CleanupApplication: PID %d for %q was not both terminated and untracked: %v", targetPID, name, err)
	}
}

func isOpaqueApplicationResourceName(name string) bool {
	resourceID, found := strings.CutPrefix(name, "applications/")
	if !found || len(resourceID) != 64 {
		return false
	}
	for _, character := range resourceID {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}

func exactProcessGone(pid int32) (bool, error) {
	if pid <= 1 {
		return false, fmt.Errorf("unsafe PID %d", pid)
	}
	err := syscall.Kill(int(pid), syscall.Signal(0))
	switch {
	case err == nil, errors.Is(err, syscall.EPERM):
		return false, nil
	case errors.Is(err, syscall.ESRCH):
		return true, nil
	default:
		return false, fmt.Errorf("probe PID %d: %w", pid, err)
	}
}

// cleanupServer stops the server and verifies port release
func cleanupServer(t *testing.T, cmd *exec.Cmd, serverAddr string) {
	if cmd != nil && cmd.Process != nil {
		t.Logf("Stopping server (PID %d) at %s...", cmd.Process.Pid, serverAddr)
		startTime := time.Now()
		if err := integrationfixture.StopChild(cmd); err != nil {
			t.Errorf("Stop server child: %v", err)
			return
		}
		elapsed := time.Since(startTime)
		t.Logf("Server stopped in %v", elapsed)

		// CI-009: Verify port release after server shutdown
		t.Logf("Verifying port release for %s...", serverAddr)
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := waitForPortAvailable(t, releaseCtx, serverAddr); err != nil {
			t.Errorf("Port %s not released after server kill: %v", serverAddr, err)
		} else {
			t.Logf("Port %s confirmed released", serverAddr)
		}
	}
}

// startServer starts the MacosUse server and returns the command and address
func startServer(t *testing.T, ctx context.Context) (*exec.Cmd, string) {
	// Check if INTEGRATION_SERVER_ADDR is set (for external server)
	if addr := os.Getenv("INTEGRATION_SERVER_ADDR"); addr != "" {
		t.Logf("Using existing server at %s", addr)
		// External server should already be running and ready
		return nil, addr
	}

	// CRITICAL FIX: Use dynamic port allocation to prevent CI port contention
	port := getAvailablePort(t)
	serverAddr := fmt.Sprintf("127.0.0.1:%d", port)
	t.Logf("Allocated dynamic port %d for server", port)

	// Wait for port to be available before attempting to start server
	portWaitCtx, portCancel := context.WithTimeout(ctx, 10*time.Second)
	defer portCancel()

	if err := waitForPortAvailable(t, portWaitCtx, serverAddr); err != nil {
		t.Fatalf("Allocated port %s did not become available: %v", serverAddr, err)
	}

	// Start the server with dynamic port
	t.Logf("Starting MacosUse server on %s...", serverAddr)

	cmd := exec.CommandContext(ctx, "../Server/.build/release/MacosUseServer")
	cmd.Env = append(os.Environ(),
		"GRPC_LISTEN_ADDRESS=127.0.0.1",
		fmt.Sprintf("GRPC_PORT=%d", port),
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	testConn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("Failed to construct readiness client: %v", err)
	}
	defer testConn.Close()
	healthClient := healthpb.NewHealthClient(testConn)

	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}

	// Probe the generic gRPC health contract. Each attempt has its own bound so
	// one transport failure cannot consume the entire readiness deadline.
	t.Log("Waiting for server to be ready...")
	serverCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	err = waitForServerReadiness(serverCtx, 100*time.Millisecond, 250*time.Millisecond, func(attemptCtx context.Context) error {
		response, probeErr := healthClient.Check(attemptCtx, &healthpb.HealthCheckRequest{
			Service: "macosusesdk.v1.MacosUse",
		})
		if probeErr != nil {
			return probeErr
		}
		if response.Status != healthpb.HealthCheckResponse_SERVING {
			return fmt.Errorf("health status = %s, want SERVING", response.Status)
		}
		return nil
	})
	if err != nil {
		if stopErr := integrationfixture.StopChild(cmd); stopErr != nil {
			t.Logf("Failed to stop and reap unready server child: %v", stopErr)
		}
		childState := "unreaped"
		if cmd.ProcessState != nil {
			childState = cmd.ProcessState.String()
		}
		t.Fatalf("Server failed to become ready: %v; child state=%s", err, childState)
	}

	return cmd, serverAddr
}

// connectToServer establishes a gRPC connection
func connectToServer(t *testing.T, ctx context.Context, addr string) *grpc.ClientConn {
	t.Logf("Connecting to server at %s...", addr)

	var conn *grpc.ClientConn
	var err error

	// CRITICAL FIX: Increased retry count from 10 to 20 with exponential backoff for CI environment
	for i := range 20 {
		conn, err = grpc.NewClient(
			addr,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err == nil {
			// Try to make a simple call to verify connection
			client := pb.NewMacosUseClient(conn)
			_, err = client.ListApplications(ctx, &pb.ListApplicationsRequest{})
			if err == nil {
				t.Log("Successfully connected to server")
				return conn
			}
			conn.Close()
		}

		t.Logf("Connection attempt %d/20 failed, retrying... (error: %v)", i+1, err)

		// CRITICAL FIX: Exponential backoff (100ms → 200ms → 400ms... capped at 1.6s)
		retryDelay := time.Duration(100<<min(i, 5)) * time.Millisecond

		retryCtx, cancel := context.WithTimeout(ctx, retryDelay)
		_ = PollUntilContext(retryCtx, 50*time.Millisecond, func() (bool, error) {
			return true, nil
		})
		cancel()
	}

	t.Fatalf("Failed to connect to server after retries: %v", err)
	return nil
}

// OpenApplicationObserved opens or activates an application and requires the
// unary response to contain both the exact tracked resource and an observed
// disposition.
func DiscoverApplicationBundle(
	t *testing.T,
	ctx context.Context,
	client pb.MacosUseClient,
	bundleID string,
) *pb.ApplicationBundle {
	t.Helper()

	var matches []*pb.ApplicationBundle
	pageToken := ""
	seenTokens := make(map[string]struct{})
	for {
		response, err := client.ListApplicationBundles(ctx, &pb.ListApplicationBundlesRequest{
			PageSize:  1000,
			PageToken: pageToken,
			Filter:    fmt.Sprintf("bundle_id = %s", strconv.Quote(bundleID)),
			OrderBy:   "name",
			View:      pb.ApplicationView_APPLICATION_VIEW_FULL,
		})
		if err != nil {
			t.Fatalf("ListApplicationBundles(%q) failed: %v", bundleID, err)
		}
		if response == nil {
			t.Fatalf("ListApplicationBundles(%q) returned nil", bundleID)
		}
		for _, bundle := range response.ApplicationBundles {
			if bundle != nil && bundle.BundleId == bundleID {
				matches = append(matches, bundle)
			}
		}
		pageToken = response.NextPageToken
		if pageToken == "" {
			break
		}
		if _, duplicate := seenTokens[pageToken]; duplicate {
			t.Fatalf("ListApplicationBundles(%q) repeated page token", bundleID)
		}
		seenTokens[pageToken] = struct{}{}
	}

	if len(matches) != 1 {
		resources := make([]string, 0, len(matches))
		for _, bundle := range matches {
			resources = append(resources, fmt.Sprintf("%s=%s", bundle.Name, bundle.BundleUrl))
		}
		t.Fatalf(
			"ListApplicationBundles(%q) returned %d exact candidates; select an unambiguous bundle resource: %v",
			bundleID,
			len(matches),
			resources,
		)
	}
	bundle := matches[0]
	if !strings.HasPrefix(bundle.Name, "applicationBundles/") || bundle.BundleUrl == "" {
		t.Fatalf("ListApplicationBundles(%q) returned incomplete bundle: %+v", bundleID, bundle)
	}
	return bundle
}

// OpenApplicationObserved discovers exactly one installed bundle before it
// mutates the desktop, then opens only the returned resource name.
func OpenApplicationObserved(t *testing.T, ctx context.Context, client pb.MacosUseClient, bundleID string) *pb.Application {
	t.Helper()
	bundle := DiscoverApplicationBundle(t, ctx, client, bundleID)

	response, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Name: bundle.Name,
		Mode: pb.ApplicationOpenMode_APPLICATION_OPEN_MODE_LAUNCH_OR_ACTIVATE,
	})
	if err != nil {
		t.Fatalf("OpenApplication failed: %v", err)
	}
	if response == nil || response.Application == nil {
		t.Fatal("OpenApplication returned no application")
	}
	if response.Application.Name == "" || response.Application.Pid <= 0 ||
		response.Application.ApplicationBundle != bundle.Name {
		t.Fatalf("OpenApplication returned incomplete application: %+v", response.Application)
	}
	switch response.Disposition {
	case pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_LAUNCHED_NEW,
		pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_ACTIVATED_EXISTING,
		pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_ALREADY_ACTIVE,
		pb.ApplicationOpenDisposition_APPLICATION_OPEN_DISPOSITION_REUSED_EXISTING:
	default:
		t.Fatalf("OpenApplication returned invalid disposition: %s", response.Disposition)
	}

	t.Logf(
		"Application open observed: %s (PID: %d, disposition: %s)",
		response.Application.Name,
		response.Application.Pid,
		response.Disposition,
	)
	return response.Application
}
