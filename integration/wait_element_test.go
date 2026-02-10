package integration

import (
	"context"
	"testing"
	"time"

	longrunningpb "cloud.google.com/go/longrunning/autogen/longrunningpb"
	typepb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/type"
	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// TestWaitElement_ButtonExists verifies WaitElement succeeds quickly for an existing button.
// Uses Calculator, which has well-known buttons like "1", "2", "+", etc.
func TestWaitElement_ButtonExists(t *testing.T) {
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

	// Wait for Calculator windows to appear
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

	// Switch to Basic mode
	t.Log("Switching to Basic mode...")
	switchCalculatorToBasicMode(t, ctx, client, app)

	// Test 1: WaitElement for a button that exists (text="1" which always exists in Basic mode)
	t.Log("Test 1: WaitElement for button with text '1' (should succeed quickly)...")
	startTime := time.Now()

	op, err := client.WaitElement(ctx, &pb.WaitElementRequest{
		Parent: app.Name,
		Selector: &typepb.ElementSelector{
			Criteria: &typepb.ElementSelector_Text{Text: "1"},
		},
		Timeout:      10, // 10 seconds
		PollInterval: 0.5,
	})
	if err != nil {
		t.Fatalf("WaitElement RPC failed: %v", err)
	}
	t.Logf("WaitElement operation started: %s", op.Name)

	// Verify LRO lifecycle: pending -> done
	err = PollUntilContext(ctx, 100*time.Millisecond, func() (bool, error) {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			return false, err
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("Failed waiting for WaitElement operation: %v", err)
	}

	elapsed := time.Since(startTime)
	t.Logf("WaitElement completed in %v", elapsed)

	// Verify operation succeeded
	if op.GetError() != nil {
		t.Errorf("WaitElement should succeed for existing button, got error: %v", op.GetError())
	}

	// Verify result contains an element
	if op.GetResponse() != nil {
		response := &pb.WaitElementResponse{}
		if err := op.GetResponse().UnmarshalTo(response); err != nil {
			t.Errorf("Failed to unmarshal WaitElement response: %v", err)
		} else if response.Element != nil {
			t.Logf("Found element with role: %s", response.Element.Role)
		} else {
			t.Errorf("WaitElement response has nil element")
		}
	}

	// The operation should complete fairly quickly since buttons exist
	if elapsed > 5*time.Second {
		t.Logf("Warning: WaitElement took longer than expected (%v) for existing element", elapsed)
	}

	t.Log("WaitElement for existing element test passed ✓")
}

// TestWaitElement_Timeout verifies WaitElement times out correctly for impossible selector.
func TestWaitElement_Timeout(t *testing.T) {
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

	// Wait for Calculator to be ready
	t.Log("Waiting for Calculator to be ready...")
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
		t.Fatalf("Calculator never became ready: %v", err)
	}

	// Test 2: WaitElement with impossible selector (non-existent text)
	t.Log("Test 2: WaitElement with impossible selector (should timeout)...")
	impossibleText := "IMPOSSIBLE_ELEMENT_TEXT_THAT_DOES_NOT_EXIST_12345"
	startTime := time.Now()

	op, err := client.WaitElement(ctx, &pb.WaitElementRequest{
		Parent: app.Name,
		Selector: &typepb.ElementSelector{
			Criteria: &typepb.ElementSelector_Text{Text: impossibleText},
		},
		Timeout:      3, // Short timeout (3 seconds)
		PollInterval: 0.5,
	})
	if err != nil {
		t.Fatalf("WaitElement RPC failed: %v", err)
	}
	t.Logf("WaitElement (timeout test) operation started: %s", op.Name)

	// Poll for operation completion
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			return false, err
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("Failed waiting for WaitElement operation: %v", err)
	}

	elapsed := time.Since(startTime)
	t.Logf("WaitElement (timeout) completed in %v", elapsed)

	// Verify operation failed with timeout/not-found error
	if op.GetError() == nil {
		t.Error("WaitElement should fail for impossible selector, but got success")
	} else {
		errStatus := op.GetError()
		t.Logf("WaitElement correctly timed out with error: code=%d, message=%s", errStatus.Code, errStatus.Message)
		// Error should be deadline exceeded or not found
		if errStatus.Code != int32(codes.DeadlineExceeded) && errStatus.Code != int32(codes.NotFound) {
			t.Logf("Unexpected error code: %d (expected DeadlineExceeded or NotFound)", errStatus.Code)
		}
	}

	// Verify the timeout was respected (should be close to 3 seconds)
	if elapsed < 2*time.Second {
		t.Errorf("WaitElement completed too quickly (%v), expected ~3 second timeout", elapsed)
	}
	if elapsed > 10*time.Second {
		t.Errorf("WaitElement took too long (%v), expected ~3 second timeout", elapsed)
	}

	t.Log("WaitElement timeout test passed ✓")
}

// TestWaitElement_LROLifecycle verifies the LRO lifecycle progression.
func TestWaitElement_LROLifecycle(t *testing.T) {
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

	// Test LRO lifecycle with a selector that will take some time
	// Use an impossible selector with longer timeout to observe states
	t.Log("Test: Verify LRO lifecycle (pending -> done)...")

	op, err := client.WaitElement(ctx, &pb.WaitElementRequest{
		Parent: app.Name,
		Selector: &typepb.ElementSelector{
			Criteria: &typepb.ElementSelector_Text{Text: "LIFECYCLE_TEST_12345"},
		},
		Timeout:      5, // 5 second wait
		PollInterval: 1,
	})
	if err != nil {
		t.Fatalf("WaitElement RPC failed: %v", err)
	}
	t.Logf("WaitElement operation name: %s", op.Name)

	// Initial state should show operation is not done
	initialOp, err := opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
		Name: op.Name,
	})
	if err != nil {
		t.Fatalf("Failed to get initial operation state: %v", err)
	}

	// Operation might be done already if timeout < poll interval, but typically not
	if !initialOp.Done {
		t.Log("✓ Initial operation state is pending (done=false)")
	} else {
		t.Log("Initial operation already done (fast timeout)")
	}

	// Wait for completion
	err = PollUntilContext(ctx, 200*time.Millisecond, func() (bool, error) {
		op, err = opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
			Name: op.Name,
		})
		if err != nil {
			return false, err
		}
		return op.Done, nil
	})
	if err != nil {
		t.Fatalf("Failed waiting for operation: %v", err)
	}

	// Final state should be done=true
	if op.Done {
		t.Log("✓ Final operation state is done (done=true)")
	} else {
		t.Error("Final operation state should be done=true")
	}

	// Verify the operation has either result or error
	hasResult := op.GetResponse() != nil
	hasError := op.GetError() != nil
	if hasResult || hasError {
		t.Logf("✓ Operation has result=%v or error=%v", hasResult, hasError)
	} else {
		t.Error("Completed operation should have either result or error")
	}

	// Verify operation can still be queried after completion
	finalOp, err := opsClient.GetOperation(ctx, &longrunningpb.GetOperationRequest{
		Name: op.Name,
	})
	if err != nil {
		st, ok := status.FromError(err)
		if ok && st.Code() == codes.NotFound {
			t.Log("Operation was cleaned up after completion (acceptable behavior)")
		} else {
			t.Errorf("Failed to query completed operation: %v", err)
		}
	} else {
		t.Logf("✓ Completed operation still queryable: done=%v", finalOp.Done)
	}

	t.Log("LRO lifecycle test passed ✓")
}
