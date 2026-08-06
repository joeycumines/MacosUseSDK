// Copyright 2026 Joseph Cumines

package server

import (
	"encoding/json"
	"fmt"
	"math"
	"time"
)

const (
	defaultCUAWaitSeconds float64       = 1
	maximumCUAWait        time.Duration = 1<<63 - 1
)

// handleWait performs a local cancellable pause without a gRPC call.
func (s *MCPServer) handleWait(call *ToolCall) (*ToolResult, error) {
	var params struct {
		Duration *float64 `json:"duration"`
	}
	if err := json.Unmarshal(call.Arguments, &params); err != nil {
		return errorResultf("Invalid parameters: %v", err), nil
	}

	duration, err := parseCUAWaitDuration(
		params.Duration,
		time.Duration(s.cfg.RequestTimeout)*time.Second,
	)
	if err != nil {
		return errorResult(err.Error()), nil
	}

	timer := time.NewTimer(time.Duration(duration * float64(time.Second)))
	defer timer.Stop()
	select {
	case <-s.toolCallContext(call).Done():
		return errorResult("Wait cancelled"), nil
	case <-timer.C:
		return textResultf("Waited %.1fs", duration), nil
	}
}

func parseCUAWaitDuration(duration *float64, timeout time.Duration) (float64, error) {
	seconds := defaultCUAWaitSeconds
	if duration != nil {
		seconds = *duration
	}
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return 0, fmt.Errorf("duration must be a finite number")
	}
	if seconds <= 0 {
		return 0, fmt.Errorf("duration must be greater than 0")
	}
	if timeout <= 0 || seconds > timeout.Seconds() {
		return 0, fmt.Errorf("duration must be at most %.0f seconds", timeout.Seconds())
	}
	if seconds > float64(maximumCUAWait)/float64(time.Second) ||
		time.Duration(seconds*float64(time.Second)) <= 0 {
		return 0, fmt.Errorf("duration is outside the supported range")
	}
	return seconds, nil
}
