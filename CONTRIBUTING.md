# Contributing to MacosUseSDK

Thank you for your interest in contributing to MacosUseSDK!

## Development Requirements

- **macOS**: This project requires macOS for development (Accessibility APIs)
- **Go 1.25+**: For the MCP server and integration tests
- **Swift 6.1+**: For the gRPC server
- **make**: GNU Make for build orchestration
- **protoc** + **buf**: For protobuf code generation

## Building

```sh
# Full build (Swift + Go + Proto generation)
make all

# Run all tests
make test
```

## Testing

### Unit Tests

```sh
# Go unit tests
make go.test

# Swift unit tests
make swift.test
```

### Integration Tests

Integration tests require macOS accessibility permissions:

```sh
# Run integration tests (requires Calculator, TextEdit, Finder)
make go.test.integration
```

**Important**: Integration tests use `PollUntilContext` patterns, never `time.Sleep`.

## Code Style

### Go

- Run `go vet` and `staticcheck` before committing
- All exported types and functions require godoc comments
- Error messages follow the format: `"failed to [action]: [details]"`

### Swift

- Use `Logger` with privacy annotations; `fputs`/`print` are forbidden for diagnostics
- Actor-based concurrency for shared state
- Consistent `RPCError(code:message:)` pattern for errors

### Proto

- Follow [Google AIPs](https://google.aip.dev/) (2025 standards)
- Use `google.api.field_behavior` annotations
- Document coordinate systems explicitly (Global Display Coordinates)
- Page tokens are opaque per AIP-158

## Pull Request Process

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes with tests
4. Run `make all` to verify
5. Submit a PR with a descriptive title

### Commit Messages

Use conventional commits:

```
feat(scope): add new feature
fix(scope): fix bug description
test(scope): add test coverage
docs(scope): update documentation
refactor(scope): improve code structure
```

## Architecture Overview

See [docs/01-window-management-subsystems.md](docs/01-window-management-subsystems.md) for the system architecture.

Key components:
- **Swift gRPC Server** (`Server/`): macOS Accessibility API integration
- **Go MCP Server** (`internal/`): MCP proxy with 77 tools
- **Proto Definitions** (`proto/`): API contracts following Google AIPs

## License

By contributing, you agree that your contributions will be licensed under the project's license.
