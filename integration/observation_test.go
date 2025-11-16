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

	// 3. Wait for initial window to appear
	t.Log("Waiting for TextEdit window to appear...")
	var initialWindow *pb.Window
	err := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		resp, err := client.ListWindows(ctx, &pb.ListWindowsRequest{
			Parent: app.Name,
		})
		if err != nil {
			return false, err
		}
		if len(resp.Windows) > 0 {
			initialWindow = resp.Windows[0]
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		t.Fatalf("Initial window never appeared: %v", err)
	}
	t.Logf("Initial window found: %s", initialWindow.Name)

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

	// 6. Test Case 1: Window Resize
	t.Log("Test 1: Resizing window...")
	_, err = client.ResizeWindow(ctx, &pb.ResizeWindowRequest{
		Name:   initialWindow.Name,
		Width:  600,
		Height: 400,
	})
	if err != nil {
		t.Fatalf("ResizeWindow failed: %v", err)
	}

	// Wait for resize event with PollUntil pattern via event channel
	resizeEventReceived := false
	pollErr := PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		select {
		case event := <-eventsChan:
			if windowEvent := event.GetWindowEvent(); windowEvent != nil {
				if windowEvent.EventType == pb.WindowEvent_WINDOW_EVENT_TYPE_RESIZED {
					t.Log("✓ Resize event received")
					resizeEventReceived = true
					return true, nil
				}
			}
		case err := <-errChan:
			return false, err
		default:
		}
		return false, nil
	})
	if pollErr != nil || !resizeEventReceived {
		t.Error("Expected window resize event but did not receive it")
	}

	// Verify state delta - window bounds should reflect resize
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		window, err := client.GetWindow(ctx, &pb.GetWindowRequest{
			Name: initialWindow.Name,
		})
		if err != nil {
			return false, err
		}
		// Allow 2-pixel tolerance for window manager adjustments
		widthOk := window.Bounds.Width >= 598 && window.Bounds.Width <= 602
		heightOk := window.Bounds.Height >= 398 && window.Bounds.Height <= 402
		return widthOk && heightOk, nil
	})
	if err != nil {
		t.Error("Window bounds did not reflect resize operation")
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
	pollErr = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
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
	if pollErr != nil || !moveEventReceived {
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
	pollErr = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
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
	if pollErr != nil || !minimizeEventReceived {
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
	pollErr = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
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
	if pollErr != nil || !restoreEventReceived {
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
	pollErr = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
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
	if pollErr != nil || !destroyedEventReceived {
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
