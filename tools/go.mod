module github.com/joeycumines/MacosUseSDK/tools

go 1.23

require github.com/googleapis/api-linter v1.67.7

// This module is separate from the main module to avoid dependency conflicts
// between api-linter and the generated gRPC stubs
