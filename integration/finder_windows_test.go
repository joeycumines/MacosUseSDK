package integration

import (
	"context"
	"math"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestFinderWindows_Lifecycle verifies complete window lifecycle using Finder:
// - Open Finder window
// - List windows (verify present)
// - Get window metadata (title, bounds)
// - Move window
// - Verify new position
// - Close window
// - Verify removed from list
func TestFinderWindows_Lifecycle(t *testing.T) {
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

	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.finder")
	defer CleanupApplication(t, ctx, client, app.Name)

	// Create a new Finder window using AppleScript
	t.Log("Creating new Finder window...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to make new Finder window`,
	})
	if err != nil {
		t.Fatalf("Failed to create Finder window: %v", err)
	}

	// Step 1: List windows and verify Finder window is present
	t.Log("Step 1: Listing Finder windows...")
	var finderWindow *pb.Window
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}

		// Find a window with reasonable dimensions (not tiny)
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
	t.Logf("✓ Found Finder window: %s", finderWindow.Name)

	// Step 2: Get window metadata
	t.Log("Step 2: Getting window metadata...")
	getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
		Name: finderWindow.Name,
	})
	if err != nil {
		t.Fatalf("GetWindow failed: %v", err)
	}

	initialBounds := getResp.Bounds
	t.Logf("✓ Window title: %s", getResp.Title)
	t.Logf("✓ Window bounds: %.0fx%.0f at (%.0f, %.0f)",
		initialBounds.Width, initialBounds.Height, initialBounds.X, initialBounds.Y)

	// Store window name (may change during mutations due to ID regeneration)
	currentWindowName := finderWindow.Name

	// Step 3: Move window to new position
	// Use distinctive coordinates to avoid conflicts
	targetX := 234.0
	targetY := 156.0
	// Ensure they're different from initial position
	if math.Abs(initialBounds.X-targetX) < 10 {
		targetX = 345.0
	}
	if math.Abs(initialBounds.Y-targetY) < 10 {
		targetY = 267.0
	}

	t.Logf("Step 3: Moving window to (%.0f, %.0f)...", targetX, targetY)
	moveResp, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: currentWindowName,
		X:    targetX,
		Y:    targetY,
	})
	if err != nil {
		t.Fatalf("MoveWindow failed: %v", err)
	}

	// Update window name if it changed
	if moveResp.Name != currentWindowName {
		t.Logf("Window name changed after move: %s → %s", currentWindowName, moveResp.Name)
		currentWindowName = moveResp.Name
	}
	t.Log("✓ MoveWindow completed")

	// Step 4: Verify new position (state-delta assertion)
	t.Log("Step 4: Verifying new position...")
	var newBounds *pb.Bounds
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: currentWindowName,
		})
		if err != nil {
			// Window ID may have regenerated, try to find it again
			listResp, listErr := client.ListWindows(ctx, &pb.ListWindowsRequest{
				Parent: app.Name,
			})
			if listErr != nil {
				return false, nil
			}
			// Find window near target position
			for _, w := range listResp.Windows {
				if w.Bounds != nil && w.Bounds.Width > 100 && w.Bounds.Height > 100 {
					if math.Abs(w.Bounds.X-targetX) < 50 && math.Abs(w.Bounds.Y-targetY) < 50 {
						currentWindowName = w.Name
						newBounds = w.Bounds
						return true, nil
					}
				}
			}
			return false, nil
		}

		newBounds = getResp.Bounds
		// Check if position changed toward target (within tolerance)
		xMoved := math.Abs(newBounds.X-targetX) < 50
		yMoved := math.Abs(newBounds.Y-targetY) < 50
		return xMoved && yMoved, nil
	})
	if err != nil {
		t.Errorf("Window did not move to target position: %v", err)
	} else {
		t.Logf("✓ Window at new position: (%.0f, %.0f)", newBounds.X, newBounds.Y)
	}

	// Step 5: Close window
	t.Log("Step 5: Closing window...")
	_, err = client.CloseWindow(ctx, &pb.CloseWindowRequest{
		Name: currentWindowName,
	})
	if err != nil {
		t.Fatalf("CloseWindow failed: %v", err)
	}
	t.Log("✓ CloseWindow completed")

	// Step 6: Verify window removed from list (state-delta assertion)
	t.Log("Step 6: Verifying window removed from list...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, nil // Retry on error
		}

		// Check that our window is no longer in the list
		for _, w := range resp.Windows {
			if w.Name == currentWindowName {
				return false, nil // Window still exists
			}
		}
		return true, nil // Window is gone
	})
	if err != nil {
		t.Errorf("Window was not removed from list: %v", err)
	} else {
		t.Log("✓ Window removed from list")
	}

	t.Log("Finder window lifecycle test passed ✓")
}

// TestFinderWindows_Resize verifies window resize operation.
func TestFinderWindows_Resize(t *testing.T) {
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

	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.finder")
	defer CleanupApplication(t, ctx, client, app.Name)

	// Create a new Finder window
	t.Log("Creating new Finder window...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to make new Finder window`,
	})
	if err != nil {
		t.Fatalf("Failed to create Finder window: %v", err)
	}

	// Find the window
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
	t.Logf("Found Finder window: %s (%.0fx%.0f)", finderWindow.Name,
		finderWindow.Bounds.Width, finderWindow.Bounds.Height)

	currentWindowName := finderWindow.Name
	initialWidth := finderWindow.Bounds.Width
	initialHeight := finderWindow.Bounds.Height

	// Calculate target size (different from initial)
	targetWidth := 600.0
	targetHeight := 400.0
	if math.Abs(initialWidth-targetWidth) < 50 {
		targetWidth = 700.0
	}
	if math.Abs(initialHeight-targetHeight) < 50 {
		targetHeight = 500.0
	}

	t.Logf("Resizing window to %.0fx%.0f...", targetWidth, targetHeight)
	resizeResp, err := client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   currentWindowName,
		Width:  targetWidth,
		Height: targetHeight,
	})
	if err != nil {
		t.Fatalf("ResizeWindow failed: %v", err)
	}

	// Update window name if changed
	if resizeResp.Name != currentWindowName {
		t.Logf("Window name changed after resize: %s → %s", currentWindowName, resizeResp.Name)
		currentWindowName = resizeResp.Name
	}

	// Verify new size
	t.Log("Verifying new size...")
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		getResp, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: currentWindowName,
		})
		if err != nil {
			return false, nil // Retry
		}

		widthMatch := math.Abs(getResp.Bounds.Width-targetWidth) < 20
		heightMatch := math.Abs(getResp.Bounds.Height-targetHeight) < 20

		t.Logf("Current size: %.0fx%.0f (target: %.0fx%.0f)",
			getResp.Bounds.Width, getResp.Bounds.Height, targetWidth, targetHeight)

		return widthMatch && heightMatch, nil
	})
	if err != nil {
		t.Errorf("Window did not resize to target: %v", err)
	} else {
		t.Log("✓ Window resized successfully")
	}

	// Clean up
	_, _ = client.CloseWindow(ctx, &pb.CloseWindowRequest{Name: currentWindowName})

	t.Log("Finder window resize test passed ✓")
}

// TestFinderWindows_ListMultiple verifies listing multiple windows.
func TestFinderWindows_ListMultiple(t *testing.T) {
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

	// Open Finder
	t.Log("Opening Finder...")
	app := OpenApplicationAndWait(t, ctx, client, opsClient, "com.apple.finder")
	defer CleanupApplication(t, ctx, client, app.Name)

	// Create two Finder windows
	t.Log("Creating first Finder window...")
	_, err := client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to make new Finder window`,
	})
	if err != nil {
		t.Fatalf("Failed to create first Finder window: %v", err)
	}

	t.Log("Creating second Finder window...")
	_, err = client.ExecuteAppleScript(ctx, &pb.ExecuteAppleScriptRequest{
		Script: `tell application "Finder" to make new Finder window`,
	})
	if err != nil {
		t.Fatalf("Failed to create second Finder window: %v", err)
	}

	// Wait for at least 2 windows
	t.Log("Waiting for multiple windows...")
	var windows []*pb.Window
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}

		// Count windows with reasonable dimensions
		windows = nil
		for _, w := range resp.Windows {
			if w.Bounds != nil && w.Bounds.Width > 100 && w.Bounds.Height > 100 {
				windows = append(windows, w)
			}
		}
		return len(windows) >= 2, nil
	})
	if err != nil {
		t.Fatalf("Did not find 2 windows: found %d, error=%v", len(windows), err)
	}

	t.Logf("✓ Found %d Finder windows", len(windows))
	for i, w := range windows {
		t.Logf("  Window %d: %s at (%.0f, %.0f)", i+1, w.Name, w.Bounds.X, w.Bounds.Y)
	}

	// Close all windows
	for _, w := range windows {
		_, _ = client.CloseWindow(ctx, &pb.CloseWindowRequest{Name: w.Name})
	}

	t.Log("Finder multiple windows test passed ✓")
}
