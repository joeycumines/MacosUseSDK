// Copyright 2025 Joseph Cumines
//
// Integration test for background parameter in OpenApplication

package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestBackgroundOpenDoesNotStealFocus verifies that opening an application with
// background=true does not steal focus from the current frontmost application.
//
// This test:
// 1. Records current frontmost app via AppleScript
// 2. Opens Calculator with background=true
// 3. Verifies Calculator is tracked (ListApplications includes it)
// 4. Verifies frontmost app unchanged
// 5. Cleans up
func TestBackgroundOpenDoesNotStealFocus(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// 2. Ensure Finder is frontmost first (stable starting point)
	t.Log("Activating Finder as the starting frontmost application...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}

	// Wait for Finder to become frontmost
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		return resp.GetOutput() == "Finder", nil
	})
	if err != nil {
		t.Fatalf("Failed to make Finder frontmost: %v", err)
	}

	// 3. Record the current frontmost app
	t.Log("Recording initial frontmost application...")
	initialFrontmost := "Finder"
	t.Logf("Initial frontmost: %s", initialFrontmost)

	// 4. Open Calculator with background=true
	t.Log("Opening Calculator with background=true...")
	op, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id:         "Calculator",
		Background: true,
	})
	if err != nil {
		t.Fatalf("Failed to initiate OpenApplication: %v", err)
	}

	// Wait for operation to complete
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			return false, nil
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("OpenApplication operation never completed: %v", err)
	}
	if op.GetError() != nil {
		t.Fatalf("OpenApplication failed: %s", op.GetError().GetMessage())
	}

	// Extract the application from the response
	resp := &pb.OpenApplicationResponse{}
	if err := op.GetResponse().UnmarshalTo(resp); err != nil {
		t.Fatalf("Failed to unmarshal OpenApplicationResponse: %v", err)
	}
	app := resp.Application
	if app == nil {
		t.Fatalf("OpenApplication succeeded but returned nil application")
	}
	t.Logf("Calculator opened with PID %d (name: %s)", app.Pid, app.Name)

	// Clean up Calculator after test
	defer cleanupApplication(t, ctx, client, app)

	// 5. Verify Calculator is tracked in ListApplications
	t.Log("Verifying Calculator is tracked...")
	listResp, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{})
	if err != nil {
		t.Fatalf("Failed to list applications: %v", err)
	}
	found := false
	for _, trackedApp := range listResp.Applications {
		if trackedApp.Name == app.Name {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("Calculator (name=%s) not found in tracked applications", app.Name)
	}
	t.Log("Calculator is correctly tracked")

	// 6. Verify frontmost app is still the original (not Calculator)
	t.Log("Verifying frontmost app is unchanged...")
	frontmostResp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
	})
	if err != nil {
		t.Fatalf("Failed to check frontmost app: %v", err)
	}
	currentFrontmost := frontmostResp.GetOutput()
	t.Logf("Current frontmost: %s", currentFrontmost)

	if currentFrontmost == "Calculator" {
		t.Fatalf("FOCUS STEALING DETECTED: Calculator became frontmost despite background=true")
	}
	if currentFrontmost != initialFrontmost {
		t.Logf("Note: Frontmost changed from %s to %s, but not to Calculator", initialFrontmost, currentFrontmost)
	}
	t.Logf("SUCCESS: Background open did not steal focus. Initial=%s, Current=%s", initialFrontmost, currentFrontmost)
}

// TestForegroundOpenDoesStealFocus verifies that opening an application with
// background=false (the default) DOES make it frontmost.
func TestForegroundOpenDoesStealFocus(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// 2. Ensure Finder is frontmost first
	t.Log("Activating Finder as the starting frontmost application...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}

	// Wait for Finder to become frontmost
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		return resp.GetOutput() == "Finder", nil
	})
	if err != nil {
		t.Fatalf("Failed to make Finder frontmost: %v", err)
	}
	t.Log("Finder is frontmost")

	// 3. Open Calculator with background=false (default behavior)
	t.Log("Opening Calculator with background=false (default)...")
	op, err := client.OpenApplication(ctx, &pb.OpenApplicationRequest{
		Id:         "Calculator",
		Background: false, // Explicit for clarity
	})
	if err != nil {
		t.Fatalf("Failed to initiate OpenApplication: %v", err)
	}

	// Wait for operation to complete
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			return false, nil
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("OpenApplication operation never completed: %v", err)
	}
	if op.GetError() != nil {
		t.Fatalf("OpenApplication failed: %s", op.GetError().GetMessage())
	}

	resp := &pb.OpenApplicationResponse{}
	if err := op.GetResponse().UnmarshalTo(resp); err != nil {
		t.Fatalf("Failed to unmarshal OpenApplicationResponse: %v", err)
	}
	app := resp.Application
	if app == nil {
		t.Fatalf("OpenApplication succeeded but returned nil application")
	}
	t.Logf("Calculator opened with PID %d", app.Pid)
	defer cleanupApplication(t, ctx, client, app)

	// 4. Verify Calculator became frontmost
	t.Log("Verifying Calculator became frontmost...")
	calculatorBecameFrontmost := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		frontmostResp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		if frontmostResp.GetOutput() == "Calculator" {
			calculatorBecameFrontmost = true
			return true, nil
		}
		return false, nil
	})
	if !calculatorBecameFrontmost {
		t.Fatalf("Expected Calculator to become frontmost with background=false, but it did not")
	}
	t.Log("SUCCESS: Foreground open correctly made Calculator frontmost")
}
