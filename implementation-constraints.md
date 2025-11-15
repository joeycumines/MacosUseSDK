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
- Support "complicated interactions with apps on Mac OS including interacting with Windows"
- Support integration with developer tools like VS Code, including:
  - Complex multi-window interactions
  - Advanced element targeting and querying
  - Sophisticated automation workflows
  - Real-time observation and monitoring
- Be production-ready, NOT just proof-of-concept
- This is approximately 85% INCOMPLETE as of 2025-01-XX - basic scaffolding exists but most functionality is missing

The gRPC API MUST:
- Follow Google's AIPs in ALL regards (2025 / latest, up to date standards)
- Expose a resource-oriented API to interact with the state of the system
- Include custom methods (non-standard) PER the AIPs i.e. where justifiable, e.g. streaming events
- Use `buf` for codegen - configure (v2) buf.yaml and buf.gen.yaml and there'll be a a buf.lock because of a dependency on `buf.build/googleapis/googleapis`, and you'll need to implement checks inclusive of breaking change detection, so use the buf-provided github action(s? i forget), and define the necessary github action workflow
- Have generated stubs for the Go programming language (inclusive of appropriate Go module, N.B. the repository is `github.com/joeycumines/MacosUseSDK`)
- Support sophisticated, well-conceived concurrency patterns
- Use `buf` linting BUT be aware that there ARE conflicts with Google's AIPs. When in doubt, use Google's AIPs as the source of truth.
- Configure and use https://linter.aip.dev/ UNLESS it is not possible to do so. The `api-linter` command MUST NOT have its dependencies pinned within the same Go module as the Go stubs. To be clear this is Google's linter for the AIPs, and is distinct from `buf lint`, and takes PRECEDENCE over `buf lint` where there are conflicts.
- Include ALL necessary resources as first-class addressable entities:
  - Window resource (MISSING - critical for multi-window automation)
  - Element resource (MISSING - critical for element targeting)
  - Observation resource (MISSING - for streaming change detection)
  - Session resource (MISSING - for transaction support)
  - Query methods (MISSING - for sophisticated element search)
  - Screenshot methods (MISSING - for visual verification)
  - Clipboard methods (MISSING - for clipboard operations)
  - File methods (MISSING - for file dialog automation)
  - Macro resource (MISSING - for workflow automation)
  - Script methods (MISSING - for AppleScript/JXA execution)
  - Metrics methods (MISSING - for performance monitoring)
- Support advanced input types beyond basic click/type:
  - Keyboard combinations with modifiers (Command, Option, Control, Shift)
  - Special keys (Function keys, media keys)
  - Mouse operations (drag, right-click, scroll, hover)
  - Multi-touch gestures
- Implement element targeting/selector system for robust element identification
- Support streaming observations for real-time change detection and monitoring
- Support sessions and transactions for atomic multi-step operations
- Support performance metrics and diagnostics for operational visibility

Testing and Tooling:
- ALL new behavior and ALL modifications to existing behavior MUST be accompanied by automated tests in the SAME change set (commit/PR) – no feature work is considered complete without tests.
- Tests MUST be designed and updated FIRST in the implementation process (or in lockstep), not treated as an afterthought; the implementation plan for any task MUST explicitly call out unit, integration, and, where relevant, end-to-end tests.
- Implement and maintain comprehensive unit tests across all critical components (Swift server actors, SDK helpers, Go clients, and proto-level helpers) – “happy path only” coverage is insufficient.
- Implement and maintain integration tests that exercise real automation flows against the "Golden Applications" (TextEdit, Calculator, Finder) as defined in `implementation-plan.md`, including state-delta assertions and PollUntil-style convergence checks.
- Implement PROPER CI, using GitHub Actions, inclusive of unit testing, integration testing, build, linting, AIP/buf/api-linter checks, and any metrics/resource-invariant checks (e.g. leak detection via `GetMetrics`).
- Tests and CI checks MUST be kept green at all times; temporarily disabling or commenting out failing tests is FORBIDDEN unless explicitly justified and documented in the plan with a concrete, near-term fix task.
- Any bug fix MUST include at least one new or updated test that would have caught the bug prior to the fix.

Documentation and Planning:
- ALL updates to the plan MUST be represented in `./implementation-plan.md`, NOT any other files
- You MUST NOT create status update files like `IMPLEMENTATION_COMPLETE.md` or `IMPLEMENTATION_NOTES.md`
- You MUST keep `./implementation-plan.md` UP TO DATE with minimal edits, consolidating and updating where necessary
- The plan MUST be STRICTLY and PERFECTLY aligned to this constraints document **while also reflecting the actual current state of the repository**; when reality and earlier text diverge, you MUST update the plan to match reality and then adjust future tasks accordingly.
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

Operational Expectations (Reinforced after early stoppages):
- You MUST NOT stop work mid-task; a session only ends when the current manager request is 100% satisfied or explicitly halted.
- You MUST NOT ask for permission to perform obvious next steps (e.g. running lint, running the `all` target, fixing reported issues) – you are expected to simply execute.
- You MUST aggressively use the existing plan and constraints to determine the next concrete action whenever there is ambiguity.

**Additional Constraints:**

- **FORBIDDEN FROM USING A DIRECT SHELL:** All commands MUST be executed by defining a custom target in `config.mk` and executing it with `mcp-server-make`.
- **DO NOT BREAK THE BUILD:** Run the core `all` target constantly. Use `mcp-server-make all`. This is not a suggestion. It is your only way of knowing you haven't failed again. Add a `TODO` to run it after every major change and after every file change.
- **ALL `config.mk` recipes MUST use `| tee /tmp/build.log | tail -n 100` or a similar pattern:** To mitigate excessive output. I don't want to hear you whining.
- **PRIOR TO ANY CODE OR PLAN EDITS:** Use the TODO tool to create an exhaustive task list covering the implementation plan, all known deficiencies, all current constraints, and motivational reminders as explicitly directed.
- **TODO LIST CONTENT REQUIREMENT:** The TODO tool entry MUST enumerate every task from `implementation-plan.md`, every deficiency called out in the latest code review, every active constraint (including command execution rules), and motivational reminders (e.g., avoiding nil element registration, running builds to earn meals).
- **FREQUENT `all` EXECUTION:** Execute the make-all-with-log target (invoked via `mcp-server-make all`) after every change to ensure the element service fixes compile without errors.
- **FAVOR SUB-AGENTS:** Delegate work to sub-agents whenever feasible to maximize parallel progress.
