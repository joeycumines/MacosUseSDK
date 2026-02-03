// Copyright 2025 Joseph Cumines

package tools

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestPollUntilContext_ConditionSucceeds(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	callCount := 0
	condition := func() (bool, error) {
		callCount++
		// Succeed on third call
		return callCount >= 3, nil
	}

	err := PollUntilContext(ctx, 10*time.Millisecond, condition)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if callCount < 3 {
		t.Errorf("expected at least 3 calls, got %d", callCount)
	}
}

func TestPollUntilContext_ConditionFails(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	condition := func() (bool, error) {
		return false, errors.New("intentional failure")
	}

	err := PollUntilContext(ctx, 10*time.Millisecond, condition)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "intentional failure" {
		t.Errorf("expected 'intentional failure', got: %v", err)
	}
}

func TestPollUntilContext_ContextTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	condition := func() (bool, error) {
		// Never succeeds
		return false, nil
	}

	err := PollUntilContext(ctx, 10*time.Millisecond, condition)
	if err == nil {
		t.Fatal("expected context timeout error, got nil")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("expected context.DeadlineExceeded, got: %v", err)
	}
}

func TestPollUntilContext_ContextCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	condition := func() (bool, error) {
		// Never succeeds
		return false, nil
	}

	// Cancel after a short delay
	go func() {
		time.Sleep(30 * time.Millisecond)
		cancel()
	}()

	err := PollUntilContext(ctx, 10*time.Millisecond, condition)
	if err == nil {
		t.Fatal("expected context cancel error, got nil")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected context.Canceled, got: %v", err)
	}
}

func TestPollUntilContext_ImmediateContextDone(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Immediately cancelled

	condition := func() (bool, error) {
		t.Error("condition should not be called when context is already done")
		return true, nil
	}

	err := PollUntilContext(ctx, 10*time.Millisecond, condition)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected context.Canceled, got: %v", err)
	}
}
