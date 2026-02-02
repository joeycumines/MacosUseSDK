// Copyright 2025 Joseph Cumines
//
// Configuration package for MCP tool

package config

import (
	"fmt"
	"os"
)

// Config holds the configuration for the MCP tool
type Config struct {
	ServerAddr     string
	ServerCertFile string
	RequestTimeout int
	ServerTLS      bool
	Debug          bool
}

// Load loads the configuration from environment variables
func Load() (*Config, error) {
	cfg := &Config{
		ServerAddr:     getEnv("MACOS_USE_SERVER_ADDR", "localhost:50051"),
		ServerTLS:      getEnvAsBool("MACOS_USE_SERVER_TLS", false),
		ServerCertFile: os.Getenv("MACOS_USE_SERVER_CERT_FILE"),
		RequestTimeout: getEnvAsInt("MACOS_USE_REQUEST_TIMEOUT", 30),
		Debug:          getEnvAsBool("MACOS_USE_DEBUG", false),
	}

	if cfg.ServerAddr == "" {
		return nil, fmt.Errorf("server address cannot be empty")
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

func getEnvAsInt(key string, defaultValue int) int {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	var result int
	_, err := fmt.Sscanf(value, "%d", &result)
	if err != nil {
		return defaultValue
	}
	return result
}
