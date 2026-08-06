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

Or from the project root using GNU make:

```bash
gmake swift.build.Server   # Builds the Server package (release)
# Run: Server/.build/release/MacosUseServer
```

## Configuration

The server is configured via environment variables. All variables have sensible defaults.

### Core Settings (Swift server)

| Variable | Description | Default |
|----------|-------------|---------|
| `GRPC_LISTEN_ADDRESS` | gRPC server bind address | `127.0.0.1` |
| `GRPC_PORT` | gRPC server port | `8080` |
| `GRPC_UNIX_SOCKET` | Unix socket path (overrides TCP) | _(none)_ |

### Transport Settings (for MCP tool)

| Variable | Description | Default |
|----------|-------------|---------|
| `MCP_TRANSPORT` | Transport type: `stdio` or `streamable-http` | `stdio` |
| `MCP_HTTP_ADDRESS` | Streamable HTTP listen address | `127.0.0.1:8080` |
| `MCP_HTTP_SOCKET` | Unix socket path (overrides address) | _(none)_ |
| `MCP_CORS_ORIGIN` | Exact allowed browser origin | _(none)_ |
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
| `MCP_AUDIT_LOG_FILE` | Owner-private non-content audit log path | _(none)_ |

### Example Configuration

```bash
# Production deployment: Swift gRPC server bound to a unix socket
export GRPC_LISTEN_ADDRESS="127.0.0.1"
export GRPC_PORT="8080"
export GRPC_UNIX_SOCKET="$HOME/Library/Caches/macosuse.sock"

swift run MacosUseServer
```

When `MCP_AUDIT_LOG_FILE` is set, the MCP process records tool name, status, duration, and UTC timestamps only; tool arguments and user content are never stored. New files are created with mode `0600`. Existing paths must be regular files owned by the current user, mode `0600`, with one hard link; symlinks and non-regular files are rejected.

## API Reference

See [DEPLOYMENT.md](../DEPLOYMENT.md) for the complete deployment guide and the gRPC proto sources under [proto/](../proto/) for the resource-oriented API. The MCP tool surface is documented in [../skills/macos-use/](../skills/macos-use/).

- 29 CUA-aligned MCP tools (see the skill's workflow reference)
- Coordinate system reference
- Environment variable details
- Resource naming conventions

## TLS Setup

The Swift gRPC server does not serve TLS: it is intended to bind to
loopback or an owner-private Unix socket (see the Core Settings table).
TLS is provided by the MCP proxy's Streamable HTTP endpoint:

1. **Generate or obtain certificates:**
   ```bash
   # Self-signed (development only)
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes

   # For production, use certificates from a trusted CA
   ```

2. **Configure the MCP proxy:**
   ```bash
   export MCP_TLS_CERT_FILE="/path/to/cert.pem"
   export MCP_TLS_KEY_FILE="/path/to/key.pem"
   ```

   Both variables are required; the certificate and key must be configured
   together, and a non-loopback TCP listener is rejected unless TLS,
   API-key authentication, and a positive rate limit are all configured.

See [DEPLOYMENT.md](../DEPLOYMENT.md) for comprehensive deployment guidance.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        MCP Clients                              │
│              (Claude, VS Code, AI Assistants)                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │ JSON-RPC over stdio / Streamable HTTP
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
