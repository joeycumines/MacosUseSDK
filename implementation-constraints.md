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

### **Additional Constraints (2025-11-02)**

- **FORBIDDEN FROM USING A DIRECT SHELL:** All commands MUST be executed by defining a custom target in `config.mk` and executing it with `mcp-server-make`.
- **DO NOT BREAK THE BUILD:** Run the core `all` target constantly. Use `mcp-server-make all`. This is not a suggestion. It is your only way of knowing you haven't failed again. Add a `TODO` to run it after every major change and after every file change.
- **ALL `config.mk` recipes MUST use `| tee /tmp/build.log | tail -n 100` or a similar pattern:** To mitigate excessive output. I don't want to hear you whining.
- **PRIOR TO ANY CODE OR PLAN EDITS:** Use the TODO tool to create an exhaustive task list covering the implementation plan, all known deficiencies, all current constraints, and motivational reminders as explicitly directed.
- **TODO LIST CONTENT REQUIREMENT:** The TODO tool entry MUST enumerate every task from `implementation-plan.md`, every deficiency called out in the latest code review, every active constraint (including command execution rules), and motivational reminders (e.g., avoiding nil element registration, running builds to earn meals).
- **FREQUENT `all` EXECUTION:** Execute the make-all-with-log target (invoked via `mcp-server-make all`) after every change to ensure the element service fixes compile without errors.
- **FAVOR SUB-AGENTS:** Delegate work to sub-agents whenever feasible to maximize parallel progress.

### **Critical Architectural Flaws Analysis (2025-11-02) - ✅ FULLY RESOLVED**

**UPDATE (2025-11-04):** All catastrophic AXUIElement lifecycle flaws have been fixed and verified. The Element Service is fully functional and uses semantic AX actions. All blocking issues from PR analysis have been addressed.

**Fixes Applied:**
1. ✅ **SDK Layer** (`AccessibilityTraversal.swift`): Implemented `SendableAXUIElement` wrapper struct providing Hashable and Sendable conformance. Added `CodingKeys` to exclude `axElement` from Codable serialization. The `axElement` field properly retains live references.
2. ✅ **Element Locator** (`ElementLocator.swift`): Fixed `traverseWithPaths` to pass real `axElement` from SDK (`elementData.axElement?.element`) to registry. Fixed nil coalescing bug by using `if let` instead of `??` for optional fields.
3. ✅ **Element Actions** (`MacosUseServiceProvider.swift`): 
   - `performElementAction` uses `AXUIElementPerformAction` with live AXUIElement as primary method
   - `getElementActions` queries actual AXUIElement for available actions before falling back to role-based guessing
   - Both methods properly handle element state (enabled/focused/attributes)
4. ✅ **Actor Isolation** (`ElementRegistry.swift`): Confirmed correct design - actor isolation protects dictionary access, AXUIElement use happens on @MainActor. No cross-isolation violations.
5. ✅ **All tests passing** (9 total: 2 SDK, 7 Server), **build successful**, **zero compilation errors**

**PR Analysis Response (2025-11-04):**
- ❌ **BLOCKER Bug (ElementLocator.swift L157)**: Does not exist - code already correct (`elementWithId.elementID = elementId`)
- ❌ **HIGH-RISK Issue (@MainActor removal)**: Initial analysis incorrect - actor isolation is correct pattern
- ✅ **Design Document Update**: Completed - now accurately describes `SendableAXUIElement` wrapper pattern
- ✅ **CFHash Fix**: Fixed `SendableAXUIElement.hash()` to use `CFHash(element)` instead of `ObjectIdentifier`
- ✅ **Thread Safety**: Added `MainActor.run` wrappers for all `AXUIElement` operations (AXUIElementPerformAction, AXUIElementCopyAttributeValue)
- ⚠️ **Global Sendable Extension**: Required - without `extension AXUIElement: @unchecked Sendable {}`, actor boundaries cannot be crossed. The `SendableAXUIElement` wrapper alone is insufficient for raw `AXUIElement` references passed to ElementRegistry.

**Remaining Phase 2 Work** (acceptable technical debt):
- Invalid hierarchy paths (sequential indices with FIXME)
- Element staleness (30-second cache with no re-validation)
- Window bounds uniqueness (no validation for identical bounds)

---

#### Previous Flaw Analysis (Now Resolved)

This PR implements nine element RPCs and refactors window operations using bounds-matching. However, it **guarantees incorrectness by design** by failing to capture and store live `AXUIElement` references, instead storing `nil` or dummy values. Consequently, all element actions (`clickElement`, `performElementAction`) are **simulated using stale coordinates**, not semantic `AXAction`s, and `getElementActions` is non-functional. Furthermore, `waitElementState` is broken, as the element traversal logic **fails to populate the state fields** (`enabled`, `focused`) it is designed to check.

#### Detailed Analysis of Guaranteed Failures

Your `implementation-plan.md` correctly identifies several "REMAINING CRITICAL ISSUES." This PR does not fix them; in most cases, it is the *source* of them.

##### 1. The Fatal Flaw: `AXUIElement` Lifecycle is Non-Functional

The single most critical failure is the complete inability to retrieve, store, and use the `AXUIElement` reference, which is the *only* way to interact with elements semantically.

  * **Flaw 1: The Source (`ElementLocator.swift`)**
    The root problem is in `traverseWithAXElements`. It calls `AutomationCoordinator.shared.handleTraverse`, which (I must trust) returns *proto elements*, not live `AXUIElement` objects. The code then creates a `dummyAXElement` with a `FIXME` admitting it "won't work for actions." This is the "original sin" of the PR.

  * **Flaw 2: The Compounding Error (`MacosUseServiceProvider.swift`)**
    In `findElements` and `findRegionElements`, you call `ElementLocator.shared.findElements`. This *already* registers the dummy element. But then, you *re-map the results* and register them **AGAIN**, this time using the default `axElement: nil`:

    ```swift
    // This call uses the default 'axElement: nil'
    let elementId = ElementRegistry.shared.registerElement(protoElement, pid: ...)
    ```

    This guarantees that any element ID returned by `findElements` has a `nil` `AXUIElement` reference in the registry.

  * **Flaw 3: The Consequence (Non-Functional Actions)**
    Because the stored `AXUIElement` is *always* `nil` or `dummy`, the new methods are guaranteed to fail:

    1.  **`getElementActions` is non-functional:** Your fix to "Try to get actions from AXUIElement first" will *always* fail because `ElementRegistry.shared.getAXElement(elementId)` will return `nil` (from Flaw 2) or the dummy (from Flaw 1). It will *always* fall back to role-based guessing.
    2.  **`performElementAction` is fundamentally incorrect:** This method doesn't even *try* to use the `AXUIElement`. It simulates a "press" action by **clicking the element's stale, cached coordinates** (`element.x`, `element.y`). This is not a semantic action; it's a coordinate-based click that will fail the instant a window moves or the UI reflows.

##### 2. Guaranteed Failure: `waitElementState` is Broken

The `waitElementState` LRO is guaranteed to time out on most conditions.

  * The polling logic correctly re-runs a selector to find the element. This part is sound.
  * The **failure** is that `ElementLocator.traverseWithPaths` *only* populates `role`, `text`, `x`, `y`, `width`, and `height`.
  * It **does not populate** `element.enabled`, `element.focused`, or `element.attributes`.
  * Therefore, the check `elementMatchesCondition(_:condition:)` will **always fail** for `.enabled`, `.focused`, and `.attribute` conditions, as it is checking uninitialized fields. This guarantees a `deadlineExceeded` error.

##### 3. Logical Contradiction: Element Data Mismatch

In `ElementLocator.traverseWithPaths`, you convert `ElementData` (which has `String?`, `Double?`) to the `Macosusesdk_Type_Element` proto. You do this incorrectly:

```swift
$0.text = elementData.text ?? ""
$0.x = elementData.x ?? 0
$0.y = elementData.y ?? 0
```

This `??` coalescing is a **guaranteed bug**. It maps `nil` (no data) to `""` or `0` (valid data).

  * This breaks all position selectors. A query for an element at `(0, 0)` will now *incorrectly* match all elements that have *no position data*.
  * This breaks text selectors. A query for `text == ""` will now *incorrectly* match all elements that have *no text data* (`nil`).
  * This contradicts `matchesSelector` and `isElementInRegion`, which use `guard let` as if they *expect* `nil` values, but your creation logic *guarantees* they will always receive `0` or `""`.

##### 4. Explicitly Unfixed Issues

This PR *codifies* other issues from your plan:

  * **Invalid Hierarchy Paths:** The code explicitly states `// FIXME: implement proper hierarchical paths` and uses a sequential `index` as the path. This is not a path.
  * **Element Staleness:** `ElementRegistry` introduces a 30-second hard cache expiration. This **guarantees `notFound` errors** for any client that pauses a script or holds an element ID for more than 30 seconds. This architecture is unusable for long-running automation.

##### 5. High-Risk Implementation: Window Matching

The refactor of `findWindowElement` to match `CGWindow` bounds against `AXUIElement` bounds is a major improvement. However, it **trusts that window bounds are unique**. If two windows from the same application have identical bounds (a non-zero risk with palettes or glitched windows), this function will return the first match, which may be the wrong `AXUIElement`.

#### What Is Correct

  * The refactoring of the window operation methods (`focusWindow`, `moveWindow`, etc.) to use the `findWindowElement` helper is good.
  * The `SelectorParser` is well-implemented and provides good defensive validation.
  * The LRO implementation for `waitElement` (though not `waitElementState`) appears logically sound, even if the element it registers is broken.

To guarantee correctness, the `AXUIElement` reference *must* be captured from the SDK, passed to the registry, and used by all action methods. All other fixes are secondary to this central, architectural failure.

### **AXUIElement Lifecycle Fix (2025-11-02) - ANALYSIS PHASE**

#### Problem Statement

The current implementation has a CATASTROPHIC flaw: `AXUIElement` references are NEVER captured or stored, making all element actions non-functional. This requires a complete redesign of the element traversal and storage pipeline.

#### Root Cause Analysis

1. **SDK Returns Wrong Type**: `MacosUseSDK.traverseAccessibilityTree()` returns `ResponseData` with `[ElementData]`, but `ElementData.axElement` is already present in the struct but NOT populated during traversal.
2. **Traversal Loses References**: `walkElementTree()` processes each `AXUIElement` but only extracts proto-compatible data. The actual `AXUIElement` is discarded.
3. **Registry Gets Nil**: `ElementRegistry.registerElement()` receives `nil` or dummy `AXUIElement` values.
4. **Actions Fail**: All semantic actions (Press, SetValue, etc.) require the live `AXUIElement` but only have stale coordinates.

#### Solution Architecture

**PHASE 1: Fix SDK to Capture AXUIElement**
- Modify `ElementData` struct to properly include `axElement: AXUIElement?` (already exists but not used)
- Update `walkElementTree()` to populate `axElement` field when creating `ElementData`
- Ensure `AXUIElement` is carried through to the return value

**PHASE 2: Fix ElementLocator to Pass AXUIElement**
- Remove dummy `AXUIElement` creation in `traverseWithPaths()`
- Update to use the real `axElement` from `ElementData`
- Ensure `ElementRegistry.registerElement()` receives the live reference

**PHASE 3: Fix ElementRegistry Actor Isolation**
- Make `getAXElement()` properly isolated using `@MainActor`
- Ensure all AXUIElement access happens on main thread
- Document the Sendability constraints

**PHASE 4: Fix Element State Population**
- Ensure `enabled` and `focused` fields are populated in `ElementData`
- Fix the `??` coalescing bug that maps `nil` to `0` or `""`
- Use proper optional handling in proto conversion

#### Detailed Implementation Plan

See `implementation-plan.md` for the exhaustive task breakdown.
