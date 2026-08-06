// Copyright 2026 Joseph Cumines

package config

import (
	"strings"
	"testing"
)

func TestLoadRequestAdmissionDefaultsAndOverrides(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		t.Setenv("MCP_MAX_CONCURRENT_REQUESTS", "")
		t.Setenv("MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT", "")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() request admission defaults: %v", err)
		}
		if cfg.MaxConcurrentRequests != 512 || cfg.MaxConcurrentRequestsPerClient != 256 {
			t.Fatalf(
				"request admission defaults = global %d per-client %d, want 512/256",
				cfg.MaxConcurrentRequests,
				cfg.MaxConcurrentRequestsPerClient,
			)
		}
	})

	t.Run("overrides", func(t *testing.T) {
		t.Setenv("MCP_MAX_CONCURRENT_REQUESTS", "4")
		t.Setenv("MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT", "2")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() request admission overrides: %v", err)
		}
		if cfg.MaxConcurrentRequests != 4 || cfg.MaxConcurrentRequestsPerClient != 2 {
			t.Fatalf(
				"request admission overrides = global %d per-client %d, want 4/2",
				cfg.MaxConcurrentRequests,
				cfg.MaxConcurrentRequestsPerClient,
			)
		}
	})
}

func TestLoadRejectsInvalidRequestAdmission(t *testing.T) {
	tests := []struct {
		name      string
		global    string
		perClient string
		wantError string
	}{
		{
			name:      "malformed global",
			global:    "many",
			perClient: "2",
			wantError: "invalid value for MCP_MAX_CONCURRENT_REQUESTS",
		},
		{
			name:      "malformed per client",
			global:    "4",
			perClient: "many",
			wantError: "invalid value for MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT",
		},
		{
			name:      "zero global",
			global:    "0",
			perClient: "1",
			wantError: "MCP_MAX_CONCURRENT_REQUESTS must be positive",
		},
		{
			name:      "negative per client",
			global:    "4",
			perClient: "-1",
			wantError: "MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT must be positive",
		},
		{
			name:      "per client exceeds global",
			global:    "4",
			perClient: "5",
			wantError: "MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT must not exceed MCP_MAX_CONCURRENT_REQUESTS",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("MCP_MAX_CONCURRENT_REQUESTS", test.global)
			t.Setenv("MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT", test.perClient)
			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("Load() error = %v, want substring %q", err, test.wantError)
			}
		})
	}
}
