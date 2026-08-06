// Copyright 2026 Joseph Cumines

package server

import (
	"context"
	"errors"
	"sync"
)

const maxQueuedPhysicalDesktopMutations = 64

var (
	errMutationQueueFull = errors.New("physical desktop mutation queue is full")
	errNilMutation       = errors.New("physical desktop mutation handler is nil")
)

type mutationJobState uint8

const (
	mutationJobQueued mutationJobState = iota
	mutationJobActive
	mutationJobDone
)

type mutationJob struct {
	ready chan struct{}
	state mutationJobState
}

// mutationExecutor admits at most capacity waiting mutations and executes
// admitted work in FIFO order. The caller that owns an active job executes it,
// so the executor has no worker goroutine to leak during direct-handler tests.
type mutationExecutor struct {
	ctx      context.Context
	active   *mutationJob
	queue    []*mutationJob
	capacity int
	mu       sync.Mutex
}

func newMutationExecutor(ctx context.Context, capacity int) *mutationExecutor {
	if ctx == nil {
		ctx = context.Background()
	}
	if capacity < 0 {
		capacity = 0
	}
	return &mutationExecutor{ctx: ctx, capacity: capacity}
}

func (e *mutationExecutor) execute(
	ctx context.Context,
	handler func() (*ToolResult, error),
) (*ToolResult, error) {
	if handler == nil {
		return nil, errNilMutation
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := firstContextError(ctx, e.ctx); err != nil {
		return nil, err
	}

	job := &mutationJob{ready: make(chan struct{})}
	e.mu.Lock()
	if err := firstContextError(ctx, e.ctx); err != nil {
		e.mu.Unlock()
		return nil, err
	}
	if e.active == nil {
		job.state = mutationJobActive
		e.active = job
		e.mu.Unlock()
		return e.run(job, handler)
	}
	if len(e.queue) >= e.capacity {
		e.mu.Unlock()
		return nil, errMutationQueueFull
	}
	job.state = mutationJobQueued
	e.queue = append(e.queue, job)
	e.mu.Unlock()

	select {
	case <-job.ready:
		if err := firstContextError(ctx, e.ctx); err != nil {
			e.finish(job)
			return nil, err
		}
		return e.run(job, handler)
	case <-ctx.Done():
		if !e.removeQueued(job) {
			e.finish(job)
		}
		return nil, ctx.Err()
	case <-e.ctx.Done():
		if !e.removeQueued(job) {
			e.finish(job)
		}
		return nil, e.ctx.Err()
	}
}

func (e *mutationExecutor) run(
	job *mutationJob,
	handler func() (*ToolResult, error),
) (*ToolResult, error) {
	defer e.finish(job)
	return handler()
}

func (e *mutationExecutor) finish(job *mutationJob) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if job == nil || job.state != mutationJobActive || e.active != job {
		return
	}
	job.state = mutationJobDone
	e.active = nil
	if len(e.queue) == 0 {
		return
	}
	next := e.queue[0]
	copy(e.queue, e.queue[1:])
	e.queue[len(e.queue)-1] = nil
	e.queue = e.queue[:len(e.queue)-1]
	next.state = mutationJobActive
	e.active = next
	close(next.ready)
}

func (e *mutationExecutor) removeQueued(job *mutationJob) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if job == nil || job.state != mutationJobQueued {
		return false
	}
	for i, queued := range e.queue {
		if queued != job {
			continue
		}
		copy(e.queue[i:], e.queue[i+1:])
		e.queue[len(e.queue)-1] = nil
		e.queue = e.queue[:len(e.queue)-1]
		job.state = mutationJobDone
		return true
	}
	return false
}

func (e *mutationExecutor) pending() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.queue)
}

func firstContextError(contexts ...context.Context) error {
	for _, ctx := range contexts {
		if ctx != nil && ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return nil
}
