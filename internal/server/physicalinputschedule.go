// Copyright 2026 Joseph Cumines

package server

import (
	"fmt"
	"math"
	"time"

	"github.com/joeycumines/MacosUseSDK/internal/config"
	"github.com/rivo/uniseg"
)

const maximumPhysicalRequestTimeoutSeconds = int64((1<<63 - 1) / int64(time.Second))

func physicalInputRequestTimeout(cfg *config.Config) (time.Duration, error) {
	if cfg == nil {
		return 0, fmt.Errorf("physical input request timeout configuration is missing")
	}
	if cfg.RequestTimeout <= 0 {
		return 0, fmt.Errorf(
			"physical input request timeout configuration must be positive",
		)
	}
	seconds := int64(cfg.RequestTimeout)
	if seconds > maximumPhysicalRequestTimeoutSeconds {
		return 0, fmt.Errorf(
			"physical input request timeout configuration exceeds time.Duration capacity",
		)
	}
	return time.Duration(seconds) * time.Second, nil
}

func validatePhysicalInputDuration(
	cfg *config.Config,
	durationSeconds float64,
) (time.Duration, error) {
	timeout, err := physicalInputRequestTimeout(cfg)
	if err != nil {
		return 0, err
	}
	if err := validatePhysicalInputSchedule(timeout, 1, durationSeconds); err != nil {
		return 0, err
	}
	return timeout, nil
}

func validatePhysicalTypeSchedule(
	cfg *config.Config,
	text string,
	charDelaySeconds float64,
) (time.Duration, error) {
	timeout, err := physicalInputRequestTimeout(cfg)
	if err != nil {
		return 0, err
	}
	graphemes := uniseg.GraphemeClusterCount(text)
	intervals := 0
	if graphemes > 0 {
		intervals = graphemes - 1
	}
	if err := validatePhysicalInputSchedule(
		timeout,
		intervals,
		charDelaySeconds,
	); err != nil {
		return 0, err
	}
	return timeout, nil
}

func validatePhysicalInputSchedule(
	timeout time.Duration,
	intervalCount int,
	intervalSeconds float64,
) error {
	if timeout <= 0 {
		return fmt.Errorf("physical input request timeout configuration must be positive")
	}
	if intervalCount < 0 {
		return fmt.Errorf("physical input schedule interval count must not be negative")
	}
	if math.IsNaN(intervalSeconds) ||
		math.IsInf(intervalSeconds, 0) ||
		intervalSeconds < 0 {
		return fmt.Errorf("physical input schedule interval must be a finite nonnegative number")
	}

	// Swift executes UInt64(seconds * 1_000_000_000), truncating each
	// advertised interval before it advances an absolute deadline. Mirror that
	// conversion before multiplication so admission and execution agree at
	// fractional boundaries.
	scaledInterval := intervalSeconds * float64(time.Second)
	if scaledInterval >= float64(^uint64(0)) {
		return physicalInputScheduleTimeoutError(timeout)
	}
	intervalNanoseconds := uint64(scaledInterval)
	count := uint64(intervalCount)
	if count != 0 && intervalNanoseconds > ^uint64(0)/count {
		return physicalInputScheduleTimeoutError(timeout)
	}
	scheduleNanoseconds := intervalNanoseconds * count
	if scheduleNanoseconds >= uint64(timeout) {
		return physicalInputScheduleTimeoutError(timeout)
	}
	return nil
}

func physicalInputScheduleTimeoutError(timeout time.Duration) error {
	return fmt.Errorf(
		"physical input schedule must be less than configured request timeout %s",
		timeout,
	)
}

func validateCUATypeSchedule(
	cfg *config.Config,
	arguments map[string]any,
) error {
	text, ok := arguments["text"].(string)
	if !ok || text == "" {
		return fmt.Errorf("text parameter is required")
	}
	charDelay := float64(0)
	if raw, exists := arguments["char_delay"]; exists {
		number, numeric := numericValue(raw)
		if !numeric {
			return fmt.Errorf("char_delay must be numeric")
		}
		charDelay, _ = number.Float64()
		if math.IsInf(charDelay, 0) || math.IsNaN(charDelay) {
			return fmt.Errorf("char_delay must be finite")
		}
	}
	_, err := validatePhysicalTypeSchedule(cfg, text, charDelay)
	return err
}

func physicalDurationSchema(
	requestTimeoutSeconds int,
	nativeMaximum int,
	description string,
) map[string]any {
	schema := map[string]any{
		"type":        "number",
		"minimum":     0,
		"description": description,
	}
	if requestTimeoutSeconds <= nativeMaximum {
		schema["exclusiveMaximum"] = requestTimeoutSeconds
	} else {
		schema["maximum"] = nativeMaximum
	}
	return schema
}

func physicalTypeDescription(requestTimeoutSeconds int) string {
	return fmt.Sprintf(
		"Text to type. Its schedule is (extended grapheme count - 1) × char_delay and must be less than %d seconds.",
		requestTimeoutSeconds,
	)
}
