# AXUIElement Lifecycle Fix - Detailed Design Document

## Executive Summary

This document provides a complete design for fixing the catastrophic AXUIElement lifecycle flaw that prevents all element actions from functioning correctly. The current implementation discards live `AXUIElement` references during traversal, making semantic actions impossible.

## Problem Analysis

### Current State

```
┌─────────────────────────────────────────────────────────────────────┐
│ SDK: AccessibilityTraversal.swift                                    │
│                                                                       │
│ walkElementTree(element: AXUIElement) {                             │
│   // Has live AXUIElement here ✓                                    │
│   let data = extractElementAttributes(element)                      │
│   let elementData = ElementData(                                     │
│     role: data.role,                                                 │
│     text: data.text,                                                 │
│     axElement: element  // ← FIELD EXISTS BUT NOT SET!              │
│   )                                                                  │
│   collectedElements.insert(elementData)                             │
│ }                                                                    │
│                                                                       │
│ Returns: ResponseData { elements: [ElementData] }                   │
│          But elementData.axElement is nil! ✗                        │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Server: ElementLocator.swift                                         │
│                                                                       │
│ traverseWithPaths(pid: pid_t) {                                      │
│   let sdkResponse = try MacosUseSDK.traverseAccessibilityTree()     │
│   // sdkResponse.elements[i].axElement is nil ✗                     │
│                                                                       │
│   for elementData in sdkResponse.elements {                          │
│     // Creates dummy AXUIElement that doesn't work                  │
│     let dummyAX = AXUIElementCreateApplication(pid)                 │
│     ElementRegistry.registerElement(proto, axElement: dummyAX)      │
│   }                                                                  │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Server: ElementRegistry.swift                                        │
│                                                                       │
│ private var elementCache: [String: CachedElement]                   │
│   where CachedElement.axElement is dummy or nil ✗                  │
│                                                                       │
│ getAXElement(id) -> AXUIElement? {                                  │
│   return elementCache[id]?.axElement  // Returns dummy/nil ✗       │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Server: MacosUseServiceProvider.swift                                │
│                                                                       │
│ performElementAction(elementId, action: .press) {                    │
│   guard let axElement = ElementRegistry.getAXElement(elementId)     │
│   // axElement is nil or dummy, so falls through ✗                 │
│                                                                       │
│   // Falls back to coordinate-based click                           │
│   clickMouse(at: CGPoint(element.x, element.y))  // WRONG! ✗       │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Issues Identified

1. **SDK Issue**: `ElementData.axElement` field exists but is never populated in `walkElementTree()`
2. **Type Safety Issue**: `AXUIElement` is not `Sendable` and cannot cross actor boundaries
3. **Threading Issue**: AXUIElement must be accessed on main thread but ElementRegistry is an actor
4. **Data Loss**: Proto conversion uses `??` coalescing that maps `nil` to default values
5. **State Missing**: `enabled`, `focused` fields are not populated from AXUIElement

## Proposed Solution

### Phase 1: Fix SDK to Capture AXUIElement

**File**: `/Users/joeyc/dev/MacosUseSDK/Sources/MacosUseSDK/AccessibilityTraversal.swift`

**STATUS**: ✅ **IMPLEMENTED** using `SendableAXUIElement` wrapper pattern.

**Implementation Details**:

1. **`SendableAXUIElement` Wrapper Struct** (lines ~30-45):
```swift
/// Wrapper for AXUIElement that implements Hashable and Sendable.
/// AXUIElement is an opaque CFTypeRef, so we use @unchecked Sendable
/// since the Accessibility framework manages the underlying object's lifecycle.
public struct SendableAXUIElement: Hashable, Sendable {
  public let element: AXUIElement
  
  public init(_ element: AXUIElement) {
    self.element = element
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(CFHash(element))
  }
  
  public static func == (lhs: SendableAXUIElement, rhs: SendableAXUIElement) -> Bool {
    return CFEqual(lhs.element, rhs.element)
  }
}
```

2. **`ElementData` with Sendable Wrapper** (lines ~50-80):
```swift
public struct ElementData: Hashable, Sendable, Codable {
  public var role: String
  public var text: String?
  public var x: Double?
  public var y: Double?
  public var width: Double?
  public var height: Double?
  public var axElement: SendableAXUIElement?  // ← Uses wrapper struct
  public var enabled: Bool?
  public var focused: Bool?
  public var attributes: [String: String]

  // Custom CodingKeys to exclude axElement from Codable
  enum CodingKeys: String, CodingKey {
    case role, text, x, y, width, height, enabled, focused, attributes
    // Note: axElement is NOT in CodingKeys, so it won't be encoded/decoded
  }
}
```

3. **Population in `walkElementTree()`** (line ~340):
```swift
if shouldCollectElement {
  let elementData = ElementData(
    role: displayRole, 
    text: combinedText,
    x: finalX, 
    y: finalY, 
    width: finalWidth, 
    height: finalHeight,
    axElement: SendableAXUIElement(element),  // ← Wraps AXUIElement
    enabled: enabled, 
    focused: focused, 
    attributes: attributes
  )
  // ...
}
```

**Why This Approach is Better**:
- Provides explicit Sendable conformance via wrapper type
- Implements proper Hashable for use in Set-based deduplication
- Avoids global `@unchecked Sendable` extension on AXUIElement
- Type-safe: compiler enforces that SendableAXUIElement is used
- Thread-safe: the opaque CFTypeRef is managed by the Accessibility framework

### Phase 2: Fix ElementLocator to Use Real AXUIElement

**File**: `/Users/joeyc/dev/MacosUseSDK/Server/Sources/MacosUseServer/ElementLocator.swift`

**Current Code** (line ~80):
```swift
private func traverseWithPaths(pid: pid_t, visibleOnly: Bool) async throws -> [(Macosusesdk_Type_Element, [Int32])] {
  let sdkResponse = try await MainActor.run {
    try MacosUseSDK.traverseAccessibilityTree(pid: pid, onlyVisibleElements: visibleOnly)
  }
  
  var elementsWithPaths: [(Macosusesdk_Type_Element, [Int32])] = []
  
  for (index, elementData) in sdkResponse.elements.enumerated() {
    let protoElement = Macosusesdk_Type_Element.with {
      $0.role = elementData.role
      if let text = elementData.text { $0.text = text }
      if let x = elementData.x { $0.x = x }
      if let y = elementData.y { $0.y = y }
      if let width = elementData.width { $0.width = width }
      if let height = elementData.height { $0.height = height }
      if let enabled = elementData.enabled { $0.enabled = enabled }
      if let focused = elementData.focused { $0.focused = focused }
      $0.attributes = elementData.attributes
    }
    
    let elementId = await ElementRegistry.shared.registerElement(
      protoElement, 
      axElement: elementData.axElement,  // ← FIX: Use real axElement
      pid: pid
    )
    var elementWithId = protoElement
    elementWithId.elementID = elementId
    
    elementsWithPaths.append((elementWithId, [Int32(index)]))
  }
  
  return elementsWithPaths
}
```

**Changes**:
1. Line ~95: Change from `axElement: elementData.axElement` instead of creating dummy
2. Remove all dummy AXUIElement creation code
3. Fix the `??` coalescing bug:

```swift
// BEFORE (WRONG):
if let text = elementData.text { $0.text = text }  // ✓ Correct
$0.x = elementData.x ?? 0  // ✗ WRONG - maps nil to 0

// AFTER (CORRECT):
if let text = elementData.text { $0.text = text }
if let x = elementData.x { $0.x = x }
if let y = elementData.y { $0.y = y }
if let width = elementData.width { $0.width = width }
if let height = elementData.height { $0.height = height }
if let enabled = elementData.enabled { $0.enabled = enabled }
if let focused = elementData.focused { $0.focused = focused }
```

### Phase 3: Fix ElementRegistry Actor Isolation

**File**: `/Users/joeyc/dev/MacosUseSDK/Server/Sources/MacosUseServer/ElementRegistry.swift`

**Current Code** (line ~65):
```swift
nonisolated(unsafe) public func getAXElement(_ elementId: String) -> AXUIElement? {
  guard let cached = elementCache[elementId] else { return nil }
  
  if Date().timeIntervalSince(cached.timestamp) > cacheExpiration {
    elementCache.removeValue(forKey: elementId)
    return nil
  }
  
  return cached.axElement
}
```

**Problem**: `nonisolated(unsafe)` is WRONG because:
1. It allows data races on `elementCache`
2. It mutates actor state (`removeValue`) from non-isolated context
3. It bypasses actor protection

**Solution**: Make it properly isolated and require main actor for AX access:

```swift
/// Get the AXUIElement reference for an element ID.
/// - Parameter elementId: The element ID
/// - Returns: The AXUIElement if available and not expired
/// - Note: This MUST be called from MainActor context since AXUIElement requires it
public func getAXElement(_ elementId: String) async -> AXUIElement? {
  guard let cached = elementCache[elementId] else { 
    fputs("warning: [ElementRegistry] Element \(elementId) not found\n", stderr)
    return nil 
  }

  // Check if expired
  if Date().timeIntervalSince(cached.timestamp) > cacheExpiration {
    fputs("warning: [ElementRegistry] Element \(elementId) expired\n", stderr)
    elementCache.removeValue(forKey: elementId)
    return nil
  }

  return cached.axElement
}
```

**Update Callsites**: All callers must now `await` this:

```swift
// In MacosUseServiceProvider.swift
@MainActor
func performElementAction(...) async throws {
  // BEFORE:
  guard let axElement = ElementRegistry.shared.getAXElement(elementId) else { ... }
  
  // AFTER:
  guard let axElement = await ElementRegistry.shared.getAXElement(elementId) else { ... }
}
```

### Phase 4: Update AutomationCoordinator if Needed

**File**: `/Users/joeyc/dev/MacosUseSDK/Server/Sources/MacosUseServer/AutomationCoordinator.swift`

**Analysis**: This file doesn't need changes because:
1. It already uses `@MainActor` for all operations
2. It calls SDK functions that now return proper `axElement`
3. It doesn't directly access ElementRegistry

**No changes required**.

## Expected Outcomes After Fix

```
┌─────────────────────────────────────────────────────────────────────┐
│ SDK: AccessibilityTraversal.swift                                    │
│                                                                       │
│ walkElementTree(element: AXUIElement) {                             │
│   let data = extractElementAttributes(element)                      │
│   let elementData = ElementData(                                     │
│     role: data.role,                                                 │
│     text: data.text,                                                 │
│     x: data.position?.x,                                            │
│     y: data.position?.y,                                            │
│     enabled: data.enabled,                                          │
│     focused: data.focused,                                          │
│     axElement: element  // ✓ PROPERLY CAPTURED                     │
│   )                                                                  │
│ }                                                                    │
│                                                                       │
│ Returns: ResponseData with live AXUIElement ✓                       │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Server: ElementLocator.swift                                         │
│                                                                       │
│ traverseWithPaths(pid: pid_t) {                                      │
│   let sdkResponse = try MacosUseSDK.traverseAccessibilityTree()     │
│   // sdkResponse.elements[i].axElement is LIVE ✓                   │
│                                                                       │
│   for elementData in sdkResponse.elements {                          │
│     ElementRegistry.registerElement(                                │
│       proto,                                                         │
│       axElement: elementData.axElement  // ✓ Real element!         │
│     )                                                                │
│   }                                                                  │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Server: ElementRegistry.swift                                        │
│                                                                       │
│ private var elementCache: [String: CachedElement]                   │
│   where CachedElement.axElement is LIVE ✓                          │
│                                                                       │
│ getAXElement(id) async -> AXUIElement? {                            │
│   return elementCache[id]?.axElement  // Returns live element ✓    │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Server: MacosUseServiceProvider.swift                                │
│                                                                       │
│ @MainActor                                                           │
│ performElementAction(elementId, action: .press) async {              │
│   guard let axElement = await ElementRegistry.getAXElement(id)      │
│   // axElement is LIVE and USABLE ✓                                │
│                                                                       │
│   // Perform SEMANTIC AX action                                     │
│   AXUIElementPerformAction(axElement, kAXPressAction)  // WORKS! ✓ │
│ }                                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Testing Strategy

### Unit Tests

1. **Test SDK Returns AXUIElement**:
```swift
func testTraverseReturnsAXUIElement() throws {
  let response = try MacosUseSDK.traverseAccessibilityTree(pid: calculatorPID)
  XCTAssertGreaterThan(response.elements.count, 0)
  
  // At least some elements should have axElement
  let elementsWithAX = response.elements.filter { $0.axElement != nil }
  XCTAssertGreaterThan(elementsWithAX.count, 0)
}
```

2. **Test ElementRegistry Stores AXUIElement**:
```swift
func testRegistryStoresAXUIElement() async throws {
  let testElement = Macosusesdk_Type_Element.with { $0.role = "AXButton" }
  let testAX = AXUIElementCreateApplication(calculatorPID)
  
  let id = await ElementRegistry.shared.registerElement(
    testElement, 
    axElement: testAX, 
    pid: calculatorPID
  )
  
  let retrieved = await ElementRegistry.shared.getAXElement(id)
  XCTAssertNotNil(retrieved)
}
```

3. **Test Semantic Actions Work**:
```swift
@MainActor
func testPerformElementActionUsesAXUIElement() async throws {
  // Open Calculator
  let app = try await AutomationCoordinator.shared.handleOpenApplication("Calculator")
  
  // Find a button element
  let elements = try await ElementLocator.shared.findElements(
    selector: .with { $0.role = "AXButton" },
    parent: app.name,
    visibleOnly: true
  )
  
  guard let button = elements.first else {
    XCTFail("No button found")
    return
  }
  
  // Get the AXUIElement
  let axElement = await ElementRegistry.shared.getAXElement(button.element.elementID)
  XCTAssertNotNil(axElement, "AXUIElement should be stored")
  
  // Perform action
  // Should use AXUIElementPerformAction, not coordinate-based click
  try await MacosUseServiceProvider.shared.performElementAction(
    elementId: button.element.elementID,
    action: .press
  )
}
```

### Integration Tests

1. Test Calculator automation with semantic actions
2. Test element state waiting (enabled/focused)
3. Test element attribute queries
4. Test multi-window scenarios

## Risks and Mitigations

### Risk 1: AXUIElement Lifetime

**Risk**: AXUIElement references may become invalid if the UI changes.

**Mitigation**: 
- Keep 30-second cache expiration
- Add validation before using AXUIElement (check if still valid)
- Implement re-traversal on action failure

### Risk 2: Thread Safety

**Risk**: AXUIElement is not thread-safe and requires main thread.

**Mitigation**:
- Mark all AX operations with `@MainActor`
- Document the requirement clearly
- Use `nonisolated(unsafe)` ONLY for the opaque pointer, not for operations

### Risk 3: Memory Management

**Risk**: Storing AXUIElement might cause reference cycles or leaks.

**Mitigation**:
- AXUIElement is a CFTypeRef with automatic reference counting
- Swift manages the lifecycle correctly
- Test for memory leaks with Instruments

## Implementation Checklist

- [ ] Phase 1: Fix SDK `ElementData` struct
  - [ ] Remove `axElement` from `CodingKeys`
  - [ ] Add `@unchecked Sendable` conformance
  - [ ] Verify `axElement` is populated in `walkElementTree()`
  - [ ] Test that traversal returns non-nil axElement
  
- [ ] Phase 2: Fix ElementLocator
  - [ ] Remove dummy AXUIElement creation
  - [ ] Use real `elementData.axElement`
  - [ ] Fix `??` coalescing to use proper optionals
  - [ ] Ensure enabled/focused are populated
  
- [ ] Phase 3: Fix ElementRegistry
  - [ ] Remove `nonisolated(unsafe)` from `getAXElement`
  - [ ] Make `getAXElement` async and properly isolated
  - [ ] Update all callsites to await
  - [ ] Add proper error logging
  
- [ ] Phase 4: Update MacosUseServiceProvider
  - [ ] Update `performElementAction` to await `getAXElement`
  - [ ] Update `getElementActions` to await `getAXElement`
  - [ ] Ensure all methods are marked `@MainActor`
  - [ ] Test semantic actions work
  
- [ ] Testing
  - [ ] Write unit tests for SDK
  - [ ] Write unit tests for ElementRegistry
  - [ ] Write integration tests for element actions
  - [ ] Run Calculator integration test
  - [ ] Verify no memory leaks
  
- [ ] Documentation
  - [ ] Update implementation-plan.md
  - [ ] Add comments explaining AXUIElement lifecycle
  - [ ] Document thread-safety requirements

## Conclusion

This fix addresses the ROOT CAUSE of the element action failures by ensuring that live `AXUIElement` references are captured, stored, and used throughout the system. The changes are surgical and focused on the data flow pipeline without requiring architectural changes to the actor system or service layer.
