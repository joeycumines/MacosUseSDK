# mcp-server-macos-use: code-grounded analysis

Subject: `mediar-ai/mcp-server-macos-use`
(git HEAD `b5b9b9d`, package version `0.1.18`).
Sources: `README.md`, `Package.swift`, `Package.resolved`, `package.json`,
`CLAUDE.md`, `llms.txt`, `bin/`, `Sources/MCPServer/main.swift` (2056
lines), `Sources/MCPServer/InputGuard.swift`,
`Sources/ScreenshotHelper/main.swift`. Claims cite file and line.

## One-paragraph summary

`mediar-ai/mcp-server-macos-use` is a Swift MCP server that exposes macOS
Accessibility automation over stdio. It is an orchestration layer on top
of the `MacosUseSDK` Swift package: each tool performs one action through
the SDK's `performAction` and then returns a compact summary plus paths to a
full accessibility-tree dump and a window screenshot under `/tmp/macos-use/`.
It is a runnable server binary
(`Sources/MCPServer/main.swift:2024-2055`, `@main` entry, `StdioTransport`
at `main.swift:2013`). It is licensed BSL 1.1 (`LICENSE`), not MIT.

## Identity and distribution

- Repository: `mediar-ai/mcp-server-macos-use`; website
  [macos-use.dev](https://macos-use.dev/) (`README.md:3`,
  `package.json:35`). The website source no longer lives in this repo; commit
  `b5b9b9d` moved it to `mediar-ai/macos-use-website`.
- Two version numbers coexist: npm package `0.1.18` (`package.json:3`) and
  MCP server identity `"SwiftMacOSServerDirect"` version `"1.6.0"`
  (`main.swift:1485-1487`).
- License is Business Source License 1.1 (`LICENSE:1`). No MIT/Apache grant.
- Distribution is npm (`package.json` `bin` entry) via a `bin/` shell wrapper
  that builds with `xcrun swift build -c release` on first run if the binary
  is absent (`bin/mcp-server-macos-use`). `postinstall` also builds
  (`package.json:17-20`).
- Platform floor: macOS 13, swift-tools 5.9 (`Package.swift:7-10`).
  MCP transport library: `modelcontextprotocol/swift-sdk` pinned to `0.11.0`
  (revision `6112a39`, `Package.resolved`).
- The SDK dependency floats: `mediar-ai/MacosUseSDK` tracked on branch
  `main` (`Package.swift:13`), resolved to revision `a2d7866`
  (`Package.resolved`). There is no version tag pin, so rebuilds can silently
  move the SDK underneath the server.

## Tool surface: 9 tools

The code registers 9 tools (`main.swift:1482`). The `README.md` documents 5
(`README.md:20-48`) and `llms.txt` claims 6 at version 0.1.17. Both documents
lag the code; the code is authoritative.

| # | Tool name | What it does (per its in-code description) |
|---|-----------|---------------------------------------------|
| 1 | `macos-use_open_application_and_traverse` | Open/activate by name, path, or bundle ID, then traverse (`main.swift:1321-1325`) |
| 2 | `macos-use_click_and_traverse` | Click at coordinates (top-left, or center when width/height given), or by partial element-text match with optional role filter; optional double-click, right-click, chained type, chained key press, all in one call (`main.swift:1327-1353`) |
| 3 | `macos-use_type_and_traverse` | Type text into the PID's app, optional chained key press (`main.swift:1355-1373`) |
| 4 | `macos-use_press_key_and_traverse` | Press a named key with optional modifiers (`main.swift:1390-1408`) |
| 5 | `macos-use_scroll_and_traverse` | Scroll wheel event at coordinates with line deltas (`main.swift:1411-1426`) |
| 6 | `macos-use_set_value_and_traverse` | Write via `kAXValueAttribute` under (x,y), bypassing the input event tap; documented for Catalyst fields and secure-input contexts where typing fails (`main.swift:1428-1444`) |
| 7 | `macos-use_press_ax_and_traverse` | `kAXPressAction` on the element under (x,y); documented for buttons where synthetic clicks are dropped (`main.swift:1446-1461`) |
| 8 | `macos-use_set_selected_and_traverse` | Set `kAXSelectedAttribute` under (x,y); documented for Catalyst table rows, sidebar entries, and outline rows that expose selection but no press action (`main.swift:1463-1479`) |
| 9 | `macos-use_refresh_traversal` | Traversal only, no action (`main.swift:1375-1387`) |

Notable details:

- Tools 6-8 repeat what click and type already do, for contexts where
  synthetic input events fail: Catalyst panes, sandboxed apps, secure input.
  The surface carries three near-duplicate tools because the primary two do
  not work there.
- The click tool's `element`/`role` parameters (`main.swift:1335-1336`) mean
  text-based clicking exists here too, but there is no standalone
  discovery/listing tool: search happens implicitly inside the click ("first
  match is clicked"). There is no way to enumerate matches before acting.
- Targeting is per-call PID plus coordinates. PIDs are exact, but they are
  transient OS identifiers, not stable resource handles: no windows list, no
  app list, no handles that survive across calls.
- There is no window management (move, resize, focus, minimize), no
  clipboard, no command execution, no macros, no sessions, no observation
  subscriptions, no display enumeration. The surface is one action plus one
  traversal, nine times.

## Response contract: summary plus receipt files

Every tool call returns a compact text summary (`buildCompactSummary`,
`main.swift:731`) containing status, PID, app name, element count, a grep
hint, error fields, and two paths (`main.swift:1960-1984`):

- Full accessibility tree as flat text:
  `/tmp/macos-use/<epoch-ms>_<tool>.txt` (`main.swift:1961-1968`).
  One element per line in `[Role] "text" x:N y:N w:W h:H visible` form
  (format described in the server instructions, `main.swift:1505`, and in
  `CLAUDE.md`).
- Window screenshot: `/tmp/macos-use/<epoch-ms>_<tool>.png`
  (`main.swift:1971-1979`), captured for the effective PID after any
  app-switch re-traversal.

Stated rationale in their own docs: keep full traversal data out of the
model context ("to reduce context bloat", `CLAUDE.md`, "MCP Response Files").
The server instructions additionally tell agents to verify every interaction
against the screenshot because "the accessibility tree alone can be
misleading (wrong element matches, stale data, etc.)"
(`main.swift:1491`). Their tree goes stale the same way any polled snapshot
does.

Action results can also carry a before/after element diff
(`traverseBefore`/`traverseAfter`/`showDiff` options, `README.md:54-56`,
diff enrichment around `main.swift:700-729`).

## Input handling: event-tap guard with Esc cancel

`InputGuard` (`Sources/MCPServer/InputGuard.swift`) blocks user keyboard/mouse
input during automation via an event tap, shows a floating overlay banner
("AI is controlling your computer — press Esc to cancel",
`InputGuard.swift:69`), and releases on plain Esc, which surfaces as
`InputGuardCancelled` and restores cursor position and the previous frontmost
app (`main.swift:1986-2000`). A 30-second watchdog auto-releases the guard
(`InputGuard.swift:24`). Debug/status breadcrumbs are written to
`/tmp/macos-use/` (`tap_status.txt`, `cancel_check.txt`, `esc_pressed.txt`;
`InputGuard.swift:56,154,347`).

It guards one synchronous action against user interference and offers cancel,
but there is no named-target transaction, no focus convergence contract, and
no delivery receipt beyond the summary text.

## Screenshots: subprocess isolation

Window screenshots go through a separate `screenshot-helper` executable
(`Sources/ScreenshotHelper/`, `Package.swift:25-28`) because loading
ReplayKit as a side effect of `CGWindowListCreateImage` would otherwise spin
forever in the parent server (stated in the helper's header comment). The
helper accepts a window ID, output path, and optional click point plus bounds
for annotation.

## Transports and security posture

- stdio only (`StdioTransport`, `main.swift:2013`). No Streamable HTTP, no
  Unix-socket listener, no TLS, no API-key auth, no rate limiting, no audit
  log in `Sources/`.
- The `/tmp/macos-use/` directory is created as needed (`main.swift:1962`)
  with ms-precision filenames to avoid collisions (`main.swift:1964`). No
  code in `Sources/` deletes these files, so long sessions accumulate
  timestamped tree dumps and screenshots there.
- Their `CLAUDE.md` names the live MCP server key as `macos-use`
  (`mcp__macos-use__*`), which is the other half of the search collision with
  this project beyond the repository name.

## Relation to ExactMac

Sources of confusion: shared lineage (their server consumes the SDK
ours forked from), overlapping vocabulary ("macos-use", "traverse",
"accessibility tree", "InputGuard"-style input locking), and a website that
ranks for the same queries.

What differs:

- Lineage: their server depends on upstream `MacosUseSDK` on floating
  `main`. ExactMac forked that SDK and diverged; nothing in ExactMac calls
  their server or its SDK pin.
- License: BSL 1.1 versus ExactMac's MIT. Reuse terms differ.
- Targeting model: per-call PID plus coordinates or first-text-match,
  versus ExactMac's opaque named resources with pagination, sessions, and
  observations.
- Response model: summary plus tree/screenshot files in a shared tmp
  directory, versus ExactMac's accessor-verified delivery results over
  gRPC/MCP transports.
- Surface breadth: 9 action-plus-traversal tools versus ExactMac's 29
  across input, elements, windows, applications, clipboard, execution,
  display, and macros. This project has no window management, no app
  enumeration, no clipboard, no execution, and no multi-step constructs.
- Transports and hardening: stdio only, no auth/TLS/rate-limit/audit,
  versus stdio plus Streamable HTTP with all four.

Strengths: small surface where each tool chains its common follow-ups
(click+type+press in one call), AX fallbacks for frameworks where synthetic
input fails, screenshot-backed verification guidance, and an input guard with
cancel. Weaknesses: PID targeting without stable handles, file responses in
a shared tmp dir with no retention, floating SDK pin, stale public docs
(5 tools documented, 6 claimed in llms.txt, 9 shipped), and a platform floor
of macOS 13 with swift-tools 5.9.
