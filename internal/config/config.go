// Copyright 2025 Joseph Cumines

// Package config provides configuration loading for the MCP tool,
// including environment variable parsing and default values.
package config

import (
	"fmt"
	"math"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// TransportType represents the MCP transport type
type TransportType string

const (
	// TransportStdio uses stdin/stdout for communication
	TransportStdio TransportType = "stdio"
	// TransportHTTP uses the MCP Streamable HTTP transport.
	TransportHTTP TransportType = "streamable-http"

	defaultMaxConcurrentRequests          = 512
	defaultMaxConcurrentRequestsPerClient = 256
)

// Config holds the configuration for the MCP tool, loaded from environment variables.
// All fields have sensible defaults via the Load function.
type Config struct {
	// ServerAddr is the gRPC server address (env: EXACTMAC_SERVER_ADDR, default: localhost:50051)
	// When ServerSocketPath is set, this field is ignored.
	ServerAddr string
	// ServerSocketPath is the Unix socket path for the gRPC server (env: EXACTMAC_SERVER_SOCKET_PATH, optional)
	// If set, the MCP server connects to the gRPC server via Unix socket.
	ServerSocketPath string
	// ServerCertFile is the path to the server TLS certificate (env: EXACTMAC_SERVER_CERT_FILE, optional)
	ServerCertFile string
	// HTTPAddress is the Streamable HTTP server listen address (env: MCP_HTTP_ADDRESS, default: 127.0.0.1:8080)
	HTTPAddress string
	// HTTPSocketPath is the Unix socket path for HTTP transport (env: MCP_HTTP_SOCKET, optional)
	HTTPSocketPath string
	// CORSOrigin is the allowed browser Origin (env: MCP_CORS_ORIGIN, default: none)
	CORSOrigin string
	// TLSCertFile is the path to the TLS certificate for HTTPS (env: MCP_TLS_CERT_FILE, optional)
	TLSCertFile string
	// TLSKeyFile is the path to the TLS private key for HTTPS (env: MCP_TLS_KEY_FILE, optional)
	TLSKeyFile string
	// APIKey is the API key for Bearer token authentication (env: MCP_API_KEY, optional)
	// If set, all requests (except /health) require Authorization: Bearer <key> header.
	APIKey string
	// AuditLogFile is the path to the audit log file (env: MCP_AUDIT_LOG_FILE, optional)
	// If set, non-content tool metadata is appended to an owner-private regular file.
	// If empty, audit logging is disabled.
	AuditLogFile string
	// Transport is the transport type selected by the CLI subcommand:
	// "stdio" for `exactmac mcp`, "streamable-http" for `exactmac http`.
	Transport TransportType
	// HTTPReadTimeout is the HTTP server read timeout (env: MCP_HTTP_READ_TIMEOUT, default: 30s)
	HTTPReadTimeout time.Duration
	// HTTPWriteTimeout is the HTTP server write timeout (env: MCP_HTTP_WRITE_TIMEOUT, default: 30s)
	HTTPWriteTimeout time.Duration
	// RateLimit is the rate limit in requests per second (env: MCP_RATE_LIMIT, default: 0 = disabled)
	RateLimit float64
	// RequestTimeout is the gRPC request timeout in seconds (env: EXACTMAC_REQUEST_TIMEOUT, default: 30)
	RequestTimeout int
	// MaxConcurrentRequests is the global active MCP request limit (env: MCP_MAX_CONCURRENT_REQUESTS, default: 512)
	MaxConcurrentRequests int
	// MaxConcurrentRequestsPerClient is the active MCP request limit for one transport-owned client (env: MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT, default: 256)
	MaxConcurrentRequestsPerClient int
	// ServerTLS enables TLS for gRPC (env: EXACTMAC_SERVER_TLS, default: false)
	ServerTLS bool
	// Debug enables debug logging (env: EXACTMAC_DEBUG, default: false)
	Debug bool
	// ShellCommandsEnabled enables shell command execution (env: MCP_SHELL_COMMANDS_ENABLED, default: false)
	// WARNING: Enabling this allows arbitrary command execution and should only be used in trusted environments.
	ShellCommandsEnabled bool
}

// Load loads configuration from environment variables for the given transport
// (selected by the CLI subcommand, not by environment). All other fields have
// sensible defaults. Returns an error if validation fails.
func Load(transport TransportType) (*Config, error) {
	requestTimeout, err := getEnvAsInt("EXACTMAC_REQUEST_TIMEOUT", 30)
	if err != nil {
		return nil, err
	}
	maxConcurrentRequests, err := getEnvAsInt("MCP_MAX_CONCURRENT_REQUESTS", defaultMaxConcurrentRequests)
	if err != nil {
		return nil, err
	}
	maxConcurrentRequestsPerClient, err := getEnvAsInt(
		"MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT",
		defaultMaxConcurrentRequestsPerClient,
	)
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

	rateLimit, err := getEnvAsFloat("MCP_RATE_LIMIT", 0)
	if err != nil {
		return nil, err
	}

	serverTLS, err := getEnvAsBool("EXACTMAC_SERVER_TLS", false)
	if err != nil {
		return nil, err
	}

	debug, err := getEnvAsBool("EXACTMAC_DEBUG", false)
	if err != nil {
		return nil, err
	}

	shellCommandsEnabled, err := getEnvAsBool("MCP_SHELL_COMMANDS_ENABLED", false)
	if err != nil {
		return nil, err
	}

	cfg := &Config{
		ServerAddr:                     getEnv("EXACTMAC_SERVER_ADDR", "localhost:50051"),
		ServerSocketPath:               os.Getenv("EXACTMAC_SERVER_SOCKET_PATH"),
		ServerTLS:                      serverTLS,
		ServerCertFile:                 os.Getenv("EXACTMAC_SERVER_CERT_FILE"),
		RequestTimeout:                 requestTimeout,
		MaxConcurrentRequests:          maxConcurrentRequests,
		MaxConcurrentRequestsPerClient: maxConcurrentRequestsPerClient,
		Debug:                          debug,
		// Transport comes from the CLI subcommand (`mcp` or `http`).
		Transport:        transport,
		HTTPAddress:      getEnv("MCP_HTTP_ADDRESS", "127.0.0.1:8080"),
		HTTPSocketPath:   os.Getenv("MCP_HTTP_SOCKET"),
		CORSOrigin:       os.Getenv("MCP_CORS_ORIGIN"),
		HTTPReadTimeout:  httpReadTimeout,
		HTTPWriteTimeout: httpWriteTimeout,
		// TLS configuration for HTTPS
		TLSCertFile: os.Getenv("MCP_TLS_CERT_FILE"),
		TLSKeyFile:  os.Getenv("MCP_TLS_KEY_FILE"),
		// API key authentication
		APIKey: os.Getenv("MCP_API_KEY"),
		// Audit logging
		AuditLogFile: os.Getenv("MCP_AUDIT_LOG_FILE"),
		// Rate limiting
		RateLimit: rateLimit,
		// Security: shell commands are disabled by default
		ShellCommandsEnabled: shellCommandsEnabled,
	}

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

func (c *Config) validate() error {
	if c.ServerAddr == "" && c.ServerSocketPath == "" {
		return fmt.Errorf("server address or socket path must be provided")
	}
	if c.Transport != TransportStdio && c.Transport != TransportHTTP {
		return fmt.Errorf("invalid transport type: %s (must be 'stdio' or 'streamable-http')", c.Transport)
	}
	if c.RequestTimeout <= 0 {
		return fmt.Errorf("EXACTMAC_REQUEST_TIMEOUT must be positive")
	}
	const maximumDurationSeconds = int64((1<<63 - 1) / int64(time.Second))
	if int64(c.RequestTimeout) > maximumDurationSeconds {
		return fmt.Errorf(
			"EXACTMAC_REQUEST_TIMEOUT must not exceed %d seconds",
			maximumDurationSeconds,
		)
	}
	if c.MaxConcurrentRequests <= 0 {
		return fmt.Errorf("MCP_MAX_CONCURRENT_REQUESTS must be positive")
	}
	if c.MaxConcurrentRequestsPerClient <= 0 {
		return fmt.Errorf("MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT must be positive")
	}
	if c.MaxConcurrentRequestsPerClient > c.MaxConcurrentRequests {
		return fmt.Errorf("MCP_MAX_CONCURRENT_REQUESTS_PER_CLIENT must not exceed MCP_MAX_CONCURRENT_REQUESTS")
	}
	if c.HTTPReadTimeout <= 0 {
		return fmt.Errorf("MCP_HTTP_READ_TIMEOUT must be positive")
	}
	if c.HTTPWriteTimeout < 0 {
		return fmt.Errorf("MCP_HTTP_WRITE_TIMEOUT must not be negative")
	}
	if math.IsNaN(c.RateLimit) || math.IsInf(c.RateLimit, 0) || c.RateLimit < 0 {
		return fmt.Errorf("MCP_RATE_LIMIT must be zero or a finite positive number")
	}
	if (c.TLSCertFile == "") != (c.TLSKeyFile == "") {
		return fmt.Errorf("MCP_TLS_CERT_FILE and MCP_TLS_KEY_FILE must be configured together")
	}
	if err := validateCORSOrigin(c.CORSOrigin); err != nil {
		return err
	}
	if c.Transport != TransportHTTP {
		return nil
	}
	if c.HTTPSocketPath != "" {
		if !filepath.IsAbs(c.HTTPSocketPath) {
			return fmt.Errorf("MCP_HTTP_SOCKET must be an absolute path")
		}
		return nil
	}
	return c.validateHTTPAddress()
}

func (c *Config) validateHTTPAddress() error {
	host, port, err := net.SplitHostPort(c.HTTPAddress)
	if err != nil {
		return fmt.Errorf("MCP_HTTP_ADDRESS must be a host:port listener address: %w", err)
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		return fmt.Errorf("MCP_HTTP_ADDRESS must contain a numeric port between 1 and 65535")
	}

	loopback := strings.EqualFold(host, "localhost")
	if ip := net.ParseIP(host); ip != nil {
		loopback = ip.IsLoopback()
	}
	if !loopback && (c.TLSCertFile == "" || c.APIKey == "" || c.RateLimit <= 0) {
		return fmt.Errorf("non-loopback MCP_HTTP_ADDRESS requires TLS, API key authentication, and rate limiting")
	}
	return nil
}

func validateCORSOrigin(origin string) error {
	if origin == "" {
		return nil
	}
	parsed, err := url.Parse(origin)
	if err != nil ||
		(parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Host == "" ||
		parsed.Hostname() == "" ||
		parsed.User != nil ||
		parsed.Opaque != "" ||
		parsed.Path != "" ||
		parsed.RawPath != "" ||
		parsed.ForceQuery ||
		parsed.RawQuery != "" ||
		parsed.Fragment != "" ||
		strings.TrimSpace(origin) != origin ||
		parsed.String() != origin {
		return fmt.Errorf("MCP_CORS_ORIGIN must be an exact HTTP or HTTPS origin without credentials, path, query, or fragment")
	}
	return nil
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvAsBool(key string, defaultValue bool) (bool, error) {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue, nil
	}
	switch strings.ToLower(value) {
	case "true", "1", "yes":
		return true, nil
	case "false", "0", "no":
		return false, nil
	default:
		return false, fmt.Errorf("invalid value for %s: %q (expected true, false, 1, 0, yes, or no)", key, value)
	}
}

func getEnvAsInt(key string, defaultValue int) (int, error) {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue, nil
	}
	result, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("invalid value for %s: %q (expected integer)", key, value)
	}
	return result, nil
}

func getEnvAsFloat(key string, defaultValue float64) (float64, error) {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue, nil
	}
	result, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid value for %s: %q (expected number)", key, value)
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
