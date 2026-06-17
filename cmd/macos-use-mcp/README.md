# MCP Tool

The `macos-use-mcp` binary is a Model Context Protocol (MCP) server that proxies the current 23 redesigned CUA-aligned macOS automation tools to AI assistants like Claude Desktop.

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

All configuration is via environment variables. See [docs/ai-artifacts/10-api-reference.md](../../docs/ai-artifacts/10-api-reference.md#environment-variables) for the complete reference.

### Core Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MACOS_USE_SERVER_ADDR` | `localhost:50051` | gRPC backend address |
| `MACOS_USE_REQUEST_TIMEOUT` | `30` | Default gRPC request timeout (seconds) |
| `MCP_TRANSPORT` | `stdio` | Transport type: `stdio` or `sse` |

### HTTP Transport Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_HTTP_ADDRESS` | `:8080` | HTTP/SSE server listen address |
| `MCP_HTTP_SOCKET` | (none) | Unix socket path for HTTP/SSE transport |
| `MCP_HTTP_READ_TIMEOUT` | `30s` | HTTP read timeout |
| `MCP_HTTP_WRITE_TIMEOUT` | `30s` | HTTP write timeout |
| `MCP_CORS_ORIGIN` | `*` | CORS allowed origin |

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
        "MACOS_USE_SERVER_ADDR": "localhost:50051",
        "MCP_TRANSPORT": "stdio"
      }
    }
  }
}
```

## Related Documentation

- [API Reference](../../docs/ai-artifacts/10-api-reference.md) - 23 current MCP tools documented with examples
- [MCP Integration](../../docs/ai-artifacts/05-mcp-integration.md) - Protocol compliance details
- [Production Deployment](../../docs/ai-artifacts/08-production-deployment.md) - Deployment guide
- [Security Hardening](../../docs/ai-artifacts/09-security-hardening.md) - Security best practices
