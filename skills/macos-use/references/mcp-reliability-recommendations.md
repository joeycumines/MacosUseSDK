# MacosUseSDK Reliability Notes

Empirically derived notes on the MCP server's input and discovery behavior.
Items marked **Implemented** describe current server behavior; the remaining
items are open proposals. Load this file when investigating click/input
reliability issues.

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

An open proposal remains: expose programmatic evaluation (WebKit
`Runtime.evaluate`) directly instead of depending on AX focus at all.

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
area may be the associated control. Proposed (not implemented):

1. Check `kAXClickPointAttribute` when present and click there instead.
2. Otherwise click the geometric center and surface a warning that the
   element may not be interactive.

## Priority Ranking

| # | Item | Status | Impact |
|---|------|--------|--------|
| 1 | Click center by default | Implemented | Eliminates most click failures |
| 2 | Focus acquisition before click | Implemented | Eliminates focus-related failures |
| 3 | DevTools console input | Partially addressed | Enables reliable diagnostic workflows |
| 4 | find_elements staleness | Implemented | Reduces stale-data confusion |
| 5 | Clickable area inference | Open proposal | Reduces mis-clicks on labels |
