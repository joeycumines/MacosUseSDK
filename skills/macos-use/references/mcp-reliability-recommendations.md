# MacosUseSDK Reliability Notes

Empirically derived notes on the MCP server's input, discovery, and runtime behavior.
Items marked **Implemented** describe current server behavior; items marked **Empirical Finding**
record real-world integration behaviors across different application frameworks.

---

## 1. `click_element` Clicks the Center of the Element — **Implemented**

`click_element` clicks the geometric center of the element's bounds,
calculated from the AX frame, and returns an error for elements without
usable bounds rather than clicking at `(0, 0)`.

## 2. Focus Acquisition Before Click — **Implemented**

`click_element` automatically acquires focus for the target element's
window before clicking. Focus acquisition failures are not silently
tolerated: if the window cannot be activated or focused, the call fails
with an explicit error instead of clicking an unfocused target.

## 3. DevTools Console Input Reliability — **Partially addressed**

Typing into the WebKit Web Inspector console prompt via physical `type` is
unreliable — the typed text can go to the wrong application. Two mitigations
exist:

- `type_element` with `input_method="keystrokes"` sends physical keyboard
  events for web/Electron DOM-event compatibility (the console prompt is an
  `AXTextArea` in a web view).
- When the console is unreachable, prefer reading existing console output
  via `find_elements` (`AXStaticText` elements) instead of typing.

## 4. `find_elements` Staleness Mitigation — **Implemented**

`find_elements` accepts `force_refresh=true`, which discards the server's
cached AX data and re-walks the tree before returning results. Default is
`force_refresh=false`. After interactions that modify element state, use
`force_refresh=true` or `read_element` on the specific element for a fresh
read.

## 5. Element Bounds Accuracy for Clickable Area — **Open proposal**

The AX frame represents visual bounds, which may include padding. Clicking
the geometric center is usually within the clickable area, but for
non-interactive elements (`AXStaticText` used as labels), the clickable
area may be the associated control.

---

## 6. Java / Swing / JetBrains Runtime (JBR) Accessibility Disabled — **Empirical Finding**

Java Swing applications running on the JetBrains Runtime (GoLand, IntelliJ,
PyCharm, WebStorm) disable the Java Accessibility Bridge (JAB) by default to
reduce runtime overhead:

- Probing the application element returns `kAXErrorAPIDisabled (-25211)`.
- Inspecting window attributes returns `kAXErrorCannotComplete (-25202)`.

**Mitigations:**
1. **User Setting:** Enable **GoLand → Settings → Appearance & Behavior →
   Appearance → Accessibility → "Support screen readers"** and restart the IDE.
2. **Visual Grounding Fallback:** When AX is disabled, capture a window
   screenshot via `screenshot(window=window)` and compute global coordinates:
   $$\text{target\_x} = \text{window.x} + \text{local\_x}$$
   $$\text{target\_y} = \text{window.y} + \text{local\_y}$$
   Drive the IDE using `double_click`, `click`, `type`, and `keypress`.

## 7. Dynamic DOM Handle Invalidation in Web & Electron Apps — **Empirical Finding**

In web browsers (Chrome, Safari, Firefox) and Electron applications (Slack,
VS Code), DOM redraws and dynamic updates invalidate element handles
(`elem_<timestamp>_<id>`) rapidly.

**Mitigations:**
- Avoid conversational turns between `find_elements` and `click_element`.
- If an element handle reports `Element ... is no longer available` or is not attached
  to an AX window, call `find_elements(force_refresh=true)` on the current parent and
  use the fresh actionable handle immediately. If that also fails, re-list/focus the
  exact process/window and rediscover before using coordinates.
- When a fresh `read_element` provides usable bounds, record the center coordinates:
  $$\text{center\_x} = \text{bounds.x} + \frac{\text{bounds.width}}{2}$$
  $$\text{center\_y} = \text{bounds.y} + \frac{\text{bounds.height}}{2}$$
  Coordinate clicks on the geometric center via `click(target=window, x, y)`
  are immune to snapshot handle invalidation, but only use them after confirming that
  the target window is visible on the active Space.

## 8. Selector Ambiguity (`FailedPrecondition`) — **Empirical Finding**

Calling `click_element(parent, selector="text:X")` fails with
`FailedPrecondition - Selector matched multiple elements` if the text
appears in multiple elements (e.g. an `AXGroup`, `AXHeading`, and `AXLink`
in Reddit/social feeds).

**Mitigations:**
- Do not retry the exact same ambiguous selector.
- Use `find_elements` with that text to inspect all matching handles.
- Select the actionable interactable element (`role:AXLink` or `role:AXButton`)
  and call `click_element(parent, element=handle)` or click its center coordinates.

## 9. Chrome Cold Launch Profile Picker — **Empirical Finding**

Launching Google Chrome via `open_app(bundle)` on systems with multiple user
profiles initially opens a "Google Chrome" window displaying the Profile Picker
(`Open Person 1 profile`, `Guest mode`, `Add`).

**Mitigation:**
- Check for `Open Person 1 profile` or similar profile buttons in the AX tree.
- Click the profile button to transition to the main browser window before
  attempting URL navigation or tab manipulation.

## 10. Multi-Monitor Coordinate System Realities — **Empirical Finding**

macOS displays are arranged in a global coordinate space where origin `(0, 0)`
is the top-left corner of the primary display:
- Secondary monitors to the left or above the main display have **negative coordinates**
  (e.g., origin `(-1801, -1692)`).
- Input coordinates passed to `click`, `move`, `scroll`, and `drag` are interpreted
  in Global Display Coordinates.
- Window coordinates returned by `list_windows` and `screenshot` already reside in
  this same coordinate space, allowing direct linear addition:
  $$\text{global} = \text{window origin} + \text{window-relative pixel offset}$$

## 11. Installed Bundle Resource Rejection — **Empirical Finding**

On some server/runtime combinations, `open_app` can reject the exact
`applicationBundles/{id}` resource returned by `list_apps(kind="installed")` with an
invalid, non-canonical-resource, or `Application bundle not found` error. Treat this as
a resource/cache mismatch, not as permission to edit the opaque ID.

**Mitigation:**

1. Refresh `list_apps(kind="running")`.
2. If the target is still absent, use MCP `run(type="applescript", command=...)` with
   an identity-bound command such as `tell application id "<bundle-id>" to launch` and
   `tell application id "<bundle-id>" to activate`. Use the shell fallback only when
   the server explicitly enables it.
3. Poll fresh `list_apps(kind="running")` and `list_windows(app)` calls for a bounded
   number of attempts. Stop and report the launch error if no user-facing content window
   appears; do not loop indefinitely.
4. Resolve the process from descriptive window title plus AXWebArea/destination evidence
   or a screenshot. A nonzero window count alone does not identify the user-facing
   process; helpers and web-content processes remain candidates to reject.

## 12. Background Spaces and Multi-Process Apps — **Empirical Finding**

`list_windows` can return title-bar windows, helper windows, feed/popup windows, and
content windows on another Space. Negative global coordinates normally identify a
secondary-monitor placement and do not, by themselves, identify a background Space.
An otherwise valid window can still be inaccessible to pointer input from the active
Space.

**Mitigation:** use visibility/focus or AX-access evidence to distinguish Space access
from monitor placement. If the content window is inaccessible, activate the exact
running application process with `open_app(applications/{id})` or identity-bound
AppleScript `activate`; then re-enumerate windows, focus the accessible content window,
and rediscover AX elements. Do not call `focus_window` on the inaccessible background
window or reuse handles obtained before the transition.

## 13. Navigation Requires Two Signals — **Empirical Finding**

A matching page or tab label does not prove that navigation completed. Rows and buttons
can share text, canvas state can be invisible to AX, and the requested destination may
already be selected before the action.

**Mitigation:** capture a baseline, then verify two independent post-action signals, with
at least one proving a state change: for example, a changed selected-row/title/URL signal
plus destination-specific content or a before/after screenshot. If the baseline already
shows the requested destination selected, report that no navigation action was needed.
If neither signal changes or identifies the destination, report navigation as unverified.

---

## Priority & Impact Summary

| # | Item | Status | Impact |
|---|------|--------|--------|
| 1 | Click center by default | Implemented | Eliminates most click failures |
| 2 | Focus acquisition before click | Implemented | Eliminates focus-related failures |
| 3 | DevTools console input | Partially addressed | Enables reliable diagnostic workflows |
| 4 | `find_elements` staleness | Implemented | Reduces stale-data confusion |
| 5 | Clickable area inference | Open proposal | Reduces mis-clicks on labels |
| 6 | JetBrains / Swing AX disabled | Empirical Finding | Prevents infinite AX error loops |
| 7 | Dynamic DOM handle invalidation | Empirical Finding | Ensures robust web/Electron automation |
| 8 | Selector ambiguity handling | Empirical Finding | Prevents multi-match failure stalls |
| 9 | Chrome Profile Picker detection | Empirical Finding | Unblocks fresh browser automations |
| 10| Multi-monitor coordinate math | Empirical Finding | Eliminates pointer misses on secondary displays |
| 11| Installed bundle recovery | Empirical Finding | Recovers from launch-resource mismatches without inventing IDs |
| 12| Background Space/process selection | Empirical Finding | Avoids targeting helpers or inaccessible windows |
| 13| Two-signal navigation verification | Empirical Finding | Prevents false completion on matching labels |
