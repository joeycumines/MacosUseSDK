# ExactMac AI Tool Integration Matrix

One local binary (`cmd/exactmac` → `exactmac`, served as `exactmac mcp`) serves every MCP-capable
AI tool below over **stdio** (default, selected via `MCP_TRANSPORT`) or
**Streamable HTTP**. No code changes per client — only the registration
snippet differs. The MCP server runs as the `mcp` subcommand: `exactmac mcp`. Other subcommands: `exactmac help`, `exactmac version`. Unknown commands fail with usage on stderr.

Conventions used throughout:

- `<EXACTMAC_BIN>` = absolute path to your built proxy, e.g.
  `/Users/you/dev/ExactMac/exactmac` (from
  `go build -o exactmac ./cmd/exactmac` at the repo root).
- The proxy needs the Swift gRPC backend: set `EXACTMAC_SERVER_ADDR`
  (default `localhost:50051`) to the running `ExactMacServer` listener.
- MCP protocol version: `2025-11-25`.
- macOS grants Accessibility / Screen Recording to the **host process** (your
  terminal or agent app), not to the binary. Grant both in
  System Settings → Privacy & Security, then restart the host.

## 1. Claude Code (recommended first target)

Claude Code routes **MCP tools before its built-in `computer-use` server**, so
ExactMac becomes the fast, precise path (AX tree, click by text) and the built-in
stays the screenshot safety net for canvases with no Accessibility tree.

```sh
# Project scope (persists for this project)
claude mcp add exactmac -- <EXACTMAC_BIN> mcp

# Global scope (all projects)
claude mcp add -s user exactmac -- <EXACTMAC_BIN> mcp
```

With environment passthrough:

```sh
claude mcp add -s user exactmac --env EXACTMAC_SERVER_ADDR=localhost:50051 -- <EXACTMAC_BIN> mcp
```

Verify with `claude mcp list`, then ask for `list_apps`. To avoid per-tool
permission prompts, add `mcp__exactmac__*` to `permissions.allow` in
`.claude/settings.local.json`. The built-in `computer-use` server stays
disabled until you enable it in `/mcp` — enable both and Claude picks ExactMac
first automatically.

## 2. Codex CLI

In `~/.codex/config.toml`:

```toml
[mcp_servers.exactmac]
command = "<EXACTMAC_BIN>"
args = ["mcp"]
```

Codex spawns the server over stdio. First tool call may stall a few seconds on
cold start (Swift backend dial + AX snapshot) — subsequent calls reuse the
connection. Floor: macOS 15 or later for the Swift backend
(`Server/Package.swift`, `make/exactmac.mk` `EXACTMAC_MIN_MACOS ?= 15.0`).
Codex's own bundled computer-use helper carries a separate Swift-runtime OS
floor of its own; ExactMac's requirement comes from gRPC Swift 2's Swift 6
concurrency features, not from a bundled helper.

## 3. Codex App (Codex Desktop)

Register ExactMac as an MCP server in the app's MCP settings with the same stdio
command as Codex CLI. Optionally wrap the skill in `skills/exactmac/` as a
Codex skill so the app's planner follows the AX-first workflow, stale-handle
escalation, and two-signal navigation verification automatically.

## 4. Cursor

Global (`~/.cursor/mcp.json`) or per-project (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "exactmac": {
      "command": "<EXACTMAC_BIN>",
      "args": ["mcp"]
    }
  }
}
```

Restart Cursor (Settings → MCP shows the server). Smoke: ask the agent to call
`list_apps`.

## 5. OpenCode

In `opencode.jsonc` (project) or `~/.config/opencode/opencode.json` (global):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "exactmac": {
      "type": "local",
      "command": ["<EXACTMAC_BIN>", "mcp"],
      "enabled": true,
      "environment": {
        "EXACTMAC_SERVER_ADDR": "localhost:50051"
      },
      "timeout": 10000
    }
  }
}
```

Note: the `type: "local"` + `command` array + `environment` + `timeout` shape is
the OpenCode convention (see the OpenCode MCP docs). A personal absolute-path
variant of this file may exist in this checkout — replace the binary path with
your build and keep the environment block.

## 6. Gemini CLI

In `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "exactmac": {
      "command": "<EXACTMAC_BIN>",
      "args": ["mcp"]
    }
  }
}
```

Restart Gemini CLI. Smoke: `list_apps`.

## 7. VS Code (Copilot Chat) / Windsurf

Both accept standard MCP stdio entries. Add to the client's MCP settings file:

```json
{
  "mcpServers": {
    "exactmac": {
      "command": "<EXACTMAC_BIN>",
      "args": ["mcp"]
    }
  }
}
```

VS Code: MCP settings under Settings → MCP (or `.vscode/mcp.json` per project).
Windsurf: MCP settings panel. Smoke in both: `list_apps`.

## 8. Claude Desktop (stdio-only)

In `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "exactmac": {
      "command": "<EXACTMAC_BIN>",
      "env": {
        "EXACTMAC_SERVER_ADDR": "localhost:50051",
        "MCP_TRANSPORT": "stdio"
      }
    }
  }
}
```

Restart Claude Desktop. Desktop supports stdio entries only — for the
Streamable HTTP transport, front it with `mcp-remote` as a stdio-to-HTTP
bridge (same pattern as other multi-instance setups).

## 9. Streamable HTTP (shared / multi-instance)

One persistent proxy serves many clients:

```sh
MCP_TRANSPORT=streamable-http \
MCP_HTTP_ADDRESS=127.0.0.1:8080 \
EXACTMAC_SERVER_ADDR=localhost:50051 \
<EXACTMAC_BIN> mcp
```

Or over a Unix socket: set `MCP_HTTP_SOCKET=/path/to/exactmac.sock` (overrides
TCP). Harden non-loopback listeners with `MCP_TLS_CERT_FILE` +
`MCP_TLS_KEY_FILE`, `MCP_API_KEY`, and a positive `MCP_RATE_LIMIT` — the proxy
refuses insecure non-loopback binds. Initialize per the MCP `initialize`
handshake (`protocolVersion: 2025-11-25`), keep the `MCP-Session-Id` header,
then `tools/call`.

## 10. Pi / Tau / Zed / Cline

Any client that launches a stdio MCP server works with the same command shape
(`<EXACTMAC_BIN> mcp`). Pi/Tau project extensions can wrap the 29 tools with
narrower verbs (snapshot → click/type/scroll at returned coordinates) following
the `skills/exactmac/` workflow; keep AX-first ordering and the coordinate
math in Global Display Coordinates (top-left origin).

## Smoke check (every client)

1. `list_apps` (no args) returns running applications with exact
   `applications/{id}` names.
2. `get_display` returns `displays/1` geometry and cursor position.
3. `list_windows` with one exact `applications/{id}` returns that app's windows
   in Global Display Coordinates.
4. Never invent resource IDs — every `applications/*`, `applicationBundles/*`,
   `windows/*`, `displays/*` value comes verbatim from a prior call.

## Permissions checklist

- Accessibility: host process (terminal/agent app) — required for clicks, typing,
  scrolling, AX reads.
- Screen Recording: host process — required for screenshots.
- Automation (AppleScript fallback only): prompted on first use.
- After granting, restart the host process; macOS may require it before Screen
  Recording takes effect.

## Known limits (honest)

- Apps with no Accessibility tree (some games, custom canvases, JetBrains IDEs
  with screen-reader support off) fall back to coordinate input via screenshot —
  the skill's visual-grounding workflow covers this; built-in screenshot computer
  use is the alternative safety net.
- Cross-window drag-and-drop is brittle; prefer copy/paste.
- No record/replay API beyond the 6 macro tools.
- One interactive desktop session at a time for physical input; concurrent MCP
  clients share the backend and must not interleave input to the same app.
