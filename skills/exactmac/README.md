# exactmac Skill

macOS desktop automation for the ExactMac MCP server.

## Structure

| File | Purpose |
|------|---------|
| `claude-plugin.json` | Plugin manifest with metadata and version |
| `SKILL.md` | Primary skill instructions — loaded by Claude for macOS automation |
| `LICENSE` | MIT license |
| `references/` | Supporting docs (window state, MCP reliability, workflows) |

## Activation

This skill activates automatically for tasks involving macOS desktop automation, Accessibility APIs, MCP tool interaction, or any task involving controlling or interacting with macOS applications or desktop elements programmatically.

## Entry Point

`SKILL.md` — read first on every activation. It covers the core principles, app lifecycle, safety rules, and quick-reference tool table. The manifest itself carries metadata; it does not declare an `entryPoint` field.
