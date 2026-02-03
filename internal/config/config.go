// Copyright 2025 Joseph Cumines

// Package config provides configuration loading for the MCP tool,
// including environment variable parsing and default values.
package config

import (
	"fmt"
	"os"
	"time"
)

// TransportType represents the MCP transport type
type TransportType string

const (
	// TransportStdio uses stdin/stdout for communication
	TransportStdio TransportType = "stdio"
	// TransportHTTP uses HTTP/SSE for communication
	TransportHTTP TransportType = "sse"
)

// Config holds the configuration for the MCP tool, loaded from environment variables.
// All fields have sensible defaults via the Load function.
type Config struct {
	// ServerAddr is the gRPC server address (env: MACOS_USE_SERVER_ADDR, default: localhost:50051)
	ServerAddr string
	// ServerCertFile is the path to the server TLS certificate (env: MACOS_USE_SERVER_CERT_FILE, optional)
	ServerCertFile string
	// HTTPAddress is the HTTP/SSE server listen address (env: MCP_HTTP_ADDRESS, default: :8080)
	HTTPAddress string
	// HTTPSocketPath is the Unix socket path for HTTP transport (env: MCP_HTTP_SOCKET, optional)
	HTTPSocketPath string
	// CORSOrigin is the allowed CORS origin (env: MCP_CORS_ORIGIN, default: *)
	CORSOrigin string
	// Transport is the transport type: "stdio" or "sse" (env: MCP_TRANSPORT, default: stdio)
	Transport TransportType
	// HeartbeatInterval is the SSE heartbeat interval (env: MCP_HEARTBEAT_INTERVAL, default: 30s)
	HeartbeatInterval time.Duration
	// HTTPReadTimeout is the HTTP server read timeout (env: MCP_HTTP_READ_TIMEOUT, default: 30s)
	HTTPReadTimeout time.Duration
	// HTTPWriteTimeout is the HTTP server write timeout (env: MCP_HTTP_WRITE_TIMEOUT, default: 30s)
	HTTPWriteTimeout time.Duration
	// RequestTimeout is the gRPC request timeout in seconds (env: MACOS_USE_REQUEST_TIMEOUT, default: 30)
	RequestTimeout int
	// ServerTLS enables TLS for gRPC (env: MACOS_USE_SERVER_TLS, default: false)
	ServerTLS bool
	// Debug enables debug logging (env: MACOS_USE_DEBUG, default: false)
	Debug bool
	// ShellCommandsEnabled enables shell command execution (env: MCP_SHELL_COMMANDS_ENABLED, default: false)
	// WARNING: Enabling this allows arbitrary command execution and should only be used in trusted environments.
	ShellCommandsEnabled bool
}

// Load loads the configuration from environment variables
func Load() (*Config, error) {
	requestTimeout, err := getEnvAsInt("MACOS_USE_REQUEST_TIMEOUT", 30)
	if err != nil {
		return nil, err
	}

	heartbeatInterval, err := getEnvAsDuration("MCP_HEARTBEAT_INTERVAL", 30*time.Second)
	if err != nil {
		return nil, err
	}

	httpReadTimeout, err := getEnvAsDuration("MCP_HTTP_READ_TIMEOUT", 30*time.Second)
	if err != nil {
		return nil, err
	}

	httpWriteTimeout, err := getEnvAsDuration("MCP_HTTP_WRITE_TIMEOUT", 30*time.Second)
	if err != nil {
		return nil, err
	}

	cfg := &Config{
		ServerAddr:     getEnv("MACOS_USE_SERVER_ADDR", "localhost:50051"),
		ServerTLS:      getEnvAsBool("MACOS_USE_SERVER_TLS", false),
		ServerCertFile: os.Getenv("MACOS_USE_SERVER_CERT_FILE"),
		RequestTimeout: requestTimeout,
		Debug:          getEnvAsBool("MACOS_USE_DEBUG", false),
		// MCP Transport configuration
		Transport:         TransportType(getEnv("MCP_TRANSPORT", "stdio")),
		HTTPAddress:       getEnv("MCP_HTTP_ADDRESS", ":8080"),
		HTTPSocketPath:    os.Getenv("MCP_HTTP_SOCKET"),
		HeartbeatInterval: heartbeatInterval,
		CORSOrigin:        getEnv("MCP_CORS_ORIGIN", "*"),
		HTTPReadTimeout:   httpReadTimeout,
		HTTPWriteTimeout:  httpWriteTimeout,
		// Security: shell commands are disabled by default
		ShellCommandsEnabled: getEnvAsBool("MCP_SHELL_COMMANDS_ENABLED", false),
	}

	if cfg.ServerAddr == "" {
		return nil, fmt.Errorf("server address cannot be empty")
	}

	// Validate transport type
	if cfg.Transport != TransportStdio && cfg.Transport != TransportHTTP {
		return nil, fmt.Errorf("invalid transport type: %s (must be 'stdio' or 'sse')", cfg.Transport)
	}

	return cfg, nil
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvAsBool(key string, defaultValue bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return value == "true" || value == "1" || value == "yes"
}

func getEnvAsInt(key string, defaultValue int) (int, error) {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue, nil
	}
	var result int
	_, err := fmt.Sscanf(value, "%d", &result)
	if err != nil {
		return 0, fmt.Errorf("invalid value for %s: %q (expected integer)", key, value)
	}
	return result, nil
}

func getEnvAsDuration(key string, defaultValue time.Duration) (time.Duration, error) {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue, nil
	}
	d, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid value for %s: %q (expected duration, e.g., '30s', '5m')", key, value)
	}
	return d, nil
}
