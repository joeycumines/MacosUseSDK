package integration_test

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	defaultServerAddr = "localhost:50051"
	calculatorAppName = "Calculator"
)

// TestCalculatorAddition is an integration test that:
// 1. Starts the MacosUse gRPC server
// 2. Opens the Calculator app
// 3. Performs addition (2+3)
// 4. Reads the result from the UI
// 5. Verifies the result is 5
func TestCalculatorAddition(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Calculator
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Wait for app to be ready
	time.Sleep(1 * time.Second)

	// Type: 2+3=
	t.Log("Typing '2+3='...")
	performInput(t, ctx, client, app, "2")
	performInput(t, ctx, client, app, "+")
	performInput(t, ctx, client, app, "3")
	performInput(t, ctx, client, app, "=")

	// Wait for calculation to complete
	time.Sleep(500 * time.Millisecond)

	// Traverse the UI to get the result
	t.Log("Reading result from Calculator...")
	result := readCalculatorResult(t, ctx, client, app)

	// Verify the result
	if result != "5" {
		t.Fatalf("Expected result '5', got '%s'", result)
	}

	t.Log("✅ Successfully verified: 2+3=5")
}

// TestCalculatorMultiplication tests multiplication: 7*8=56
func TestCalculatorMultiplication(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Calculator
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Wait for app to be ready
	time.Sleep(1 * time.Second)

	// Type: 7*8=
	t.Log("Typing '7*8='...")
	performInput(t, ctx, client, app, "7")
	performInput(t, ctx, client, app, "*")
	performInput(t, ctx, client, app, "8")
	performInput(t, ctx, client, app, "=")

	// Wait for calculation to complete
	time.Sleep(500 * time.Millisecond)

	// Traverse the UI to get the result
	t.Log("Reading result from Calculator...")
	result := readCalculatorResult(t, ctx, client, app)

	// Verify the result
	if result != "56" {
		t.Fatalf("Expected result '56', got '%s'", result)
	}

	t.Log("✅ Successfully verified: 7*8=56")
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

// openCalculator opens the Calculator app and waits for the operation to complete
func openCalculator(t *testing.T, ctx context.Context, client pb.MacosUseClient, opsClient longrunningpb.OperationsClient) *pb.Application {
	// Start the long-running operation
	op, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id: calculatorAppName,
	})
	if err != nil {
		t.Fatalf("Failed to start OpenApplication: %v", err)
	}

	t.Logf("OpenApplication operation started: %s", op.Name)

	// Poll the operation until it completes
	for {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			t.Fatalf("Failed to get operation status: %v", err)
		}

		if op.Done {
			break
		}

		t.Logf("Waiting for operation to complete...")
		time.Sleep(500 * time.Millisecond)
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

	t.Logf("Calculator opened successfully: %s (PID: %d)", app.Name, app.Pid)
	return app
}

// cleanupApplication removes the application from tracking
func cleanupApplication(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application) {
	if app == nil {
		return
	}

	t.Logf("Cleaning up application: %s", app.Name)
	_, err := client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
		Name: app.Name,
	})
	if err != nil {
		t.Logf("Warning: Failed to delete application: %v", err)
	}
}

// performInput creates and executes an input action
func performInput(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application, text string) {
	input, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_TypeText{
					TypeText: text,
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Failed to create input '%s': %v", text, err)
	}

	t.Logf("Input created and executed: %s", input.Name)

	// Wait for input to be processed
	time.Sleep(100 * time.Millisecond)
}

// readCalculatorResult traverses the UI and extracts the calculator result
func readCalculatorResult(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application) string {
	// Traverse the accessibility tree
	resp, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
		Name: app.Name,
	})
	if err != nil {
		t.Fatalf("Failed to traverse accessibility tree: %v", err)
	}

	if len(resp.Elements) == 0 {
		t.Fatalf("No elements in accessibility tree")
	}

	// Find the display element (usually a static text with the result)
	result := findCalculatorDisplay(resp.Elements)
	if result == "" {
		t.Fatalf("Could not find calculator display in UI tree")
	}

	return result
}

// findCalculatorDisplay searches through elements for the calculator display
func findCalculatorDisplay(elements []*typepb.Element) string {
	for _, elem := range elements {
		if elem == nil {
			continue
		}

		// Calculator display is typically a static text element with a number
		// Look for elements with text that looks like a number
		text := elem.GetText()
		if text != "" {
			value := strings.TrimSpace(text)
			if isNumeric(value) {
				return value
			}
		}
	}

	return ""
}

// isNumeric checks if a string looks like a numeric result
func isNumeric(s string) bool {
	if s == "" {
		return false
	}

	// Remove common formatting characters
	s = strings.ReplaceAll(s, ",", "")
	s = strings.ReplaceAll(s, " ", "")

	// Check if it's a valid number (simple check)
	for _, r := range s {
		if r < '0' || r > '9' {
			if r != '.' && r != '-' {
				return false
			}
		}
	}

	return true
}

// TestServerHealthCheck verifies the server is responding
func TestServerHealthCheck(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	// List applications (should return empty list initially)
	resp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("Failed to list applications: %v", err)
	}

	t.Logf("Server is healthy. Currently tracking %d applications", len(resp.Applications))
}

func TestMain(m *testing.M) {
	// Check if we're running on macOS
	if os.Getenv("SKIP_INTEGRATION_TESTS") != "" {
		fmt.Println("Skipping integration tests (SKIP_INTEGRATION_TESTS is set)")
		os.Exit(0)
	}

	// Run tests
	code := m.Run()
	os.Exit(code)
}
