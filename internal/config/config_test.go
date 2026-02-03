// Copyright 2025 Joseph Cumines
//
// Configuration unit tests

package config

import (
	"os"
	"testing"
	"time"
)

func TestLoad_Defaults(t *testing.T) {
	// Clear any env vars that might affect the test
	os.Unsetenv("MACOS_USE_SERVER_ADDR")
	os.Unsetenv("MACOS_USE_SERVER_TLS")
	os.Unsetenv("MACOS_USE_REQUEST_TIMEOUT")
	os.Unsetenv("MACOS_USE_DEBUG")
	os.Unsetenv("MCP_TRANSPORT")
	os.Unsetenv("MCP_HTTP_ADDRESS")
	os.Unsetenv("MCP_HTTP_SOCKET")
	os.Unsetenv("MCP_HEARTBEAT_INTERVAL")
	os.Unsetenv("MCP_CORS_ORIGIN")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.ServerAddr != "localhost:50051" {
		t.Errorf("ServerAddr = %s, want localhost:50051", cfg.ServerAddr)
	}

	if cfg.ServerTLS != false {
		t.Errorf("ServerTLS = %v, want false", cfg.ServerTLS)
	}

	if cfg.RequestTimeout != 30 {
		t.Errorf("RequestTimeout = %d, want 30", cfg.RequestTimeout)
	}

	if cfg.Transport != TransportStdio {
		t.Errorf("Transport = %s, want stdio", cfg.Transport)
	}

	if cfg.HTTPAddress != ":8080" {
		t.Errorf("HTTPAddress = %s, want :8080", cfg.HTTPAddress)
	}

	if cfg.HeartbeatInterval != 30*time.Second {
		t.Errorf("HeartbeatInterval = %v, want 30s", cfg.HeartbeatInterval)
	}

	if cfg.CORSOrigin != "*" {
		t.Errorf("CORSOrigin = %s, want *", cfg.CORSOrigin)
	}
}

func TestLoad_TransportStdio(t *testing.T) {
	os.Setenv("MCP_TRANSPORT", "stdio")
	defer os.Unsetenv("MCP_TRANSPORT")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.Transport != TransportStdio {
		t.Errorf("Transport = %s, want stdio", cfg.Transport)
	}
}

func TestLoad_TransportSSE(t *testing.T) {
	os.Setenv("MCP_TRANSPORT", "sse")
	defer os.Unsetenv("MCP_TRANSPORT")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.Transport != TransportHTTP {
		t.Errorf("Transport = %s, want sse", cfg.Transport)
	}
}

func TestLoad_TransportInvalid(t *testing.T) {
	os.Setenv("MCP_TRANSPORT", "invalid")
	defer os.Unsetenv("MCP_TRANSPORT")

	_, err := Load()
	if err == nil {
		t.Error("Load() should return error for invalid transport")
	}
}

func TestLoad_HTTPConfig(t *testing.T) {
	os.Setenv("MCP_HTTP_ADDRESS", ":9000")
	os.Setenv("MCP_HTTP_SOCKET", "/tmp/mcp.sock")
	os.Setenv("MCP_HEARTBEAT_INTERVAL", "60s")
	os.Setenv("MCP_CORS_ORIGIN", "https://example.com")
	os.Setenv("MCP_HTTP_READ_TIMEOUT", "45s")
	os.Setenv("MCP_HTTP_WRITE_TIMEOUT", "45s")
	defer func() {
		os.Unsetenv("MCP_HTTP_ADDRESS")
		os.Unsetenv("MCP_HTTP_SOCKET")
		os.Unsetenv("MCP_HEARTBEAT_INTERVAL")
		os.Unsetenv("MCP_CORS_ORIGIN")
		os.Unsetenv("MCP_HTTP_READ_TIMEOUT")
		os.Unsetenv("MCP_HTTP_WRITE_TIMEOUT")
	}()

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.HTTPAddress != ":9000" {
		t.Errorf("HTTPAddress = %s, want :9000", cfg.HTTPAddress)
	}

	if cfg.HTTPSocketPath != "/tmp/mcp.sock" {
		t.Errorf("HTTPSocketPath = %s, want /tmp/mcp.sock", cfg.HTTPSocketPath)
	}

	if cfg.HeartbeatInterval != 60*time.Second {
		t.Errorf("HeartbeatInterval = %v, want 60s", cfg.HeartbeatInterval)
	}

	if cfg.CORSOrigin != "https://example.com" {
		t.Errorf("CORSOrigin = %s, want https://example.com", cfg.CORSOrigin)
	}

	if cfg.HTTPReadTimeout != 45*time.Second {
		t.Errorf("HTTPReadTimeout = %v, want 45s", cfg.HTTPReadTimeout)
	}

	if cfg.HTTPWriteTimeout != 45*time.Second {
		t.Errorf("HTTPWriteTimeout = %v, want 45s", cfg.HTTPWriteTimeout)
	}
}

func TestTransportTypeConstants(t *testing.T) {
	if TransportStdio != "stdio" {
		t.Errorf("TransportStdio = %s, want stdio", TransportStdio)
	}

	if TransportHTTP != "sse" {
		t.Errorf("TransportHTTP = %s, want sse", TransportHTTP)
	}
}

func TestGetEnvAsDuration(t *testing.T) {
	tests := []struct {
		name     string
		envValue string
		want     time.Duration
	}{
		{"valid duration", "30s", 30 * time.Second},
		{"minutes", "5m", 5 * time.Minute},
		{"milliseconds", "500ms", 500 * time.Millisecond},
		{"empty fallback", "", 10 * time.Second},
		{"invalid fallback", "invalid", 10 * time.Second},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			os.Setenv("TEST_DURATION", tt.envValue)
			defer os.Unsetenv("TEST_DURATION")

			got := getEnvAsDuration("TEST_DURATION", 10*time.Second)
			if got != tt.want {
				t.Errorf("getEnvAsDuration() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestGetEnv(t *testing.T) {
	os.Setenv("TEST_ENV", "custom")
	defer os.Unsetenv("TEST_ENV")

	if got := getEnv("TEST_ENV", "default"); got != "custom" {
		t.Errorf("getEnv() = %s, want custom", got)
	}

	if got := getEnv("TEST_ENV_UNDEFINED", "default"); got != "default" {
		t.Errorf("getEnv() for undefined = %s, want default", got)
	}
}

func TestGetEnvAsBool(t *testing.T) {
	tests := []struct {
		value string
		want  bool
	}{
		{"true", true},
		{"1", true},
		{"yes", true},
		{"false", false},
		{"0", false},
		{"no", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			if tt.value != "" {
				os.Setenv("TEST_BOOL", tt.value)
				defer os.Unsetenv("TEST_BOOL")
			} else {
				os.Unsetenv("TEST_BOOL")
			}

			got := getEnvAsBool("TEST_BOOL", false)
			if got != tt.want {
				t.Errorf("getEnvAsBool(%q) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}

func TestGetEnvAsInt(t *testing.T) {
	tests := []struct {
		value string
		want  int
	}{
		{"42", 42},
		{"0", 0},
		{"-1", -1},
		{"invalid", 10},
		{"", 10},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			if tt.value != "" {
				os.Setenv("TEST_INT", tt.value)
				defer os.Unsetenv("TEST_INT")
			} else {
				os.Unsetenv("TEST_INT")
			}

			got := getEnvAsInt("TEST_INT", 10)
			if got != tt.want {
				t.Errorf("getEnvAsInt(%q) = %d, want %d", tt.value, got, tt.want)
			}
		})
	}
}