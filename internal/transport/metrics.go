// Copyright 2025 Joseph Cumines
//
// Metrics registry for observability

package transport

import (
	"fmt"
	"io"
	"sort"
	"sync"
	"time"
)

// MetricsRegistry provides thread-safe metrics collection for the MCP server.
// It tracks request counts, latencies, and active connections using simple
// in-memory counters that can be exported in Prometheus text format.
type MetricsRegistry struct {
	counters   map[string]*counter
	histograms map[string]*histogram
	gauges     map[string]*gauge
	mu         sync.RWMutex
}

// counter represents a monotonically increasing counter with optional labels.
type counter struct {
	values map[string]uint64 // label combo -> count
	mu     sync.RWMutex
}

// histogram represents a distribution of values with predefined buckets.
type histogram struct {
	counts  map[string][]uint64 // label combo -> bucket counts
	sums    map[string]float64  // label combo -> sum of all values
	totals  map[string]uint64   // label combo -> total count
	buckets []float64           // bucket upper bounds
	mu      sync.RWMutex
}

// gauge represents a value that can go up or down.
type gauge struct {
	values map[string]float64
	mu     sync.RWMutex
}

// Default histogram buckets for request latencies (in seconds)
var defaultLatencyBuckets = []float64{
	0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
}

// NewMetricsRegistry creates a new metrics registry with standard MCP metrics registered.
func NewMetricsRegistry() *MetricsRegistry {
	m := &MetricsRegistry{
		counters:   make(map[string]*counter),
		histograms: make(map[string]*histogram),
		gauges:     make(map[string]*gauge),
	}

	// Pre-register standard metrics
	m.registerCounter("mcp_requests_total")
	m.registerCounter("mcp_sse_events_sent_total")
	m.registerHistogram("mcp_request_duration_seconds", defaultLatencyBuckets)
	m.registerGauge("mcp_sse_connections_active")

	return m
}

func (m *MetricsRegistry) registerCounter(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.counters[name] = &counter{values: make(map[string]uint64)}
}

func (m *MetricsRegistry) registerHistogram(name string, buckets []float64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.histograms[name] = &histogram{
		buckets: buckets,
		counts:  make(map[string][]uint64),
		sums:    make(map[string]float64),
		totals:  make(map[string]uint64),
	}
}

func (m *MetricsRegistry) registerGauge(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gauges[name] = &gauge{values: make(map[string]float64)}
}

// IncrementCounter increments a counter by 1 for the given label combination.
// Labels should be formatted as: key1="value1",key2="value2"
func (m *MetricsRegistry) IncrementCounter(name string, labels string) {
	m.mu.RLock()
	c, ok := m.counters[name]
	m.mu.RUnlock()
	if !ok {
		return
	}

	c.mu.Lock()
	c.values[labels]++
	c.mu.Unlock()
}

// ObserveHistogram records a value in a histogram for the given label combination.
func (m *MetricsRegistry) ObserveHistogram(name string, labels string, value float64) {
	m.mu.RLock()
	h, ok := m.histograms[name]
	m.mu.RUnlock()
	if !ok {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	// Initialize bucket counts if not present
	if _, exists := h.counts[labels]; !exists {
		h.counts[labels] = make([]uint64, len(h.buckets)+1) // +1 for +Inf
		h.sums[labels] = 0
		h.totals[labels] = 0
	}

	// Update sum and total
	h.sums[labels] += value
	h.totals[labels]++

	// Update bucket counts
	for i, bound := range h.buckets {
		if value <= bound {
			h.counts[labels][i]++
		}
	}
	// Always increment +Inf bucket
	h.counts[labels][len(h.buckets)]++
}

// SetGauge sets a gauge to a specific value.
func (m *MetricsRegistry) SetGauge(name string, labels string, value float64) {
	m.mu.RLock()
	g, ok := m.gauges[name]
	m.mu.RUnlock()
	if !ok {
		return
	}

	g.mu.Lock()
	g.values[labels] = value
	g.mu.Unlock()
}

// IncrementGauge increments a gauge by delta.
func (m *MetricsRegistry) IncrementGauge(name string, labels string, delta float64) {
	m.mu.RLock()
	g, ok := m.gauges[name]
	m.mu.RUnlock()
	if !ok {
		return
	}

	g.mu.Lock()
	g.values[labels] += delta
	g.mu.Unlock()
}

// WritePrometheus writes all metrics in Prometheus text format to the writer.
func (m *MetricsRegistry) WritePrometheus(w io.Writer) error {
	m.mu.RLock()
	defer m.mu.RUnlock()

	// Sort metric names for deterministic output
	counterNames := make([]string, 0, len(m.counters))
	for name := range m.counters {
		counterNames = append(counterNames, name)
	}
	sort.Strings(counterNames)

	histogramNames := make([]string, 0, len(m.histograms))
	for name := range m.histograms {
		histogramNames = append(histogramNames, name)
	}
	sort.Strings(histogramNames)

	gaugeNames := make([]string, 0, len(m.gauges))
	for name := range m.gauges {
		gaugeNames = append(gaugeNames, name)
	}
	sort.Strings(gaugeNames)

	// Write counters
	for _, name := range counterNames {
		c := m.counters[name]
		c.mu.RLock()
		if _, err := fmt.Fprintf(w, "# TYPE %s counter\n", name); err != nil {
			c.mu.RUnlock()
			return err
		}
		labels := make([]string, 0, len(c.values))
		for l := range c.values {
			labels = append(labels, l)
		}
		sort.Strings(labels)
		for _, l := range labels {
			v := c.values[l]
			if l == "" {
				if _, err := fmt.Fprintf(w, "%s %d\n", name, v); err != nil {
					c.mu.RUnlock()
					return err
				}
			} else {
				if _, err := fmt.Fprintf(w, "%s{%s} %d\n", name, l, v); err != nil {
					c.mu.RUnlock()
					return err
				}
			}
		}
		c.mu.RUnlock()
	}

	// Write gauges
	for _, name := range gaugeNames {
		g := m.gauges[name]
		g.mu.RLock()
		if _, err := fmt.Fprintf(w, "# TYPE %s gauge\n", name); err != nil {
			g.mu.RUnlock()
			return err
		}
		labels := make([]string, 0, len(g.values))
		for l := range g.values {
			labels = append(labels, l)
		}
		sort.Strings(labels)
		for _, l := range labels {
			v := g.values[l]
			if l == "" {
				if _, err := fmt.Fprintf(w, "%s %g\n", name, v); err != nil {
					g.mu.RUnlock()
					return err
				}
			} else {
				if _, err := fmt.Fprintf(w, "%s{%s} %g\n", name, l, v); err != nil {
					g.mu.RUnlock()
					return err
				}
			}
		}
		g.mu.RUnlock()
	}

	// Write histograms
	for _, name := range histogramNames {
		h := m.histograms[name]
		h.mu.RLock()
		if _, err := fmt.Fprintf(w, "# TYPE %s histogram\n", name); err != nil {
			h.mu.RUnlock()
			return err
		}
		labels := make([]string, 0, len(h.counts))
		for l := range h.counts {
			labels = append(labels, l)
		}
		sort.Strings(labels)
		for _, l := range labels {
			counts := h.counts[l]
			sum := h.sums[l]
			total := h.totals[l]

			labelPrefix := ""
			if l != "" {
				labelPrefix = l + ","
			}

			// Write bucket counts
			var cumulative uint64
			for i, bound := range h.buckets {
				cumulative += counts[i]
				if _, err := fmt.Fprintf(w, "%s_bucket{%sle=\"%g\"} %d\n", name, labelPrefix, bound, cumulative); err != nil {
					h.mu.RUnlock()
					return err
				}
			}
			// +Inf bucket
			cumulative += counts[len(h.buckets)]
			if _, err := fmt.Fprintf(w, "%s_bucket{%sle=\"+Inf\"} %d\n", name, labelPrefix, cumulative); err != nil {
				h.mu.RUnlock()
				return err
			}

			// Write sum and count
			if l == "" {
				if _, err := fmt.Fprintf(w, "%s_sum %g\n", name, sum); err != nil {
					h.mu.RUnlock()
					return err
				}
				if _, err := fmt.Fprintf(w, "%s_count %d\n", name, total); err != nil {
					h.mu.RUnlock()
					return err
				}
			} else {
				if _, err := fmt.Fprintf(w, "%s_sum{%s} %g\n", name, l, sum); err != nil {
					h.mu.RUnlock()
					return err
				}
				if _, err := fmt.Fprintf(w, "%s_count{%s} %d\n", name, l, total); err != nil {
					h.mu.RUnlock()
					return err
				}
			}
		}
		h.mu.RUnlock()
	}

	return nil
}

// RecordRequest records a tool invocation with count and latency metrics.
// This is the main entry point for instrumentation from the MCP server.
func (m *MetricsRegistry) RecordRequest(tool string, status string, duration time.Duration) {
	labels := fmt.Sprintf(`tool="%s",status="%s"`, tool, status)
	m.IncrementCounter("mcp_requests_total", labels)

	toolLabels := fmt.Sprintf(`tool="%s"`, tool)
	m.ObserveHistogram("mcp_request_duration_seconds", toolLabels, duration.Seconds())
}

// RecordSSEEvent records an SSE event being sent.
func (m *MetricsRegistry) RecordSSEEvent() {
	m.IncrementCounter("mcp_sse_events_sent_total", "")
}

// SetSSEConnections sets the current number of active SSE connections.
func (m *MetricsRegistry) SetSSEConnections(count int) {
	m.SetGauge("mcp_sse_connections_active", "", float64(count))
}

// Global metrics registry instance
var defaultMetrics = NewMetricsRegistry()

// DefaultMetrics returns the global metrics registry.
func DefaultMetrics() *MetricsRegistry {
	return defaultMetrics
}
