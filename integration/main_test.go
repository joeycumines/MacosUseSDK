package integration

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
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

	// Pre-flight cleanup: Kill any stray servers and golden applications
	_, _ = fmt.Fprintln(os.Stderr, "TestMain: Pre-flight cleanup - killing stray servers and golden applications...")
	killStrayServers()
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
		defer killStrayServers()
		defer func() {
			_, _ = fmt.Fprintln(os.Stderr, "TestMain: Post-suite cleanup - killing servers and golden applications...")
		}()
		// ^ Post-suite cleanup

		return m.Run()
	}()

	os.Exit(code)
}

// killStrayServers forcefully terminates any MacosUseServer processes
// to prevent port conflicts when starting new test servers.
func killStrayServers() {
	cmd := exec.Command("killall", "-9", "MacosUseServer")
	_ = cmd.Run() // Ignore errors (server may not be running)
	// Port release is handled by server startup retry logic
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

// killGoldenApplications forcefully terminates all golden test applications.
// Golden Applications:
// - Calculator (com.apple.calculator)
// - TextEdit (com.apple.TextEdit)
// - Finder is NOT killed to prevent system issues
func killGoldenApplications() {
	apps := []string{"Calculator", "TextEdit"}
	for _, app := range apps {
		cmd := exec.Command("killall", "-9", app)
		_ = cmd.Run() // Ignore errors (app may not be running)
	}
}

// CleanupApplication closes an application using the DeleteApplication RPC and verifies the process is killed.
// This is the MANDATORY per-test cleanup pattern for Test Fixture Lifecycle (Phase 4.2).
func CleanupApplication(t *testing.T, ctx context.Context, client pb.MacosUseClient, name string) {
	t.Helper()

	// List applications to find the target
	listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Logf("CleanupApplication: Failed to list applications: %v", err)
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
		t.Logf("CleanupApplication: Application %q not found (may already be closed)", name)
		return
	}

	targetPID := targetApp.Pid

	// Call DeleteApplication
	_, err = client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: targetApp.Name,
	})
	if err != nil {
		t.Logf("CleanupApplication: Failed to delete application %q: %v", name, err)
		// Fall back to killall using display_name
		cmd := exec.Command("killall", "-9", targetApp.DisplayName)
		_ = cmd.Run()
		return
	}

	// Verify the application is removed from server's tracking using PollUntil (max 2s)
	verifyCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	err = PollUntilContext(verifyCtx, 100*time.Millisecond, func() (bool, error) {
		// Check if application still exists in server's ListApplications
		listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
		if err != nil {
			// Treat errors as transient during cleanup
			return false, nil
		}

		// Application is gone when it no longer appears in the list
		for _, app := range listResp.Applications {
			if app.Name == targetApp.Name {
				// Application still exists
				return false, nil
			}
		}

		// Application is gone
		return true, nil
	})

	if err != nil {
		t.Errorf("CleanupApplication: Process %d for %q still alive after DeleteApplication", targetPID, name)
	}
}

// cleanupServer stops the server and verifies port release
func cleanupServer(t *testing.T, cmd *exec.Cmd, serverAddr string) {
	if cmd != nil && cmd.Process != nil {
		t.Logf("Stopping server (PID %d) at %s...", cmd.Process.Pid, serverAddr)
		startTime := time.Now()
		if err := cmd.Process.Kill(); err != nil {
			t.Logf("Warning: Failed to kill server: %v", err)
		}
		cmd.Wait()
		elapsed := time.Since(startTime)
		t.Logf("Server stopped in %v", elapsed)

		// CI-009: Verify port release after server shutdown
		t.Logf("Verifying port release for %s...", serverAddr)
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := waitForPortAvailable(t, releaseCtx, serverAddr); err != nil {
			t.Logf("Warning: Port %s not released after server kill: %v", serverAddr, err)
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

	// Kill any stray servers before starting a new one to prevent port conflicts
	killStrayServers()
	// Wait for port to be available before attempting to start server
	portWaitCtx, portCancel := context.WithTimeout(ctx, 10*time.Second)
	defer portCancel()

	if err := waitForPortAvailable(t, portWaitCtx, serverAddr); err != nil {
		t.Fatalf("Port %s not available after stray server kill: %v", serverAddr, err)
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

	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}

	// Wait for server to be ready using poll
	t.Log("Waiting for server to be ready...")
	serverCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	err := PollUntilContext(serverCtx, 100*time.Millisecond, func() (bool, error) {
		testConn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			return false, nil
		}
		defer testConn.Close()

		client := pb.NewMacosUseClient(testConn)
		_, err = client.ListApplications(serverCtx, &pb.ListApplicationsRequest{})
		return err == nil, nil
	})
	if err != nil {
		cmd.Process.Kill()
		t.Fatalf("Server failed to become ready: %v", err)
	}

	return cmd, serverAddr
}

// connectToServer establishes a gRPC connection
func connectToServer(t *testing.T, ctx context.Context, addr string) *grpc.ClientConn {
	t.Logf("Connecting to server at %s...", addr)

	var conn *grpc.ClientConn
	var err error

	// CRITICAL FIX: Increased retry count from 10 to 20 with exponential backoff for CI environment
	for i := 0; i < 20; i++ {
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

// OpenApplicationAndWait opens an application and waits for the LRO to complete.
// Returns the Application resource on success.
func OpenApplicationAndWait(t *testing.T, ctx context.Context, client pb.MacosUseClient, opsClient longrunningpb.OperationsClient, appID string) *pb.Application {
	t.Helper()

	// Start the long-running operation
	op, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id: appID,
	})
	if err != nil {
		t.Fatalf("Failed to start OpenApplication: %v", err)
	}

	t.Logf("OpenApplication operation started: %s", op.Name)

	// Poll the operation until it completes
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			return false, fmt.Errorf("failed to get operation status: %w", err)
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("Failed waiting for OpenApplication operation: %v", err)
	}

	// Check for error
	if op.GetError() != nil {
		t.Fatalf("OpenApplication operation failed: %v", op.GetError())
	}

	// Extract the Application from the response
	response := &pb.OpenApplicationResponse{}
	if err := op.GetResponse().UnmarshalTo(response); err != nil {
		t.Fatalf("Failed to unmarshal operation response: %v", err)
	}

	app := response.Application
	if app == nil {
		t.Fatalf("Operation completed but no application returned")
	}

	t.Logf("Application opened successfully: %s (PID: %d)", app.Name, app.Pid)
	return app
}
