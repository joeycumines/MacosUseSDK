package integration

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"

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

	// Pre-flight cleanup: Kill golden applications to ensure clean slate
	_, _ = fmt.Fprintln(os.Stderr, "TestMain: Pre-flight cleanup - killing golden applications...")
	killGoldenApplications()

	code := m.Run()

	os.Exit(code)
}

// killGoldenApplications forcefully terminates all golden test applications.
// Golden Applications:
// - Calculator (com.apple.calculator)
// - TextEdit (com.apple.TextEdit) - NOTE: Hopefully you aren't using it...
// - Finder (com.apple.finder) - NOTE: Avoiding Finder kill to prevent system issues
func killGoldenApplications() {
	apps := []string{"Calculator", "TextEdit"}
	for _, app := range apps {
		cmd := exec.Command("killall", "-9", app)
		_ = cmd.Run() // Ignore errors (app may not be running)
	}
	// Give OS time to clean up processes
	time.Sleep(500 * time.Millisecond)
}

// cleanupServer stops the server
func cleanupServer(t *testing.T, cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		t.Log("Stopping server...")
		if err := cmd.Process.Kill(); err != nil {
			t.Logf("Warning: Failed to kill server: %v", err)
		}
		cmd.Wait()
	}
}

// startServer starts the MacosUse server and returns the command and address
func startServer(t *testing.T, ctx context.Context) (*exec.Cmd, string) {
	// Check if INTEGRATION_SERVER_ADDR is set (for external server)
	if addr := os.Getenv("INTEGRATION_SERVER_ADDR"); addr != "" {
		t.Logf("Using existing server at %s", addr)
		// Wait a bit to ensure it's ready
		time.Sleep(500 * time.Millisecond)
		return nil, addr
	}

	// Build the server
	t.Log("Building MacosUse server...")
	buildCmd := exec.CommandContext(ctx, "swift", "build", "-c", "release", "--package-path", "../Server")
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr
	if err := buildCmd.Run(); err != nil {
		t.Fatalf("Failed to build server: %v", err)
	}

	// Start the server
	serverAddr := defaultServerAddr
	t.Logf("Starting MacosUse server on %s...", serverAddr)

	cmd := exec.CommandContext(ctx, "../Server/.build/release/MacosUseServer")
	cmd.Env = append(os.Environ(),
		"GRPC_LISTEN_ADDRESS=0.0.0.0",
		"GRPC_PORT=50051",
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start server: %v", err)
	}

	// Wait for server to be ready
	t.Log("Waiting for server to be ready...")
	time.Sleep(3 * time.Second)

	return cmd, serverAddr
}

// connectToServer establishes a gRPC connection
func connectToServer(t *testing.T, ctx context.Context, addr string) *grpc.ClientConn {
	t.Logf("Connecting to server at %s...", addr)

	var conn *grpc.ClientConn
	var err error

	// Retry connection with backoff
	for i := 0; i < 10; i++ {
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

		t.Logf("Connection attempt %d failed, retrying... (error: %v)", i+1, err)
		time.Sleep(500 * time.Millisecond)
	}

	t.Fatalf("Failed to connect to server after retries: %v", err)
	return nil
}
