# Changelog

All notable changes to ExactMac will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-24

### Added

- First public ExactMac distribution with the Swift Accessibility/gRPC server, Swift SDK, Go `exactmac` CLI, and MCP integration skill.
- `exactmac mcp` for stdio and `exactmac http` for Streamable HTTP, plus MCP resources, prompts, and the CUA-aligned tool registry.
- The consolidated `ExactMac` gRPC service for applications, inputs, elements, windows, observations, sessions, macros, scripting, clipboard, screenshots, and displays.
- `ListDisplays` with display identifiers, global display frames, visible frames, main-display state, and scale factors.
- AIP-158 `skip` support on the eleven hand-authored List/Find gRPC requests. Programmatic callers can skip resources on a first page or continuation; MCP schemas remain unchanged.
- PNG, JPEG, and TIFF screenshot output. PNG and TIFF preserve source alpha when present; JPEG is explicitly opaque because the format has no alpha channel.
- TLS, API-key authentication, token-bucket rate limiting, Prometheus metrics, and structured audit logging for the HTTP transport.
- Deployment, MCP integration, tool-reference, and AI-client integration documentation.

### Changed

- The first public protobuf contract uses the `exactmac.v1` package, normalized resource and field names, corrected resource annotations, and declaration-order field numbers. This is an intentional breaking pre-1.0 contract change.
- Input creation now records an owned transaction with an exact application, window, display, or desktop target and reports observable delivery state.
- Pagination page tokens are authenticated, encrypted, URL-safe, and opaque. Page size may change on a continuation, while semantic query changes remain bound to the token.
- MCP tool schemas expose the supported user-facing arguments without the programmatic `skip` control.
- CI keeps manual workflow dispatch, adds same-job formatting drift checks, and generates descriptor sets before the integration server build.

### Fixed

- Region screenshot benchmarks now use an admitted display and a valid clamped benchmark region instead of assuming a 1000x800 region fits every runner display.
- Equivalent selector maps now produce the same continuation identity regardless of protobuf map iteration order.
- Screenshot capture configuration keeps alpha-capable output independent of window-shadow selection.
- Public contract validation rejects negative `skip` values and token-plus-`skip` arithmetic overflow.

[Unreleased]: https://github.com/joeycumines/ExactMac/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/joeycumines/ExactMac/releases/tag/v0.1.0
