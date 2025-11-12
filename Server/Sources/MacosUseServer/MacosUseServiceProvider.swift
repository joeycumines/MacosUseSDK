import ApplicationServices
import CoreGraphics
import Foundation
import GRPC
import MacosUseSDKProtos
import SwiftProtobuf

/// This is the single, correct gRPC provider for the `MacosUse` service.
///
/// It implements the generated `Macosusesdk_V1_MacosUseAsyncProvider` protocol
/// and acts as the bridge between gRPC requests and the `AutomationCoordinator`.
final class MacosUseServiceProvider: Macosusesdk_V1_MacosUseAsyncProvider {
  let stateStore: AppStateStore
  let operationStore: OperationStore
  let windowRegistry: WindowRegistry

  init(stateStore: AppStateStore, operationStore: OperationStore) {
    self.stateStore = stateStore
    self.operationStore = operationStore
    self.windowRegistry = WindowRegistry()
  }

  // MARK: - Application Methods

  func openApplication(
    request: Macosusesdk_V1_OpenApplicationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    fputs("info: [MacosUseServiceProvider] openApplication called\n", stderr)

    fputs("info: [MacosUseServiceProvider] openApplication called (LRO)\n", stderr)

    // Create an operation and return immediately
    let opName = "operations/open/\(UUID().uuidString)"

    // optional metadata could include the requested id
    let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
      $0.typeURL = "type.googleapis.com/macosusesdk.v1.OpenApplicationMetadata"
      $0.value = try Macosusesdk_V1_OpenApplicationMetadata.with { $0.id = request.id }
        .serializedData()
    }

    let op = await operationStore.createOperation(name: opName, metadata: metadata)

    // Schedule actual open on background task (coordinator runs on @MainActor internally)
    Task {
      do {
        let app = try await AutomationCoordinator.shared.handleOpenApplication(
          identifier: request.id)
        await stateStore.addTarget(app)

        let response = Macosusesdk_V1_OpenApplicationResponse.with {
          $0.application = app
        }

        try await operationStore.finishOperation(name: opName, responseMessage: response)
      } catch {
        // mark operation as done with an error in the response's metadata
        var errOp = await operationStore.getOperation(name: opName) ?? op
        errOp.done = true
        errOp.error = Google_Rpc_Status.with {
          $0.code = 13
          $0.message = "\(error)"
        }
        await operationStore.putOperation(errOp)
      }
    }

    return op
  }

  func getApplication(
    request: Macosusesdk_V1_GetApplicationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Application {
    fputs("info: [MacosUseServiceProvider] getApplication called\n", stderr)
    let pid = try parsePID(fromName: request.name)
    guard let app = await stateStore.getTarget(pid: pid) else {
      throw GRPCStatus(code: .notFound, message: "Application not found")
    }
    return app
  }

  func listApplications(
    request: Macosusesdk_V1_ListApplicationsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ListApplicationsResponse {
    fputs("info: [MacosUseServiceProvider] listApplications called\n", stderr)
    let apps = await stateStore.listTargets()
    return Macosusesdk_V1_ListApplicationsResponse.with {
      $0.applications = apps
    }
  }

  func deleteApplication(
    request: Macosusesdk_V1_DeleteApplicationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
    fputs("info: [MacosUseServiceProvider] deleteApplication called\n", stderr)
    let pid = try parsePID(fromName: request.name)
    _ = await stateStore.removeTarget(pid: pid)
    return SwiftProtobuf.Google_Protobuf_Empty()
  }

  // MARK: - Input Methods

  func createInput(request: Macosusesdk_V1_CreateInputRequest, context: GRPCAsyncServerCallContext)
    async throws -> Macosusesdk_V1_Input
  {
    fputs("info: [MacosUseServiceProvider] createInput called\n", stderr)

    let inputId = request.inputID.isEmpty ? UUID().uuidString : request.inputID
    let pid: pid_t? = request.parent.isEmpty ? nil : try parsePID(fromName: request.parent)
    let name =
      request.parent.isEmpty ? "desktopInputs/\(inputId)" : "\(request.parent)/inputs/\(inputId)"

    let input = Macosusesdk_V1_Input.with {
      $0.name = name
      $0.action = request.input.action
      $0.state = .pending
      $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
    }

    await stateStore.addInput(input)

    // Update to executing
    var executingInput = input
    executingInput.state = .executing
    await stateStore.addInput(executingInput)

    do {
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: request.input.action,
        pid: pid,
        showAnimation: request.input.action.showAnimation,
        animationDuration: request.input.action.animationDuration
      )
      // Update to completed
      var completedInput = executingInput
      completedInput.state = .completed
      completedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
      await stateStore.addInput(completedInput)
      return completedInput
    } catch {
      // Update to failed
      var failedInput = executingInput
      failedInput.state = .failed
      failedInput.error = error.localizedDescription
      failedInput.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
      await stateStore.addInput(failedInput)
      return failedInput
    }
  }

  func getInput(request: Macosusesdk_V1_GetInputRequest, context: GRPCAsyncServerCallContext)
    async throws -> Macosusesdk_V1_Input
  {
    fputs("info: [MacosUseServiceProvider] getInput called\n", stderr)
    guard let input = await stateStore.getInput(name: request.name) else {
      throw GRPCStatus(code: .notFound, message: "Input not found")
    }
    return input
  }

  func listInputs(request: Macosusesdk_V1_ListInputsRequest, context: GRPCAsyncServerCallContext)
    async throws -> Macosusesdk_V1_ListInputsResponse
  {
    fputs("info: [MacosUseServiceProvider] listInputs called\n", stderr)
    let inputs = await stateStore.listInputs(parent: request.parent)
    return Macosusesdk_V1_ListInputsResponse.with {
      $0.inputs = inputs
    }
  }

  // MARK: - Custom Methods

  func traverseAccessibility(
    request: Macosusesdk_V1_TraverseAccessibilityRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_TraverseAccessibilityResponse {
    fputs("info: [MacosUseServiceProvider] traverseAccessibility called\n", stderr)
    let pid = try parsePID(fromName: request.name)
    return try await AutomationCoordinator.shared.handleTraverse(
      pid: pid, visibleOnly: request.visibleOnly)
  }

  func watchAccessibility(
    request: Macosusesdk_V1_WatchAccessibilityRequest,
    responseStream: GRPCAsyncResponseStreamWriter<Macosusesdk_V1_WatchAccessibilityResponse>,
    context: GRPCAsyncServerCallContext
  ) async throws {
    fputs("info: [MacosUseServiceProvider] watchAccessibility called\n", stderr)

    let pid = try parsePID(fromName: request.name)
    let pollInterval = request.pollInterval > 0 ? request.pollInterval : 1.0

    var previous: [Macosusesdk_Type_Element] = []

    while !Task.isCancelled {
      do {
        let trav = try await AutomationCoordinator.shared.handleTraverse(
          pid: pid, visibleOnly: request.visibleOnly)

        // Naive diff: if previous empty, send all as added; otherwise send elements as modified
        let resp = Macosusesdk_V1_WatchAccessibilityResponse.with {
          if previous.isEmpty {
            $0.added = trav.elements
          } else {
            $0.modified = trav.elements.map { element in
              Macosusesdk_V1_ModifiedElement.with {
                $0.oldElement = Macosusesdk_Type_Element()
                $0.newElement = element
              }
            }
          }
        }

        try await responseStream.send(resp)
        previous = trav.elements
      } catch {
        // send an empty heartbeat to keep client alive
        let _ = try? await responseStream.send(Macosusesdk_V1_WatchAccessibilityResponse())
      }

      // Sleep for interval, but allow task cancellation to stop
      try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
  }

  // MARK: - Window Methods

  func getWindow(
    request: Macosusesdk_V1_GetWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Window {
    fputs("info: [MacosUseServiceProvider] getWindow called\n", stderr)
    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/")
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let registry = WindowRegistry()
    try await registry.refreshWindows(forPID: pid)

    guard let windowInfo = try await registry.getWindow(windowId) else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

    // Get AXUIElement for additional state
    let windowElement = try findWindowElement(pid: pid, windowId: windowId)
    let (minimized, focused, fullscreen) = getWindowState(window: windowElement)

    return Macosusesdk_V1_Window.with {
      $0.name = request.name
      $0.title = windowInfo.title
      $0.bounds = Macosusesdk_V1_Bounds.with {
        $0.x = windowInfo.bounds.origin.x
        $0.y = windowInfo.bounds.origin.y
        $0.width = windowInfo.bounds.size.width
        $0.height = windowInfo.bounds.size.height
      }
      $0.zIndex = Int32(windowInfo.layer)
      $0.visible = windowInfo.isOnScreen
      $0.minimized = minimized
      $0.focused = focused
      $0.fullscreen = fullscreen
      $0.state = Macosusesdk_V1_WindowState()  // TODO: Query window attributes
    }
  }

  func listWindows(
    request: Macosusesdk_V1_ListWindowsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ListWindowsResponse {
    fputs("info: [MacosUseServiceProvider] listWindows called\n", stderr)

    // Parse "applications/{pid}"
    let pid = try parsePID(fromName: request.parent)

    let registry = WindowRegistry()
    try await registry.refreshWindows(forPID: pid)
    let windowInfos = try await registry.listWindows(forPID: pid)

    let windows = windowInfos.map { windowInfo in
      Macosusesdk_V1_Window.with {
        $0.name = "applications/\(pid)/windows/\(windowInfo.windowID)"
        $0.title = windowInfo.title
        $0.bounds = Macosusesdk_V1_Bounds.with {
          $0.x = windowInfo.bounds.origin.x
          $0.y = windowInfo.bounds.origin.y
          $0.width = windowInfo.bounds.size.width
          $0.height = windowInfo.bounds.size.height
        }
        $0.zIndex = Int32(windowInfo.layer)
        $0.visible = windowInfo.isOnScreen
        $0.minimized = false
        $0.focused = false
        $0.fullscreen = false
        $0.state = Macosusesdk_V1_WindowState()
      }
    }

    return Macosusesdk_V1_ListWindowsResponse.with {
      $0.windows = windows
    }
  }

  func focusWindow(
    request: Macosusesdk_V1_FocusWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Window {
    fputs("info: [MacosUseServiceProvider] focusWindow called\n", stderr)

    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let windowToFocus = try findWindowElement(pid: pid, windowId: windowId)

    // Set kAXMainAttribute to true to focus the window
    let mainResult = AXUIElementSetAttributeValue(
      windowToFocus, kAXMainAttribute as CFString, kCFBooleanTrue)
    guard mainResult == .success else {
      throw GRPCStatus(code: .internalError, message: "Failed to focus window")
    }

    // Return updated window state
    return try await getWindow(
      request: Macosusesdk_V1_GetWindowRequest.with { $0.name = request.name }, context: context)
  }

  func moveWindow(
    request: Macosusesdk_V1_MoveWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Window {
    fputs("info: [MacosUseServiceProvider] moveWindow called\n", stderr)

    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let window = try findWindowElement(pid: pid, windowId: windowId)

    // Create AXValue for new position
    var newPosition = CGPoint(x: request.x, y: request.y)
    guard let positionValue = AXValueCreate(.cgPoint, &newPosition) else {
      throw GRPCStatus(code: .internalError, message: "Failed to create position value")
    }

    // Set position
    let setResult = AXUIElementSetAttributeValue(
      window, kAXPositionAttribute as CFString, positionValue)
    guard setResult == .success else {
      throw GRPCStatus(
        code: .internalError, message: "Failed to move window: \(setResult.rawValue)")
    }

    // Return updated window state
    return try await getWindow(
      request: Macosusesdk_V1_GetWindowRequest.with { $0.name = request.name }, context: context)
  }

  func resizeWindow(
    request: Macosusesdk_V1_ResizeWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Window {
    fputs("info: [MacosUseServiceProvider] resizeWindow called\n", stderr)

    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let window = try findWindowElement(pid: pid, windowId: windowId)

    // Create AXValue for new size
    var newSize = CGSize(width: request.width, height: request.height)
    guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
      throw GRPCStatus(code: .internalError, message: "Failed to create size value")
    }

    // Set size
    let setResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    guard setResult == .success else {
      throw GRPCStatus(
        code: .internalError, message: "Failed to resize window: \(setResult.rawValue)")
    }

    // Return updated window state
    return try await getWindow(
      request: Macosusesdk_V1_GetWindowRequest.with { $0.name = request.name }, context: context)
  }

  func minimizeWindow(
    request: Macosusesdk_V1_MinimizeWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Window {
    fputs("info: [MacosUseServiceProvider] minimizeWindow called\n", stderr)

    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let window = try findWindowElement(pid: pid, windowId: windowId)

    // Set kAXMinimizedAttribute to true
    let setResult = AXUIElementSetAttributeValue(
      window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    guard setResult == .success else {
      throw GRPCStatus(
        code: .internalError, message: "Failed to minimize window: \(setResult.rawValue)")
    }

    // Return updated window state
    return try await getWindow(
      request: Macosusesdk_V1_GetWindowRequest.with { $0.name = request.name }, context: context)
  }

  func restoreWindow(
    request: Macosusesdk_V1_RestoreWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Window {
    fputs("info: [MacosUseServiceProvider] restoreWindow called\n", stderr)

    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let window = try findWindowElement(pid: pid, windowId: windowId)

    // Set kAXMinimizedAttribute to false
    let setResult = AXUIElementSetAttributeValue(
      window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    guard setResult == .success else {
      throw GRPCStatus(
        code: .internalError, message: "Failed to restore window: \(setResult.rawValue)")
    }

    // Return updated window state
    return try await getWindow(
      request: Macosusesdk_V1_GetWindowRequest.with { $0.name = request.name }, context: context)
  }

  func closeWindow(
    request: Macosusesdk_V1_CloseWindowRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CloseWindowResponse {
    fputs("info: [MacosUseServiceProvider] closeWindow called\n", stderr)

    // Parse "applications/{pid}/windows/{windowId}"
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowId = CGWindowID(components[3])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid window name format")
    }

    let window = try findWindowElement(pid: pid, windowId: windowId)

    // Get close button
    var closeButtonValue: CFTypeRef?
    let closeResult = AXUIElementCopyAttributeValue(
      window, kAXCloseButtonAttribute as CFString, &closeButtonValue)
    guard closeResult == .success, let closeButton = closeButtonValue as! AXUIElement? else {
      throw GRPCStatus(code: .internalError, message: "Failed to get close button")
    }

    // Press the close button
    let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    guard pressResult == .success else {
      throw GRPCStatus(
        code: .internalError, message: "Failed to close window: \(pressResult.rawValue)")
    }

    return Macosusesdk_V1_CloseWindowResponse()
  }

  // MARK: - Element Methods

  func findElements(
    request: Macosusesdk_V1_FindElementsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_FindElementsResponse {
    fputs("info: [MacosUseServiceProvider] findElements called\n", stderr)

    // Validate and parse the selector
    let selector = try SelectorParser.shared.parseSelector(request.selector)

    // Find elements using ElementLocator
    let elementsWithPaths = try await ElementLocator.shared.findElements(
      selector: selector,
      parent: request.parent,
      visibleOnly: request.visibleOnly,
      maxResults: Int(request.pageSize)
    )

    // Convert to proto elements and register them
    var elements: [Macosusesdk_Type_Element] = []
    let pid = try parsePID(fromName: request.parent)
    for (element, path) in elementsWithPaths {
      let protoElement = element
      // Generate and assign element ID
      let elementId = await ElementRegistry.shared.registerElement(protoElement, pid: pid)
      var protoWithId = protoElement
      protoWithId.elementID = elementId
      protoWithId.path = path
      elements.append(protoWithId)
    }

    return Macosusesdk_V1_FindElementsResponse.with {
      $0.elements = elements
      // TODO: Implement pagination with next_page_token
      $0.nextPageToken = ""
    }
  }

  func findRegionElements(
    request: Macosusesdk_V1_FindRegionElementsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_FindRegionElementsResponse {
    fputs("info: [MacosUseServiceProvider] findRegionElements called\n", stderr)

    // Validate selector if provided
    let selector =
      request.hasSelector ? try SelectorParser.shared.parseSelector(request.selector) : nil

    // Find elements in region using ElementLocator
    let elementsWithPaths = try await ElementLocator.shared.findElementsInRegion(
      region: request.region,
      selector: selector,
      parent: request.parent,
      visibleOnly: false,  // Region search doesn't have visibleOnly parameter
      maxResults: Int(request.pageSize)
    )

    // Convert to proto elements and register them
    var elements: [Macosusesdk_Type_Element] = []
    let pid = try parsePID(fromName: request.parent)
    for (element, path) in elementsWithPaths {
      let protoElement = element
      // Generate and assign element ID
      let elementId = await ElementRegistry.shared.registerElement(protoElement, pid: pid)
      var protoWithId = protoElement
      protoWithId.elementID = elementId
      protoWithId.path = path
      elements.append(protoWithId)
    }

    return Macosusesdk_V1_FindRegionElementsResponse.with {
      $0.elements = elements
      // TODO: Implement pagination with next_page_token
      $0.nextPageToken = ""
    }
  }

  func getElement(
    request: Macosusesdk_V1_GetElementRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_Type_Element {
    fputs("info: [MacosUseServiceProvider] getElement called\n", stderr)

    return try await ElementLocator.shared.getElement(name: request.name)
  }

  func clickElement(
    request: Macosusesdk_V1_ClickElementRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ClickElementResponse {
    fputs("info: [MacosUseServiceProvider] clickElement called\n", stderr)

    let element: Macosusesdk_Type_Element
    let pid: pid_t

    // Find the element to click
    switch request.target {
    case .elementID(let elementId):
      // Get element by ID
      guard let foundElement = await ElementRegistry.shared.getElement(elementId) else {
        throw GRPCStatus(code: .notFound, message: "Element not found")
      }
      element = foundElement
      pid = try parsePID(fromName: request.parent)

    case .selector(let selector):
      // Find element by selector
      let validatedSelector = try SelectorParser.shared.parseSelector(selector)
      let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: validatedSelector,
        parent: request.parent,
        visibleOnly: true,
        maxResults: 1
      )

      guard let firstElement = elementsWithPaths.first else {
        throw GRPCStatus(code: .notFound, message: "No element found matching selector")
      }

      element = firstElement.element
      pid = try parsePID(fromName: request.parent)

    case .none:
      throw GRPCStatus(
        code: .invalidArgument, message: "Either element_id or selector must be specified")
    }

    // Get element position for clicking
    guard element.hasX && element.hasY else {
      throw GRPCStatus(code: .failedPrecondition, message: "Element has no position information")
    }
    let x = element.x
    let y = element.y

    // Determine click type
    let clickType = request.clickType

    // Perform the click using AutomationCoordinator
    switch clickType {
    case .single, .unspecified, .UNRECOGNIZED(_):
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macosusesdk_V1_InputAction.with {
          $0.inputType = .click(
            Macosusesdk_V1_MouseClick.with {
              $0.position = Macosusesdk_Type_Point.with {
                $0.x = x
                $0.y = y
              }
              $0.clickType = .left
              $0.clickCount = 1
            })
        },
        pid: pid,
        showAnimation: false,
        animationDuration: 0
      )

    case .double:
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macosusesdk_V1_InputAction.with {
          $0.inputType = .click(
            Macosusesdk_V1_MouseClick.with {
              $0.position = Macosusesdk_Type_Point.with {
                $0.x = x
                $0.y = y
              }
              $0.clickType = .left
              $0.clickCount = 2
            })
        },
        pid: pid,
        showAnimation: false,
        animationDuration: 0
      )

    case .right:
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macosusesdk_V1_InputAction.with {
          $0.inputType = .click(
            Macosusesdk_V1_MouseClick.with {
              $0.position = Macosusesdk_Type_Point.with {
                $0.x = x
                $0.y = y
              }
              $0.clickType = .right
              $0.clickCount = 1
            })
        },
        pid: pid,
        showAnimation: false,
        animationDuration: 0
      )
    }

    return Macosusesdk_V1_ClickElementResponse.with {
      $0.success = true
      $0.element = element
    }
  }

  func writeElementValue(
    request: Macosusesdk_V1_WriteElementValueRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_WriteElementValueResponse {
    fputs("info: [MacosUseServiceProvider] writeElementValue called\n", stderr)

    let element: Macosusesdk_Type_Element
    let pid: pid_t

    // Find the element to modify
    switch request.target {
    case .elementID(let elementId):
      guard let foundElement = await ElementRegistry.shared.getElement(elementId) else {
        throw GRPCStatus(code: .notFound, message: "Element not found")
      }
      element = foundElement
      pid = try parsePID(fromName: request.parent)

    case .selector(let selector):
      let validatedSelector = try SelectorParser.shared.parseSelector(selector)
      let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: validatedSelector,
        parent: request.parent,
        visibleOnly: true,
        maxResults: 1
      )

      guard let firstElement = elementsWithPaths.first else {
        throw GRPCStatus(code: .notFound, message: "No element found matching selector")
      }

      element = firstElement.element
      pid = try parsePID(fromName: request.parent)

    case .none:
      throw GRPCStatus(
        code: .invalidArgument, message: "Either element_id or selector must be specified")
    }

    // Get element position for typing
    guard element.hasX && element.hasY else {
      throw GRPCStatus(code: .failedPrecondition, message: "Element has no position information")
    }
    let x = element.x
    let y = element.y

    // Click on the element first to focus it
    try await AutomationCoordinator.shared.handleExecuteInput(
      action: Macosusesdk_V1_InputAction.with {
        $0.inputType = .click(
          Macosusesdk_V1_MouseClick.with {
            $0.position = Macosusesdk_Type_Point.with {
              $0.x = x
              $0.y = y
            }
            $0.clickType = .left
            $0.clickCount = 1
          })
      },
      pid: pid,
      showAnimation: false,
      animationDuration: 0
    )

    // Type the value
    try await AutomationCoordinator.shared.handleExecuteInput(
      action: Macosusesdk_V1_InputAction.with {
        $0.inputType = .typeText(
          Macosusesdk_V1_TextInput.with {
            $0.text = request.value
          })
      },
      pid: pid,
      showAnimation: false,
      animationDuration: 0
    )

    return Macosusesdk_V1_WriteElementValueResponse.with {
      $0.success = true
      $0.element = element
    }
  }

  @MainActor
  func getElementActions(
    request: Macosusesdk_V1_GetElementActionsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ElementActions {
    fputs("info: [MacosUseServiceProvider] getElementActions called\n", stderr)

    // Parse element name to get element ID
    let components = request.name.split(separator: "/").map(String.init)
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "elements"
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid element name format")
    }

    let elementId = components[3]

    // Get element from registry
    guard let element = await ElementRegistry.shared.getElement(elementId) else {
      throw GRPCStatus(code: .notFound, message: "Element not found")
    }

    // Try to get actions from AXUIElement first
    if let axElement = await ElementRegistry.shared.getAXElement(elementId) {
      // Query the AXUIElement for its actions
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(axElement, "AXActions" as CFString, &value) == .success
      else {
        // Fallback to role-based if query fails
        let actions = getActionsForRole(element.role)
        return Macosusesdk_V1_ElementActions.with { $0.actions = actions }
      }

      if let actionsArray = value as? [String] {
        return Macosusesdk_V1_ElementActions.with {
          $0.actions = actionsArray
        }
      }
    }

    // Fallback to role-based actions
    let actions = getActionsForRole(element.role)

    return Macosusesdk_V1_ElementActions.with {
      $0.actions = actions
    }
  }

  @MainActor
  func performElementAction(
    request: Macosusesdk_V1_PerformElementActionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_PerformElementActionResponse {
    fputs("info: [MacosUseServiceProvider] performElementAction called\n", stderr)

    let element: Macosusesdk_Type_Element
    let elementID: String
    let pid: pid_t

    // Find the element
    switch request.target {
    case .elementID(let id):
      guard let foundElement = await ElementRegistry.shared.getElement(id) else {
        throw GRPCStatus(code: .notFound, message: "Element not found")
      }
      element = foundElement
      elementID = id
      pid = try parsePID(fromName: request.parent)

    case .selector(let selector):
      let validatedSelector = try SelectorParser.shared.parseSelector(selector)
      let elementsWithPaths = try await ElementLocator.shared.findElements(
        selector: validatedSelector,
        parent: request.parent,
        visibleOnly: true,
        maxResults: 1
      )

      guard let firstElement = elementsWithPaths.first else {
        throw GRPCStatus(code: .notFound, message: "No element found matching selector")
      }

      element = firstElement.element
      elementID = element.elementID
      pid = try parsePID(fromName: request.parent)

    case .none:
      throw GRPCStatus(
        code: .invalidArgument, message: "Either element_id or selector must be specified")
    }

    // Try to get the AXUIElement and perform semantic action
    if let axElement = await ElementRegistry.shared.getAXElement(elementID) {
      let actionName: String

      // Map common action names to AX action constants
      switch request.action.lowercased() {
      case "press", "click":
        actionName = kAXPressAction as String
      case "showmenu", "openmenu":
        actionName = kAXShowMenuAction as String
      default:
        actionName = request.action
      }

      // Perform the AX action
      let result = AXUIElementPerformAction(axElement, actionName as CFString)

      if result == .success {
        return Macosusesdk_V1_PerformElementActionResponse.with {
          $0.success = true
          $0.element = element
        }
      }

      // If action failed but element has position, fall through to coordinate-based fallback
      if !element.hasX || !element.hasY {
        throw GRPCStatus(
          code: .internalError,
          message: "AX action failed: \(result.rawValue) and no position available for fallback")
      }
    }

    // Fallback to coordinate-based simulation if AXUIElement is nil or action failed
    guard element.hasX && element.hasY else {
      throw GRPCStatus(
        code: .failedPrecondition, message: "Element has no AXUIElement and no position for action")
    }

    let x = element.x
    let y = element.y

    switch request.action.lowercased() {
    case "press", "click":
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macosusesdk_V1_InputAction.with {
          $0.inputType = .click(
            Macosusesdk_V1_MouseClick.with {
              $0.position = Macosusesdk_Type_Point.with {
                $0.x = x
                $0.y = y
              }
              $0.clickType = .left
              $0.clickCount = 1
            })
        },
        pid: pid,
        showAnimation: false,
        animationDuration: 0
      )

    case "showmenu", "openmenu":
      try await AutomationCoordinator.shared.handleExecuteInput(
        action: Macosusesdk_V1_InputAction.with {
          $0.inputType = .click(
            Macosusesdk_V1_MouseClick.with {
              $0.position = Macosusesdk_Type_Point.with {
                $0.x = x
                $0.y = y
              }
              $0.clickType = .right
              $0.clickCount = 1
            })
        },
        pid: pid,
        showAnimation: false,
        animationDuration: 0
      )

    default:
      throw GRPCStatus(
        code: .unimplemented, message: "Action '\(request.action)' is not implemented")
    }

    return Macosusesdk_V1_PerformElementActionResponse.with {
      $0.success = true
      $0.element = element
    }
  }

  func waitElement(
    request: Macosusesdk_V1_WaitElementRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    fputs("info: [MacosUseServiceProvider] waitElement called (LRO)\n", stderr)

    // Validate selector
    let selector = try SelectorParser.shared.parseSelector(request.selector)

    // Create LRO
    let opName = "operations/waitElement/\(UUID().uuidString)"
    let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
      $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementMetadata"
      $0.value = try Macosusesdk_V1_WaitElementMetadata.with {
        $0.selector = selector
        $0.attempts = 0
      }.serializedData()
    }

    let op = await operationStore.createOperation(name: opName, metadata: metadata)

    // Start background task
    Task {
      do {
        let timeout = request.timeout > 0 ? request.timeout : 30.0
        let pollInterval = request.pollInterval > 0 ? request.pollInterval : 0.5
        let endTime = Date().timeIntervalSince1970 + timeout
        var attempts = 0

        while Date().timeIntervalSince1970 < endTime {
          attempts += 1

          // Update metadata with attempt count
          let updatedMetadata = Macosusesdk_V1_WaitElementMetadata.with {
            $0.selector = selector
            $0.attempts = Int32(attempts)
          }
          var updatedOp = await operationStore.getOperation(name: opName) ?? op
          updatedOp.metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementMetadata"
            $0.value = try updatedMetadata.serializedData()
          }
          await operationStore.putOperation(updatedOp)

          // Try to find the element
          let elementsWithPaths = try await ElementLocator.shared.findElements(
            selector: selector,
            parent: request.parent,
            visibleOnly: true,
            maxResults: 1
          )

          if let firstElement = elementsWithPaths.first {
            // Element found! Complete the operation
            var elementWithId = firstElement.element
            let elementId = await ElementRegistry.shared.registerElement(
              elementWithId, pid: try parsePID(fromName: request.parent))
            elementWithId.elementID = elementId
            elementWithId.path = firstElement.path

            let response = Macosusesdk_V1_WaitElementResponse.with {
              $0.element = elementWithId
            }

            try await operationStore.finishOperation(name: opName, responseMessage: response)
            return
          }

          // Wait before next attempt
          try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // Timeout - mark operation as failed
        var failedOp = await operationStore.getOperation(name: opName) ?? op
        failedOp.done = true
        failedOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.deadlineExceeded.rawValue)
          $0.message = "Element did not appear within timeout"
        }
        await operationStore.putOperation(failedOp)

      } catch {
        // Mark operation as failed
        var errOp = await operationStore.getOperation(name: opName) ?? op
        errOp.done = true
        errOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.internalError.rawValue)
          $0.message = "\(error)"
        }
        await operationStore.putOperation(errOp)
      }
    }

    return op
  }

  func waitElementState(
    request: Macosusesdk_V1_WaitElementStateRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    fputs("info: [MacosUseServiceProvider] waitElementState called (LRO)\n", stderr)

    // Store the original selector for re-running, or create one for elementId case
    let selectorToUse: Macosusesdk_Type_ElementSelector
    let pid: pid_t

    switch request.target {
    case .elementID(let elementID):
      guard let foundElement = await ElementRegistry.shared.getElement(elementID) else {
        throw GRPCStatus(code: .notFound, message: "Element not found")
      }
      pid = try parsePID(fromName: request.parent)

      // Create a selector based on the element's stable attributes
      // This is a fallback - ideally we'd store the original selector
      selectorToUse = Macosusesdk_Type_ElementSelector.with {
        $0.criteria = .role(foundElement.role)
        // Add more criteria if available for uniqueness
        if foundElement.hasText && !foundElement.text.isEmpty {
          $0.criteria = .compound(
            Macosusesdk_Type_CompoundSelector.with {
              $0.operator = .and
              $0.selectors = [
                Macosusesdk_Type_ElementSelector.with { $0.criteria = .role(foundElement.role) },
                Macosusesdk_Type_ElementSelector.with { $0.criteria = .text(foundElement.text) },
              ]
            })
        }
      }

    case .selector(let selector):
      selectorToUse = try SelectorParser.shared.parseSelector(selector)
      pid = try parsePID(fromName: request.parent)

    case .none:
      throw GRPCStatus(
        code: .invalidArgument, message: "Either element_id or selector must be specified")
    }

    // Create LRO
    let opName = "operations/waitElementState/\(UUID().uuidString)"
    let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
      $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementStateMetadata"
      $0.value = try Macosusesdk_V1_WaitElementStateMetadata.with {
        $0.condition = request.condition
        $0.attempts = 0
      }.serializedData()
    }

    let op = await operationStore.createOperation(name: opName, metadata: metadata)

    // Start background task
    Task {
      do {
        let timeout = request.timeout > 0 ? request.timeout : 30.0
        let pollInterval = request.pollInterval > 0 ? request.pollInterval : 0.5
        let endTime = Date().timeIntervalSince1970 + timeout
        var attempts = 0

        while Date().timeIntervalSince1970 < endTime {
          attempts += 1

          // Update metadata with attempt count
          let updatedMetadata = Macosusesdk_V1_WaitElementStateMetadata.with {
            $0.condition = request.condition
            $0.attempts = Int32(attempts)
          }
          var updatedOp = await operationStore.getOperation(name: opName) ?? op
          updatedOp.metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = "type.googleapis.com/macosusesdk.v1.WaitElementStateMetadata"
            $0.value = try updatedMetadata.serializedData()
          }
          await operationStore.putOperation(updatedOp)

          // Re-run the selector to find the current element
          let elementsWithPaths = try await ElementLocator.shared.findElements(
            selector: selectorToUse,
            parent: request.parent,
            visibleOnly: true,
            maxResults: 1
          )

          if let currentElementWithPath = elementsWithPaths.first,
            elementMatchesCondition(currentElementWithPath.element, condition: request.condition)
          {

            // Condition met! Complete the operation
            var elementWithId = currentElementWithPath.element
            let elementId = await ElementRegistry.shared.registerElement(elementWithId, pid: pid)
            elementWithId.elementID = elementId
            elementWithId.path = currentElementWithPath.path

            let response = Macosusesdk_V1_WaitElementStateResponse.with {
              $0.element = elementWithId
            }

            try await operationStore.finishOperation(name: opName, responseMessage: response)
            return
          }

          // Wait before next attempt
          try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // Timeout - mark operation as failed
        var failedOp = await operationStore.getOperation(name: opName) ?? op
        failedOp.done = true
        failedOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.deadlineExceeded.rawValue)
          $0.message = "Element did not reach expected state within timeout"
        }
        await operationStore.putOperation(failedOp)

      } catch {
        // Mark operation as failed
        var errOp = await operationStore.getOperation(name: opName) ?? op
        errOp.done = true
        errOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.internalError.rawValue)
          $0.message = "\(error)"
        }
        await operationStore.putOperation(errOp)
      }
    }

    return op
  }

  // MARK: - Observation Methods

  func createObservation(
    request: Macosusesdk_V1_CreateObservationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    fputs("info: [MacosUseServiceProvider] createObservation called (LRO)\n", stderr)

    // Parse parent resource name to get PID
    let pid = try parsePID(fromName: request.parent)

    // Generate observation ID
    let observationId =
      request.observationID.isEmpty ? UUID().uuidString : request.observationID
    let observationName = "\(request.parent)/observations/\(observationId)"

    // Create operation for LRO
    let opName = "operations/observation/\(observationId)"

    // Create initial observation in ObservationManager
    let observation = await ObservationManager.shared.createObservation(
      name: observationName,
      type: request.observation.type,
      parent: request.parent,
      filter: request.observation.hasFilter ? request.observation.filter : nil,
      pid: pid
    )

    // Create metadata
    let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
      $0.typeURL = "type.googleapis.com/macosusesdk.v1.Observation"
      $0.value = try observation.serializedData()
    }

    // Create LRO
    let op = await operationStore.createOperation(name: opName, metadata: metadata)

    // Start observation in background
    Task {
      do {
        // Start the observation
        try await ObservationManager.shared.startObservation(name: observationName)

        // Get updated observation
        guard
          let startedObservation = await ObservationManager.shared.getObservation(
            name: observationName)
        else {
          throw GRPCStatus(code: .internalError, message: "Failed to start observation")
        }

        // Mark operation as done with observation in response
        try await operationStore.finishOperation(name: opName, responseMessage: startedObservation)

      } catch {
        // Mark operation as failed
        var errOp = await operationStore.getOperation(name: opName) ?? op
        errOp.done = true
        errOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.internalError.rawValue)
          $0.message = "\(error)"
        }
        await operationStore.putOperation(errOp)
      }
    }

    return op
  }

  func getObservation(
    request: Macosusesdk_V1_GetObservationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Observation {
    fputs("info: [MacosUseServiceProvider] getObservation called\n", stderr)

    // Get observation from ObservationManager
    guard let observation = await ObservationManager.shared.getObservation(name: request.name)
    else {
      throw GRPCStatus(code: .notFound, message: "Observation not found")
    }

    return observation
  }

  func listObservations(
    request: Macosusesdk_V1_ListObservationsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ListObservationsResponse {
    fputs("info: [MacosUseServiceProvider] listObservations called\n", stderr)

    // List observations for parent
    let observations = await ObservationManager.shared.listObservations(parent: request.parent)

    return Macosusesdk_V1_ListObservationsResponse.with {
      $0.observations = observations
      // TODO: Implement pagination with next_page_token
      $0.nextPageToken = ""
    }
  }

  func cancelObservation(
    request: Macosusesdk_V1_CancelObservationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Observation {
    fputs("info: [MacosUseServiceProvider] cancelObservation called\n", stderr)

    // Cancel observation in ObservationManager
    guard
      let observation = await ObservationManager.shared.cancelObservation(name: request.name)
    else {
      throw GRPCStatus(code: .notFound, message: "Observation not found")
    }

    return observation
  }

  func streamObservations(
    request: Macosusesdk_V1_StreamObservationsRequest,
    responseStream: GRPCAsyncResponseStreamWriter<Macosusesdk_V1_StreamObservationsResponse>,
    context: GRPCAsyncServerCallContext
  ) async throws {
    fputs("info: [MacosUseServiceProvider] streamObservations called (streaming)\n", stderr)

    // Verify observation exists
    guard await ObservationManager.shared.getObservation(name: request.name) != nil else {
      throw GRPCStatus(code: .notFound, message: "Observation not found")
    }

    // Create event stream
    guard let eventStream = await ObservationManager.shared.createEventStream(name: request.name)
    else {
      throw GRPCStatus(code: .notFound, message: "Failed to create event stream")
    }

    // Stream events to client
    for await event in eventStream {
      // Check if client disconnected
      if Task.isCancelled {
        fputs(
          "info: [MacosUseServiceProvider] client disconnected from observation stream\n", stderr)
        break
      }

      // Send event to client
      let response = Macosusesdk_V1_StreamObservationsResponse.with {
        $0.event = event
      }

      try await responseStream.send(response)
    }
  }

  // MARK: - Session Methods

  func createSession(
    request: Macosusesdk_V1_CreateSessionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Session {
    fputs("info: [MacosUseServiceProvider] createSession called\n", stderr)

    // Extract session parameters from request
    let sessionId = request.sessionID.isEmpty ? nil : request.sessionID
    let displayName =
      request.session.displayName.isEmpty ? "Unnamed Session" : request.session.displayName
    let metadata = request.session.metadata

    // Create session in SessionManager
    let session = await SessionManager.shared.createSession(
      sessionId: sessionId,
      displayName: displayName,
      metadata: metadata
    )

    return session
  }

  func getSession(
    request: Macosusesdk_V1_GetSessionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Session {
    fputs("info: [MacosUseServiceProvider] getSession called\n", stderr)

    // Get session from SessionManager
    guard let session = await SessionManager.shared.getSession(name: request.name) else {
      throw GRPCStatus(code: .notFound, message: "Session not found: \(request.name)")
    }

    return session
  }

  func listSessions(
    request: Macosusesdk_V1_ListSessionsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ListSessionsResponse {
    fputs("info: [MacosUseServiceProvider] listSessions called\n", stderr)

    // List sessions from SessionManager with pagination
    let pageSize = Int(request.pageSize)
    let pageToken = request.pageToken.isEmpty ? nil : request.pageToken

    let (sessions, nextToken) = await SessionManager.shared.listSessions(
      pageSize: pageSize,
      pageToken: pageToken
    )

    return Macosusesdk_V1_ListSessionsResponse.with {
      $0.sessions = sessions
      $0.nextPageToken = nextToken ?? ""
    }
  }

  func deleteSession(
    request: Macosusesdk_V1_DeleteSessionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
    fputs("info: [MacosUseServiceProvider] deleteSession called\n", stderr)

    // Delete session from SessionManager
    let deleted = await SessionManager.shared.deleteSession(name: request.name)

    if !deleted {
      throw GRPCStatus(code: .notFound, message: "Session not found: \(request.name)")
    }

    return SwiftProtobuf.Google_Protobuf_Empty()
  }

  func beginTransaction(
    request: Macosusesdk_V1_BeginTransactionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_BeginTransactionResponse {
    fputs("info: [MacosUseServiceProvider] beginTransaction called\n", stderr)

    do {
      // Begin transaction in SessionManager
      let isolationLevel =
        request.isolationLevel == .unspecified ? .serializable : request.isolationLevel
      let timeout = request.timeout > 0 ? request.timeout : 300.0

      let (transactionId, session) = try await SessionManager.shared.beginTransaction(
        sessionName: request.session,
        isolationLevel: isolationLevel,
        timeout: timeout
      )

      return Macosusesdk_V1_BeginTransactionResponse.with {
        $0.transactionID = transactionId
        $0.session = session
      }
    } catch let error as SessionError {
      throw GRPCStatus(code: .failedPrecondition, message: error.description)
    } catch {
      throw GRPCStatus(code: .internalError, message: "Failed to begin transaction: \(error)")
    }
  }

  func commitTransaction(
    request: Macosusesdk_V1_CommitTransactionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CommitTransactionResponse {
    fputs("info: [MacosUseServiceProvider] commitTransaction called\n", stderr)

    do {
      // Commit transaction in SessionManager
      let (session, transaction, operationsCount) = try await SessionManager.shared
        .commitTransaction(
          sessionName: request.name,
          transactionId: request.transactionID
        )

      return Macosusesdk_V1_CommitTransactionResponse.with {
        $0.session = session
        $0.transaction = transaction
        $0.operationsCount = operationsCount
      }
    } catch let error as SessionError {
      throw GRPCStatus(code: .failedPrecondition, message: error.description)
    } catch {
      throw GRPCStatus(code: .internalError, message: "Failed to commit transaction: \(error)")
    }
  }

  func rollbackTransaction(
    request: Macosusesdk_V1_RollbackTransactionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_RollbackTransactionResponse {
    fputs("info: [MacosUseServiceProvider] rollbackTransaction called\n", stderr)

    do {
      // Rollback transaction in SessionManager
      let (session, transaction, operationsCount) = try await SessionManager.shared
        .rollbackTransaction(
          sessionName: request.name,
          transactionId: request.transactionID,
          revisionId: request.revisionID
        )

      return Macosusesdk_V1_RollbackTransactionResponse.with {
        $0.session = session
        $0.transaction = transaction
        $0.operationsCount = operationsCount
      }
    } catch let error as SessionError {
      throw GRPCStatus(code: .failedPrecondition, message: error.description)
    } catch {
      throw GRPCStatus(code: .internalError, message: "Failed to rollback transaction: \(error)")
    }
  }

  func getSessionSnapshot(
    request: Macosusesdk_V1_GetSessionSnapshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_SessionSnapshot {
    fputs("info: [MacosUseServiceProvider] getSessionSnapshot called\n", stderr)

    // Get session snapshot from SessionManager
    guard let snapshot = await SessionManager.shared.getSessionSnapshot(sessionName: request.name)
    else {
      throw GRPCStatus(code: .notFound, message: "Session not found: \(request.name)")
    }

    return snapshot
  }

  // MARK: - Screenshot Methods

  func captureScreenshot(
    request: Macosusesdk_V1_CaptureScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureScreenshotResponse {
    fputs("info: [captureScreenshot] Capturing screen screenshot\n", stderr)

    // Determine display ID (0 = main display, nil = all displays)
    let displayID: CGDirectDisplayID? =
      request.display > 0
      ? CGDirectDisplayID(request.display)
      : nil

    // Determine format (default to PNG)
    let format = request.format == .unspecified ? .png : request.format

    // Capture screen
    let result = try await ScreenshotCapture.captureScreen(
      displayID: displayID,
      format: format,
      quality: request.quality,
      includeOCR: request.includeOcrText
    )

    // Build response
    var response = Macosusesdk_V1_CaptureScreenshotResponse()
    response.imageData = result.data
    response.format = format
    response.width = result.width
    response.height = result.height
    if let ocrText = result.ocrText {
      response.ocrText = ocrText
    }

    fputs(
      "info: [captureScreenshot] Captured \(result.width)x\(result.height) screenshot\n", stderr)
    return response
  }

  func captureWindowScreenshot(
    request: Macosusesdk_V1_CaptureWindowScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureWindowScreenshotResponse {
    fputs("info: [captureWindowScreenshot] Capturing window screenshot\n", stderr)

    // Parse window resource name: applications/{pid}/windows/{windowId}
    let components = request.window.split(separator: "/")
    guard components.count == 4,
      components[0] == "applications",
      components[2] == "windows",
      let pid = pid_t(components[1]),
      let windowIdInt = Int(components[3])
    else {
      throw GRPCStatus(
        code: .invalidArgument,
        message: "Invalid window resource name: \(request.window)"
      )
    }

    // Find window in registry
    let windowInfo = try await windowRegistry.listWindows(forPID: pid).first {
      $0.windowID == CGWindowID(windowIdInt)
    }

    guard let windowInfo = windowInfo else {
      throw GRPCStatus(
        code: .notFound,
        message: "Window not found: \(request.window)"
      )
    }

    // Determine format (default to PNG)
    let format = request.format == .unspecified ? .png : request.format

    // Capture window
    let result = try await ScreenshotCapture.captureWindow(
      windowID: windowInfo.windowID,
      includeShadow: request.includeShadow,
      format: format,
      quality: request.quality,
      includeOCR: request.includeOcrText
    )

    // Build response
    var response = Macosusesdk_V1_CaptureWindowScreenshotResponse()
    response.imageData = result.data
    response.format = format
    response.width = result.width
    response.height = result.height
    response.window = request.window
    if let ocrText = result.ocrText {
      response.ocrText = ocrText
    }

    fputs(
      "info: [captureWindowScreenshot] Captured \(result.width)x\(result.height) window screenshot\n",
      stderr)
    return response
  }

  func captureElementScreenshot(
    request: Macosusesdk_V1_CaptureElementScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureElementScreenshotResponse {
    fputs("info: [captureElementScreenshot] Capturing element screenshot\n", stderr)

    // Get element from registry
    guard let element = await ElementRegistry.shared.getElement(request.elementID) else {
      throw GRPCStatus(
        code: .notFound,
        message: "Element not found: \(request.elementID)"
      )
    }

    // Check element has bounds (x, y, width, height)
    guard element.hasX, element.hasY, element.hasWidth, element.hasHeight else {
      throw GRPCStatus(
        code: .failedPrecondition,
        message: "Element has no bounds: \(request.elementID)"
      )
    }

    // Apply padding if specified
    let padding = CGFloat(request.padding)
    let bounds = CGRect(
      x: element.x - padding,
      y: element.y - padding,
      width: element.width + (padding * 2),
      height: element.height + (padding * 2)
    )

    // Determine format (default to PNG)
    let format = request.format == .unspecified ? .png : request.format

    // Capture element region
    let result = try await ScreenshotCapture.captureRegion(
      bounds: bounds,
      format: format,
      quality: request.quality,
      includeOCR: request.includeOcrText
    )

    // Build response
    var response = Macosusesdk_V1_CaptureElementScreenshotResponse()
    response.imageData = result.data
    response.format = format
    response.width = result.width
    response.height = result.height
    response.elementID = request.elementID
    if let ocrText = result.ocrText {
      response.ocrText = ocrText
    }

    fputs(
      "info: [captureElementScreenshot] Captured \(result.width)x\(result.height) element screenshot\n",
      stderr)
    return response
  }

  func captureRegionScreenshot(
    request: Macosusesdk_V1_CaptureRegionScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureRegionScreenshotResponse {
    fputs("info: [captureRegionScreenshot] Capturing region screenshot\n", stderr)

    // Validate region
    guard request.hasRegion else {
      throw GRPCStatus(
        code: .invalidArgument,
        message: "Region is required"
      )
    }

    // Convert proto Region to CGRect
    let bounds = CGRect(
      x: request.region.x,
      y: request.region.y,
      width: request.region.width,
      height: request.region.height
    )

    // Determine display ID (for multi-monitor setups)
    let displayID: CGDirectDisplayID? =
      request.display > 0
      ? CGDirectDisplayID(request.display)
      : nil

    // Determine format (default to PNG)
    let format = request.format == .unspecified ? .png : request.format

    // Capture region
    let result = try await ScreenshotCapture.captureRegion(
      bounds: bounds,
      displayID: displayID,
      format: format,
      quality: request.quality,
      includeOCR: request.includeOcrText
    )

    // Build response
    var response = Macosusesdk_V1_CaptureRegionScreenshotResponse()
    response.imageData = result.data
    response.format = format
    response.width = result.width
    response.height = result.height
    if let ocrText = result.ocrText {
      response.ocrText = ocrText
    }

    fputs(
      "info: [captureRegionScreenshot] Captured \(result.width)x\(result.height) region screenshot\n",
      stderr)
    return response
  }

  // MARK: - Clipboard Methods

  func getClipboard(
    request: Macosusesdk_V1_GetClipboardRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Clipboard {
    fputs("info: [MacosUseServiceProvider] getClipboard called\n", stderr)

    // Validate resource name (singleton: "clipboard")
    guard request.name == "clipboard" else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid clipboard name: \(request.name)")
    }

    return await ClipboardManager.shared.readClipboard()
  }

  func writeClipboard(
    request: Macosusesdk_V1_WriteClipboardRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_WriteClipboardResponse {
    fputs("info: [MacosUseServiceProvider] writeClipboard called\n", stderr)

    // Validate content
    guard request.hasContent else {
      throw GRPCStatus(code: .invalidArgument, message: "Content is required")
    }

    do {
      // Write to clipboard
      let clipboard = try await ClipboardManager.shared.writeClipboard(
        content: request.content,
        clearExisting: request.clearExisting_p
      )

      return Macosusesdk_V1_WriteClipboardResponse.with {
        $0.success = true
        $0.type = clipboard.content.type
      }
    } catch let error as ClipboardError {
      throw GRPCStatus(code: .internalError, message: error.description)
    } catch {
      throw GRPCStatus(code: .internalError, message: "Failed to write clipboard: \(error)")
    }
  }

  func clearClipboard(
    request: Macosusesdk_V1_ClearClipboardRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ClearClipboardResponse {
    fputs("info: [MacosUseServiceProvider] clearClipboard called\n", stderr)

    await ClipboardManager.shared.clearClipboard()

    return Macosusesdk_V1_ClearClipboardResponse.with {
      $0.success = true
    }
  }

  func getClipboardHistory(
    request: Macosusesdk_V1_GetClipboardHistoryRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ClipboardHistory {
    fputs("info: [MacosUseServiceProvider] getClipboardHistory called\n", stderr)

    // Validate resource name (singleton: "clipboard/history")
    guard request.name == "clipboard/history" else {
      throw GRPCStatus(
        code: .invalidArgument, message: "Invalid clipboard history name: \(request.name)")
    }

    return await ClipboardHistoryManager.shared.getHistory()
  }

  // MARK: - File Dialog Methods

  func automateOpenFileDialog(
    request: Macosusesdk_V1_AutomateOpenFileDialogRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_AutomateOpenFileDialogResponse {
    fputs("info: [MacosUseServiceProvider] automateOpenFileDialog called\n", stderr)

    do {
      let selectedPaths = try await FileDialogAutomation.shared.automateOpenFileDialog(
        filePath: request.filePath.isEmpty ? nil : request.filePath,
        defaultDirectory: request.defaultDirectory.isEmpty ? nil : request.defaultDirectory,
        fileFilters: request.fileFilters,
        allowMultiple: request.allowMultiple
      )

      return Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
        $0.success = true
        $0.selectedPaths = selectedPaths
      }
    } catch let error as FileDialogError {
      return Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
        $0.success = false
        $0.error = error.description
      }
    } catch {
      return Macosusesdk_V1_AutomateOpenFileDialogResponse.with {
        $0.success = false
        $0.error = "Failed to automate open file dialog: \(error.localizedDescription)"
      }
    }
  }

  func automateSaveFileDialog(
    request: Macosusesdk_V1_AutomateSaveFileDialogRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_AutomateSaveFileDialogResponse {
    fputs("info: [MacosUseServiceProvider] automateSaveFileDialog called\n", stderr)

    do {
      let savedPath = try await FileDialogAutomation.shared.automateSaveFileDialog(
        filePath: request.filePath,
        defaultDirectory: request.defaultDirectory.isEmpty ? nil : request.defaultDirectory,
        defaultFilename: request.defaultFilename.isEmpty ? nil : request.defaultFilename,
        confirmOverwrite: request.confirmOverwrite
      )

      return Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
        $0.success = true
        $0.savedPath = savedPath
      }
    } catch let error as FileDialogError {
      return Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
        $0.success = false
        $0.error = error.description
      }
    } catch {
      return Macosusesdk_V1_AutomateSaveFileDialogResponse.with {
        $0.success = false
        $0.error = "Failed to automate save file dialog: \(error.localizedDescription)"
      }
    }
  }

  func selectFile(
    request: Macosusesdk_V1_SelectFileRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_SelectFileResponse {
    fputs("info: [MacosUseServiceProvider] selectFile called\n", stderr)

    do {
      let selectedPath = try await FileDialogAutomation.shared.selectFile(
        filePath: request.filePath,
        revealInFinder: request.revealFinder
      )

      return Macosusesdk_V1_SelectFileResponse.with {
        $0.success = true
        $0.selectedPath = selectedPath
      }
    } catch let error as FileDialogError {
      return Macosusesdk_V1_SelectFileResponse.with {
        $0.success = false
        $0.error = error.description
      }
    } catch {
      return Macosusesdk_V1_SelectFileResponse.with {
        $0.success = false
        $0.error = "Failed to select file: \(error.localizedDescription)"
      }
    }
  }

  func selectDirectory(
    request: Macosusesdk_V1_SelectDirectoryRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_SelectDirectoryResponse {
    fputs("info: [MacosUseServiceProvider] selectDirectory called\n", stderr)

    do {
      let (selectedPath, wasCreated) = try await FileDialogAutomation.shared.selectDirectory(
        directoryPath: request.directoryPath,
        createMissing: request.createMissing
      )

      return Macosusesdk_V1_SelectDirectoryResponse.with {
        $0.success = true
        $0.selectedPath = selectedPath
        $0.created = wasCreated
      }
    } catch let error as FileDialogError {
      return Macosusesdk_V1_SelectDirectoryResponse.with {
        $0.success = false
        $0.error = error.description
      }
    } catch {
      return Macosusesdk_V1_SelectDirectoryResponse.with {
        $0.success = false
        $0.error = "Failed to select directory: \(error.localizedDescription)"
      }
    }
  }

  func dragFiles(
    request: Macosusesdk_V1_DragFilesRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_DragFilesResponse {
    fputs("info: [MacosUseServiceProvider] dragFiles called\n", stderr)

    // Validate inputs
    guard !request.filePaths.isEmpty else {
      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = false
        $0.error = "At least one file path is required"
      }
    }

    guard !request.targetElementID.isEmpty else {
      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = false
        $0.error = "Target element ID is required"
      }
    }

    // Get target element from registry
    guard let targetElement = await ElementRegistry.shared.getElement(request.targetElementID)
    else {
      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = false
        $0.error = "Target element not found: \(request.targetElementID)"
      }
    }

    // Ensure element has position
    guard targetElement.hasX && targetElement.hasY else {
      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = false
        $0.error = "Target element has no position information"
      }
    }

    let targetPoint = CGPoint(x: targetElement.x, y: targetElement.y)
    let duration = request.duration > 0 ? request.duration : 0.5

    do {
      try await FileDialogAutomation.shared.dragFilesToElement(
        filePaths: request.filePaths,
        targetElement: targetPoint,
        duration: duration
      )

      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = true
        $0.filesDropped = Int32(request.filePaths.count)
      }
    } catch let error as FileDialogError {
      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = false
        $0.error = error.description
      }
    } catch {
      return Macosusesdk_V1_DragFilesResponse.with {
        $0.success = false
        $0.error = "Failed to drag files: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Macro Methods

  func createMacro(
    request: Macosusesdk_V1_CreateMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Macro {
    throw GRPCStatus(code: .unimplemented, message: "createMacro not yet implemented")
  }

  func getMacro(
    request: Macosusesdk_V1_GetMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Macro {
    throw GRPCStatus(code: .unimplemented, message: "getMacro not yet implemented")
  }

  func listMacros(
    request: Macosusesdk_V1_ListMacrosRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macrosusesdk_V1_ListMacrosResponse {
    fputs("info: [MacosUseServiceProvider] listMacros called\n", stderr)

    // List macros with pagination
    let pageSize = Int(request.pageSize > 0 ? request.pageSize : 50)
    let pageToken = request.pageToken.isEmpty ? nil : request.pageToken

    let (macros, nextToken) = await MacroRegistry.shared.listMacros(
      pageSize: pageSize,
      pageToken: pageToken
    )

    return Macrosusesdk_V1_ListMacrosResponse.with {
      $0.macros = macros
      $0.nextPageToken = nextToken ?? ""
    }
  }

  func updateMacro(
    request: Macosusesdk_V1_UpdateMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Macro {
    fputs("info: [MacosUseServiceProvider] updateMacro called\n", stderr)

    // Parse field mask to determine what to update
    let updateMask = request.updateMask

    // Extract fields to update from request.macro
    var displayName: String? = nil
    var description: String? = nil
    var actions: [Macrosusesdk_V1_MacroAction]? = nil
    var parameters: [Macrosusesdk_V1_MacroParameter]? = nil
    var tags: [String]? = nil

    // Apply field mask (if empty, update all provided fields)
    if updateMask.paths.isEmpty {
      // Update all non-empty fields
      if !request.macro.displayName.isEmpty {
        displayName = request.macro.displayName
      }
      if !request.macro.description_p.isEmpty {
        description = request.macro.description_p
      }
      if !request.macro.actions.isEmpty {
        actions = request.macro.actions
      }
      if !request.macro.parameters.isEmpty {
        parameters = request.macro.parameters
      }
      if !request.macro.tags.isEmpty {
        tags = request.macro.tags
      }
    } else {
      // Update only specified fields
      for path in updateMask.paths {
        switch path {
        case "display_name":
          displayName = request.macro.displayName
        case "description":
          description = request.macro.description_p
        case "actions":
          actions = request.macro.actions
        case "parameters":
          parameters = request.macro.parameters
        case "tags":
          tags = request.macro.tags
        default:
          throw GRPCStatus(code: .invalidArgument, message: "Invalid field path: \(path)")
        }
      }
    }

    // Update macro in registry
    guard
      let updatedMacro = await MacroRegistry.shared.updateMacro(
        name: request.macro.name,
        displayName: displayName,
        description: description,
        actions: actions,
        parameters: parameters,
        tags: tags
      )
    else {
      throw GRPCStatus(code: .notFound, message: "Macro not found: \(request.macro.name)")
    }

    return updatedMacro
  }

  func deleteMacro(
    request: Macosusesdk_V1_DeleteMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
    fputs("info: [MacosUseServiceProvider] deleteMacro called\n", stderr)

    // Delete macro from registry
    let deleted = await MacroRegistry.shared.deleteMacro(name: request.name)

    if !deleted {
      throw GRPCStatus(code: .notFound, message: "Macro not found: \(request.name)")
    }

    return SwiftProtobuf.Google_Protobuf_Empty()
  }

  func executeMacro(
    request: Macosusesdk_V1_ExecuteMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    fputs("info: [MacosUseServiceProvider] executeMacro called (LRO)\n", stderr)

    // Get macro from registry
    guard let macro = await MacroRegistry.shared.getMacro(name: request.name) else {
      throw GRPCStatus(code: .notFound, message: "Macro not found: \(request.name)")
    }

    // Create LRO
    let opName = "operations/executeMacro/\(UUID().uuidString)"
    let metadata = try SwiftProtobuf.Google_Protobuf_Any.with {
      $0.typeURL = "type.googleapis.com/macosusesdk.v1.ExecuteMacroMetadata"
      $0.value = try Macrosusesdk_V1_ExecuteMacroMetadata.with {
        $0.macroName = request.name
        $0.startTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
      }.serializedData()
    }

    let op = await operationStore.createOperation(name: opName, metadata: metadata)

    // Execute macro in background
    Task {
      do {
        let timeout = request.timeout > 0 ? request.timeout : 300.0

        // Execute macro
        try await MacroExecutor.shared.executeMacro(
          macro: macro,
          parameters: request.parameters,
          parent: request.parent,
          timeout: timeout
        )

        // Increment execution count
        await MacroRegistry.shared.incrementExecutionCount(name: request.name)

        // Complete operation
        let response = Macrosusesdk_V1_ExecuteMacroResponse.with {
          $0.success = true
          $0.macroName = request.name
        }

        try await operationStore.finishOperation(name: opName, responseMessage: response)

      } catch let error as MacroExecutionError {
        // Mark operation as failed with macro error
        var errOp = await operationStore.getOperation(name: opName) ?? op
        errOp.done = true
        errOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.internalError.rawValue)
          $0.message = error.description
        }
        await operationStore.putOperation(errOp)

      } catch {
        // Mark operation as failed with generic error
        var errOp = await operationStore.getOperation(name: opName) ?? op
        errOp.done = true
        errOp.error = Google_Rpc_Status.with {
          $0.code = Int32(GRPCStatus.Code.internalError.rawValue)
          $0.message = "\(error)"
        }
        await operationStore.putOperation(errOp)
      }
    }

    return op
  }

  // MARK: - Script Methods

  func executeAppleScript(
    request: Macosusesdk_V1_ExecuteAppleScriptRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ExecuteAppleScriptResponse {
    fputs("info: [MacosUseServiceProvider] executeAppleScript called\n", stderr)

    // Parse timeout from Duration
    let timeout: TimeInterval
    if request.hasTimeout {
      timeout = Double(request.timeout.seconds) + (Double(request.timeout.nanos) / 1_000_000_000)
    } else {
      timeout = 30.0  // Default 30 seconds
    }

    do {
      // Execute AppleScript using ScriptExecutor
      let result = try await ScriptExecutor.shared.executeAppleScript(
        request.script,
        timeout: timeout,
        compileOnly: request.compileOnly
      )

      return Macosusesdk_V1_ExecuteAppleScriptResponse.with {
        $0.success = result.success
        $0.output = result.output
        if let error = result.error {
          $0.error = error
        }
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
          $0.seconds = Int64(result.duration)
          $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
        }
      }
    } catch let error as ScriptExecutionError {
      return Macosusesdk_V1_ExecuteAppleScriptResponse.with {
        $0.success = false
        $0.output = ""
        $0.error = error.description
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
      }
    } catch {
      return Macosusesdk_V1_ExecuteAppleScriptResponse.with {
        $0.success = false
        $0.output = ""
        $0.error = "Unexpected error: \(error.localizedDescription)"
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
      }
    }
  }

  func executeJavaScript(
    request: Macosusesdk_V1_ExecuteJavaScriptRequest,
    context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ExecuteJavaScriptResponse {
    fputs("info: [MacosUseServiceProvider] executeJavaScript called\n", stderr)

    // Parse timeout from Duration
    let timeout: TimeInterval
    if request.hasTimeout {
      timeout = Double(request.timeout.seconds) + (Double(request.timeout.nanos) / 1_000_000_000)
    } else {
      timeout = 30.0  // Default 30 seconds
    }

    do {
      // Execute JavaScript using ScriptExecutor
      let result = try await ScriptExecutor.shared.executeJavaScript(
        request.script,
        timeout: timeout,
        compileOnly: request.compileOnly
      )

      return Macosusesdk_V1_ExecuteJavaScriptResponse.with {
        $0.success = result.success
        $0.output = result.output
        if let error = result.error {
          $0.error = error
        }
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
          $0.seconds = Int64(result.duration)
          $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
        }
      }
    } catch let error as ScriptExecutionError {
      return Macosusesdk_V1_ExecuteJavaScriptResponse.with {
        $0.success = false
        $0.output = ""
        $0.error = error.description
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
      }
    } catch {
      return Macosusesdk_V1_ExecuteJavaScriptResponse.with {
        $0.success = false
        $0.output = ""
        $0.error = "Unexpected error: \(error.localizedDescription)"
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
      }
    }
  }

  func executeShellCommand(
    request: Macosusesdk_V1_ExecuteShellCommandRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ExecuteShellCommandResponse {
    fputs("info: [MacosUseServiceProvider] executeShellCommand called\n", stderr)

    // Parse timeout from Duration
    let timeout: TimeInterval
    if request.hasTimeout {
      timeout = Double(request.timeout.seconds) + (Double(request.timeout.nanos) / 1_000_000_000)
    } else {
      timeout = 30.0  // Default 30 seconds
    }

    // Extract shell (default to /bin/bash)
    let shell = request.shell.isEmpty ? "/bin/bash" : request.shell

    // Extract working directory (optional)
    let workingDir = request.workingDirectory.isEmpty ? nil : request.workingDirectory

    // Extract environment (optional)
    let environment =
      request.environment.isEmpty
      ? nil : Dictionary(uniqueKeysWithValues: request.environment.map { ($0.key, $0.value) })

    // Extract stdin (optional)
    let stdin = request.stdin.isEmpty ? nil : request.stdin

    do {
      // Execute shell command using ScriptExecutor
      let result = try await ScriptExecutor.shared.executeShellCommand(
        request.command,
        args: Array(request.args),
        workingDirectory: workingDir,
        environment: environment,
        timeout: timeout,
        stdin: stdin,
        shell: shell
      )

      return Macosusesdk_V1_ExecuteShellCommandResponse.with {
        $0.success = result.success
        $0.stdout = result.stdout
        $0.stderr = result.stderr
        $0.exitCode = result.exitCode
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration.with {
          $0.seconds = Int64(result.duration)
          $0.nanos = Int32((result.duration.truncatingRemainder(dividingBy: 1.0)) * 1_000_000_000)
        }
        if let error = result.error {
          $0.error = error
        }
      }
    } catch let error as ScriptExecutionError {
      return Macosusesdk_V1_ExecuteShellCommandResponse.with {
        $0.success = false
        $0.stdout = ""
        $0.stderr = ""
        $0.exitCode = -1
        $0.error = error.description
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
      }
    } catch {
      return Macosusesdk_V1_ExecuteShellCommandResponse.with {
        $0.success = false
        $0.stdout = ""
        $0.stderr = ""
        $0.exitCode = -1
        $0.error = "Unexpected error: \(error.localizedDescription)"
        $0.executionDuration = SwiftProtobuf.Google_Protobuf_Duration()
      }
    }
  }

  func validateScript(
    request: Macosusesdk_V1_ValidateScriptRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ValidateScriptResponse {
    fputs("info: [MacosUseServiceProvider] validateScript called\n", stderr)

    // Convert proto ScriptType to internal ScriptType
    let scriptType: ScriptType
    switch request.type {
    case .applescript:
      scriptType = .appleScript
    case .jxa:
      scriptType = .jxa
    case .shell:
      scriptType = .shell
    case .unspecified, .UNRECOGNIZED(_):
      throw GRPCStatus(code: .invalidArgument, message: "Script type must be specified")
    }

    do {
      // Validate script using ScriptExecutor
      let result = try await ScriptExecutor.shared.validateScript(request.script, type: scriptType)

      return Macosusesdk_V1_ValidateScriptResponse.with {
        $0.valid = result.valid
        $0.errors = result.errors
        $0.warnings = result.warnings
      }
    } catch let error as ScriptExecutionError {
      return Macosusesdk_V1_ValidateScriptResponse.with {
        $0.valid = false
        $0.errors = [error.description]
        $0.warnings = []
      }
    } catch {
      return Macosusesdk_V1_ValidateScriptResponse.with {
        $0.valid = false
        $0.errors = ["Unexpected error: \(error.localizedDescription)"]
        $0.warnings = []
      }
    }
  }

  func getScriptingDictionaries(
    request: Macosusesdk_V1_GetScriptingDictionariesRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ScriptingDictionaries {
    fputs("info: [MacosUseServiceProvider] getScriptingDictionaries called\n", stderr)

    // Validate resource name (singleton: "scriptingDictionaries")
    guard request.name == "scriptingDictionaries" else {
      throw GRPCStatus(
        code: .invalidArgument, message: "Invalid scripting dictionaries name: \(request.name)")
    }

    // Get all tracked applications
    let applications = await stateStore.listTargets()

    var dictionaries: [Macosusesdk_V1_ScriptingDictionary] = []

    // For each application, check if it has scripting support
    for app in applications {
      // Note: Application proto doesn't have bundleID field,
      // so we extract it from the app name if available
      let bundleId = "unknown"  // TODO: Store bundleID in Application proto or metadata

      // Create dictionary entry for the application
      let dictionary = Macosusesdk_V1_ScriptingDictionary.with {
        $0.application = app.name
        $0.bundleID = bundleId
        // Most macOS applications support AppleScript
        $0.supportsApplescript = true
        // JXA is supported by apps that support AppleScript
        $0.supportsJxa = true
        // Note: Getting actual scripting commands/classes would require
        // parsing the application's scripting dictionary (sdef file)
        // which is complex - for now, return common commands
        $0.commands = ["activate", "quit", "open", "close", "save"]
        $0.classes = ["application", "window", "document"]
      }
      dictionaries.append(dictionary)
    }

    // Add system-level applications that are always available
    let systemApps = [
      ("Finder", "com.apple.finder"),
      ("System Events", "com.apple.systemevents"),
      ("Safari", "com.apple.Safari"),
      ("Terminal", "com.apple.Terminal"),
    ]

    for (name, bundleId) in systemApps {
      // Check if already in list
      if !dictionaries.contains(where: { $0.bundleID == bundleId }) {
        let dictionary = Macosusesdk_V1_ScriptingDictionary.with {
          $0.application = name
          $0.bundleID = bundleId
          $0.supportsApplescript = true
          $0.supportsJxa = true
          $0.commands = ["activate", "quit", "open", "close"]
          $0.classes = ["application", "window"]
        }
        dictionaries.append(dictionary)
      }
    }

    return Macosusesdk_V1_ScriptingDictionaries.with {
      $0.dictionaries = dictionaries
    }
  }

  // MARK: - Metrics Methods

  func getMetrics(
    request: Macosusesdk_V1_GetMetricsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Metrics {
    throw GRPCStatus(code: .unimplemented, message: "getMetrics not yet implemented")
  }

  func getPerformanceReport(
    request: Macosusesdk_V1_GetPerformanceReportRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_PerformanceReport {
    throw GRPCStatus(code: .unimplemented, message: "getPerformanceReport not yet implemented")
  }

  func resetMetrics(
    request: Macosusesdk_V1_ResetMetricsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ResetMetricsResponse {
    throw GRPCStatus(code: .unimplemented, message: "resetMetrics not yet implemented")
  }
}

// MARK: - Helpers

extension MacosUseServiceProvider {
  fileprivate func parsePID(fromName name: String) throws -> pid_t {
    let components = name.split(separator: "/").map(String.init)
    guard components.count >= 2, components[0] == "applications", let pidInt = Int32(components[1])
    else {
      throw GRPCStatus(code: .invalidArgument, message: "Invalid application name: \(name)")
    }
    return pid_t(pidInt)
  }

  fileprivate func findWindowElement(pid: pid_t, windowId: CGWindowID) throws -> AXUIElement {
    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Get CGWindowList for matching
    guard
      let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else {
      throw GRPCStatus(code: .internalError, message: "Failed to get window list")
    }

    // Find window with matching CGWindowID
    guard
      let cgWindow = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? Int32) == Int32(windowId)
      })
    else {
      throw GRPCStatus(
        code: .notFound, message: "Window with ID \(windowId) not found in CGWindowList")
    }

    // Get bounds from CGWindow
    guard let cgBounds = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
      let cgX = cgBounds["X"], let cgY = cgBounds["Y"],
      let cgWidth = cgBounds["Width"], let cgHeight = cgBounds["Height"]
    else {
      throw GRPCStatus(code: .internalError, message: "Failed to get bounds from CGWindow")
    }

    // Find matching AXUIElement by bounds
    for window in windows {
      var posValue: CFTypeRef?
      var sizeValue: CFTypeRef?
      if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        == .success,
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
        let pos = posValue as! AXValue?, let size = sizeValue as! AXValue?
      {
        var axPos = CGPoint()
        var axSize = CGSize()
        if AXValueGetValue(pos, .cgPoint, &axPos), AXValueGetValue(size, .cgSize, &axSize) {
          // Check if bounds match (with small tolerance for floating point)
          if abs(axPos.x - cgX) < 1 && abs(axPos.y - cgY) < 1 && abs(axSize.width - cgWidth) < 1
            && abs(axSize.height - cgHeight) < 1
          {
            return window
          }
        }
      }
    }

    throw GRPCStatus(code: .notFound, message: "AXUIElement not found for window ID \(windowId)")
  }

  fileprivate func getWindowState(window: AXUIElement) -> (
    minimized: Bool, focused: Bool, fullscreen: Bool
  ) {
    var minimized = false
    var focused = false
    let fullscreen = false

    // Check minimized
    var minValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minValue)
      == .success,
      let minBool = minValue as? Bool
    {
      minimized = minBool
    }

    // Check focused (main window)
    var mainValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &mainValue) == .success,
      let mainBool = mainValue as? Bool
    {
      focused = mainBool
    }

    // Note: kAXFullscreenAttribute is not available in Accessibility API
    // fullscreen remains false

    return (minimized, focused, fullscreen)
  }

  fileprivate func getActionsForRole(_ role: String) -> [String] {
    // Return common actions based on element role
    // This is a simplified implementation
    switch role.lowercased() {
    case "button":
      return ["press"]
    case "checkbox", "radiobutton":
      return ["press"]
    case "slider", "scrollbar":
      return ["increment", "decrement"]
    case "menu", "menuitem":
      return ["press", "open", "close"]
    case "tab":
      return ["press", "select"]
    case "combobox", "popupbutton":
      return ["press", "open", "close"]
    case "text", "textfield", "textarea":
      return ["focus", "select"]
    default:
      return ["press"]  // Default action
    }
  }

  fileprivate func findMatchingElement(
    _ targetElement: Macosusesdk_Type_Element, in elements: [Macosusesdk_Type_Element]
  ) -> Macosusesdk_Type_Element? {
    // Simple matching by position (not ideal but works for basic cases)
    guard targetElement.hasX && targetElement.hasY else { return nil }
    let targetX = targetElement.x
    let targetY = targetElement.y

    return elements.first { element in
      guard element.hasX && element.hasY else { return false }
      let x = element.x
      let y = element.y
      // Allow small tolerance for position matching
      return abs(x - targetX) < 5 && abs(y - targetY) < 5
    }
  }

  fileprivate func elementMatchesCondition(
    _ element: Macosusesdk_Type_Element, condition: Macosusesdk_V1_StateCondition
  ) -> Bool {
    switch condition.condition {
    case .enabled(let expectedEnabled):
      return element.enabled == expectedEnabled

    case .focused(let expectedFocused):
      return element.focused == expectedFocused

    case .textEquals(let expectedText):
      return element.text == expectedText

    case .textContains(let substring):
      guard element.hasText else { return false }
      let text = element.text
      return text.contains(substring)

    case .attribute(let attributeCondition):
      guard let actualValue = element.attributes[attributeCondition.attribute] else { return false }
      return actualValue == attributeCondition.value

    case .none:
      return true
    }
  }
}
