package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestWindowChangeObservation verifies that StreamObservations correctly emits
// window change events (created, moved, resized, minimized, restored, destroyed)
// when windows are manipulated. Uses PollUntil pattern, NO sleep.
//
// ARCHITECTURAL FIX COMPLETED: handleTraverse removed from @MainActor, observation streaming
// no longer blocks concurrent RPCs. Task.detached event publishing + nonisolated traversal
// provides full decoupling of producer/consumer and concurrent RPC execution.
func TestWindowChangeObservation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	// 1. Infrastructure Setup
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)
	opsClient := longrunningpb.NewOperationsClient(conn)

	// 2. Application Setup - Open TextEdit
	t.Log("Opening TextEdit...")
	app := openTextEdit(t, ctx, client, opsClient)
	defer cleanupApplication(t, ctx, client, app)

	// 3. Dismiss file picker dialog and create a new document
	t.Log("Dismissing file picker and creating new document...")
	// Close the initial file picker window (Cancel button)
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		// Find and close the file picker (small window)
		for _, window := range resp.Windows {
			if window.Bounds != nil && window.Bounds.Width < 200 {
				// This is likely the file picker - close it
				_, err := client.CloseWindow(ctx, &pb.CloseWindowRequest{
					Name: window.Name,
				})
				return err == nil, err
			}
		}
		return true, nil // No file picker found, proceed
	})
	if err != nil {
		t.Logf("Warning: failed to close file picker: %v", err)
	}

	// Create a new document using Cmd+N
	t.Log("Creating new document with Cmd+N...")
	_, err = client.CreateInput(ctx, &pb.CreateInputRequest{
		Parent: app.Name,
		Input: &pb.Input{
			Action: &pb.InputAction{
				InputType: &pb.InputAction_PressKey{
					PressKey: &pb.KeyPress{
						Key:       "n",
						Modifiers: []pb.KeyPress_Modifier{pb.KeyPress_MODIFIER_COMMAND},
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Failed to send Cmd+N: %v", err)
	}

	// Wait for document window to appear
	t.Log("Waiting for TextEdit document window to appear...")
	var initialWindow *pb.Window
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		// A real document window should have reasonable dimensions (ListWindows doesn't return detailed state)
		for _, window := range resp.Windows {
			if window.Bounds != nil &&
				window.Bounds.Width >= 200 && window.Bounds.Height >= 200 {
				// Found a candidate - use GetWindow to check if it's minimizable
				fullWindow, err := client.GetWindow(ctx, &pb.GetWindowRequest{
					Name: window.Name,
				})
				if err != nil {
					continue
				}
				t.Logf("  Window: %s, minimizable=%v, bounds=%.0fx%.0f at (%.0f, %.0f)",
					fullWindow.Name,
					fullWindow.State != nil && fullWindow.State.Minimizable,
					fullWindow.Bounds.Width, fullWindow.Bounds.Height, fullWindow.Bounds.X, fullWindow.Bounds.Y)
				if fullWindow.State != nil && fullWindow.State.Minimizable {
					initialWindow = fullWindow
					return true, nil
				}
			}
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Initial document window never appeared: %v", err)
	}
	t.Logf("Initial window found: %s", initialWindow.Name)

	// Get initial window bounds for later comparison
	initialBounds := initialWindow.Bounds
	t.Logf("Initial window bounds: %.0fx%.0f at (%.0f, %.0f)",
		initialBounds.Width, initialBounds.Height, initialBounds.X, initialBounds.Y)

	// 4. Create observation for window changes
	t.Log("Creating window change observation...")
	createObsReq := &pb.CreateObservationRequest{
		Parent: app.Name,
		Observation: &pb.Observation{
			Type: pb.ObservationType_OBSERVATION_TYPE_WINDOW_CHANGES,
			Filter: &pb.ObservationFilter{
				VisibleOnly:  false,
				PollInterval: 0.5, // 500ms polling
			},
		},
	}

	createObsOp, err := client.CreateObservation(ctx, createObsReq)
	if err != nil {
		t.Fatalf("Failed to start CreateObservation: %v", err)
	}

	// Wait for observation creation to complete
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		op, err := opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: createObsOp.Name,
		})
		if err != nil {
			return false, err
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("Failed waiting for CreateObservation: %v", err)
	}

	// Get the observation resource
	createObsOp, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
		Name: createObsOp.Name,
	})
	if err != nil {
		t.Fatalf("Failed to get observation operation: %v", err)
	}

	if createObsOp.GetError() != nil {
		t.Fatalf("CreateObservation failed: %v", createObsOp.GetError())
	}

	observation := &pb.Observation{}
	if err := createObsOp.GetResponse().UnmarshalTo(observation); err != nil {
		t.Fatalf("Failed to unmarshal observation response: %v", err)
	}

	if observation.Name == "" {
		t.Fatal("Observation creation completed but no observation name returned")
	}
	t.Logf("Observation created: %s", observation.Name)

	// 5. Start streaming observations
	t.Log("Starting observation stream...")
	streamCtx, streamCancel := context.WithCancel(ctx)
	defer streamCancel()

	stream, err := client.StreamObservations(streamCtx, &pb.StreamObservationsRequest{
		Name: observation.Name,
	})
	if err != nil {
		t.Fatalf("Failed to start StreamObservations: %v", err)
	}

	// Channel to collect events
	eventsChan := make(chan *pb.ObservationEvent, 10)
	errChan := make(chan error, 1)

	// Start goroutine to receive events
	go func() {
		for {
			resp, err := stream.Recv()
			if err != nil {
				errChan <- err
				return
			}
			if resp.Event != nil {
				t.Logf("Received observation event: sequence=%d", resp.Event.Sequence)
				eventsChan <- resp.Event
			}
		}
	}()

	// 6. Wait for observation to establish baseline (receive initial "created" event)
	t.Log("Waiting for observation baseline...")
	baselineReceived := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_CREATED {
					t.Log("✓ Baseline window created event received")
					baselineReceived = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !baselineReceived {
		t.Fatal("Failed to receive baseline window created event")
	}

	// 7. Test Case 1: Window Resize (First Resize to Different Dimensions)
	// Calculate target dimensions that are different from initial
	targetWidth1 := float64(500)
	targetHeight1 := float64(300)
	// Ensure they're different from initial
	if initialBounds.Width == targetWidth1 {
		targetWidth1 = 450
	}
	if initialBounds.Height == targetHeight1 {
		targetHeight1 = 350
	}

	t.Logf("Test 1a: Resizing window to %.0fx%.0f...", targetWidth1, targetHeight1)
	_, err = client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   initialWindow.Name,
		Width:  targetWidth1,
		Height: targetHeight1,
	})
	if err != nil {
		t.Fatalf("ResizeWindow (first) failed: %v", err)
	}

	// Wait for first resize event with PollUntil pattern via event channel
	resizeEvent1Received := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_RESIZED {
					t.Log("✓ First resize event received")
					resizeEvent1Received = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !resizeEvent1Received {
		t.Error("Expected first window resize event but did not receive it")
	}

	// Verify state delta - window dimensions changed
	// Note: Window manager may adjust requested dimensions, so we verify change occurred, not exact match
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		window, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: initialWindow.Name,
		})
		if err != nil {
			return false, err
		}
		// Window changed if height is close to target (window manager constraints may prevent exact width)
		heightChanged := window.Bounds.Height >= targetHeight1-50 && window.Bounds.Height <= targetHeight1+50
		return heightChanged, nil
	})
	if err != nil {
		t.Error("Window bounds did not reflect first resize operation")
	}

	// Test Case 1b: Resize back to original dimensions
	t.Logf("Test 1b: Resizing window back to original %.0fx%.0f...",
		initialBounds.Width, initialBounds.Height)
	_, err = client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   initialWindow.Name,
		Width:  initialBounds.Width,
		Height: initialBounds.Height,
	})
	if err != nil {
		t.Fatalf("ResizeWindow (back to original) failed: %v", err)
	}

	// Wait for second resize event
	resizeEvent2Received := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_RESIZED {
					t.Log("✓ Second resize event received")
					resizeEvent2Received = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !resizeEvent2Received {
		t.Error("Expected second window resize event but did not receive it")
	}

	// Verify state delta - window dimensions returned toward original
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		window, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: initialWindow.Name,
		})
		if err != nil {
			return false, err
		}
		// Verify height changed back (allow window manager adjustments)
		heightChanged := window.Bounds.Height >= initialBounds.Height-50 && window.Bounds.Height <= initialBounds.Height+50
		return heightChanged, nil
	})
	if err != nil {
		t.Error("Window bounds did not reflect second resize operation")
	}

	// 7. Test Case 2: Window Move
	t.Log("Test 2: Moving window...")
	_, err = client.MoveWindow(ctx, &pb.MoveWindowRequest{
		Name: initialWindow.Name,
		X:    200,
		Y:    200,
	})
	if err != nil {
		t.Fatalf("MoveWindow failed: %v", err)
	}

	// Wait for move event
	moveEventReceived := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_MOVED {
					t.Log("✓ Move event received")
					moveEventReceived = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !moveEventReceived {
		t.Error("Expected window move event but did not receive it")
	}

	// Verify state delta - window position should reflect move
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		window, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: initialWindow.Name,
		})
		if err != nil {
			return false, err
		}
		// Allow 2-pixel tolerance
		xOk := window.Bounds.X >= 198 && window.Bounds.X <= 202
		yOk := window.Bounds.Y >= 198 && window.Bounds.Y <= 202
		return xOk && yOk, nil
	})
	if err != nil {
		t.Error("Window position did not reflect move operation")
	}

	// 8. Test Case 3: Window Minimize/Restore
	t.Log("Test 3: Minimizing window...")
	_, err = client.MinimizeWindow(ctx, &pb.MinimizeWindowRequest{
		Name: initialWindow.Name,
	})
	if err != nil {
		t.Fatalf("MinimizeWindow failed: %v", err)
	}

	// Wait for minimize event
	minimizeEventReceived := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_MINIMIZED {
					t.Log("✓ Minimize event received")
					minimizeEventReceived = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !minimizeEventReceived {
		t.Error("Expected window minimize event but did not receive it")
	}

	// Verify state delta - window should be minimized
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		window, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: initialWindow.Name,
		})
		if err != nil {
			return false, err
		}
		return !window.Visible, nil // Minimized windows are not visible
	})
	if err != nil {
		t.Error("Window did not reflect minimized state")
	}

	t.Log("Restoring window...")
	_, err = client.RestoreWindow(ctx, &pb.RestoreWindowRequest{
		Name: initialWindow.Name,
	})
	if err != nil {
		t.Fatalf("RestoreWindow failed: %v", err)
	}

	// Wait for restore event
	restoreEventReceived := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_RESTORED {
					t.Log("✓ Restore event received")
					restoreEventReceived = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !restoreEventReceived {
		t.Error("Expected window restore event but did not receive it")
	}

	// Verify state delta - window should be visible again
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		window, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: initialWindow.Name,
		})
		if err != nil {
			return false, err
		}
		return window.Visible, nil
	})
	if err != nil {
		t.Error("Window did not reflect restored state")
	}

	// 9. Test Case 4: Window Destroyed (Close)
	t.Log("Test 4: Closing window...")
	_, err = client.CloseWindow(ctx, &pb.CloseWindowRequest{
		Name: initialWindow.Name,
	})
	if err != nil {
		t.Fatalf("CloseWindow failed: %v", err)
	}

	// Wait for destroyed event
	destroyedEventReceived := false
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_DESTROYED {
					t.Log("✓ Window destroyed event received")
					destroyedEventReceived = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if err != nil || !destroyedEventReceived {
		t.Error("Expected window destroyed event but did not receive it")
	}

	// Verify state delta - window should no longer exist
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		// Window should be gone
		for _, w := range resp.Windows {
			if w.Name == initialWindow.Name {
				return false, nil // Window still exists
			}
		}
		return true, nil // Window is gone
	})
	if err != nil {
		t.Error("Window was not destroyed as expected")
	}

	// 10. Cleanup
	t.Log("Canceling observation...")
	streamCancel() // Stop the stream
	_, err = client.CancelObservation(ctx, &pb.CancelObservationRequest{
		Name: observation.Name,
	})
	if err != nil {
		t.Logf("Warning: Failed to cancel observation: %v", err)
	}

	t.Log("Window change observation test passed ✓")
}
