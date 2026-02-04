# Changelog

All notable changes to MacosUseSDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-02-04

### Added

#### MCP Server (77 Tools)

- **Screenshot Tools (4)**: `capture_screenshot`, `capture_window_screenshot`, `capture_region_screenshot`, `capture_element_screenshot`
- **Input Tools (11)**: `click`, `type_text`, `press_key`, `hold_key`, `mouse_move`, `scroll`, `drag`, `mouse_button_down`, `mouse_button_up`, `hover`, `gesture`
- **Element Tools (10)**: `find_elements`, `get_element`, `get_element_actions`, `click_element`, `write_element_value`, `perform_element_action`, `traverse_accessibility`, `find_region_elements`, `wait_element`, `wait_element_state`
- **Window Tools (9)**: `list_windows`, `get_window`, `get_window_state`, `focus_window`, `move_window`, `resize_window`, `minimize_window`, `restore_window`, `close_window`
- **Display Tools (3)**: `list_displays`, `get_display`, `cursor_position`
- **Clipboard Tools (4)**: `get_clipboard`, `write_clipboard`, `clear_clipboard`, `get_clipboard_history`
- **Application Tools (4)**: `open_application`, `list_applications`, `get_application`, `delete_application`
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
- **HTTP/SSE**: Server-Sent Events for web integrations

#### Documentation

- Comprehensive API reference (docs/10-api-reference.md)
- Production deployment guide (docs/08-production-deployment.md)
- Security hardening guide (docs/09-security-hardening.md)
- MCP integration details (docs/05-mcp-integration.md)
- Architecture documentation (docs/01-window-management-subsystems.md)

### Testing

- 350+ unit tests across 14 test files
- 20+ integration test files
- PollUntilContext patterns (zero time.Sleep)
- Golden applications: Calculator, TextEdit, Finder

### Protocol

- MCP specification version: 2025-11-25
- Google AIPs compliance (2025 standards)
- Pagination per AIP-158 with opaque tokens

## [Unreleased]

No unreleased changes.

---

For earlier development history, see the git commit log.
