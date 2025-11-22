# The Grand Unification of macOS Window Management: A Comprehensive Analysis of Quartz and Accessibility Architectures

## 1. Introduction: The Bifurcated Nature of the macOS Desktop

The development of window management utilities on macOS represents one of the most distinct and technically demanding challenges within the Apple software ecosystem. Unlike the X11 or Wayland display servers of the Linux world, or the Win32 API of Windows—both of which generally provide unified interfaces for querying and manipulating window state—macOS relies on a historically bifurcated architecture. This architecture separates the act of _perceiving_ the desktop from the act of _manipulating_ it, placing these capabilities into two completely distinct frameworks: **Quartz Window Services** (Core Graphics) and the **Accessibility API** (Application Services).

This separation is not merely a matter of header files or framework organization; it is a fundamental architectural boundary that reflects the operating system's security model, its history transitioning from Carbon to Cocoa, and its reliance on the Window Server as the ultimate arbiter of display reality.

For the systems engineer tasked with building a tiling window manager (like Yabai or Amethyst), a workflow automation tool (like Hammerspoon), or a window snapper (like Magnet), this bifurcation presents the "Extremely Difficult Problem": effectively bridging the high-fidelity, global, read-only view provided by Quartz with the process-specific, interaction-heavy, write-capable view provided by Accessibility.

The Quartz layer, accessed primarily through `CGWindowListCopyWindowInfo`, offers a "God’s Eye View" of the system. It sees everything: every pixel buffer, every shadow, every menu bar element, and every transparent overlay. It identifies these elements with a specialized integer, the `CGWindowID`. However, Quartz is immutable; it cannot move a window, resize it, or focus it.

Conversely, the Accessibility API, accessed via `AXUIElement`, treats the desktop not as a set of composited layers but as a semantic hierarchy of User Interface elements. It allows for granular control—moving windows, clicking buttons, and querying titles—but it operates through a heavy Inter-Process Communication (IPC) mechanism. Crucially, it identifies elements via `AXUIElementRef` tokens, not `CGWindowID`s.

There is no public API to convert a `CGWindowID` to an `AXUIElementRef`.

This report serves as an exhaustive reference and analysis of this problem space. It synthesizes scattered documentation, reverse-engineered findings from open-source projects, and undocumented private APIs to provide a unified theory of macOS window management. It explores the mathematical complexities of multi-monitor coordinate spaces, the opaque handling of virtual desktops (Spaces), and the increasingly restrictive security sandbox (TCC) that governs these interactions.

---

## 2. The Quartz Window Services Architecture

To understand the state of the desktop, one must first interrogate the Window Server. The Window Server is the daemon responsible for compositing applications' surfaces onto the physical displays. The interface to this daemon is **Quartz Window Services**, a C-based API within the Core Graphics framework.

### 2.1 The Source of Truth: `CGWindowListCopyWindowInfo`

The primary mechanism for state retrieval is the function `CGWindowListCopyWindowInfo`. This function is unique in that it does not query applications directly; rather, it queries the Window Server's internal display list. This makes it extremely robust against hung applications—if an app is frozen, Quartz can still report its window position instantly because that data is cached in the compositor.  

#### 2.1.1 Functional Analysis and Signature

The function signature, defined in `CGWindow.h`, reveals its procedural nature:

C

```
CFArrayRef CGWindowListCopyWindowInfo(
    CGWindowListOption option, 
    CGWindowID relativeToWindow
);
```

This function returns a `CFArray` of `CFDictionary` objects. It is essential to recognize that this return value is a **snapshot**. Unlike Cocoa’s `NSWindow` objects, which might update their properties via Key-Value Observing (KVO), the dictionaries returned by Quartz are static data structures. If a window moves one millisecond after this function returns, the data in the dictionary is stale. This necessitates a polling architecture for any application that needs to visualize window state in real-time, which introduces significant performance considerations discussed in later sections.

The `option` parameter allows the caller to filter the returned list. Common options include:

- `kCGWindowListOptionAll`: Returns all windows, including off-screen and invisible ones.
    
- `kCGWindowListOptionOnScreenOnly`: Filters for windows that are strictly visible on the compositing plane.
    
- `kCGWindowListExcludeDesktopElements`: Removes the desktop wallpaper and desktop icons from the list, which is crucial for filtering out "noise".  
    

#### 2.1.2 The Data Model: Deconstructing the Window Dictionary

The dictionary returned for each window contains a specific set of keys that constitute the "Identity" of the window from the perspective of the Window Server. Through extensive analysis of the Core Graphics headers and runtime inspection , we can document the schema of this dictionary with a level of detail necessary for systems programming.  

**Table 1: The Quartz Window Dictionary Schema**

|Key Constant|Underlying Type|Semantic Description & Analysis|
|---|---|---|
|`kCGWindowNumber`|`CFNumber` (Int32)|**The Unique Identifier.** This corresponds to the `CGWindowID`. It is unique across the entire user session and persists for the lifetime of the window. This is the "Primary Key" for any window management database. It acts as the fundamental handle for all Quartz operations (e.g., screenshots).|
|`kCGWindowOwnerPID`|`CFNumber` (Int32)|**The Process Link.** The Process ID (PID) of the application that owns the window. This acts as the "Foreign Key" linking the Quartz entity to the Accessibility entity. It is the essential bridge for creating an `AXUIElement` via `AXUIElementCreateApplication`.|
|`kCGWindowBounds`|`CFDictionary`|**The Geometry.** A dictionary representation of `CGRect` (X, Y, Width, Height). _Crucial Architectural Note:_ The origin (0,0) is the top-left corner of the **primary** display. This differs from the standard Quartz 2D drawing coordinate system (bottom-left) but generally aligns with the Accessibility API.|
|`kCGWindowLayer`|`CFNumber` (Int32)|**The Z-Plane.** This integer defines the window's stacking order level. Standard application windows reside at Layer 0. Floating windows, docks, and menus reside at higher positive layers. Desktop elements often reside at negative layers. Filtering by `kCGWindowLayer == 0` is the primary heuristic for finding "user-interactive" windows.|
|`kCGWindowOwnerName`|`CFString`|**The Application Name.** The name of the process. While useful for logging, it should never be used for programmatic identification as it is subject to localization and distinct from the bundle identifier.|
|`kCGWindowName`|`CFString`|**The Window Title.** _Warning:_ This field is notoriously unreliable. Many modern applications (e.g., Chrome, Electron apps) draw custom title bars that the Window Server does not recognize as "system" titles, leaving this field empty. Furthermore, relying on this field requires Screen Recording permissions.|
|`kCGWindowAlpha`|`CFNumber` (Float)|**The Transparency.** A value of 0.0 often indicates the window is technically "open" but invisible or minimized. This is a critical filter for removing "ghost" windows from a user-facing list.|
|`kCGWindowSharingState`|`CFNumber` (Enum)|**The Security Flag.** Indicates if the window's content can be captured by other processes. If the calling application lacks `kTCCServiceScreenCapture` permissions, this will consistently report `kCGWindowSharingNone` (0), and the `kCGWindowName` will be sanitized.|
|`kCGWindowStoreType`|`CFNumber` (Enum)|**The Backing Store.** Indicates how the window's pixel buffer is managed (e.g., `kCGBackingStoreBuffered`). Rarely used for logic but useful for debugging memory usage.|

 

### 2.2 The "Fake Window" Taxonomy

One of the most confounding aspects of `CGWindowListCopyWindowInfo` is that it returns _too much_ information. The Window Server considers _everything_ a window. To build a functional window manager, one must implement rigorous filtering logic to separate "real" application windows from system artifacts.

Research indicates the following common categories of "Fake" windows that must be programmatically excluded :  

1. **The 1x1 Pixel Windows:** Many applications verify their connectivity to the Window Server by spawning 1x1 pixel invisible windows. These clutter the list and must be filtered by checking `bounds.width > 50 && bounds.height > 50`.
    
2. **The Dock and Menu Bar:** These system UI elements have their own `CGWindowID`s but operate on high Z-layers. Filtering for `kCGWindowLayer == 0` effectively removes them.
    
3. **Shadows and Overlays:** Some applications implement drop shadows as separate, translucent windows that follow the main window. These usually share the same PID but have distinct IDs. Logic often requires grouping windows by PID and selecting the one with the largest surface area or the most standard aspect ratio.
    
4. **Status Items:** Menu bar applications often keep a hidden window loaded to display their dropdowns quickly. These usually have `kCGWindowAlpha = 0` or are positioned off-screen.
    

### 2.3 Performance Characteristics and Latency

Calls to `CGWindowListCopyWindowInfo` are computationally expensive. The function triggers a context switch to the Window Server, which must serialize the state of potentially hundreds of surfaces, package them into Core Foundation types, and transfer them to the calling process's memory space.

Benchmarks from high-performance tools suggest that a single call can take between 10ms and 40ms depending on system load and the number of open windows. In the context of a user-interface rendering loop (where the budget is 16ms for 60fps), this function is blocking and dangerous.  

**Optimization Insight:** Systems attempting to render window overlays or border highlights (like Yabai or JankyBorders) cannot call this function on every frame. They typically implement a caching architecture where the window list is refreshed only upon receiving a `kAXWindowCreated` or `kAXFocusedWindowChanged` notification, rather than polling continuously.  

---

## 3. The Accessibility (AX) API Architecture

While Quartz provides the visual truth of the system, the **Accessibility API** provides the mechanism for interaction. This API is part of the `HIServices` framework, a legacy of the Carbon era, but it remains the only sanctioned method for inter-process UI manipulation on macOS.

### 3.1 The Object Model: `AXUIElementRef`

The fundamental primitive of this API is the `AXUIElementRef`. Unlike the integer-based `CGWindowID`, an `AXUIElementRef` is a Core Foundation object (`CFType`) that wraps a secure Mach port connection to a specific UI element within another process.  

The hierarchy is strict and tree-like:

1. **System Wide Element:** Created via `AXUIElementCreateSystemWide()`. Represents the root of the accessibility tree.
    
2. **Application Element:** Created via `AXUIElementCreateApplication(pid_t pid)`. This is the root node for a specific running application.
    
3. **Window Element:** A child of the Application Element.
    
4. **UI Components:** Buttons, text fields, scroll views, and splitters are children of the Window Element.
    

### 3.2 The Control Interface: Attributes and Actions

Interaction with these elements occurs strictly through a Key-Value coding mechanism using "Attributes" for state and "Actions" for commands.

#### 3.2.1 Critical Attributes for Window Management

The following attributes constitute the primary interface for window manipulation. This table synthesizes information from headers `AXAttributeConstants.h` and developer documentation.  

**Table 2: Essential Accessibility Attributes**

|Attribute Constant|Data Type|Usage & Constraints|
|---|---|---|
|`kAXPositionAttribute`|`CGPoint` (boxed in `AXValue`)|**Read/Write.** Controls the window's origin (top-left). Writing to this attribute moves the window. Note that the coordinate system matches the Quartz `kCGWindowBounds` (top-left origin), which simplifies integration, but some apps may reject coordinates that place the window partially off-screen or violate minimum size constraints.|
|`kAXSizeAttribute`|`CGSize` (boxed in `AXValue`)|**Read/Write.** Controls the window's dimensions. Resizing is often the most expensive operation as it triggers a full layout pass in the target application.|
|`kAXTitleAttribute`|`CFString`|**Read Only.** The window's accessible title. This is often more reliable than the Quartz `kCGWindowName` because it reflects the app's internal semantic model rather than the Window Server's display list.|
|`kAXMainAttribute`|`CFBoolean`|**Read/Write.** Indicates if the window is the "Main" window of the application. Setting this to `true` is part of the heuristic for focusing a window.|
|`kAXFocusedAttribute`|`CFBoolean`|**Read/Write.** Indicates if the window has keyboard focus. Writing `true` to this attribute attempts to raise the window and give it input focus.|
|`kAXWindowsAttribute`|`CFArray` of `AXUIElement`|**Read Only.** Accessed on the **Application Element**. This returns a list of all open windows for that specific app. **Crucial Limitation:** In most cases, this array only contains windows present on the **currently active Space**. Windows on hidden spaces are often excluded, creating a major synchronization gap with Quartz.|
|`kAXMinimizedAttribute`|`CFBoolean`|**Read/Write.** Controls the minimized state. This is the definitive way to check if a window is minimized, as relying solely on `kCGWindowAlpha` or bounds can be misleading.|

 

#### 3.2.2 Actions and Event Simulation

Beyond attributes, the API exposes actions:

- `AXUIElementPerformAction(element, kAXRaiseAction)`: Brings the window to the front of the Z-order without necessarily passing focus.
    
- `AXUIElementPerformAction(element, kAXPressAction)`: Used to simulate clicks on standard UI controls like the "Close" or "Zoom" buttons found in the window's title bar hierarchy.
    

### 3.3 The IPC Bottleneck and Failure Modes

The Accessibility API operates over Mach ports, meaning every call to `AXUIElementCopyAttributeValue` or `AXUIElementSetAttributeValue` involves:

1. Serializing the request parameters.
    
2. A kernel context switch.
    
3. Dispatching the message to the target process's run loop.
    
4. Waiting for the target process to handle the request on its main thread.
    
5. Deserializing the response.
    

This architecture makes the API inherently synchronous and blocking. If the target application is busy (e.g., Xcode indexing, a browser rendering complex JavaScript), the AX call will block the caller. To mitigate this, robust implementations must use `AXUIElementSetMessagingTimeout` to prevent indefinite hangs. Typical timeout values range from 100ms to 500ms depending on the desired responsiveness.  

Common error codes encountered include:

- `kAXErrorCannotComplete`: The target process failed to respond within the timeout or is in a bad state.  
    

- `kAXErrorInvalidUIElement`: The window referenced by the element has been closed or destroyed.
    
- `kAXErrorAPIDisabled`: The target application (or the system) does not have Accessibility permissions enabled.
    

---

## 4. The "Extremely Difficult" Integration Problem: Bridging the Gap

We have established the existence of two disparate systems:

1. **Quartz (`CGWindowID`):** Fast, global, accurate Z-order, knows about all windows, read-only. ID is an Integer.
    
2. **Accessibility (`AXUIElementRef`):** Slow, per-process, interaction-capable, oblivious to off-screen spaces. ID is an IPC Token.
    

The core problem facing any window manager developer is this: **You have a `CGWindowID` identifying a window at coordinates (100, 100). You wish to move it. To move it, you need an `AXUIElementRef`. How do you get the Ref from the ID?**

There is no public Apple API function `AXUIElementCreateFromCGWindowID(CGWindowID id)`. There is no public Apple API function `AXUIElementGetCGWindowID(AXUIElementRef element)`.

This gap forces developers to resort to complex correlation strategies. The system ostensibly separates these concepts because they belong to different security and architectural domains—Quartz manages pixel composition, while Accessibility manages semantic UI trees.

### 4.1 Integration Strategy A: The Private API Bridge (`_AXUIElementGetWindow`)

The most direct solution—and the one employed by open-source tools willing to bypass Mac App Store (MAS) restrictions—relies on an undocumented private function exported by the `HIServices` framework.

#### 4.1.1 Reference Documentation: `_AXUIElementGetWindow`

While undocumented, this function has existed since macOS 10.5 (Leopard) and remains present through macOS 14 (Sonoma) and macOS 15 (Sequoia).  

- **Symbol Name:** `_AXUIElementGetWindow`
    
- **Framework:** ApplicationServices (specifically `HIServices.framework`)
    
- **Language:** C / Objective-C
    
- **Signature:**
    
    C
    

- ```
    extern "C" AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID* outWindowID);
    ```
    
- **Functional Description:** This function queries the private internal state of an `AXUIElement` (specifically a window element) to retrieve its associated Window Server ID (`CGWindowID`). It provides a deterministic 1:1 mapping from an Accessibility object to a Quartz ID.
    

#### 4.1.2 Implementation Guide

To utilize this function in a modern Swift or Objective-C project, one must manually expose the C symbol, as it is not present in the public headers.

**Objective-C Bridging Header approach:**

Objective-C

```
// AccessibilityBridgingHeader.h
#import <ApplicationServices/ApplicationServices.h>

// Forward declaration of the private API
// Note: CGWindowID is a typedef for uint32_t
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outIdentifier);
```

**Swift Implementation:**

Swift

```
import Cocoa
import ApplicationServices

func getCGWindowID(from axElement: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    let result = _AXUIElementGetWindow(axElement, &windowID)
    
    if result ==.success {
        return windowID
    } else {
        // Handle errors: kAXErrorInvalidUIElement, kAXErrorCannotComplete
        return nil
    }
}
```

**Validation and Constraints:** Multiple research snippets confirm the efficacy of this method. However, it is crucial to note that this function only solves the `AX -> CG` direction. It does _not_ allow creating an AX element from a CG ID. To achieve the reverse (`CG -> AX`), the developer must:  

1. Identify the PID from the `CGWindowID` (via `CGWindowList`).
    
2. Create the Application Element for that PID.
    
3. Iterate through all windows (`kAXWindowsAttribute`) of that application.
    
4. For each window, call `_AXUIElementGetWindow`.
    
5. If the returned ID matches the target `CGWindowID`, the bridge is established.
    

### 4.2 Integration Strategy B: The Heuristic Matcher

For applications distributed via the Mac App Store, private APIs are strictly prohibited. Developers must rely on "Heuristic Matching," an algorithmic approach that correlates windows based on shared properties. This is the strategy used by apps like Magnet, Rectangle (MAS version), and AltTab.  

#### 4.2.1 The Algorithm

The goal is to find an `AXUIElement` that corresponds to a specific `CGWindowID`.

1. **Input:** A target `CGWindowID` and its `pid` (derived from `CGWindowListCopyWindowInfo`).
    
2. **Step 1:** Create an `AXUIElementRef` for the application using the `pid`.
    
3. **Step 2:** Query the application for its list of windows via `kAXWindowsAttribute`.
    
4. **Step 3 (The Iteration):** Loop through the candidate AX windows.
    
5. **Step 4 (Property Comparison):**
    
    - **Check A (Title):** Compare `kAXTitle` with `kCGWindowName`. _Reliability: Low._ Titles often change dynamically (e.g., browser tabs) or are empty in Quartz.
        
    - **Check B (Frame Geometry):** Compare `kAXPosition`/`kAXSize` with `kCGWindowBounds`. _Reliability: High._
        
6. **Step 5 (Fuzzy Logic):**
    
    - Coordinate systems may have slight variances due to window shadows, borders, or the difference between the "perceived" window and the "clickable" window area.
        
    - The algorithm must employ a tolerance (e.g., ±10 pixels) when comparing origins and sizes.
        

#### 4.2.2 Code Example: The Robust Heuristic Matcher (Swift)

The following implementation demonstrates a robust heuristic matcher that accounts for the fuzzy nature of coordinate comparisons.

Swift

```
import Cocoa
import ApplicationServices

func findAXElement(for targetCGWindow:) -> AXUIElement? {
    // 1. Extract Identity from CG Dictionary
    guard let pid = targetCGWindow as? pid_t,
          let targetFrameDict = targetCGWindow as? else { return nil }
    
    // Parse the CGRect from the dictionary representation
    let targetFrame = CGRect(dictionaryRepresentation: targetFrameDict as CFDictionary)??.zero
    
    // 2. Create Application Element
    let appElement = AXUIElementCreateApplication(pid)
    
    // 3. Get List of Windows
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    
    guard result ==.success, let windowList = windowsRef as? [AXUIElement] else { return nil }
    
    // 4. Iterate and Match
    for window in windowList {
        // Fetch AX Frame Data
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        
        var position = CGPoint.zero
        var size = CGSize.zero
        
        if let posVal = positionRef as! AXValue? { AXValueGetValue(posVal,.cgPoint, &position) }
        if let sizeVal = sizeRef as! AXValue? { AXValueGetValue(sizeVal,.cgSize, &size) }
        
        let axFrame = CGRect(origin: position, size: size)
        
        // Fuzzy Match Logic: Tolerance of 10 pixels to account for shadows/borders
        let xDelta = abs(axFrame.origin.x - targetFrame.origin.x)
        let yDelta = abs(axFrame.origin.y - targetFrame.origin.y)
        let wDelta = abs(axFrame.width - targetFrame.width)
        let hDelta = abs(axFrame.height - targetFrame.height)
        
        if xDelta < 10 && yDelta < 10 && wDelta < 10 && hDelta < 10 {
            // High confidence match found via geometry
            return window
        }
    }
    
    // No match found (window might be on another space or minimized in a way AX hides)
    return nil
}
```

#### 4.2.3 Failure Modes and Limitations

- **Performance:** This approach is `O(N*M)` where N is the number of applications and M is the number of windows. It requires excessive IPC calls just to find a handle. Caching is mandatory.
    
- **Stacked Windows:** If an application has two windows of the exact same size at the exact same position (e.g., a modal dialog perfectly covering the main window), heuristics cannot distinguish them. The private API is the _only_ way to resolve this specific collision.
    
- **Title Instability:** Relying on titles is discouraged. Snippets indicate that titles like "Untitled" or dynamic webpage titles often cause mismatches.  
    

---

## 5. The Spaces (Virtual Desktop) Frontier

Perhaps the most severe limitation of the `CG <-> AX` integration is the "Spaces Barrier." macOS supports multiple virtual desktops ("Spaces"), and the interaction between these APIs and Spaces is notoriously opaque.

### 5.1 The Visibility Phenomenon

- **Quartz Behavior:** `CGWindowListCopyWindowInfo` (with `kCGWindowListOptionAll`) is capable of returning windows on Space 1, Space 2, and Space 3 simultaneously. It provides a global view of the session.
    
- **Accessibility Behavior:** `AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` generally **only** returns windows present on the **currently active Space**.  
    

This creates a fundamental disconnect. Quartz reports that a window exists on Space 2, but if the user is currently on Space 1, the Accessibility API will refuse to provide a reference to that window. Consequently, it is impossible to move or resize a window on a background space using standard public APIs.

### 5.2 Advanced Private APIs: `SkyLight` and `CGSConnection`

To overcome the Spaces barrier, advanced window managers like Yabai and Amethyst (in its more aggressive modes) must bypass the high-level frameworks and interact directly with the Window Server's private interfaces. Historically, these were known as CoreGraphics Services (`CGS`), but in modern macOS versions, they have been migrated to the private `SkyLight.framework`.

#### 5.2.1 `CGSGetWindowList` and `SLSGetWindowList`

Research into the private headers reveals functions that allow for querying window ownership across spaces.  

C

```
// Private SkyLight / CoreGraphics function
extern OSStatus CGSGetWindowList(
    const CGSConnection cid, 
    CGSConnection targetCID, 
    int listSize, 
    int* list, 
    int* numberOfWindows
);
```

These functions operate on `CGSConnection` IDs, which represent a connection to the Window Server. By establishing a connection (via `_CGSDefaultConnection()`), a tool can query lists of windows for specific spaces.

#### 5.2.2 Space Manipulation via `CGSMoveWorkspaceWindowList`

Snippet analysis points to the existence of `CGSMoveWorkspaceWindowList` (or its `SLS` equivalent in SkyLight). This function allows a developer to reassign a list of `CGWindowID`s to a specific Workspace (Space) ID.  

C

```
// Theoretical signature derived from reverse engineering
extern CGError CGSMoveWorkspaceWindowList(
    CGSConnection connection, 
    CGWindowID *windowIDs, 
    int windowCount, 
    int spaceNumber
);
```

Using this API allows a window manager to throw a window from Space 1 to Space 2 without the user having to drag it manually. However, this is highly dangerous; incorrect usage can corrupt the Window Server's state, leading to graphical glitches or session termination.

### 5.3 Injection Architectures (Yabai Case Study)

Yabai, the most advanced tiling window manager for macOS, employs a "Scripting Addition" architecture to solve the Spaces problem.

- **Mechanism:** Yabai injects code directly into the `Dock.app` process. The Dock is the owner of Mission Control and manages the concept of Spaces.
    
- **The payload:** By running code _inside_ the Dock's address space, Yabai gains access to internal Window Server data structures that are not exposed even to root processes.  
    

- **Implication:** This requires disabling **System Integrity Protection (SIP)**. For the average developer distributing an app, this is not a viable path, reinforcing the "Extremely Difficult" nature of the problem for standard software.
    

---

## 6. Coordinate Systems and Multi-Monitor Math

A major source of bugs in window management logic is the mismatch between the various coordinate systems employed by macOS frameworks. A precise mathematical understanding is required to bridge them.

### 6.1 The Three Coordinate Systems

1. **Quartz Display Bounds (`CGDisplayBounds`):**
    
    - **Origin:** Top-Left corner of the _Main Display_ (the monitor with the menu bar).
        
    - **Y-Axis:** Positive creates downward.
        
    - **Multi-Monitor:** Secondary displays to the left or above the main display have _negative_ coordinates.
        
2. **Cocoa (`NSWindow` / `NSScreen`):**
    
    - **Origin:** Bottom-Left corner of the _Main Display_.
        
    - **Y-Axis:** Positive creates upward.
        
    - **Multi-Monitor:** Consistent with Cartesian graphing standards.
        
3. **Accessibility (`kAXPosition`):**
    
    - **Origin:** Top-Left corner of the _Main Display_.
        
    - **Y-Axis:** Positive creates downward.
        
    - **Note:** Generally matches Quartz, but subtle bugs arise when interacting with `NSWindow` frames converted to AX coordinates.
        

### 6.2 The Conversion Formula

When identifying which monitor a window is on, developers often use `NSScreen`. To compare an `NSScreen` frame (Bottom-Left) with a `CGWindow` frame (Top-Left), a conversion is necessary.

The conversion must anchor around the **Main Screen's Height**. It is a common mistake to use the _current_ screen's height, which leads to errors on mixed-resolution setups.

**Mathematical Definition:** Let Hprimary​ be the height of the primary screen (screen at index 0). Let ycocoa​ be the Y-coordinate in Cocoa space. Let yquartz​ be the Y-coordinate in Quartz/AX space. Let hwindow​ be the height of the window.

The conversion from Cocoa to Quartz is:

yquartz​=Hprimary​−ycocoa​−hwindow​

The conversion from Quartz to Cocoa is:

ycocoa​=Hprimary​−yquartz​−hwindow​

**Edge Case Analysis:**

- **Vertical Arrangement:** If Monitor B is arranged _above_ Monitor A, its Cocoa Y-coordinates will be >Hprimary​. Its Quartz Y-coordinates will be negative.
    
    - _Example:_ Monitor A is 1080p. Monitor B is 1080p, placed directly above.
        
    - Top of Monitor B in Cocoa: y=2160.
        
    - Top of Monitor B in Quartz: y=−1080.
        
- **Implication:** Algorithms that clamp negative coordinates to 0 (assuming "off-screen") will incorrectly break functionality for users with vertical monitor stacks.  
    

---

## 7. Security, Sandboxing, and TCC

In the modern macOS era (Mojave and beyond), simply knowing the APIs is insufficient. The **Transparency, Consent, and Control (TCC)** subsystem actively prevents window management applications from functioning unless explicit permissions are granted.

### 7.1 The Permissions Triad

Building a functional window manager requires navigating three distinct permission gates:

1. **Accessibility (`kTCCServiceAccessibility`):**
    
    - **Requirement:** Essential for all `AXUIElement` functions. Without this, creating an application element returns a valid object that is functionally dead (attributes are empty).
        
    - **Mechanism:** There is no API to request this permission. An app must check `AXIsProcessTrustedWithOptions`. If false, the app must guide the user to _System Settings > Privacy & Security > Accessibility_.  
        

- **Storage:** Permissions are stored in `/Library/Application Support/com.apple.TCC/TCC.db`. This is a SQLite database protected by SIP.  
    

- **Screen Recording (`kTCCServiceScreenCapture`):**
    
    - **Requirement:** Essential for `CGWindowListCopyWindowInfo`.
        
    - **The Catch:** Even if you do not record pixels, you need this permission to read **Window Titles** (`kCGWindowName`). Without it, titles are returned as empty strings or generic placeholders, breaking title-based heuristic matching.
        
    - **Sharing State:** Without this, `kCGWindowSharingState` defaults to `0` (None), masking the true state of the window.  
        

- **Sequoia Aggression:** macOS 15 (Sequoia) introduced a monthly recurring prompt for Screen Recording permissions, treating window managers as potential spyware. This has significant UX implications for persistent background utilities.  
    

2. **Process Control (Apple Events):**
    
    - If the application uses AppleScript to control windows (a fallback strategy), it must request permission to send Apple Events to `System Events.app` or specific target applications.
        

### 7.2 The Info.plist Entitlements

For applications attempting to bypass the monthly prompts or access private APIs, specific entitlements are often required, though these usually prevent Mac App Store distribution.

- `com.apple.security.app-sandbox`: Must be **false** for `_AXUIElementGetWindow` to work reliably. Sandboxed apps often find that Accessibility tokens for other processes are sanitized or blocked.
    
- `com.apple.private.tcc.allow`: Used by system binaries to bypass TCC, inaccessible to third-party devs.
    

---

## 8. Performance Optimization and Caching Strategies

A naive implementation that calls `CGWindowListCopyWindowInfo` and `AXUIElementCopyAttributeValue` inside a high-frequency loop (e.g., 60Hz) will consume excessive CPU and cause system-wide stutter.

### 8.1 The Caching Architecture

Optimization relies on the principle of **Lazy Invalidation**.

1. **The Cache:** Maintain a local `Dictionary<CGWindowID, WindowState>` that stores the last known frame, title, and AX reference.
    
2. **The Trigger:** Do not poll. Use `AXObserver` to subscribe to `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, and `kAXWindowCreatedNotification`.  
    

3. **The Update:** Only when a notification is received, or when the user triggers a command (e.g., "Tile Windows"), should the `CGWindowList` be refreshed.
    

### 8.2 Batching and Filtering

- **Filter Early:** When calling `CGWindowListCopyWindowInfo`, always use `kCGWindowListExcludeDesktopElements`. This removes hundreds of unnecessary icons from the serialization process.  
    

- **Attribute Batching:** Use `AXUIElementCopyMultipleAttributeValues` instead of single calls. This reduces the number of IPC round-trips by fetching Position, Size, and Title in a single Mach message.  
    

---

## 9. The Unified Reference Implementation

The following section provides a "Production Grade" implementation reference that bridges all the concepts discussed: Quartz retrieval, Private API bridging, and Heuristic fallback.

### 9.1 Unified Window Manager Class (Swift)

Swift

```
import Cocoa
import ApplicationServices

// Bridge for the Private API
// In a real project, this would be in a bridging header or exposed via `@_silgen_name`
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

class UnifiedWindowManager {
    
    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let appName: String
        let frame: CGRect
        let axElement: AXUIElement?
    }

    /// The master function to retrieve the state of the world
    func getAllWindows() -> {
        // 1. Query Quartz for the visual truth
        let options = CGWindowListOption(arrayLiteral:.optionOnScreenOnly,.excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as?] else { return }
        
        var results: =
        
        for entry in list {
            // 2. Extract Quartz Identity
            guard let id = entry as? CGWindowID,
                  let pid = entry as? pid_t,
                  let frameDict = entry as?,
                  let frame = CGRect(dictionaryRepresentation: frameDict as CFDictionary) else { continue }
            
            // 3. Filter System Noise
            let layer = entry as? Int?? 0
            let alpha = entry as? Float?? 1.0
            
            // Layer 0 is standard user windows. Alpha > 0.1 prevents invisible ghosts.
            // Size check prevents 1x1 pixel keep-alive windows.
            if layer!= 0 |

| alpha < 0.1 |
| frame.width < 50 |
| frame.height < 50 { continue }
            
            // 4. Bind the AX Element (The "Extremely Difficult" part)
            let axElement = self.bindAXElement(pid: pid, windowID: id, frame: frame)
            
            let appName = entry as? String?? ""
            results.append(WindowInfo(id: id, pid: pid, appName: appName, frame: frame, axElement: axElement))
        }
        return results
    }

    /// The Bridge Function: Attempts Private API first, then falls back to Heuristics
    private func bindAXElement(pid: pid_t, windowID: CGWindowID, frame: CGRect) -> AXUIElement? {
        let appRef = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        
        // Fetch all windows for the app
        // Note: This list may be empty if the app is on another Space!
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result ==.success, let windows = windowsRef as? [AXUIElement] else { return nil }
        
        for window in windows {
            // Strategy A: Private API Match (Deterministic)
            var axID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &axID) ==.success {
                if axID == windowID { return window }
            }
            
            // Strategy B: Heuristic Fallback (Probabilistic)
            // Used if Private API fails or returns 0
            var posVal: CFTypeRef?
            var sizeVal: CFTypeRef?
            
            // Batch these calls if possible in production
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posVal)
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeVal)
            
            var pos = CGPoint.zero
            var size = CGSize.zero
            
            if let p = posVal as! AXValue? { AXValueGetValue(p,.cgPoint, &pos) }
            if let s = sizeVal as! AXValue? { AXValueGetValue(s,.cgSize, &size) }
            
            // Fuzzy Match Logic: +/- 10 pixels
            if abs(pos.x - frame.origin.x) < 10 && 
               abs(pos.y - frame.origin.y) < 10 &&
               abs(size.width - frame.width) < 10 &&
               abs(size.height - frame.height) < 10 {
                return window
            }
        }
        return nil
    }
}
```

---

## 10. Conclusion

The architecture of macOS window management is defined by the tension between the immutable, secure world of Quartz and the mutable, legacy world of Accessibility. While Apple provides no direct bridge between these worlds, a robust solution can be engineered by combining `CGWindowListCopyWindowInfo` for state retrieval with `AXUIElement` for control, bridged by the `_AXUIElementGetWindow` private function or sophisticated geometric heuristics.

For the systems engineer, success lies not just in API knowledge, but in mastering the edge cases: the nuances of multi-monitor coordinate math, the invisible boundaries of Mission Control Spaces, and the ever-tightening grip of TCC security policies. This report defines the roadmap for traversing that landscape.