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

Documentation and Planning:
- ALL updates to the plan MUST be represented in `./implementation-plan.md`, NOT any other files
- You MUST NOT create status update files like `IMPLEMENTATION_COMPLETE.md` or `IMPLEMENTATION_NOTES.md`
- You MUST keep `./implementation-plan.md` UP TO DATE with minimal edits, consolidating and updating where necessary
- The plan MUST be STRICTLY and PERFECTLY aligned to this constraints document
- You MUST update `implementation-plan.md` as part of each set of changes, potentially multiple times per session

Proto API Structure:
- Proto files MUST be located at `proto/macosusesdk/v1/` (NOT `proto/v1/`) - the proto dir is the root of the proto path and MUST mirror the package structure
- Common components MUST be created under `proto/macosusesdk/type` where appropriate per https://google.aip.dev/213
- Resource definitions MUST be in their own .proto files separate from service definitions
- Method request/response messages MUST be co-located with the service definition
- File names MUST correctly align with service names per AIPs
- Files MUST include mandatory file options per AIPs
- MUST follow https://google.aip.dev/190 and https://google.aip.dev/191 for naming conventions
- Consolidate all services into a SINGLE service named `MacosUse`
- Document proto semantics in `proto/README.md`

Input Action Modeling:
- Model input actions as a timeline of inputs (actual collections): `applications/*/inputs/*`, `desktopInputs/*`, etc.
- Input resources MUST support Get and List standard methods per https://google.aip.dev/130, https://google.aip.dev/131, https://google.aip.dev/132
- Inputs which have been handled MUST have a circular buffer per target resource, applicable to COMPLETED actions

OpenApplication Method:
- MUST use a dedicated response type (not returning TargetApplication directly)
- MUST be a long-running operation using the `google.longrunning` API per https://google.aip.dev/151

Google API Linter:
- api-linter MUST be run using `go -C hack/google-api-linter run api-linter` from a dedicated Go module at `hack/google-api-linter/`
- MUST use `buf export` command to export the full (flattened) protopath for googleapis protos
- MUST use a tempdir to stage the proto files with proper cleanup hooks
- MUST configure api-linter with a config file located at `google-api-linter.yaml`
- MUST output in GitHub Actions format
- Logic MUST be encapsulated in a POSIX-compliant shell script at `./hack/google-api-linter.sh`
- The contents of `./google-api-linter.yaml` MUST be:
  ```yaml
  ---
  - included_paths:
      - 'google/**/*.proto'
    disabled_rules:
      - 'all'
  ```
- MUST NOT ignore linting for ANYTHING except googleapis protos (which are entirely ignored)
- ALL linting issues MUST be fixed

CI/CD Workflows:
- MUST use reusable workflow pattern with `workflow_call`
- Individual workflows (buf, api-linter, swift) MUST be callable as jobs in a single core CI workflow `ci.yaml`
- Individual workflows MUST NOT have push/pull_request triggers - those belong on `ci.yaml` only
- `ci.yaml` MUST have events: push or pull request to main, or workflow dispatch
- `ci.yaml` MUST have a final summary job with `if: always()` that runs after ALL other jobs
- MUST NOT auto-commit generated code - generate all required source locally and commit it
- MUST properly lock dependencies with `buf dep update`
- Scripts MUST handle ALL errors and MUST NOT assume the use of `set -e`
- MUST NOT use `set -e` - use chaining with `&&` or explicit if conditions with non-zero exit codes
- For multi-command scripts, typically use `set -x`

IMPORTANT: You, the implementer, are expected to read and CONTINUALLY refine [implementation-plan.md](./implementation-plan.md).
