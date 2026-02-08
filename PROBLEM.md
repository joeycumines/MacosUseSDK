## Directive: Holistic Redesign of the Observation Mechanism

### The Problem

A **cycle of activation** was triggered within the observation/traversal system. The core issue stems from the interaction between:

1. **Accessibility traversal** (
    
    AccessibilityTraversal.swift lines 244-254) — automatically calls 
    
    ```
    app.activate()
    ```
    
     when the target app is not already active
2. **Observation monitoring** (
    
    ObservationManager.swift) — polls the accessibility tree at regular intervals
3. **Change detection** (
    
    ChangeDetector.swift) — listens for 
    
    ```
    didActivateApplicationNotification
    ```
    
     and 
    
    ```
    didDeactivateApplicationNotification
    ```
    

### The Activation Cycle Footgun

┌─────────────────────────────────────────────────────────────────────────┐

│  OBSERVATION monitors App A                                              │

│       ↓                                                                  │

│  Traversal runs → calls app.activate() to get fresh AX data            │

│       ↓                                                                  │

│  macOS switches focus to App A                                          │

│       ↓                                                                  │

│  ChangeDetector receives didActivateApplicationNotification             │

│       ↓                                                                  │

│  Events stream back → triggers additional processing                    │

│       ↓                                                                  │

│  Original app (e.g., the agent's terminal) becomes inactive            │

│       ↓                                                                  │

│  didDeactivateApplicationNotification fires                             │

│       ↓                                                                  │

│  User's context is disrupted; infinite loop if re-observing            │

└─────────────────────────────────────────────────────────────────────────┘

**This is a footgun** because:

- The SDK silently steals focus from the user/agent
- Observation creates a side effect (activation) that may trigger _more_ observations
- Only **ONE app can be active at a time** — observing multiple apps via polling would cause focus thrashing

### Constraints

|Must Preserve|Must Eliminate|
|---|---|
|Ability to get accurate/fresh AX data|Implicit focus stealing|
|Observation of multiple apps concurrently|Activation cycles|
|Background monitoring capability|User-disruptive side effects|

### Investigation Plan

1. **Audit all** 
    
    **`activate()`**
    
     **call sites**
    
    - ```
        AccessibilityTraversal.swift:248
        ```
        
         — primary culprit
    - Any other transitive calls
2. **Determine if activation is _truly_ required for fresh AX data**
    
    - Test hypothesis: "AX data is stale for background apps"
    - Measure AX attribute freshness with/without activation
    - If required, find the _minimal_ activation strategy (e.g., activate only once at observation start, not every poll)
3. **Design alternative approaches**
    
    - **Option A: Opt-in activation** — add a 
        
        ```
        shouldActivate: bool
        ```
        
         parameter, default 
        
        ```
        false
        ```
        
    - **Option B: Activation-free mode** — annotate observations with a "passive" mode that never activates
    - **Option C: Coordination layer** — if activation is needed, use a coordinator that prevents thrashing (e.g., rate limiting, queuing, or exclusive mode)
4. **Update the observation flow**
    
    - Break the feedback loop between 
        
        ```
        ChangeDetector
        ```
        
        's activation notifications and 
        
        ```
        ObservationManager
        ```
        
        's polling
    - Consider whether observations should _ignore_ activation events caused by the SDK itself (self-heal the cycle)
5. **Add safeguards**
    
    - Circuit breaker if activation/deactivation events exceed a threshold per second
    - Logging/warnings when activation is about to occur

### Deliverables

- [ ]  Root cause analysis document with test results
- [ ]  Design proposal for redesigned observation mechanism
- [ ]  Implementation with backward-compatible API changes
- [ ]  Integration tests validating no focus stealing during observation
- [ ]  Documentation update explaining passive vs active observation modes

### Priority

**HIGH** — this is a usability and correctness issue. An agent using this SDK should _never_ unexpectedly lose focus, nor should observation cause cascading side effects in the system under test.
