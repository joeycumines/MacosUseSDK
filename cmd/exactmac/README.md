# `exactmac` CLI (ExactMac)

The `exactmac` binary is the ExactMac command-line interface. The MCP server —
the current 29 CUA-aligned macOS automation tools for any MCP-capable AI
assistant (Claude Code, Codex CLI/App, Cursor, OpenCode, Gemini CLI, VS Code,
Windsurf, or Claude Desktop) — runs as `exactmac mcp` (stdio) or
`exactmac http` (Streamable HTTP).

## Building

```sh
# Build from project root
go build -o exactmac ./cmd/exactmac
```

## Running

### `exactmac mcp` — Stdio Transport

For MCP clients like Claude Desktop:

```sh
./exactmac mcp
```

### `exactmac http` — Streamable HTTP Transport

For web-based integrations:

```sh
export MCP_HTTP_ADDRESS=127.0.0.1:8080
export EXACTMAC_SERVER_ADDR=127.0.0.1:50051
./exactmac http
```

## Configuration

All configuration is via environment variables. See [Server/README.md](../../Server/README.md) for the Swift backend and [DEPLOYMENT.md](../../DEPLOYMENT.md) for the full deployment guide.

### Core Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EXACTMAC_SERVER_ADDR` | `localhost:50051` | gRPC backend address |
| `EXACTMAC_REQUEST_TIMEOUT` | `30` | Default gRPC request timeout (seconds) |

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

## AI Tool Integration

Any MCP-capable client works over stdio with the absolute binary path
plus the `mcp` subcommand. Full per-client matrix — Claude Code (`claude mcp add exactmac`),
Codex CLI (`~/.codex/config.toml`), Codex App, Cursor, OpenCode
(`opencode.jsonc` local type), Gemini CLI, VS Code, Windsurf, Claude Desktop —
with snippets and smoke checks: [ai-tool-integration.md](../../docs/ai-artifacts/ai-tool-integration.md).

### Claude Desktop Integration (example)

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "exactmac": {
      "command": "/path/to/exactmac",
      "args": ["mcp"],
      "env": {
        "EXACTMAC_SERVER_ADDR": "localhost:50051"
      }
    }
  }
}
```

## Related Documentation

- [MCP Integration](../../docs/ai-artifacts/05-mcp-integration.md) - Protocol compliance details
- [Deployment Guide](../../DEPLOYMENT.md) - Full deployment guide
- [AI Tool Integration](../../docs/ai-artifacts/ai-tool-integration.md) - Per-client setup for every supported AI coding tool
- [exactmac skill](../../skills/exactmac/) - Agent-facing workflow and tool reference
