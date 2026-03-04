// Copyright 2025 Joseph Cumines
//
// Drag operation integration test using Finder.
// Tests window drag via MouseDrag proto action (a complete drag operation:
// buttonDown → incremental leftMouseDragged events → buttonUp), then verifies
// the window position changed (state-delta assertion).
// Task: T075

package integration

import (
	"context"
	"math"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestDragOperation_MoveFinderWindow verifies window drag via CreateInput by:
// 1. Opening Finder and creating a window at a known position
// 2. Recording the window's initial position
// 3. Performing a drag on the title bar using MouseDrag proto action
// 4. Verifying the window moved to the target position (state-delta assertion)
//
// This exercises the MouseDrag input type which performs a complete drag operation
// using leftMouseDragged CGEvent type (required for proper window manager recognition).
func TestDragOperation_MoveFinderWindow(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// Open Finder and create a window.
	t.Log("Opening Finder...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.finder")
	defer CleanupApplication(t, ctx, client, app.Name)

	t.Log("Creating new Finder window...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to make new Finder window`,
	})
	if err != nil {
		t.Fatalf("Failed to create Finder window: %v", err)
	}

	// Find the Finder window.
	var finderWindow *pb.Window
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		for _, w := range resp.Windows {
			if w.Bounds != nil && w.Bounds.Width > 100 && w.Bounds.Height > 100 {
				finderWindow = w
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Finder window never appeared: %v", err)
	}
	t.Logf("Found Finder window: %s", finderWindow.Name)

	currentWindowName := finderWindow.Name

	// Register deferred cleanup: close the Finder window.
	// Registered early so it runs even if subsequent steps fatal.
	defer func() {
		_, _ = client.CloseWindow(ctx, &pb.CloseWindowRequest{Name: currentWindowName})
	}()

	// Move window to a known starting position away from screen edges.
	startX := 200.0
	startY := 200.0

	moveResp, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: currentWindowName,
		X:    startX,
		Y:    startY,
	})
	if err != nil {
		t.Fatalf("MoveWindow to starting position failed: %v", err)
	}
	if moveResp.Name != currentWindowName {
		t.Logf("Window name changed after MoveWindow: %s -> %s", currentWindowName, moveResp.Name)
		currentWindowName = moveResp.Name
	}

	// Wait for window to arrive at starting position.
	// Use ListWindows fallback to handle window ID regeneration race condition.
	var initialBounds *pb.Bounds
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: currentWindowName,
		})
		if err == nil {
			initialBounds = getResp.Bounds
			xOK := math.Abs(initialBounds.X-startX) < 50
			yOK := math.Abs(initialBounds.Y-startY) < 50
			return xOK && yOK, nil
		}
		// GetWindow failed; fallback to ListWindows.
		listResp, listErr := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if listErr != nil {
			return false, nil
		}
		for _, w := range listResp.Windows {
			if w.Bounds != nil && w.Bounds.Width > 100 && w.Bounds.Height > 100 {
				if math.Abs(w.Bounds.X-startX) < 50 && math.Abs(w.Bounds.Y-startY) < 50 {
					currentWindowName = w.Name
					initialBounds = w.Bounds
					return true, nil
				}
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Window did not settle at starting position: %v", err)
	}
	t.Logf("Window at starting position: (%.0f, %.0f) size: %.0fx%.0f",
		initialBounds.X, initialBounds.Y, initialBounds.Width, initialBounds.Height)

	// Perform drag using the MouseDrag proto action which performs a complete
	// drag operation: buttonDown at start → incremental leftMouseDragged events → buttonUp.
	// The MouseDrag action is the proper mechanism for window title-bar dragging.
	//
	// Title bar drag point: use position ~100px from left edge, 12px from top.
	// Avoid the window center where Finder toolbar controls may intercept the event.
	// The title bar "drag region" is typically the leftmost portion before toolbar items.
	dragStartX := initialBounds.X + 100
	dragStartY := initialBounds.Y + 12
	dragDeltaX := 200.0
	dragDeltaY := 150.0
	dragEndX := dragStartX + dragDeltaX
	dragEndY := dragStartY + dragDeltaY

	// Ensure Finder is frontmost so the window manager recognizes title bar drags.
	_, err = client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to activate`,
	})
	if err != nil {
		t.Fatalf("Failed to activate Finder: %v", err)
	}
	// Wait for activation to take effect; use PollUntil with a fixed number of
	// iterations (poll checks are cheap but activation is asynchronous).
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		// ListWindows is cheap and forces a round-trip — if Finder has focus,
		// its window ordering should be stable by now.
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{Parent: app.Name})
		if err != nil {
			return false, nil
		}
		// We consider activation "done" once we can enumerate at least one window.
		return len(resp.Windows) > 0, nil
	})
	if err != nil {
		t.Logf("Warning: Finder activation may not have completed: %v", err)
	}

	t.Logf("Drag: from (%.0f, %.0f) to (%.0f, %.0f)",
		dragStartX, dragStartY, dragEndX, dragEndY)

	dragResp, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_Drag{
					Drag: &pb.MouseDrag{
						StartPosition: &typepb.Point{X: dragStartX, Y: dragStartY},
						EndPosition:   &typepb.Point{X: dragEndX, Y: dragEndY},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("CreateInput (drag) gRPC error: %v", err)
	}
	if dragResp.State != pb.Input_STATE_COMPLETED {
		t.Fatalf("CreateInput (drag) unexpected state %v (error: %s)", dragResp.State, dragResp.Error)
	}
	t.Log("Drag completed")

	// Verify window moved (state-delta assertion).
	expectedX := initialBounds.X + dragDeltaX
	expectedY := initialBounds.Y + dragDeltaY
	t.Logf("Expected window position: (%.0f, %.0f)", expectedX, expectedY)

	var finalBounds *pb.Bounds
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: currentWindowName,
		})
		if err == nil {
			finalBounds = getResp.Bounds
			xOK := math.Abs(finalBounds.X-expectedX) < 80
			yOK := math.Abs(finalBounds.Y-expectedY) < 80
			return xOK && yOK, nil
		}
		// Window ID may have regenerated; search by proximity.
		listResp, listErr := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if listErr != nil {
			return false, nil
		}
		for _, w := range listResp.Windows {
			if w.Bounds != nil && w.Bounds.Width > 100 && w.Bounds.Height > 100 {
				if math.Abs(w.Bounds.X-expectedX) < 80 && math.Abs(w.Bounds.Y-expectedY) < 80 {
					currentWindowName = w.Name
					finalBounds = w.Bounds
					return true, nil
				}
			}
		}
		return false, nil
	})
	if err != nil {
		if finalBounds != nil {
			t.Fatalf("Window did not move to expected position: actual=(%.0f, %.0f), expected=(%.0f, %.0f): %v",
				finalBounds.X, finalBounds.Y, expectedX, expectedY, err)
		}
		t.Fatalf("Window position could not be determined after drag: %v", err)
	}

	// Verify the window moved significantly (at least 100px in one direction).
	deltaX := math.Abs(finalBounds.X - initialBounds.X)
	deltaY := math.Abs(finalBounds.Y - initialBounds.Y)
	t.Logf("Window moved from (%.0f, %.0f) to (%.0f, %.0f) -- delta=(%.0f, %.0f)",
		initialBounds.X, initialBounds.Y, finalBounds.X, finalBounds.Y, deltaX, deltaY)

	if deltaX < 100 && deltaY < 100 {
		t.Errorf("Window did not move significantly: deltaX=%.0f, deltaY=%.0f (expected at least 100px in one axis)",
			deltaX, deltaY)
	}

	t.Logf("Drag successfully moved window to (%.0f, %.0f)", finalBounds.X, finalBounds.Y)
}

// TestDragOperation_InputStateTracking verifies that the server correctly
// reports Input.State = COMPLETED for a MouseDrag operation and that the
// resulting Input is retrievable via GetInput. Also validates the AIP-159
// wildcard parent "applications/-" for desktop-level input scope.
func TestDragOperation_InputStateTracking(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	// Get display center for safe coordinates.
	displayResp, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Fatalf("ListDisplays failed: %v", err)
	}
	if len(displayResp.Displays) == 0 {
		t.Fatal("No displays found")
	}

	var mainDisplay *pb.Display
	for _, d := range displayResp.Displays {
		if d.IsMain {
			mainDisplay = d
			break
		}
	}
	if mainDisplay == nil {
		mainDisplay = displayResp.Displays[0]
	}
	cx := mainDisplay.Frame.X + mainDisplay.Frame.Width/2
	cy := mainDisplay.Frame.Y + mainDisplay.Frame.Height/2

	// Use AIP-159 wildcard parent "applications/-" to indicate desktop-level
	// (all applications) scope for CGEvent-based mouse operations. The server
	// treats this as nil PID, identical to empty parent but semantically correct.
	dragResp, err := client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: "applications/-",
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_Drag{
					Drag: &pb.MouseDrag{
						StartPosition: &typepb.Point{X: cx, Y: cy},
						EndPosition:   &typepb.Point{X: cx + 50, Y: cy + 50},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("MouseDrag gRPC error: %v", err)
	}
	if dragResp.State != pb.Input_STATE_COMPLETED {
		t.Errorf("MouseDrag state: got %v, want COMPLETED (error: %s)", dragResp.State, dragResp.Error)
	} else {
		t.Logf("MouseDrag state=COMPLETED, name=%s", dragResp.Name)
	}

	// Verify drag input is retrievable via GetInput and has correct state.
	getResp, err := client.GetInput(ctx, &pb.GetInputRequest{Name: dragResp.Name})
	if err != nil {
		t.Fatalf("GetInput(%s) failed: %v", dragResp.Name, err)
	}
	if getResp.State != pb.Input_STATE_COMPLETED {
		t.Errorf("GetInput(%s) state: got %v, want COMPLETED", dragResp.Name, getResp.State)
	}

	// Verify the input name uses desktopInputs/ prefix (wildcard parent = desktop-level).
	if len(dragResp.Name) < 14 || dragResp.Name[:14] != "desktopInputs/" {
		t.Errorf("Expected desktopInputs/ prefix for wildcard parent, got name: %s", dragResp.Name)
	}
}
