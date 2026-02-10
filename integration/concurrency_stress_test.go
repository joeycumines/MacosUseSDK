package integration

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/joeycumines/MacosUseSDK/gen/go/macosusesdk/v1"
)

// TestConcurrencyStress sends multiple concurrent gRPC requests to verify
// the server handles concurrent load without crashes, deadlocks, or data corruption.
func TestConcurrencyStress(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	// Setup: start server and connect
	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	const (
		numGoroutines = 50
		opsPerWorker  = 5
	)

	// Track results
	var (
		successCount atomic.Int64
		errorCount   atomic.Int64
		wg           sync.WaitGroup
	)

	// Define operation types to mix (all are parameter-free read-only ops)
	operations := []func(ctx context.Context, c pb.MacosUseClient) error{
		// List applications (no parent/name required)
		func(ctx context.Context, c pb.MacosUseClient) error {
			_, err := c.ListApplications(ctx, &pb.ListApplicationsRequest{PageSize: 10})
			return err
		},
		// List displays
		func(ctx context.Context, c pb.MacosUseClient) error {
			_, err := c.ListDisplays(ctx, &pb.ListDisplaysRequest{})
			return err
		},
		// Get clipboard (requires Name: "clipboard")
		func(ctx context.Context, c pb.MacosUseClient) error {
			_, err := c.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
			return err
		},
		// List applications again with different page size
		func(ctx context.Context, c pb.MacosUseClient) error {
			_, err := c.ListApplications(ctx, &pb.ListApplicationsRequest{PageSize: 50})
			return err
		},
	}

	t.Logf("Starting concurrency stress test: %d goroutines, %d ops each", numGoroutines, opsPerWorker)
	startTime := time.Now()

	// Launch concurrent workers
	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for j := 0; j < opsPerWorker; j++ {
				select {
				case <-ctx.Done():
					return
				default:
				}
				// Pick operation based on worker+iteration to ensure variety
				opIdx := (workerID + j) % len(operations)
				op := operations[opIdx]
				// Execute with per-request context
				reqCtx, reqCancel := context.WithTimeout(ctx, 10*time.Second)
				err := op(reqCtx, client)
				reqCancel()
				if err != nil {
					errorCount.Add(1)
					t.Logf("Worker %d op %d failed: %v", workerID, j, err)
				} else {
					successCount.Add(1)
				}
			}
		}(i)
	}

	// Wait for completion with timeout
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		// All workers completed
	case <-ctx.Done():
		t.Fatal("Timeout waiting for workers to complete - possible deadlock")
	}

	duration := time.Since(startTime)
	totalOps := successCount.Load() + errorCount.Load()
	t.Logf("Concurrency stress test completed:")
	t.Logf("  Duration: %v", duration)
	t.Logf("  Total ops: %d", totalOps)
	t.Logf("  Successes: %d", successCount.Load())
	t.Logf("  Errors: %d", errorCount.Load())
	t.Logf("  Throughput: %.1f ops/sec", float64(totalOps)/duration.Seconds())

	// Assertions
	expectedOps := int64(numGoroutines * opsPerWorker)
	if totalOps != expectedOps {
		t.Errorf("Expected %d total operations, got %d", expectedOps, totalOps)
	}
	// Allow up to 10% errors (network issues, timing, etc.)
	maxErrors := expectedOps / 10
	if errorCount.Load() > maxErrors {
		t.Errorf("Too many errors: %d (max allowed: %d)", errorCount.Load(), maxErrors)
	}

	// Ensure server is still responsive after stress test
	endCtx, endCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer endCancel()
	_, err := client.ListDisplays(endCtx, &pb.ListDisplaysRequest{})
	if err != nil {
		t.Errorf("Server unresponsive after stress test: %v", err)
	}
}

// TestConcurrencyMutationSafety verifies that concurrent mutations don't corrupt state.
func TestConcurrencyMutationSafety(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	const numGoroutines = 10
	var wg sync.WaitGroup
	results := make(chan string, numGoroutines*2)

	// Launch concurrent clipboard writes, each with unique content
	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			content := time.Now().Format(time.RFC3339Nano) + "-" + string(rune('A'+workerID))
			// Write to clipboard
			_, err := client.WriteClipboard(ctx, &pb.WriteClipboardRequest{
				Content:       &pb.ClipboardContent{Content: &pb.ClipboardContent_Text{Text: content}},
				ClearExisting: true,
			})
			if err != nil {
				results <- "write-error"
				return
			}
			results <- "write-ok"
		}(i)
	}

	// Wait for all writes
	wg.Wait()
	close(results)

	// Count results
	okCount := 0
	errCount := 0
	for r := range results {
		if r == "write-ok" {
			okCount++
		} else {
			errCount++
		}
	}

	t.Logf("Concurrent clipboard writes: %d ok, %d errors", okCount, errCount)
	// All writes should succeed (last-write-wins is acceptable)
	if errCount > 0 {
		t.Errorf("Some clipboard writes failed: %d errors", errCount)
	}

	// Verify clipboard is still readable
	_, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{Name: "clipboard"})
	if err != nil {
		t.Errorf("Failed to read clipboard after concurrent writes: %v", err)
	}
}

// TestConcurrencyNoDeadlock verifies that mixed read operations don't deadlock
// and that the server remains responsive under concurrent load.
func TestConcurrencyNoDeadlock(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serverCmd, serverAddr := startServer(t, ctx)
	defer cleanupServer(t, serverCmd, serverAddr)

	conn := connectToServer(t, ctx, serverAddr)
	defer conn.Close()

	client := pb.NewMacosUseClient(conn)

	const numOps = 20
	var (
		wg           sync.WaitGroup
		successCount atomic.Int64
		errorCount   atomic.Int64
	)

	for i := 0; i < numOps; i++ {
		wg.Add(1)
		go func(opID int) {
			defer wg.Done()
			var err error
			// Alternate between different read operations
			if opID%2 == 0 {
				_, err = client.ListDisplays(ctx, &pb.ListDisplaysRequest{})
			} else {
				_, err = client.ListApplications(ctx, &pb.ListApplicationsRequest{})
			}
			if err != nil {
				errorCount.Add(1)
			} else {
				successCount.Add(1)
			}
		}(i)
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		t.Logf("All %d operations completed: %d successes, %d errors",
			numOps, successCount.Load(), errorCount.Load())
	case <-ctx.Done():
		t.Fatal("Possible deadlock: operations did not complete within timeout")
	}

	// At least some operations must have succeeded
	if successCount.Load() == 0 {
		t.Error("No operations succeeded — server may be unresponsive")
	}
}
