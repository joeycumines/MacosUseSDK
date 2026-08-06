# Changelog

All notable changes to MacosUseSDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-02-04

### Added

#### Historical MCP Server Inventory (76 Listed Tools)

The following inventory describes the 0.1.0-era design and is not the current
MCP registry. The current implementation exposes 29 tools; see
`skills/macos-use/references/workflows-and-tools.md`.

- **Screenshot Tools (4)**: `capture_screenshot`, `capture_window_screenshot`, `capture_region_screenshot`, `capture_element_screenshot`
- **Input Tools (11)**: `click`, `type_text`, `press_key`, `hold_key`, `mouse_move`, `scroll`, `drag`, `mouse_button_down`, `mouse_button_up`, `hover`, `gesture`
- **Element Tools (10)**: `find_elements`, `get_element`, `get_element_actions`, `click_element`, `write_element_value`, `perform_element_action`, `traverse_accessibility`, `find_region_elements`, `wait_element`, `wait_element_state`
- **Window Tools (9)**: `list_windows`, `get_window`, `get_window_state`, `focus_window`, `move_window`, `resize_window`, `minimize_window`, `restore_window`, `close_window`
- **Display Tools (3)**: `list_displays`, `get_display`, `cursor_position`
- **Clipboard Tools (4)**: `get_clipboard`, `write_clipboard`, `clear_clipboard`, `get_clipboard_history`
- **Application Tools (3)**: `open_app`, `list_apps`, `close_app`
- **Scripting Tools (4)**: `execute_apple_script`, `execute_javascript`, `execute_shell_command`, `validate_script`
- **Observation Tools (5)**: `create_observation`, `stream_observations`, `get_observation`, `list_observations`, `cancel_observation`
- **Session Tools (8)**: `create_session`, `get_session`, `list_sessions`, `delete_session`, `get_session_snapshot`, `begin_transaction`, `commit_transaction`, `rollback_transaction`
- **Macro Tools (6)**: `create_macro`, `get_macro`, `list_macros`, `delete_macro`, `execute_macro`, `update_macro`
- **File Dialog Tools (5)**: `automate_open_file_dialog`, `automate_save_file_dialog`, `select_file`, `select_directory`, `drag_files`
- **Input Query Tools (2)**: `get_input`, `list_inputs`
- **Scripting Discovery Tools (2)**: `get_scripting_dictionaries`, `watch_accessibility`

#### Security & Observability

- TLS support with `MCP_TLS_CERT_FILE` and `MCP_TLS_KEY_FILE`
- API key authentication with constant-time comparison
- Rate limiting (token bucket algorithm)
- Prometheus-compatible metrics at `/metrics`
- Structured audit logging

#### Transports

- **stdio**: JSON-RPC 2.0 over stdin/stdout for Claude Desktop
- **Streamable HTTP**: Synchronous JSON responses at `/mcp`; standalone SSE is not initiated

#### Documentation

- Production deployment guide (`DEPLOYMENT.md`)
- MCP tool reference (`skills/macos-use/references/workflows-and-tools.md`)
- MCP integration details (docs/ai-artifacts/05-mcp-integration.md)
- Architecture documentation (docs/ai-artifacts/01-window-management-subsystems.md)

### Testing

- Unit and integration coverage across the Swift and Go packages
- PollUntilContext is required for integration/state-convergence tests
- Golden applications: Calculator, TextEdit, Finder

### Protocol

- MCP specification version: 2025-11-25
- Google AIPs compliance (2025 standards)
- Pagination per AIP-158 with opaque tokens

## [Unreleased]

### Added

- **Background Application Open Mode**: the gRPC `OpenApplication` API supports background launch without stealing focus
- **MCP Resources Support**: `resources/list` and `resources/read` methods for `screen://`, `accessibility://`, `clipboard://` URIs
- **MCP Prompts Support**: `prompts/list` and `prompts/get` methods for predefined automation prompts

### Changed

- **Owned Physical Input Transactions**: `CreateInput` now requires one exact application, window, display, or explicit desktop target; preserves caller IDs and immutable intent; reports `PENDING`, `EXECUTING`, `COMPLETED`, `FAILED`, or `CANCELLED`; and returns explicit delivery commitment, post count, and routed-observation evidence.
- **Strict MCP Input Boundary**: All seven physical MCP tools require exact targets, generate opaque per-call input IDs, forward complete timing/modifier/path intent, and reject malformed or non-settled backend responses.
- **Root Product Topology**: Removed the unsupported `ActionTool`, `AppOpenerTool`, `HighlightTraversalTool`, `InputControllerTool`, `TraversalTool`, and `VisualInputTool` executable products instead of preserving unowned bypass paths.
- **Passive Observation Mode (Default)**: observation polling defaults to `activate=false`; the current traversal RPC boundary does not expose an `activate` field
- **Circuit Breaker in ChangeDetector**: Per-PID throttling (5 events/second) prevents activation storms from external events
- **SDK Activation Filtering**: `ChangeDetector` contains activation suppression helpers for SDK-triggered activations

### Fixed

- **Activation Cycle Fix**: Eliminated destructive feedback loop where observation polling caused continuous app activation/deactivation cycles
- **Proto Annotation Improvements**: Added `google.api.field_behavior` annotations across the hand-authored API fields
- **Lint Cleanup**: Cleaned hand-written Swift lint directives and explicit `self.` prefixes for Swift 6 concurrency; generated files remain separately excluded from linting

### Testing

- **Expanded Integration Tests**: Calculator, TextEdit, and Finder coverage for elements, windows, clipboard, and observations
- **Proto Backward Compatibility Tests**: 15 tests verifying field numbers, enum values, unknown field preservation
- **CI Improvements**: Proto lint steps, Go/Swift coverage reporting, dependency caching

---

For earlier development history, see the git commit log.
