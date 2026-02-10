package integration
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
	client, opClient, cleanup := setupTestWithClients(t, ctx)
	defer cleanup()
	_ = opClient // Not used in this test

	const (
		numGoroutines = 50
		opsPerWorker  = 5
	)























































































































































































































}	}		t.Fatal("Possible deadlock: operations did not complete within timeout")	case <-deadlockTimeout:		t.Log("No deadlock detected - all operations completed")	case <-done:	select {	}()		close(done)		wg.Wait()	go func() {	done := make(chan struct{})	}		}(i)			}				_, _ = client.ListApplications(ctx, &pb.ListApplicationsRequest{})			} else {				_, _ = client.ListWindows(ctx, &pb.ListWindowsRequest{})			if opID%2 == 0 {			// Alternate between reads and potentially blocking operations			defer wg.Done()		go func(opID int) {		wg.Add(1)	for i := 0; i < numOps; i++ {	deadlockTimeout := time.After(25 * time.Second)	var wg sync.WaitGroup	const numOps = 20	defer cleanup()	client, _, cleanup := setupTestWithClients(t, ctx)	defer cancel()	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)func TestConcurrencyNoDeadlock(t *testing.T) {// TestConcurrencyNoDeadlock verifies that mixed read/write operations don't deadlock.}	}		t.Errorf("Failed to read clipboard after concurrent writes: %v", err)	if err != nil {	_, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{})	// Verify clipboard is still readable	}		t.Errorf("Some clipboard writes failed: %d errors", errCount)	if errCount > 0 {	// All writes should succeed (last-write-wins is acceptable)	t.Logf("Concurrent clipboard writes: %d ok, %d errors", okCount, errCount)	}		}			errCount++		} else {			okCount++		if r == "write-ok" {	for r := range results {	errCount := 0	okCount := 0	// Count results	close(results)	wg.Wait()	// Wait for all writes	}		}(i)			results <- "write-ok"			}				return				results <- "write-error"			if err != nil {			})				Data:        content,				ContentType: pb.ClipboardContentType_CONTENT_TYPE_TEXT,			_, err := client.WriteClipboard(ctx, &pb.WriteClipboardRequest{			// Write to clipboard			content := []byte(time.Now().Format(time.RFC3339Nano) + "-" + string(rune('A'+workerID)))			defer wg.Done()		go func(workerID int) {		wg.Add(1)	for i := 0; i < numGoroutines; i++ {	// Launch concurrent clipboard writes, each with unique content	results := make(chan string, numGoroutines*2)	var wg sync.WaitGroup	const numGoroutines = 10	defer cleanup()	client, _, cleanup := setupTestWithClients(t, ctx)	defer cancel()	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)func TestConcurrencyMutationSafety(t *testing.T) {// TestConcurrencyMutationSafety verifies that concurrent mutations don't corrupt state.}	}		t.Errorf("Server unresponsive after stress test: %v", err)	if err != nil {	_, err := client.ListDisplays(endCtx, &pb.ListDisplaysRequest{})	defer endCancel()	endCtx, endCancel := context.WithTimeout(context.Background(), 5*time.Second)	// Ensure server is still responsive after stress test	}		t.Errorf("Too many errors: %d (max allowed: %d)", errorCount.Load(), maxErrors)	if errorCount.Load() > maxErrors {	maxErrors := expectedOps / 10	// Allow up to 10% errors (network issues, timing, etc.)	}		t.Errorf("Expected %d total operations, got %d", expectedOps, totalOps)	if totalOps != expectedOps {	expectedOps := int64(numGoroutines * opsPerWorker)	// Assertions	t.Logf("  Throughput: %.1f ops/sec", float64(totalOps)/duration.Seconds())	t.Logf("  Errors: %d", errorCount.Load())	t.Logf("  Successes: %d", successCount.Load())	t.Logf("  Total ops: %d", totalOps)	t.Logf("  Duration: %v", duration)	t.Logf("Concurrency stress test completed:")	totalOps := successCount.Load() + errorCount.Load()	duration := time.Since(startTime)	}		t.Fatal("Timeout waiting for workers to complete - possible deadlock")	case <-ctx.Done():		// All workers completed	case <-done:	select {	}()		close(done)		wg.Wait()	go func() {	done := make(chan struct{})	// Wait for completion with timeout	}		}(i)			}				}					successCount.Add(1)				} else {					t.Logf("Worker %d op %d failed: %v", workerID, j, err)					errorCount.Add(1)				if err != nil {				reqCancel()				err := op(reqCtx, client)				reqCtx, reqCancel := context.WithTimeout(ctx, 10*time.Second)				// Execute with per-request context				op := operations[opIdx]				opIdx := (workerID + j) % len(operations)				// Pick operation based on worker+iteration to ensure variety				}				default:					return				case <-ctx.Done():				select {			for j := 0; j < opsPerWorker; j++ {			defer wg.Done()		go func(workerID int) {		wg.Add(1)	for i := 0; i < numGoroutines; i++ {	// Launch concurrent workers	startTime := time.Now()	t.Logf("Starting concurrency stress test: %d goroutines, %d ops each", numGoroutines, opsPerWorker)	}		},			return err			_, err := client.ListDisplays(ctx, &pb.ListDisplaysRequest{})		func(ctx context.Context, client pb.MacosUseClient) error {		// List displays		},			return err			_, err := client.GetClipboard(ctx, &pb.GetClipboardRequest{})		func(ctx context.Context, client pb.MacosUseClient) error {		// Get clipboard		},			return err			_, err := client.ListApplications(ctx, &pb.ListApplicationsRequest{PageSize: 10})		func(ctx context.Context, client pb.MacosUseClient) error {		// List applications		},			return err			_, err := client.ListWindows(ctx, &pb.ListWindowsRequest{PageSize: 10})		func(ctx context.Context, client pb.MacosUseClient) error {		// List windows	operations := []func(ctx context.Context, client pb.MacosUseClient) error{	// Define operation types to mix	)		wg           sync.WaitGroup		errorCount   atomic.Int64		successCount atomic.Int64	var (	// Track results