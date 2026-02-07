# MacosUseServer

gRPC server providing macOS automation capabilities via the MacosUseSDK.

## Overview

MacosUseServer is a Swift 6-based gRPC server that exposes macOS accessibility, window management, screenshot, input simulation, and scripting APIs. It serves as the backend for the MCP (Model Context Protocol) tool, enabling AI assistants to interact with macOS applications.

## Prerequisites

- **macOS 15.0+** (required for Swift 6 concurrency features)
- **Xcode 16+** with Swift 6.0 toolchain
- **Accessibility permissions** granted to the host application (System Preferences → Privacy & Security → Accessibility)
- **Screen Recording permissions** for screenshot functionality

## Building

From the `Server/` directory:

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run the server
swift run MacosUseServer
```

Or from the project root using make:

```bash
make swift-build     # Builds both SDK and Server
make swift-run       # Runs the server
```

## Configuration

The server is configured via environment variables. All variables have sensible defaults.

### Core Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `MACOS_USE_SERVER_ADDR` | gRPC server listen address | `localhost:50051` |
| `MACOS_USE_SERVER_TLS` | Enable TLS for gRPC connections | `false` |
| `MACOS_USE_SERVER_CERT_FILE` | Path to TLS certificate (when TLS enabled) | _(none)_ |
| `MACOS_USE_REQUEST_TIMEOUT` | Request timeout in seconds | `30` |
| `MACOS_USE_DEBUG` | Enable debug logging | `false` |

### Transport Settings (for MCP tool)

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_TRANSPORT` | Transport type: `stdio` or `sse` | `stdio` |
| `MCP_HTTP_ADDRESS` | HTTP/SSE listen address | `:8080` |
| `MCP_HTTP_SOCKET` | Unix socket path (overrides address) | _(none)_ |
| `MCP_CORS_ORIGIN` | CORS allowed origin | `*` |
| `MCP_HEARTBEAT_INTERVAL` | SSE heartbeat interval | `30s` |
| `MCP_HTTP_READ_TIMEOUT` | HTTP read timeout | `30s` |
| `MCP_HTTP_WRITE_TIMEOUT` | HTTP write timeout | `30s` |

### Security Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_TLS_CERT_FILE` | TLS certificate for HTTPS | _(none)_ |
| `MCP_TLS_KEY_FILE` | TLS private key for HTTPS | _(none)_ |
| `MCP_API_KEY` | API key for Bearer token authentication | _(none)_ |
| `MCP_SHELL_COMMANDS_ENABLED` | Enable shell command execution | `false` |
| `MCP_RATE_LIMIT` | Rate limit in requests/second (0=disabled) | `0` |
| `MCP_AUDIT_LOG_FILE` | Path to audit log file | _(none)_ |

### Example Configuration

```bash
# Production deployment
export MACOS_USE_SERVER_ADDR="0.0.0.0:50051"
export MACOS_USE_SERVER_TLS="true"
export MACOS_USE_SERVER_CERT_FILE="/etc/ssl/certs/server.crt"
export MCP_API_KEY="$(openssl rand -base64 32)"
export MCP_RATE_LIMIT="100"
export MCP_AUDIT_LOG_FILE="/var/log/macos-use-audit.log"

swift run MacosUseServer
```

## API Reference

See [docs/10-api-reference.md](../docs/ai-artifacts/10-api-reference.md) for the complete API documentation including:

- 77 MCP tools across 14 categories
- Coordinate system reference
- Environment variable details
- Error code reference
- Resource naming conventions

## TLS Setup

For production deployments with TLS:

1. **Generate or obtain certificates:**
   ```bash
   # Self-signed (development only)
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes

   # For production, use certificates from a trusted CA
   ```

2. **Configure the server:**
   ```bash
   export MACOS_USE_SERVER_TLS="true"
   export MACOS_USE_SERVER_CERT_FILE="/path/to/cert.pem"
   # Note: Private key path is derived from cert file location
   ```

3. **For HTTPS (MCP SSE transport):**
   ```bash
   export MCP_TLS_CERT_FILE="/path/to/cert.pem"
   export MCP_TLS_KEY_FILE="/path/to/key.pem"
   ```

See [docs/ai-artifacts/08-production-deployment.md](../docs/ai-artifacts/08-production-deployment.md) and [docs/ai-artifacts/09-security-hardening.md](../docs/ai-artifacts/09-security-hardening.md) for comprehensive deployment guidance.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        MCP Clients                              │
│              (Claude, VS Code, AI Assistants)                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │ JSON-RPC over stdio/SSE
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                       macos-use-mcp (Go)                             │
│                  MCP Protocol Handler                           │
└───────────────────────────┬─────────────────────────────────────┘
                            │ gRPC
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                   MacosUseServer (Swift)                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Application │  │   Window    │  │        Element          │  │
│  │   Service   │  │   Service   │  │        Service          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Screenshot  │  │    Input    │  │      Observation        │  │
│  │   Service   │  │   Service   │  │        Service          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     MacosUseSDK (Swift)                         │
│            Accessibility, Window, Input, Screenshot             │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    macOS System APIs                            │
│           (Accessibility, CoreGraphics, AppKit)                 │
└─────────────────────────────────────────────────────────────────┘
```

## Development

### Running Tests

```bash
swift test
```

### Proto Generation

Proto files are located in `../proto/macosusesdk/v1/`. To regenerate Swift stubs:

```bash
# From project root
make buf-generate
```

### Dependencies

- [grpc-swift-2](https://github.com/grpc/grpc-swift-2) - gRPC Swift 2 core
- [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf) - Protobuf integration
- [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) - HTTP/2 transport
- MacosUseSDK - macOS automation primitives

## License

See [LICENSE](../LICENSE) in the project root.
