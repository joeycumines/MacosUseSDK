# MCP Tool

The `macos-use-mcp` binary is a Model Context Protocol (MCP) server that proxies the current 29 CUA-aligned macOS automation tools to AI assistants like Claude Desktop.

## Building

```sh
# Build from project root
go build -o macos-use-mcp ./cmd/macos-use-mcp
```

## Running

### Stdio Transport (Default)

For MCP clients like Claude Desktop:

```sh
./macos-use-mcp
```

### Streamable HTTP Transport

For web-based integrations:

```sh
export MCP_TRANSPORT=streamable-http
export MCP_HTTP_ADDRESS=127.0.0.1:8080
./macos-use-mcp
```

## Configuration

All configuration is via environment variables. See [Server/README.md](../../Server/README.md) for the Swift backend and [DEPLOYMENT.md](../../DEPLOYMENT.md) for the full deployment guide.

### Core Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MACOS_USE_SERVER_ADDR` | `localhost:50051` | gRPC backend address |
| `MACOS_USE_REQUEST_TIMEOUT` | `30` | Default gRPC request timeout (seconds) |
| `MCP_TRANSPORT` | `stdio` | Transport type: `stdio` or `streamable-http` |

### HTTP Transport Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_HTTP_ADDRESS` | `127.0.0.1:8080` | Streamable HTTP server listen address |
| `MCP_HTTP_SOCKET` | (none) | Unix socket path for Streamable HTTP |
| `MCP_HTTP_READ_TIMEOUT` | `30s` | HTTP read timeout |
| `MCP_HTTP_WRITE_TIMEOUT` | `30s` | HTTP write timeout |
| `MCP_CORS_ORIGIN` | (none) | Exact browser Origin to allow; requests with Origin are denied when unset |

### Security Variables (Production)

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_TLS_CERT_FILE` | (none) | TLS certificate file path |
| `MCP_TLS_KEY_FILE` | (none) | TLS private key file path |
| `MCP_API_KEY` | (none) | API key for authentication |
| `MCP_RATE_LIMIT` | `0` | Requests per second; zero disables limiting |

Certificate and key must be configured together. `MCP_CORS_ORIGIN` accepts one
exact `http` or `https` origin, never `*`. A non-loopback TCP listener is rejected
unless TLS, API-key authentication, and a positive rate limit are all configured.

## Claude Desktop Integration

Add to `~/.config/claude/mcp_settings.json`:

```json
{
  "mcpServers": {
    "macos-use": {
      "command": "/path/to/macos-use-mcp",
      "env": {
        "MACOS_USE_SERVER_ADDR": "localhost:50051",
        "MCP_TRANSPORT": "stdio"
      }
    }
  }
}
```

## Related Documentation

- [MCP Integration](../../docs/ai-artifacts/05-mcp-integration.md) - Protocol compliance details
- [Deployment Guide](../../DEPLOYMENT.md) - Full deployment guide
- [macos-use skill](../../skills/macos-use/) - Agent-facing workflow and tool reference
