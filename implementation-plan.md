**This is `./implementation-plan.md`. KEEP THE PLAN UP TO DATE AS YOU EVOLVE THE CODE. DEVIATIONS TO THE PLAN MUST BE LOGGED WITHIN THE PLAN. THE PLAN MUST BE REASSESSED HOLISTICALLY AFTER ANY CHANGE OF ANY SIZE.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**!! MANDATORY OPERATIONAL DIRECTIVE !!**
**The use of subagents via the `runSubagent` tool is MANDATORY for the execution of the tasks below. Tasks are grouped specifically to be run in distinct subagent contexts to prevent context window exhaustion. Do not attempt to solve all groups in a single turn.**

---

# Implementation Plan: MacosUseSDK gRPC Service

---

**STATUS SECTION (ACTION-FOCUSED)**

### **Current Reality**

**CRITICAL DEFECTS (Immediate Action Required):**
1. The only known defects are identified by `./FIX_ME_THEN_DELETE_THIS_DOC.md` (READ THE ACTUAL DOC, N.B. asyncMap already dealt with)

---

### **Work Queue (Grouped for Subagents)**

**GROUP B: Critical Consolidation & Correctness (Target: `InputController.swift`, `WindowQuery.swift`, `WindowRegistry.swift`)**
* **Subagent Objective:** Resolve the "Split-Brain" race condition and blocking I/O issues.
* [ ] **Async Input Controller (Liveness):**
    * Convert `InputController` methods to `async/await`.
    * Remove `usleep` and replace with `Task.sleep`.
    * Update `AutomationCoordinator` to await these calls.
* [X] **Window Authority Primitives (Race Condition Fix):**  **COMPLETE - 2025-11-22**
    * Modified SDK `WindowQuery.swift` `WindowInfo` struct to include `element: AXUIElement` field.
    * Refactored Server `WindowHelpers.swift` `findWindowElement()` to use SDK's `fetchAXWindowInfo` primitive with batched IPC.
    * Eliminated Server's manual 2N IPC iteration loop in favor of SDK's optimized 1N batched approach.
    * Fixed race condition by removing strict 2px tolerance and accepting best heuristic match during rapid mutations.
    * **Evidence:** `integration/window_metadata_test.go` now passes all mutation operations (MoveWindow → ResizeWindow → MinimizeWindow → RestoreWindow) without "AXUIElement not found" errors.

---

## **Phase 4: Testing Strategy**

### **4.1 Unit Tests**
- **Requirement:** Every fix must have accompanying unit test verification.
- **Strictness:** `integration/observation_test.go` must remain an EFFECTIVE test of the logic it covers.

### **4.2 Test Harness**
- **Golden Apps:** `TextEdit`, `Calculator`, `Finder`.
- **Lifecycle:** Tests must clean up resources (DeleteApplication) aggressively.
  - TODO: This needs to be expanded to RELIABLY include hung API servers.

### **Correctness & Verification Guarantees**
1.  **State-Difference Assertions:** Mutator RPCs must be followed by Accessor RPCs to verify delta.
2.  **PollUntil Pattern:** No `time.Sleep()`. Use polling with timeouts.

---
**END OF IMPLEMENTATION PLAN**
(To provide an update, return to the "STATUS SECTION" at the top of this document.)

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**
