package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestWindowMetadataPreservation verifies that window metadata (bundleID, zIndex, visible)
// is correctly preserved and updated in responses after window mutation operations.
//
// Test Flow:
// 1. Open TextEdit
// 2. Get initial window with bundleID, zIndex, visible
// 3. Call MoveWindow and verify response contains correct bundleID, zIndex, visible (not empty/zero/false)
// 4. Call ResizeWindow and verify response contains correct bundleID, zIndex, visible
// 5. Call MinimizeWindow and verify visible becomes false
// 6. Call RestoreWindow and verify visible becomes true
// 7. Cleanup by deleting application
func TestWindowMetadataPreservation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// 2. Open TextEdit
	t.Log("Opening TextEdit...")
	app := openTextEdit(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// 3. Wait for document window to appear and get initial window
	t.Log("Waiting for TextEdit document window to appear...")
	var initialWindow *pb.Window
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		// Find a suitable document window (reasonable dimensions, minimizable)
		for _, window := range resp.Windows {
			if window.Bounds != nil &&
				window.Bounds.Width >= 200 && window.Bounds.Height >= 200 {
				// Verify it's minimizable using GetWindowState
				stateName := window.Name + "/state"
				windowState, err := client.GetWindowState(ctx, &pb.GetWindowStateRequest{
					Name: stateName,
				})
				if err != nil {
					continue
				}
				if windowState.Minimizable {
					initialWindow = window
					return true, nil
				}
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("TextEdit document window never appeared: %v", err)
	}
	t.Logf("Initial window found: %s", initialWindow.Name)

	// 4. Verify initial window metadata is populated
	t.Log("Verifying initial window metadata...")

	// Verify initial metadata is populated
	if initialWindow.BundleId == "" {
		t.Error("Initial window: bundleID is empty")
	}
	if initialWindow.ZIndex == 0 {
		t.Log("Warning: Initial window zIndex is 0 (may be valid)")
	}
	// visible should be true for a newly opened window
	if !initialWindow.Visible {
		t.Error("Initial window: expected visible=true for new window")
	}

	t.Logf("Initial window: bundleID=%s, zIndex=%d, visible=%v",
		initialWindow.BundleId, initialWindow.ZIndex, initialWindow.Visible)

	// Store initial values for comparison
	expectedBundleID := initialWindow.BundleId
	stateName := initialWindow.Name + "/state"

	// 5. Test MoveWindow - verify metadata is preserved in response
	t.Log("Testing MoveWindow metadata preservation...")
	moveResp, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: initialWindow.Name,
		X:    150,
		Y:    150,
	})
	if err != nil {
		t.Fatalf("MoveWindow failed: %v", err)
	}

	// Verify MoveWindow response contains metadata
	if moveResp.BundleId == "" {
		t.Error("MoveWindow response: bundleID is empty")
	}
	if moveResp.BundleId != expectedBundleID {
		t.Errorf("MoveWindow response: bundleID mismatch, expected=%s, got=%s",
			expectedBundleID, moveResp.BundleId)
	}
	if moveResp.ZIndex == 0 {
		t.Log("Warning: MoveWindow response zIndex is 0")
	}
	// Window should still be visible after move
	moveVisible := moveResp.Visible
	if !moveVisible {
		t.Error("MoveWindow response: visible is false (expected true)")
	}
	t.Logf("MoveWindow response: bundleID=%s, zIndex=%d, visible=%v ✓",
		moveResp.BundleId, moveResp.ZIndex, moveResp.Visible)

	// 6. Test ResizeWindow - verify metadata is preserved in response
	t.Log("Testing ResizeWindow metadata preservation...")
	resizeResp, err := client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   initialWindow.Name,
		Width:  600,
		Height: 400,
	})
	if err != nil {
		t.Fatalf("ResizeWindow failed: %v", err)
	}

	// Verify ResizeWindow response contains metadata
	if resizeResp.BundleId == "" {
		t.Error("ResizeWindow response: bundleID is empty")
	}
	if resizeResp.BundleId != expectedBundleID {
		t.Errorf("ResizeWindow response: bundleID mismatch, expected=%s, got=%s",
			expectedBundleID, resizeResp.BundleId)
	}
	if resizeResp.ZIndex == 0 {
		t.Log("Warning: ResizeWindow response zIndex is 0")
	}
	// Window should still be visible after resize
	resizeVisible := resizeResp.Visible
	if !resizeVisible {
		t.Error("ResizeWindow response: visible is false (expected true)")
	}
	t.Logf("ResizeWindow response: bundleID=%s, zIndex=%d, visible=%v ✓",
		resizeResp.BundleId, resizeResp.ZIndex, resizeResp.Visible)

	// 7. Test MinimizeWindow - verify visible becomes false
	t.Log("Testing MinimizeWindow metadata preservation...")
	minimizeResp, err := client.MinimizeWindow(ctx, &pb.MinimizeWindowRequest{
		Name: initialWindow.Name,
	})
	if err != nil {
		t.Fatalf("MinimizeWindow failed: %v", err)
	}

	// Verify MinimizeWindow response contains metadata
	if minimizeResp.BundleId == "" {
		t.Error("MinimizeWindow response: bundleID is empty")
	}
	if minimizeResp.BundleId != expectedBundleID {
		t.Errorf("MinimizeWindow response: bundleID mismatch, expected=%s, got=%s",
			expectedBundleID, minimizeResp.BundleId)
	}
	if minimizeResp.ZIndex == 0 {
		t.Log("Warning: MinimizeWindow response zIndex is 0")
	}
	// Window should NOT be visible after minimize
	minimizeVisible := minimizeResp.Visible
	if minimizeVisible {
		t.Error("MinimizeWindow response: visible is true (expected false)")
	}
	t.Logf("MinimizeWindow response: bundleID=%s, zIndex=%d, visible=%v ✓",
		minimizeResp.BundleId, minimizeResp.ZIndex, minimizeResp.Visible)

	// Poll to verify minimized state is persistent
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		state, err := client.GetWindowState(ctx, &pb.GetWindowStateRequest{
			Name: stateName,
		})
		if err != nil {
			return false, err
		}
		return state.Minimized, nil
	})
	if err != nil {
		t.Error("Window did not become minimized in GetWindowState")
	}

	// 8. Test RestoreWindow - verify visible becomes true
	t.Log("Testing RestoreWindow metadata preservation...")
	restoreResp, err := client.RestoreWindow(ctx, &pb.RestoreWindowRequest{
		Name: initialWindow.Name,
	})
	if err != nil {
		t.Fatalf("RestoreWindow failed: %v", err)
	}

	// Verify RestoreWindow response contains metadata
	if restoreResp.BundleId == "" {
		t.Error("RestoreWindow response: bundleID is empty")
	}
	if restoreResp.BundleId != expectedBundleID {
		t.Errorf("RestoreWindow response: bundleID mismatch, expected=%s, got=%s",
			expectedBundleID, restoreResp.BundleId)
	}
	if restoreResp.ZIndex == 0 {
		t.Log("Warning: RestoreWindow response zIndex is 0")
	}
	// Window should be visible after restore
	restoreVisible := restoreResp.Visible
	if !restoreVisible {
		t.Error("RestoreWindow response: visible is false (expected true)")
	}
	t.Logf("RestoreWindow response: bundleID=%s, zIndex=%d, visible=%v ✓",
		restoreResp.BundleId, restoreResp.ZIndex, restoreResp.Visible)

	// Poll to verify restored state is persistent
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		state, err := client.GetWindowState(ctx, &pb.GetWindowStateRequest{
			Name: stateName,
		})
		if err != nil {
			return false, err
		}
		return !state.Minimized && !state.AxHidden, nil
	})
	if err != nil {
		t.Error("Window did not become restored in GetWindowState")
	}

	// 9. Cleanup - delete application
	t.Log("Test completed successfully, cleaning up...")
}
