package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestNoFocusStealingWithPassiveObservation verifies that observations with
// activate=false do not steal focus from the current application.
//
// This test validates the solution to the "activation cycle problem" documented
// in docs/window-state-management.md Section 8: when an AI agent creates an
// observation to monitor Calculator, the observation polling should NOT bring
// Calculator to the foreground, preserving the user's current focus.
func TestNoFocusStealingWithPassiveObservation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// 2. Open Calculator
	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// 3. Find Calculator window
	t.Log("Finding Calculator window...")
	var calcWindow *pb.Window
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, nil
		}
		if len(resp.Windows) > 0 {
			calcWindow = resp.Windows[0]
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Failed to find Calculator window: %v", err)
	}
	t.Logf("Found Calculator window: %s", calcWindow.Name)

	// 4. Deactivate Calculator using Finder
	t.Log("Deactivating Calculator by activating Finder...")
	_, err = client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}

	// Wait for Calculator to not be frontmost
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		frontmost := resp.GetOutput()
		t.Logf("Current frontmost: %s", frontmost)
		return frontmost != "Calculator", nil
	})
	if err != nil {
		t.Fatalf("Failed to deactivate Calculator: %v", err)
	}

	// 5. Create observation with activate=false (passive mode)
	t.Log("Creating passive observation (activate=false)...")
	createReq := &pb.CreateObservationRequest{
		Parent: app.Name,
		Observation: &pb.Observation{
			Type:     pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES,
			Activate: false,
			Filter: &pb.ObservationFilter{
				PollInterval: 0.5,
			},
		},
	}

	op, err := client.CreateObservation(ctx, createReq)
	if err != nil {
		t.Fatalf("Failed to create observation: %v", err)
	}

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
		t.Fatalf("Failed to wait for observation creation: %v", err)
	}

	if op.GetError() != nil {
		t.Fatalf("Observation creation failed: %v", op.GetError())
	}

	obs := &pb.Observation{}
	if err := op.GetResponse().UnmarshalTo(obs); err != nil {
		t.Fatalf("Failed to unmarshal observation: %v", err)
	}
	t.Logf("Created observation: %s", obs.Name)

	defer func() {
		_, _ = client.CancelObservation(ctx, &pb.CancelObservationRequest{
			Name: obs.Name,
		})
		t.Logf("Cancelled observation: %s", obs.Name)
	}()

	// 6. Perform UI changes on Calculator window
	t.Log("Performing window resize on Calculator...")
	newWidth := calcWindow.Bounds.Width + 50
	newHeight := calcWindow.Bounds.Height + 50
	_, err = client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   calcWindow.Name,
		Width:  newWidth,
		Height: newHeight,
	})
	if err != nil {
		t.Logf("Warning: ResizeWindow failed (may not be critical): %v", err)
	}

	// 7. Poll multiple times to verify Calculator never becomes frontmost
	t.Log("Verifying Calculator never becomes frontmost during observation polling...")
	focusStealingDetected := false
	pollCount := 0
	maxPolls := 20

	checkCtx, cancelCheck := context.WithTimeout(ctx, 10*time.Second)
	defer cancelCheck()

pollLoop:
	for i := 0; i < maxPolls; i++ {
		pollCount++

		resp, err := client.ExecuteAppleScript(checkCtx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			t.Logf("Warning: Failed to check frontmost app on poll %d: %v", i, err)
			continue
		}

		currentFrontmost := resp.GetOutput()
		if currentFrontmost == "Calculator" {
			focusStealingDetected = true
			t.Errorf("FOCUS STEALING DETECTED on poll %d: Calculator became frontmost!", i)
			break pollLoop
		}
		t.Logf("Poll %d: frontmost=%s (OK)", i, currentFrontmost)

		select {
		case <-checkCtx.Done():
			break pollLoop
		case <-time.After(100 * time.Millisecond):
		}
	}

	// 8. Final verification
	if focusStealingDetected {
		t.Fatalf("Focus stealing occurred during passive observation")
	}

	t.Logf("SUCCESS: No focus stealing detected across %d polls", pollCount)
}

// TestFocusStealingWithActiveObservation verifies that observations with
// activate=true DO bring the application to the foreground.
func TestFocusStealingWithActiveObservation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	t.Log("Opening Calculator...")
	app := openCalculator(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	t.Log("Deactivating Calculator by activating Finder...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}

	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		return resp.GetOutput() != "Calculator", nil
	})
	if err != nil {
		t.Fatalf("Failed to deactivate Calculator: %v", err)
	}
	t.Log("Calculator is no longer frontmost")

	t.Log("Creating active observation (activate=true)...")
	createReq := &pb.CreateObservationRequest{
		Parent: app.Name,
		Observation: &pb.Observation{
			Type:     pb.ObservationType_OBSERVATION_TYPE_TREE_CHANGES,
			Activate: true,
			Filter: &pb.ObservationFilter{
				PollInterval: 0.5,
			},
		},
	}

	op, err := client.CreateObservation(ctx, createReq)
	if err != nil {
		t.Fatalf("Failed to create observation: %v", err)
	}

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
		t.Fatalf("Failed to wait for observation creation: %v", err)
	}

	if op.GetError() != nil {
		t.Fatalf("Observation creation failed: %v", op.GetError())
	}

	obs := &pb.Observation{}
	if err := op.GetResponse().UnmarshalTo(obs); err != nil {
		t.Fatalf("Failed to unmarshal observation: %v", err)
	}
	t.Logf("Created observation: %s", obs.Name)

	defer func() {
		_, _ = client.CancelObservation(ctx, &pb.CancelObservationRequest{
			Name: obs.Name,
		})
	}()

	t.Log("Verifying Calculator becomes frontmost with active observation...")
	calculatorBecameFrontmost := false
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
			Script: `tell application "System Events" to return name of first application process whose frontmost is true`,
		})
		if err != nil {
			return false, nil
		}
		if resp.GetOutput() == "Calculator" {
			calculatorBecameFrontmost = true
			return true, nil
		}
		return false, nil
	})

	if !calculatorBecameFrontmost {
		t.Fatalf("Expected Calculator to become frontmost with activate=true, but it did not")
	}

	t.Log("SUCCESS: Calculator correctly became frontmost with active observation (activate=true)")
}
