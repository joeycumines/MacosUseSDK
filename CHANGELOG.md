# Changelog

All notable changes to MacosUseSDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-beta] - 2026-02-04

### Added

#### MCP Server (77 Tools)

- **Input Tools**: `click`, `type_text`, `press_key`, `drag`, `scroll`, `hold_key`, `mouse_button_down`, `mouse_button_up`, `cursor_position`, `get_input`
- **Element Tools**: `find_elements`, `get_element`, `click_element`, `write_element_value`, `perform_element_action`, `traverse_accessibility`, `find_region_elements`, `get_element_actions`, `wait_element`, `wait_element_state`
- **Window Tools**: `list_windows`, `get_window`, `get_window_state`, `focus_window`, `move_window`, `resize_window`, `minimize_window`, `restore_window`, `close_window`
- **Display Tools**: `list_displays`, `get_display`, `capture_cursor_position`
- **Screenshot Tools**: `create_screenshot`
- **Clipboard Tools**: `get_clipboard`, `write_clipboard`, `clear_clipboard`, `get_clipboard_history`
- **Application Tools**: `open_application`, `list_applications`, `get_application`, `delete_application`
- **Session Tools**: `create_session`, `get_session`, `list_sessions`, `delete_session`
- **Macro Tools**: `create_macro`, `get_macro`, `list_macros`, `delete_macro`, `execute_macro`
- **Observation Tools**: `create_observation`, `get_observation`, `list_observations`, `cancel_observation`, `stream_observations`
- **Scripting Tools**: `execute_applescript`, `execute_jxa`, `execute_shell`, `execute_shortcuts`
- **File Dialog Tools**: `automate_open_file_dialog`, `automate_save_file_dialog`, `select_file`, `select_directory`, `drag_files`
- **Accessibility Tools**: `list_accessibility_roles`, `read_accessibility_hierarchy`, `highlight_element`
- **Discovery Tools**: `get_automation_capabilities`

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
