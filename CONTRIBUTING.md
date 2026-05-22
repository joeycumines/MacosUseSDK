# Contributing to MacosUseSDK

Thank you for your interest in contributing to MacosUseSDK!

## Developer Setup

### System Requirements

| Requirement | Minimum Version | Notes |
|-------------|-----------------|-------|
| **macOS** | 14.0 (Sonoma) | Required for Accessibility APIs |
| **Xcode** | 16.0 | Includes Swift 6.1 toolchain |
| **Go** | 1.25+ | For MCP server and integration tests |
| **GNU Make** | 4.0+ | Build orchestration (Homebrew `make` provides `gmake`) |

### Installing Homebrew Dependencies

Install all required development tools via Homebrew:

```sh
# Core build tools
brew install go buf make

# Linting and formatting
brew install swiftformat swiftlint staticcheck golangci-lint

# Optional: Google API linter (for proto validation)
go install github.com/googleapis/api-linter/cmd/api-linter@latest
```

> **Note**: macOS includes BSD `make`. Use `gmake` (GNU Make from Homebrew) for compatibility with the build system.

### Accessibility Permissions

**CRITICAL**: Integration tests and the SDK require macOS Accessibility permissions.

1. Open **System Settings > Privacy & Security > Accessibility**
2. Add your terminal application (e.g., Terminal.app, iTerm2, VS Code)
3. Toggle the permission ON
4. **Restart your terminal** after granting permissions

To verify permissions are granted:

```sh
# This should succeed without prompting (returns the frontmost app name)
osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true'
```

### Clone and First Build

```sh
# Clone the repository
git clone https://github.com/joeycumines/MacosUseSDK.git
cd MacosUseSDK

# Generate protobuf code (required before first build)
gmake buf.generate

# Full build (Swift + Go + Proto)
gmake all

# Verify build succeeded
echo $?  # Should print 0
```

### Environment Variables (Optional)

For local development with custom server configuration:

```sh
# Swift gRPC server
export GRPC_LISTEN_ADDRESS="127.0.0.1"
export GRPC_PORT="50051"

# Go MCP server
export MCP_HTTP_ADDR="127.0.0.1:8080"
export MCP_SERVER_ADDR="127.0.0.1:50051"
```

See the [API Reference](docs/ai-artifacts/10-api-reference.md#3-environment-variable-reference) for all 18 environment variables.

## Building

```sh
# Full build (Swift + Go + Proto generation)
gmake all

# Run all tests
gmake test

# Specific component builds
gmake swift.build    # Swift SDK and Server
gmake go.build       # Go MCP server
gmake buf.generate   # Regenerate protobuf code
```

## Testing

### Unit Tests

```sh
# All unit tests
gmake test

# Go unit tests
gmake go.test

# Swift unit tests
gmake swift.test

# Run specific Swift test
swift test --filter TestClassName/testMethodName
```

### Integration Tests

Integration tests require macOS accessibility permissions and target Calculator, TextEdit, and Finder:

```sh
# Run all integration tests (requires permissions)
gmake go.test.integration

# Run specific integration test suite
cd integration && go test -v -run TestCalculator ./...
```

**Important**: Integration tests use `PollUntilContext` patterns, never `time.Sleep`. Tests must assert state differences, not just "OK" status.

## Test Guidelines

### Golden Application Constraint

Integration tests MUST target only these applications:

| Application | Use Case |
|-------------|----------|
| **Calculator** | Input simulation, element interaction |
| **TextEdit** | Text input, clipboard, document handling |
| **Finder** | File dialogs, window management |

Do not introduce new target applications without discussion.

### No `time.Sleep` Rule

**BANNED**: `time.Sleep` in all test code. Use `PollUntilContext` for async verification:

```go
// ❌ WRONG: Arbitrary sleep
time.Sleep(2 * time.Second)

// ✅ CORRECT: Poll until condition or timeout
err := PollUntilContext(ctx, 100*time.Millisecond, func() bool {
    resp, _ := client.GetWindow(ctx, &pb.GetWindowRequest{Name: windowName})
    return resp != nil && resp.GetWindow().GetTitle() == expectedTitle
})
```

The `PollUntilContext` helper polls at the given interval until the predicate returns `true` or the context expires.

### State-Delta Assertions

Tests MUST verify state changes, not just "OK" status:

```go
// ❌ WRONG: Only checking status
resp, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{...})
require.NoError(t, err) // Only verifies the call succeeded

// ✅ CORRECT: Verify the delta in state
initialWindow := getWindow(t, client, windowName)
initialX, initialY := initialWindow.GetBounds().GetX(), initialWindow.GetBounds().GetY()

_, err := client.MoveWindow(ctx, &pb.MoveWindowRequest{
    Name: windowName,
    X: 200, Y: 300,
})
require.NoError(t, err)

// Assert the state actually changed
finalWindow := getWindow(t, client, windowName)
assert.NotEqual(t, initialX, finalWindow.GetBounds().GetX())
assert.Equal(t, float64(200), finalWindow.GetBounds().GetX())
```

### Fixture Lifecycle

Every test suite must ensure a clean state:

**Before Tests (Setup)**:
```go
func TestMain(m *testing.M) {
    // SIGKILL target apps to ensure clean state
    exec.Command("pkill", "-9", "Calculator").Run()
    exec.Command("pkill", "-9", "TextEdit").Run()
    
    // ... start server ...
    
    code := m.Run()
    
    // ... cleanup ...
    os.Exit(code)
}
```

**After Tests (Cleanup)**:
```go
func TestSomething(t *testing.T) {
    // ... test setup ...
    
    t.Cleanup(func() {
        // DeleteApplication cleans up server-side state
        _, _ = client.DeleteApplication(ctx, &pb.DeleteApplicationRequest{
            Name: fmt.Sprintf("applications/%d", pid),
            Force: true,
        })
    })
    
    // ... test body ...
}
```

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

Key components:
- **Swift gRPC Server** (`Server/`): macOS Accessibility API integration
- **Go MCP Server** (`internal/`): MCP proxy with 77 tools
- **Proto Definitions** (`proto/`): API contracts following Google AIPs

## License

By contributing, you agree that your contributions will be licensed under the project's license.
