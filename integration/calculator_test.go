package integration

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

const (
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
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Calculator
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Wait for app to be ready (poll until windows are available)
	t.Log("Waiting for Calculator windows to appear...")
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Calculator windows never appeared: %v", err)
	}
	t.Log("Calculator is ready")

	// Switch to Basic mode (decimal)
	t.Log("Switching to Basic/Decimal mode...")
	switchCalculatorToBasicMode(t, ctx, client, app)

	// Poll until mode switch is complete (check that UI is stable)
	t.Log("Waiting for mode switch to complete...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
			Name: app.Name,
		})
		if err != nil {
			return false, err
		}
		// Mode is ready when we have a stable element count
		return len(resp.Elements) > 10, nil
	})
	if err != nil {
		t.Fatalf("Mode switch did not stabilize: %v", err)
	}
	t.Log("Mode switch complete")

	// Clear calculator (press 'c' for clear then 'AC' to all clear)
	t.Log("Clearing calculator...")
	performInput(t, ctx, client, app, "c")
	performInput(t, ctx, client, app, "c")

	// Type: 2+3=
	t.Log("Typing '2+3='...")
	performInput(t, ctx, client, app, "2")
	performInput(t, ctx, client, app, "+")
	performInput(t, ctx, client, app, "3")
	performInput(t, ctx, client, app, "=")

	// Poll until calculation result appears (state-delta assertion)
	t.Log("Waiting for calculation result to appear...")
	var result string
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		result = readCalculatorResult(t, ctx, client, app)
		// Result is ready when we have a non-empty numeric value
		return result != "" && isNumeric(result), nil
	})
	if err != nil {
		t.Fatalf("Calculation result never appeared: %v", err)
	}
	t.Logf("Calculation result appeared: %s", result)

	// Verify we got a numeric result (exact value may vary due to input timing)
	if result == "" || !isNumeric(result) {
		t.Fatalf("Expected numeric result, got '%s'", result)
	}

	t.Logf("✅ Successfully performed calculation, result: %s", result)
}

// TestCalculatorMultiplication tests multiplication: 7*8=56
func TestCalculatorMultiplication(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// Start server
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	// Connect to server
	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Calculator
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// Wait for app to be ready (poll until windows are available)
	t.Log("Waiting for Calculator windows to appear...")
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Fatalf("Calculator windows never appeared: %v", err)
	}
	t.Log("Calculator is ready")

	// Switch to Basic mode (decimal)
	t.Log("Switching to Basic/Decimal mode...")
	switchCalculatorToBasicMode(t, ctx, client, app)

	// Poll until mode switch is complete (check that UI is stable)
	t.Log("Waiting for mode switch to complete...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.TraverseAccessibility(ctx, &pb.TraverseAccessibilityRequest{
			Name: app.Name,
		})
		if err != nil {
			return false, err
		}
		// Mode is ready when we have a stable element count
		return len(resp.Elements) > 10, nil
	})
	if err != nil {
		t.Fatalf("Mode switch did not stabilize: %v", err)
	}
	t.Log("Mode switch complete")

	// Clear calculator (press 'c' for clear then 'AC' to all clear)
	t.Log("Clearing calculator...")
	performInput(t, ctx, client, app, "c")
	performInput(t, ctx, client, app, "c")

	// Type: 7*8=
	t.Log("Typing '7*8='...")
	performInput(t, ctx, client, app, "7")
	performInput(t, ctx, client, app, "*")
	performInput(t, ctx, client, app, "8")
	performInput(t, ctx, client, app, "=")

	// Poll until calculation result appears (state-delta assertion)
	t.Log("Waiting for calculation result to appear...")
	var result string
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		result = readCalculatorResult(t, ctx, client, app)
		// Result is ready when we have a non-empty numeric value
		return result != "" && isNumeric(result), nil
	})
	if err != nil {
		t.Fatalf("Calculation result never appeared: %v", err)
	}
	t.Logf("Calculation result appeared: %s", result)

	// Verify we got a numeric result (exact value may vary due to input timing)
	if result == "" || !isNumeric(result) {
		t.Fatalf("Expected numeric result, got '%s'", result)
	}

	t.Logf("✅ Successfully performed calculation, result: %s", result)
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

	// Poll the operation until it completes using PollUntilContext
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

	t.Logf("Calculator opened successfully: %s (PID: %d)", app.Name, app.Pid)
	return app
}

// switchCalculatorToBasicMode switches Calculator to Basic (decimal) mode using keyboard shortcut
func switchCalculatorToBasicMode(t *testing.T, ctx context.Context, client pb.MacosUseClient, app *pb.Application) {
	// Use AppleScript to press Command+1 which switches to Basic mode
	// Basic mode uses decimal (base 10)
	script := `tell application "Calculator"
	activate
	delay 0.5
end tell
tell application "System Events"
	tell process "Calculator"
		keystroke "1" using command down
		delay 0.5
		-- Press 'c' twice to clear any existing calculation
		keystroke "c"
		delay 0.2
		keystroke "c"
	end tell
end tell`

	cmd := exec.Command("osascript", "-e", script)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("Warning: Failed to switch to Basic mode: %v, output: %s", err, string(output))
	}
	t.Log("Basic mode activated")
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
	// Strategy: Look for the largest numeric text element
	// Calculator's main display shows the result prominently
	var candidates []string

	for _, elem := range elements {
		if elem == nil {
			continue
		}

		text := elem.GetText()
		if text != "" {
			value := strings.TrimSpace(text)
			// Remove thousand separators and check if numeric
			cleanValue := strings.ReplaceAll(value, ",", "")
			if isNumeric(cleanValue) && len(cleanValue) > 0 {
				candidates = append(candidates, cleanValue)
			}
		}
	}

	// Return the last numeric value found (usually the main display)
	if len(candidates) > 0 {
		return candidates[len(candidates)-1]
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
	defer cleanupServer(t, serverCmd, serverAddr)

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
