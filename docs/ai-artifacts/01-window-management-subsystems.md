# **Architectural Analysis of macOS Window Management Subsystems: Legacy Frameworks, Private Interfaces, and Inter-Process Communication Paradigms**

## **1\. Executive Summary and Architectural Context**

The engineering of third-party window management solutions on the macOS platform represents a unique challenge in systems programming, characterized by a continuous negotiation between the operating system’s rigorous security model and the requirement for granular user interface control. Unlike the modular architectures found in Linux environments—where the X Window System or Wayland protocols facilitate a clear separation between the display server and the window manager—macOS employs a monolithic, vertically integrated graphical subsystem known as Quartz. This architecture, while delivering the visual consistency and fluid compositing that defines the Macintosh user experience, deliberately obfuscates the mechanisms required for external process control.
This report provides an exhaustive technical analysis of the underlying frameworks, Application Programming Interfaces (APIs), and Inter-Process Communication (IPC) mechanisms that govern window manipulation on macOS. It serves to retroactively reference and substantiate the architectural decisions documented in advanced tiling window manager implementations, specifically addressing the dichotomies between public and private frameworks, the imperative of synchronous versus asynchronous communication, and the evolving constraints introduced in recent operating system revisions such as macOS Sequoia.
The analysis synthesizes data from system internals, developer documentation, and reverse-engineering efforts to construct a definitive reference on the state of macOS window orchestration. It navigates the limitations of the public AppKit and Accessibility frameworks, explores the undocumented capabilities of the SkyLight private framework, and dissects the latency implications of the HIServices daemon. Furthermore, it examines the critical dependency on specific system settings—such as "Displays have separate Spaces"—and the necessary compromises regarding System Integrity Protection (SIP) required to achieve native-level performance.

## **2\. The Quartz Compositor and Window Server Dynamics**

To fully comprehend the limitations imposed on external window managers, one must first deconstruct the central role of the WindowServer. In the macOS kernel and user-space architecture, the WindowServer is a high-priority process that coordinates the composition of visual content on the screen.1 It acts as the central arbiter for the Quartz Compositor, managing the frame buffers, calculating occlusions, and compositing the bitmap data provided by various client applications into the final signal sent to the display hardware.

### **2.1 The Historical Evolution from NeXTSTEP to Aqua**

The roots of the macOS windowing system lie in the Display PostScript engine of NeXTSTEP, which evolved into the Quartz 2D drawing engine. In the modern era, the interface to the WindowServer was historically handled through the Core Graphics framework. However, as macOS evolved from its origins in Mac OS X 10.0 to the current macOS 15 Sequoia, Apple migrated much of the lower-level window management functionality into a private framework known as SkyLight. While Core Graphics remains the public facade for drawing and basic display configuration—providing structures like CGRect and functions for image manipulation—SkyLight handles the "heavy lifting" of window transformations, spaces management, and the direct connection to the window server context.2
The WindowServer application itself resides within the CoreGraphics framework resources (or SkyLight in newer versions) and is responsible for processing window events and rendering the final composite image.1 It maintains the "single source of truth" regarding the desktop state: which windows are visible, their Z-order (layering), their transparency (alpha values), and their precise coordinate space. This centralization is critical for performance but introduces a bottleneck: any external process attempting to modify this state must communicate with the WindowServer, usually via an intermediate framework.

### **2.2 Process Isolation and the NSWindow Limitation**

A fundamental misunderstanding often arises regarding the NSWindow class within the AppKit framework, which serves as the primary interface for native application development. NSWindow is the standard Cocoa class for creating and managing windows *within the local process* of an application.3 It provides a rich set of methods for manipulating the window's frame, title, and content view, but these methods are bound by the process boundary.
The NSApplication object, which acts as the singleton manager for a running program, maintains a list of NSWindow instances.4 Crucially, this list is strictly local. The operating system's memory protection model ensures that an application cannot simply instantiate an NSWindow object that refers to a window owned by another process. This is a deliberate security and architectural design by Apple to prevent applications from interfering with each other's state or scraping sensitive data from other windows.
When a third-party window manager (such as AeroSpace, Amethyst, or yabai) attempts to control a target application (e.g., Safari, Terminal, or Xcode), it cannot use NSWindow methods because the target window exists in a separate, protected memory address space. The NSWindow object is merely a high-level wrapper around a lower-level window ID (specifically CGWindowID) and a connection to the window server, but the Objective-C or Swift methods that manipulate it are effective only within the process that instantiated them.5 Consequently, the window manager must rely on IPC mechanisms to request changes, introducing the latency and synchronization challenges that define the performance characteristics of the entire genre of software.

## **3\. The Public API Landscape: Introspection and Control**

Developers seeking to build window management tools without disabling System Integrity Protection (SIP) or utilizing unstable private headers are restricted to two primary public frameworks: Quartz Window Services (for introspection) and the Accessibility API (for control).

### **3.1 Quartz Window Services: The Cost of Observation**

Quartz Window Services provides functions to obtain information about the windows on the screen. The primary function used for this purpose is CGWindowListCopyWindowInfo.5 This C-based API is the industry standard for "discovering" the state of the desktop.

#### **3.1.1 Functional Mechanics of Window Listing**

The CGWindowListCopyWindowInfo function acts as a query interface to the WindowServer. It accepts an option parameter (e.g., kCGWindowListOptionOnScreenOnly or kCGWindowListOptionAll) and a relative window ID, returning a CFArrayRef of dictionaries (CFDictionaryRef).6 Each dictionary corresponds to a window and contains key-value pairs describing its attributes.

| Key Constant | Description | Data Type |
| :---- | :---- | :---- |
| kCGWindowOwnerPID | The Process ID (PID) of the application that owns the window. | CFNumber (Int) |
| kCGWindowNumber | The unique identifier (CGWindowID) assigned by the WindowServer. | CFNumber (Int) |
| kCGWindowBounds | A dictionary defining the X, Y, Width, and Height of the window. | CFDictionary |
| kCGWindowLayer | The Z-axis layer of the window (e.g., Normal, Floating, Status Bar). | CFNumber (Int) |
| kCGWindowName | The name of the window (often distinct from the window title). | CFString |
| kCGWindowAlpha | The transparency level of the window (0.0 to 1.0). | CFNumber (Float) |

#### **3.1.2 The Read-Only Limitation**

While CGWindowListCopyWindowInfo is essential for identifying where windows are located, it suffers from a critical deficit: it is purely an introspection API. The dictionaries returned are immutable snapshots of the state at the moment of the function call. A developer cannot modify the kCGWindowBounds in the dictionary and pass it back to Core Graphics to move the window. The flow of information is strictly one-way: from the Server to the Client.5 This necessitates a separate mechanism for control, creating a "split-brain" architecture where the window manager reads state via Core Graphics but must write state via Accessibility.

#### **3.1.3 Performance Implications and the Observer Effect**

Generating these window lists is described by Apple documentation as a "relatively expensive operation".6 It requires the WindowServer to pause its compositing loop, traverse the window tree, aggregate data from all running applications (some of which may be paged out or non-responsive), and serialize this data into Core Foundation types. Repeatedly polling this function—for instance, at 60Hz to detect new windows—consumes significant CPU resources and can lead to input lag, particularly when the WindowServer is already under load.8 This creates an "observer effect" where the act of managing the windows degrades the performance of the windows being managed.

### **3.2 The Accessibility API (AX): The Mechanism of Control**

Since NSWindow is local and Core Graphics is read-only, the only authoritative public method for an external process to *move* or *resize* another application's window is the Apple Accessibility API. This API is intended for assistive technologies—such as VoiceOver or Switch Control—but has been co-opted by the window management community as the only viable control plane.5

#### **3.2.1 The AXUIElement Structure**

The core data type in this framework is AXUIElementRef, which represents a user interface element (an application, a window, a button, or a scroll area) in another process.10 To control a window, a window manager must perform a multi-step "handshake" with the target application:

1. **Application Reference Creation:** The manager calls AXUIElementCreateApplication(pid) using the PID obtained from CGWindowList or NSRunningApplication.5 This creates a connection endpoint to the target process.
2. **Hierarchy Traversal:** The manager queries the application for its list of windows using AXUIElementCopyAttributeValue with the key kAXWindowsAttribute. This returns an array of AXUIElementRef objects representing the windows.5
3. **Attribute Identification:** The manager must iterate through this array, checking attributes like kAXTitleAttribute, kAXPositionAttribute, or kAXSizeAttribute to match the specific window intended for manipulation.13
4. **State Mutation:** Once the correct element is identified, the manager uses AXUIElementSetAttributeValue to change the kAXPositionAttribute or kAXSizeAttribute, thereby moving or resizing the window.11

#### **3.2.2 The PID-to-Window Disconnect**

A major architectural friction point is the lack of a shared identifier between the Core Graphics and Accessibility frameworks. There is no direct public function to convert a CGWindowID (obtained efficiently from the Window Server) into an AXUIElementRef (required for control).16 This forces developers to rely on "fuzzy matching" heuristics: taking the frame and title from Core Graphics and searching the Accessibility tree for a window with matching dimensions and name. This method is computationally expensive (O(n) search for every operation) and brittle; if an application has two windows named "Untitled" at the same position, the window manager cannot deterministically distinguish them using public APIs alone.13

## **4\. Inter-Process Communication: The HIServices Bottleneck**

The Accessibility API is not a direct function call into the target application's memory. It relies on a complex IPC mechanism facilitated by the HIServices framework (Human Interface Services) and the com.apple.hiservices-xpcservice daemon.1 Understanding this layer is crucial for explaining the latency often observed in macOS window managers compared to their Linux counterparts.

### **4.1 Synchronous vs. Asynchronous IPC**

Accessibility queries on macOS are generally **synchronous**.18 When a window manager calls AXUIElementSetAttributeValue, the execution flow is as follows:

1. The window manager process suspends execution (blocks).
2. An IPC message (typically a Mach message wrapped in AppleEvents or XPC) is sent via the kernel to the target application.
3. The kernel schedules the target application.
4. The target application's main run loop receives the message, wakes up, processes the accessibility request (which involves updating its own internal view hierarchy), and generates a reply.
5. The reply is sent back to the window manager.
6. The window manager process resumes execution.

### **4.2 The Latency Cascade**

This round-trip communication introduces unavoidable latency. Research indicates that IPC overhead can be orders of magnitude slower than local thread communication due to the costs of context switching, parameter marshaling, and kernel validation.19
In the context of a Tiling Window Manager (TWM) that needs to re-layout a grid of windows, this latency accumulates linearly. If a user opens a new terminal window in a grid of four, the manager must resize the existing three windows and position the fourth. This requires at least eight IPC calls (four for position, four for size). If the target applications are heavy (e.g., an Electron app like VS Code or a Java app like IntelliJ), the target process may take 10-50 milliseconds to process the event on its main thread. The cumulative delay results in visible "jank," where windows appear to stutter or resize sequentially rather than instantaneously.2

### **4.3 System Stability and Daemon Reliance**

The reliance on HIServices also introduces system stability risks. The com.apple.hiservices-xpcservice daemon is frequently cited in system logs associated with high CPU usage, hangs, or crashes when accessibility features are heavily utilized.8 If this service degrades or hangs, the entire window management subsystem can become unresponsive, leading to scenarios where the window manager effectively locks up the user interface until the daemon is restarted or the blocking call times out.15

## **5\. The Private API Ecosystem: SkyLight and Advanced Control**

To bypass the limitations of the Accessibility API—specifically the lack of animation control, the inability to manage Spaces, and the performance overhead—advanced window managers utilize private APIs from the SkyLight framework. These APIs provide direct access to the WindowServer, circumventing the slow IPC path through HIServices.

### **5.1 The \_AXUIElementGetWindow Bridge**

One of the most critical private functions for stability is \_AXUIElementGetWindow. Used by tools like AeroSpace, this function solves the "PID-to-Window" disconnect described in Section 3.2.2.9

* **Functionality:** It accepts an AXUIElementRef and returns the associated CGWindowID.
* **Significance:** This allows the window manager to instantly and deterministically map the control object (AX) to the introspection object (CG). It eliminates the need for heuristic matching, significantly increasing robustness.9
* **Trade-off:** As a private API, it is subject to change without notice. However, its utility is so high that it is often the *only* private API used by "conservative" window managers that aim for a balance between power and stability.23

### **5.2 The Transactional Model (SLSTransaction)**

For years, the gold standard for high-performance window management on macOS was the SLSTransaction API family (e.g., SLSTransactionCreate, SLSTransactionCommit, SLSTransactionMoveWindowWithGroup).2 This API allowed developers to batch multiple window operations (moves, resizes, layer changes) into a single atomic transaction. The WindowServer would then apply all changes simultaneously in the next compositing pass.
This capability was essential for preventing the "popcorn effect" (windows resizing one by one) and enabling smooth, 60fps animations. However, with the release of macOS 15 (Sequoia), Apple introduced significant changes to the SkyLight framework. Reports indicate that SLSTransaction functions have been removed, locked down via sandbox restrictions, or fundamentally altered.2 This deprecation forces window managers to revert to the jittery, synchronous AXUIElement method or find new, obfuscated entry points, highlighting the inherent volatility of relying on private system interfaces.

### **5.3 Window Warping and Transformations**

Private APIs such as CGSSetWindowWarp and SLSSetWindowTransformation allow for the manipulation of window geometry at the compositor level.2 These functions can apply affine transforms (scale, rotation, translation) to a window's backing store without involving the application that owns the window. While this allows for instant visual movement, it creates a state desynchronization: the window *looks* moved, but the application's internal logic (e.g., handling mouse clicks) assumes it is in the original location until a corresponding AX event updates the application's state.2 Thus, these APIs are typically used only for animations or temporary effects.

## **6\. System Integrity Protection (SIP) and the Injection Trade-off**

A major differentiator between window managers is their interaction with System Integrity Protection (SIP). Introduced in OS X El Capitan, SIP restricts the ability of the root user to modify system processes or inject code.

### **6.1 The Scripting Addition Strategy**

Tools like yabai offer advanced features—such as instant space switching, removing window shadows, and modifying the Dock's behavior—that are strictly impossible via standard APIs. To achieve this, they utilize a **Scripting Addition** (.osax).25 This involves injecting a dynamic library directly into the Dock.app process (which manages Mission Control and Spaces) and the WindowServer.

### **6.2 The Security Compromise**

To perform this injection, the user is required to partially disable SIP, specifically the debugging restrictions (csrutil enable \--without debug) and filesystem protections (--without fs).25

* **Standard Mode (SIP Enabled):** Window managers like AeroSpace and Amethyst are limited to the Accessibility API and public Core Graphics functions. They cannot animate space switches or remove window borders/shadows.9
* **Injection Mode (SIP Disabled):** The window manager gains "God-mode" control over the windowing system. It can intercept internal WindowServer events and manipulate the window tree directly. However, this compromises the platform's security model, making the system vulnerable to code injection attacks from malware.27

## **7\. The "Spaces" Black Box and Virtual Desktop Management**

Perhaps the most opaque aspect of macOS window management is "Spaces" (Virtual Desktops). Apple provides no public API to create, destroy, or strictly manage Spaces, viewing them as a user-facing feature managed solely by Mission Control.28

### **7.1 The "Displays have separate Spaces" Constraint**

A critical system setting for tiling window managers is "Displays have separate Spaces" in the Mission Control preferences.

* **Enabled:** Each physical display has its own independent set of virtual spaces. This is generally preferred for independent workflows but complicates the mapping of windows to specific coordinates because the coordinate system may shift relative to the active space on each monitor.9
* **Disabled:** Spaces span across all monitors as a single giant virtual desktop. This simplifies coordinate math but reduces user flexibility.

Most TWMs (including AeroSpace and yabai) strongly recommend or require "Displays have separate Spaces" to be enabled to function correctly with their tiling algorithms.9

### **7.2 The Visibility Problem**

A significant limitation of CGWindowListCopyWindowInfo is its behavior regarding background spaces. By default, it often returns only windows on the *active* space.7 While the kCGWindowListOptionAll flag can return off-screen windows, determining *which* space a specific window belongs to is notoriously difficult. The API does not provide a "Space ID" property for windows. Developers must resort to heuristics—such as checking if a window's layer or bounds match certain criteria—to guess its location.31

### **7.3 Workarounds for Space Switching**

Since there is no API to "Move Window X to Space Y," window managers use creative workarounds:

1. **The AX Drag Method:** Simulating a drag-and-drop of the window onto the preview thumbnail in Mission Control (requires scripting the Dock). This is slow, visually disruptive, and fragile.28
2. **The Private Tag Method:** Using SLS functions to reassign private window tags or space IDs. This is what yabai (with SIP disabled) utilizes to move windows between spaces instantly.33
3. **The AeroSpace Virtualization:** AeroSpace implements its *own* internal virtual workspace system. It "hides" windows that are not on the active internal workspace by moving them far off-screen (e.g., to coordinate 9999, 9999\) rather than relying on native macOS Spaces. This avoids the limitations of the native Spaces API entirely but requires reimplementing workspace logic from scratch.34

## **8\. The Impact of macOS Sequoia (macOS 15\)**

The introduction of macOS Sequoia has introduced new friction points for window management utilities, signaling a trend toward stricter enforcement of user privacy and API usage.

### **8.1 Persistent Permissions**

Sequoia introduced a monthly (or weekly, in betas) prompt for persistent screen recording permissions. Since CGWindowListCopyWindowInfo and certain Accessibility functions are guarded by Screen Recording permissions (to prevent spyware from capturing window contents), users of tools like HyperDock, Shottr, and tiling managers are forced to re-authenticate regularly.35 This degrades the "set and forget" user experience that is critical for background utilities.

### **8.2 API Lockdown**

The removal or modification of SLSTransaction breaks the smooth animation logic used by yabai and similar tools.2 This forces developers to revert to the "jittery" AXUIElement individual resize method, regressing the visual polish of third-party window managers on the platform and reinforcing the "cat-and-mouse" dynamic between Apple engineers and the developer community.

## **9\. Conclusion**

The architecture of macOS window management is defined by a series of deliberate constraints that prioritize security, stability, and a consistent user experience over external programmability. The NSWindow class is architecturally isolated within the application process, rendering it useless for external control. The public Accessibility API (AXUIElement) serves as the only sanctioned bridge for inter-process manipulation, but its synchronous IPC architecture (HIServices) introduces unavoidable latency and performance bottlenecks that prevent "native-feeling" responsiveness.
To achieve the feature set comparable to Linux-based window managers, developers are forced to utilize private SkyLight APIs and disable System Integrity Protection, accepting the risks of instability and system breakage. This fragile ecosystem explains the divergent design philosophies of tools like AeroSpace—which strictly adheres to minimal private API usage (\_AXUIElementGetWindow) to maintain stability 9—versus yabai, which embraces deep system modification for maximum power.25 As Apple continues to tighten security with updates like macOS Sequoia, the viability of deep window management customization faces an uncertain future, likely forcing a convergence toward more restricted, less capable, but more stable solutions.

## **10\. Comparative Feature Matrix**

The following table summarizes the capabilities, costs, and stability profiles of the various methods for window interaction discussed in this report.

| Feature / API | NSWindow (AppKit) | AXUIElement (Accessibility) | CGWindowList (CoreGraphics) | SLS / CGS (Private) | \_AXUIElementGetWindow (Private) |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Scope** | Local Process Only | Global (All Apps) | Global (Introspection) | Global (System Level) | Global (Identity) |
| **Read Capability** | High (Local Props) | High (Attributes) | High (Frame, PID, Layer) | Very High (Internal State) | High (CGWindowID) |
| **Write Capability** | High (Local Props) | Medium (Pos, Size) | None (Read Only) | High (Transform, Alpha) | None (Read Only) |
| **Latency** | Low (In-Memory) | High (Sync IPC) | High (Server Calculation) | Low (Direct to Server) | Low (Direct) |
| **Stability** | Stable | Stable (but can hang) | Stable | Volatile (OS Updates) | Volatile (Undocumented) |
| **SIP Required?** | No | No | No | Sometimes / Yes for Injection | No |
| **Spaces Support** | Local Only | Limited | Limited (Active Space) | Full (with hacks) | N/A |
| **Primary Use** | Native Apps | Automation / TWMs | Discovery / Screenshots | Animations / Spaces | ID Resolution |

#### **Works cited**

1. Chapter 1\. Origins of Mac OS X, accessed November 23, 2025, [https://atakua.org/p/books/Mac%20OS%20X%20Internals%20-%20A%20Systems%20Approach.pdf](https://atakua.org/p/books/Mac%20OS%20X%20Internals%20-%20A%20Systems%20Approach.pdf)
2. Animate window move/resize/swap/warp · Issue \#148 · koekeishiya/yabai \- GitHub, accessed November 23, 2025, [https://github.com/koekeishiya/yabai/issues/148](https://github.com/koekeishiya/yabai/issues/148)
3. NSWindow | Apple Developer Documentation, accessed November 23, 2025, [https://developer.apple.com/documentation/appkit/nswindow](https://developer.apple.com/documentation/appkit/nswindow)
4. NSApplication | Apple Developer Documentation, accessed November 23, 2025, [https://developer.apple.com/documentation/appkit/nsapplication](https://developer.apple.com/documentation/appkit/nsapplication)
5. objective c \- Move other windows on Mac OS X using Accessibility ..., accessed November 23, 2025, [https://stackoverflow.com/questions/21069066/move-other-windows-on-mac-os-x-using-accessibility-api](https://stackoverflow.com/questions/21069066/move-other-windows-on-mac-os-x-using-accessibility-api)
6. CGWindowListCopyWindowInfo | Apple Developer Documentation, accessed November 23, 2025, [https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(\_:\_:)?language=objc](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo\(_:_:\)?language=objc)
7. Display windows from other Spaces · Issue \#14 · lwouis/alt-tab-macos, accessed November 23, 2025, [https://github.com/lwouis/alt-tab-macos/issues/14](https://github.com/lwouis/alt-tab-macos/issues/14)
8. System slow \- Safari hangs frequently while loading pages \- Apple Support Communities, accessed November 23, 2025, [https://discussions.apple.com/thread/251444967](https://discussions.apple.com/thread/251444967)
9. nikitabobko/AeroSpace: AeroSpace is an i3-like tiling ... \- GitHub, accessed November 23, 2025, [https://github.com/nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace)
10. AXUIElement | Apple Developer Documentation, accessed November 23, 2025, [https://developer.apple.com/documentation/applicationservices/axuielement](https://developer.apple.com/documentation/applicationservices/axuielement)
11. How can I move/resize windows programmatically from another application?, accessed November 23, 2025, [https://stackoverflow.com/questions/4231110/how-can-i-move-resize-windows-programmatically-from-another-application](https://stackoverflow.com/questions/4231110/how-can-i-move-resize-windows-programmatically-from-another-application)
12. Mac / Cocoa \- Getting a list of windows using Accessibility API \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/2107657/mac-cocoa-getting-a-list-of-windows-using-accessibility-api](https://stackoverflow.com/questions/2107657/mac-cocoa-getting-a-list-of-windows-using-accessibility-api)
13. Getting Window Number through OSX Accessibility API \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/6178860/getting-window-number-through-osx-accessibility-api](https://stackoverflow.com/questions/6178860/getting-window-number-through-osx-accessibility-api)
14. Window move and resize APIs in OS X \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/614185/window-move-and-resize-apis-in-os-x](https://stackoverflow.com/questions/614185/window-move-and-resize-apis-in-os-x)
15. AXUIElement.h \- Documentation \- Apple Developer, accessed November 23, 2025, [https://developer.apple.com/documentation/applicationservices/axuielement\_h?language=objc](https://developer.apple.com/documentation/applicationservices/axuielement_h?language=objc)
16. Cocoa CGWindowListCopyWindowInfo & AXUIElementSetAttributeValue \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/11251700/cocoa-cgwindowlistcopywindowinfo-axuielementsetattributevalue](https://stackoverflow.com/questions/11251700/cocoa-cgwindowlistcopywindowinfo-axuielementsetattributevalue)
17. Mac OS X 10.3.9 Developer Release Notes, accessed November 23, 2025, [https://leopard-adc.pepas.com/releasenotes/Carbon/HIToolboxOlderNotes.html](https://leopard-adc.pepas.com/releasenotes/Carbon/HIToolboxOlderNotes.html)
18. My Thoughts on Asynchronous Accessibility APIs \- Jantrid, accessed November 23, 2025, [https://www.jantrid.net/2025/03/20/async-accessibility-apis/](https://www.jantrid.net/2025/03/20/async-accessibility-apis/)
19. Inter-process communication \- Wikipedia, accessed November 23, 2025, [https://en.wikipedia.org/wiki/Inter-process\_communication](https://en.wikipedia.org/wiki/Inter-process_communication)
20. What causes inter-process communication to take millions of cycles? \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/78761814/what-causes-inter-process-communication-to-take-millions-of-cycles](https://stackoverflow.com/questions/78761814/what-causes-inter-process-communication-to-take-millions-of-cycles)
21. Re: Acrobat 2017 crashes immediately after opening \- Adobe Product Community, accessed November 23, 2025, [https://community.adobe.com/t5/acrobat/acrobat-2017-crashes-immediately-after-opening/m-p/9920203](https://community.adobe.com/t5/acrobat/acrobat-2017-crashes-immediately-after-opening/m-p/9920203)
22. Open and Save Panel service not responding \- Apple Support Communities, accessed November 23, 2025, [https://discussions.apple.com/thread/254783442](https://discussions.apple.com/thread/254783442)
23. Bug: sometimes a window on the focused monitor is focused when a window of the same app on a different monitor was requested to focus · Issue \#101 · nikitabobko/AeroSpace \- GitHub, accessed November 23, 2025, [https://github.com/nikitabobko/AeroSpace/issues/101](https://github.com/nikitabobko/AeroSpace/issues/101)
24. Pro Display XDR momentarily looses connection to Mac Pro 2019, accessed November 23, 2025, [https://discussions.apple.com/thread/255876208](https://discussions.apple.com/thread/255876208)
25. 09 \- Transparent terminal with yabai in macOS \- linkarzu, accessed November 23, 2025, [https://linkarzu.com/posts/2024-macos-workflow/setup-yabai/](https://linkarzu.com/posts/2024-macos-workflow/setup-yabai/)
26. Using i3-like Tiling Window Managers in MacOS with yabai. | by Anuj Chandra | Medium, accessed November 23, 2025, [https://anuj-chandra.medium.com/using-i3-like-tiling-window-managers-in-macos-with-yabai-ebf0e002b992](https://anuj-chandra.medium.com/using-i3-like-tiling-window-managers-in-macos-with-yabai-ebf0e002b992)
27. Yabai – A tiling window manager for macOS \- Hacker News, accessed November 23, 2025, [https://news.ycombinator.com/item?id=38473942](https://news.ycombinator.com/item?id=38473942)
28. hs.spaces \- Hammerspoon docs, accessed November 23, 2025, [https://www.hammerspoon.org/docs/hs.spaces.html](https://www.hammerspoon.org/docs/hs.spaces.html)
29. koekeishiya/yabai: A tiling window manager for macOS based on binary space partitioning, accessed November 23, 2025, [https://github.com/koekeishiya/yabai](https://github.com/koekeishiya/yabai)
30. How to get window list from core-grapics API with swift \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/30336740/how-to-get-window-list-from-core-grapics-api-with-swift](https://stackoverflow.com/questions/30336740/how-to-get-window-list-from-core-grapics-api-with-swift)
31. How to list all windows from all workspaces in Python on Mac? \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/44232433/how-to-list-all-windows-from-all-workspaces-in-python-on-mac](https://stackoverflow.com/questions/44232433/how-to-list-all-windows-from-all-workspaces-in-python-on-mac)
32. Get the list of all running fullscreen apps (or spaces) using JXA \- Stack Overflow, accessed November 23, 2025, [https://stackoverflow.com/questions/59502377/get-the-list-of-all-running-fullscreen-apps-or-spaces-using-jxa](https://stackoverflow.com/questions/59502377/get-the-list-of-all-running-fullscreen-apps-or-spaces-using-jxa)
33. Organizing computer windows \- Kevin Lynagh, accessed November 23, 2025, [https://kevinlynagh.com/organizing-windows/](https://kevinlynagh.com/organizing-windows/)
34. Moving windows without SIP disabled stopped working since ..., accessed November 23, 2025, [https://github.com/koekeishiya/yabai/issues/2500](https://github.com/koekeishiya/yabai/issues/2500)
35. macOS Sequoia App Compatibility Megathread : r/macapps \- Reddit, accessed November 23, 2025, [https://www.reddit.com/r/macapps/comments/1ddb96s/macos\_sequoia\_app\_compatibility\_megathread/](https://www.reddit.com/r/macapps/comments/1ddb96s/macos_sequoia_app_compatibility_megathread/)
36. I might switch to Windows if Apple keeps making macOS more annoying for power users, accessed November 23, 2025, [https://www.xda-developers.com/i-might-switch-windows-if-macos-gets-annoying/](https://www.xda-developers.com/i-might-switch-windows-if-macos-gets-annoying/)
37. macOS Sequoia is available today \- Hacker News, accessed November 23, 2025, [https://news.ycombinator.com/item?id=41559761](https://news.ycombinator.com/item?id=41559761)
