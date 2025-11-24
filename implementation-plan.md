**This is `./implementation-plan.md`. KEEP THE PLAN UP TO DATE AS YOU EVOLVE THE CODE. DEVIATIONS TO THE PLAN MUST BE LOGGED WITHIN THE PLAN. THE PLAN MUST BE REASSESSED HOLISTICALLY AFTER ANY CHANGE OF ANY SIZE.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**!! MANDATORY OPERATIONAL DIRECTIVE !!**
**The use of subagents via the `runSubagent` tool is MANDATORY for the execution of the tasks below. Tasks are grouped specifically to be run in distinct subagent contexts to prevent context window exhaustion. Do not attempt to solve all groups in a single turn.**

---

# Implementation Plan: MacosUseSDK gRPC Service

---

**STATUS SECTION (ACTION-FOCUSED)**

---

## **Phase 4: Testing Strategy**

### **4.1 Unit Tests**
- **Requirement:** Every fix must have accompanying unit test verification.
- **Strictness:** `integration/observation_test.go` must remain an EFFECTIVE test of the logic it covers.

### **4.2 Test Harness**
- **Golden Apps:** `TextEdit`, `Calculator`, `Finder`.
- **Lifecycle:** Tests must clean up resources (DeleteApplication) aggressively.

### **4.3 Swift SDK Visual Feedback Stability**
- **Status:** Completed.
- **Issue:** `DrawVisuals` overlay windows were either crashing (Signal 11) or failing to close.
- **Resolution:**
    - Replaced `Task.sleep` with `DispatchQueue.main.asyncAfter` to avoid reentrancy/state corruption issues.
    - Set `isReleasedWhenClosed = false` on `NSWindow` to allow safe manual lifecycle management.
    - Explicitly called `orderOut` and `close` in the async callback.
    - Verified with `test-swift-with-oslog` target.

### **Correctness & Verification Guarantees**
1.  **State-Difference Assertions:** Mutator RPCs must be followed by Accessor RPCs to verify delta.
2.  **PollUntil Pattern:** No `time.Sleep()`. Use polling with timeouts.

---
**END OF IMPLEMENTATION PLAN**
(To provide an update, return to the "STATUS SECTION" at the top of this document.)

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**

**ON TOOLS: Use `config.mk` to create custom targets, and `mcp-server-make` to run targets. ALWAYS use custom targets that *limit* the amount of output you receive. For example, piping through tail, with FEW lines output. Prior to tail, pipe to tee. The file ./build.log in the root of the project is gitignored, so use that. That way you can *search* the output. To be clear, timing dependent tests are BANNED. As are those that take too long to run. Testing retries, for example, MUST be done in a way that supports avoiding running afoul of those CRITICAL rules. Abide. OBEY.**
