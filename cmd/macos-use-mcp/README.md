# MCP Tool

The `macos-use-mcp` binary is a Model Context Protocol (MCP) server that proxies 77 macOS automation tools to AI assistants like Claude Desktop.

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

### HTTP/SSE Transport

For web-based integrations:

```sh
export MCP_TRANSPORT=http
export MCP_HTTP_ADDRESS=:8080
./macos-use-mcp
```

## Configuration

All configuration is via environment variables. See [docs/10-api-reference.md](../../docs/10-api-reference.md#environment-variables) for the complete reference.

### Core Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GRPC_SERVER_ADDR` | `localhost:50051` | gRPC backend address |
| `MCP_TRANSPORT` | `stdio` | Transport type: `stdio` or `http` |
| `MCP_LOG_LEVEL` | `info` | Log level: `debug`, `info`, `warn`, `error` |
| `MCP_REQUEST_TIMEOUT` | `30` | Default request timeout (seconds) |

### HTTP Transport Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_HTTP_ADDRESS` | `:8080` | HTTP server listen address |
| `MCP_CORS_ORIGIN` | `*` | CORS allowed origin |
| `MCP_SSE_HEARTBEAT` | `15s` | SSE keepalive interval |

### Security Variables (Production)

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_TLS_CERT_FILE` | (none) | TLS certificate file path |
| `MCP_TLS_KEY_FILE` | (none) | TLS private key file path |
| `MCP_API_KEY` | (none) | API key for authentication |

## Claude Desktop Integration

Add to `~/.config/claude/mcp_settings.json`:

```json
{
  "mcpServers": {
    "macos-use": {
      "command": "/path/to/macos-use-mcp",
      "env": {
        "GRPC_SERVER_ADDR": "localhost:50051",
        "MCP_LOG_LEVEL": "warn"
      }
    }
  }
}
```

## Related Documentation

- [API Reference](../../docs/10-api-reference.md) - 77 tools documented with examples
- [MCP Integration](../../docs/05-mcp-integration.md) - Protocol compliance details
- [Production Deployment](../../docs/08-production-deployment.md) - Deployment guide
- [Security Hardening](../../docs/09-security-hardening.md) - Security best practices
