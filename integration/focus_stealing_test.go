package integration

import (
	"context"
	"fmt"
	"strconv"
	"strings"
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
	app := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app)

	// 3. Deactivate the exact Calculator process using Finder. Require a
	// stable baseline so late application-launch activation cannot be blamed on
	// the observer.
	t.Log("Deactivating Calculator by activating Finder...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}

	deactivateCtx, cancelDeactivate := context.WithTimeout(ctx, 10*time.Second)
	defer cancelDeactivate()
	err = waitForStableBackgroundProcess(deactivateCtx, client, app.Pid, time.Second)
	if err != nil {
		t.Fatalf("Failed to establish stable background Calculator PID %d: %v", app.Pid, err)
	}

	// 4. Create observation with activate=false (passive mode)
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

	// 5. Poll multiple times to verify the exact owned Calculator process never
	// becomes frontmost. Another Calculator process is external activity, not
	// evidence that this observation activated its target.
	t.Log("Verifying Calculator never becomes frontmost during observation polling...")
	focusStealingDetected := false
	pollCount := 0
	maxPolls := 20

	checkCtx, cancelCheck := context.WithTimeout(ctx, 10*time.Second)
	defer cancelCheck()
	pollTicker := time.NewTicker(100 * time.Millisecond)
	defer pollTicker.Stop()

pollLoop:
	for i := range maxPolls {
		pollCount++

		present, frontmost, err := exactProcessFrontmost(checkCtx, client, app.Pid)
		if err != nil {
			t.Fatalf("Failed to inspect Calculator PID %d on poll %d: %v", app.Pid, i, err)
		}
		if !present {
			t.Fatalf("Owned Calculator PID %d disappeared on poll %d", app.Pid, i)
		}
		if frontmost {
			focusStealingDetected = true
			t.Errorf("FOCUS STEALING DETECTED on poll %d: owned Calculator PID %d became frontmost", i, app.Pid)
			break pollLoop
		}
		t.Logf("Poll %d: Calculator PID %d remained background (OK)", i, app.Pid)

		select {
		case <-checkCtx.Done():
			break pollLoop
		case <-pollTicker.C:
		}
	}

	// 6. Final verification
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
	app := openCalculator(t, ctx, client)
	defer cleanupApplication(t, ctx, client, app)

	t.Log("Deactivating Calculator by activating Finder...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}

	deactivateCtx, cancelDeactivate := context.WithTimeout(ctx, 10*time.Second)
	defer cancelDeactivate()
	err = waitForStableBackgroundProcess(deactivateCtx, client, app.Pid, time.Second)
	if err != nil {
		t.Fatalf("Failed to establish stable background Calculator PID %d: %v", app.Pid, err)
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
		present, frontmost, err := exactProcessFrontmost(ctx, client, app.Pid)
		if err != nil {
			return false, err
		}
		if !present {
			return false, fmt.Errorf("owned Calculator PID %d disappeared", app.Pid)
		}
		if frontmost {
			calculatorBecameFrontmost = true
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Failed while waiting for active observation focus: %v", err)
	}

	if !calculatorBecameFrontmost {
		t.Fatalf("Expected Calculator to become frontmost with activate=true, but it did not")
	}

	t.Log("SUCCESS: Calculator correctly became frontmost with active observation (activate=true)")
}

func waitForStableBackgroundProcess(
	ctx context.Context,
	client pb.MacosUseClient,
	pid int32,
	stableFor time.Duration,
) error {
	var stableSince time.Time
	return PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		present, frontmost, err := exactProcessFrontmost(ctx, client, pid)
		if err != nil {
			return false, err
		}
		if !present {
			return false, fmt.Errorf("owned process PID %d disappeared", pid)
		}
		if frontmost {
			stableSince = time.Time{}
			_, err = client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
				Script: `tell application "Finder" to activate`,
			})
			return false, err
		}
		if stableSince.IsZero() {
			stableSince = time.Now()
		}
		return time.Since(stableSince) >= stableFor, nil
	})
}

func exactProcessFrontmost(
	ctx context.Context,
	client pb.MacosUseClient,
	pid int32,
) (present bool, frontmost bool, err error) {
	script := `tell application "System Events"
set matches to every application process whose unix id is ` + strconv.FormatInt(int64(pid), 10) + `
if (count of matches) is 0 then return "missing"
return frontmost of item 1 of matches
end tell`
	resp, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{Script: script})
	if err != nil {
		return false, false, err
	}
	switch strings.ToLower(strings.TrimSpace(resp.GetOutput())) {
	case "true":
		return true, true, nil
	case "false":
		return true, false, nil
	case "missing":
		return false, false, nil
	default:
		return false, false, fmt.Errorf("unexpected exact-PID frontmost response %q", resp.GetOutput())
	}
}
