package integration

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// PollUntil repeatedly checks a condition until it returns true or the timeout expires.
// It checks the condition immediately, and then every `interval`.
//
// Use this to wait for asynchronous operations to complete.
func PollUntil(timeout time.Duration, interval time.Duration, condition func() bool) error {
	// Fast path: check immediately before creating timers
	if condition() {
		return nil
	}

	deadline := time.Now().Add(timeout)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		<-ticker.C
		if condition() {
			return nil
		}
		// Check if we have exceeded the timeout *after* checking the condition
		// to ensure we don't miss a success that happened exactly at the deadline.
		if time.Now().After(deadline) {
			return fmt.Errorf("PollUntil: condition not met after %v timeout", timeout)
		}
	}
}

// PollUntilContext checks a condition repeatedly until it returns true or the context is cancelled.
// This is preferred over PollUntil if your test suite uses context for timeouts.
func PollUntilContext(ctx context.Context, interval time.Duration, condition func() (bool, error)) error {
	// Fast path
	if done, err := condition(); err != nil {
		return err
	} else if done {
		return nil
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("PollUntilContext: context cancelled: %w", ctx.Err())
		case <-ticker.C:
			done, err := condition()
			if err != nil {
				return err
			}
			if done {
				return nil
			}
		}
	}
}

func TestWaitForServerReadinessBoundsEachProbe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	attempts := 0
	err := waitForServerReadiness(ctx, time.Millisecond, 5*time.Millisecond, func(attemptCtx context.Context) error {
		attempts++
		if attempts == 1 {
			<-attemptCtx.Done()
			return attemptCtx.Err()
		}
		return nil
	})
	if err != nil {
		t.Fatalf("waitForServerReadiness: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("readiness attempts = %d, want 2", attempts)
	}
}

func TestWaitForServerReadinessReportsLastProbeError(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	probeErr := errors.New("injected readiness failure")

	err := waitForServerReadiness(ctx, time.Millisecond, time.Second, func(context.Context) error {
		cancel()
		return probeErr
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("readiness error = %v, want context cancellation", err)
	}
	if !strings.Contains(err.Error(), probeErr.Error()) {
		t.Fatalf("readiness error = %v, want last probe error %q", err, probeErr)
	}
}
