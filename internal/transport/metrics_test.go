// Copyright 2025 Joseph Cumines
//
// Metrics unit tests

package transport

import (
	"bytes"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNewMetricsRegistry(t *testing.T) {
	m := NewMetricsRegistry()
	if m == nil {
		t.Fatal("NewMetricsRegistry returned nil")
	}
	if m.counters == nil {
		t.Error("counters map is nil")
	}
	if m.histograms == nil {
		t.Error("histograms map is nil")
	}
	if m.gauges == nil {
		t.Error("gauges map is nil")
	}
}

func TestMetricsRegistry_IncrementCounter(t *testing.T) {
	m := NewMetricsRegistry()

	m.IncrementCounter("mcp_requests_total", `tool="click",status="ok"`)
	m.IncrementCounter("mcp_requests_total", `tool="click",status="ok"`)
	m.IncrementCounter("mcp_requests_total", `tool="type_text",status="ok"`)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, `mcp_requests_total{tool="click",status="ok"} 2`) {
		t.Errorf("Expected click counter = 2, got:\n%s", output)
	}
	if !strings.Contains(output, `mcp_requests_total{tool="type_text",status="ok"} 1`) {
		t.Errorf("Expected type_text counter = 1, got:\n%s", output)
	}
}

func TestMetricsRegistry_ObserveHistogram(t *testing.T) {
	m := NewMetricsRegistry()

	m.ObserveHistogram("mcp_request_duration_seconds", `tool="click"`, 0.05)
	m.ObserveHistogram("mcp_request_duration_seconds", `tool="click"`, 0.15)
	m.ObserveHistogram("mcp_request_duration_seconds", `tool="click"`, 1.5)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	// Verify histogram count
	if !strings.Contains(output, `mcp_request_duration_seconds_count{tool="click"} 3`) {
		t.Errorf("Expected histogram count = 3, got:\n%s", output)
	}
	// Verify histogram sum (0.05 + 0.15 + 1.5 = 1.7)
	if !strings.Contains(output, `mcp_request_duration_seconds_sum{tool="click"} 1.7`) {
		t.Errorf("Expected histogram sum = 1.7, got:\n%s", output)
	}
	// Verify some buckets
	if !strings.Contains(output, `le="0.05"`) {
		t.Errorf("Expected bucket le=0.05, got:\n%s", output)
	}
}

func TestMetricsRegistry_SetGauge(t *testing.T) {
	m := NewMetricsRegistry()

	m.SetGauge("mcp_sse_connections_active", "", 5)
	m.SetGauge("mcp_sse_connections_active", "", 10)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "mcp_sse_connections_active 10") {
		t.Errorf("Expected gauge = 10 (last set value), got:\n%s", output)
	}
}

func TestMetricsRegistry_IncrementGauge(t *testing.T) {
	m := NewMetricsRegistry()

	m.SetGauge("mcp_sse_connections_active", "", 0)
	m.IncrementGauge("mcp_sse_connections_active", "", 1)
	m.IncrementGauge("mcp_sse_connections_active", "", 1)
	m.IncrementGauge("mcp_sse_connections_active", "", -1)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "mcp_sse_connections_active 1") {
		t.Errorf("Expected gauge = 1 (0+1+1-1), got:\n%s", output)
	}
}

func TestMetricsRegistry_RecordRequest(t *testing.T) {
	m := NewMetricsRegistry()

	m.RecordRequest("click", "ok", 50*time.Millisecond)
	m.RecordRequest("click", "error", 100*time.Millisecond)
	m.RecordRequest("type_text", "ok", 25*time.Millisecond)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, `tool="click",status="ok"`) {
		t.Errorf("Expected click/ok counter, got:\n%s", output)
	}
	if !strings.Contains(output, `tool="click",status="error"`) {
		t.Errorf("Expected click/error counter, got:\n%s", output)
	}
}

func TestMetricsRegistry_RecordSSEEvent(t *testing.T) {
	m := NewMetricsRegistry()

	m.RecordSSEEvent()
	m.RecordSSEEvent()
	m.RecordSSEEvent()

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "mcp_sse_events_sent_total 3") {
		t.Errorf("Expected SSE events = 3, got:\n%s", output)
	}
}

func TestMetricsRegistry_SetSSEConnections(t *testing.T) {
	m := NewMetricsRegistry()

	m.SetSSEConnections(5)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "mcp_sse_connections_active 5") {
		t.Errorf("Expected SSE connections = 5, got:\n%s", output)
	}
}

func TestMetricsRegistry_ConcurrentAccess(t *testing.T) {
	m := NewMetricsRegistry()

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			m.RecordRequest("click", "ok", time.Duration(i)*time.Millisecond)
			m.SetSSEConnections(i)
			m.RecordSSEEvent()
		}(i)
	}
	wg.Wait()

	// Verify no panic and data is consistent
	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error after concurrent access: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "mcp_requests_total") {
		t.Error("Expected mcp_requests_total in output")
	}
}

func TestMetricsRegistry_UnknownMetric(t *testing.T) {
	m := NewMetricsRegistry()

	// These should not panic, just no-op
	m.IncrementCounter("unknown_counter", "")
	m.ObserveHistogram("unknown_histogram", "", 1.0)
	m.SetGauge("unknown_gauge", "", 1.0)
	m.IncrementGauge("unknown_gauge", "", 1.0)

	// Verify no metrics for unknown names
	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()
	if strings.Contains(output, "unknown_") {
		t.Errorf("Should not contain unknown metrics, got:\n%s", output)
	}
}

func TestDefaultMetrics(t *testing.T) {
	m := DefaultMetrics()
	if m == nil {
		t.Fatal("DefaultMetrics() returned nil")
	}
	// Should be same instance on multiple calls
	m2 := DefaultMetrics()
	if m != m2 {
		t.Error("DefaultMetrics() should return same instance")
	}
}

func TestMetricsRegistry_WritePrometheus_Types(t *testing.T) {
	m := NewMetricsRegistry()

	// Add some data
	m.IncrementCounter("mcp_requests_total", `tool="test",status="ok"`)
	m.ObserveHistogram("mcp_request_duration_seconds", `tool="test"`, 0.1)
	m.SetGauge("mcp_sse_connections_active", "", 3)

	var buf bytes.Buffer
	if err := m.WritePrometheus(&buf); err != nil {
		t.Fatalf("WritePrometheus error: %v", err)
	}

	output := buf.String()

	// Verify TYPE comments
	if !strings.Contains(output, "# TYPE mcp_requests_total counter") {
		t.Errorf("Expected counter type declaration, got:\n%s", output)
	}
	if !strings.Contains(output, "# TYPE mcp_request_duration_seconds histogram") {
		t.Errorf("Expected histogram type declaration, got:\n%s", output)
	}
	if !strings.Contains(output, "# TYPE mcp_sse_connections_active gauge") {
		t.Errorf("Expected gauge type declaration, got:\n%s", output)
	}
}
