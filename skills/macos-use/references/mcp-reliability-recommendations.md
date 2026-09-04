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
- If an element handle reports `Element ... is no longer available`, call
  `read_element` immediately after discovery to record its center coordinates:
  $$\text{center\_x} = \text{bounds.x} + \frac{\text{bounds.width}}{2}$$
  $$\text{center\_y} = \text{bounds.y} + \frac{\text{bounds.height}}{2}$$
  Coordinate clicks on the geometric center via `click(target=window, x, y)`
  are immune to snapshot handle invalidation.

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
