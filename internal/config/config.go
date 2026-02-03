// Copyright 2025 Joseph Cumines
//
// Configuration package for MCP tool

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

// Config holds the configuration for the MCP tool
type Config struct {
	ServerAddr           string
	ServerCertFile       string
	HTTPAddress          string
	HTTPSocketPath       string
	CORSOrigin           string
	Transport            TransportType
	HeartbeatInterval    time.Duration
	HTTPReadTimeout      time.Duration
	HTTPWriteTimeout     time.Duration
	RequestTimeout       int
	ServerTLS            bool
	Debug                bool
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
