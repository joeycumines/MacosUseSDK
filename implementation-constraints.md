Implement a FULLY-REALISED, production-ready, gRPC server, acting as an API layer around the SDK.

There MUST be a central control-loop acting as the coordinator for ALL inputs and making all logic decisions, functioning as an asynchronous means of processing commands and events (CQRS style, more or less). Obviously implement it in a pattern native to Swift. There will no doubt need to be a copy-on-write "view", used to expose ALL relevant state data, for direct queries of the state. There may need to be a "flush through" mechanism where the sequential nature of event processing is used to await processing of a command / effecting of a change, by publishing a command which has a side effect of notifying the waiting caller.

The gRPC server MUST:
- Use github.com/grpc/grpc-swift-2
- Support configuration via environment variables, e.g. listen unix socket file location, listen address (inclusive of port, or port and address split - depending on what is relevant input)
- Expose ALL BEHAVIOR AND FUNCTIONALITY implemented ANY OF the attached source files
- Integrate in a well-conceived scalable and maintainable manner with the aforementioned control loop
- Combine and extend on ALL the functionality demonstrated within ALL the "tools" that exist
- Support automating MULTIPLE windows at once
- Be performant
- Support use cases like automating actions, inclusive of identifying UI elements, reading text from UI elements, entering input into UI elements and interacting in arbitrary ways

The gRPC API MUST:
- Follow Google's AIPs in ALL regards (2025 / latest, up to date standards)
- Expose a resource-oriented API to interact with the state of the system
- Include custom methods (non-standard) PER the AIPs i.e. where justifiable, e.g. streaming events
- Use `buf` for codegen - configure (v2) buf.yaml and buf.gen.yaml and there'll be a a buf.lock because of a dependency on `buf.build/googleapis/googleapis`, and you'll need to implement checks inclusive of breaking change detection, so use the buf-provided github action(s? i forget), and define the necessary github action workflow
- Have generated stubs for the Go programming language (inclusive of appropriate Go module, N.B. the repository is `github.com/joeycumines/MacosUseSDK`)
- Support sophisticated, well-conceived concurrency patterns
- Use `buf` linting BUT be aware that there ARE conflicts with Google's AIPs. When in doubt, use Google's AIPs as the source of truth.
- Configure and use https://linter.aip.dev/ UNLESS it is not possible to do so. The `api-linter` command MUST NOT have its dependencies pinned within the same Go module as the Go stubs. To be clear this is Google's linter for the AIPs, and is distinct from `buf lint`, and takes PRECEDENCE over `buf lint` where there are conflicts.

Testing and Tooling:
- Implement comprehensive unit tests, at bare minimum
- Implement PROPER CI, using GitHub Actions, inclusive of unit testing, and build and linting and all relevant checks

IMPORTANT: You, the implementer, are expected to read and CONTINUALLY refine [implementation-plan.md](./implementation-plan.md).
