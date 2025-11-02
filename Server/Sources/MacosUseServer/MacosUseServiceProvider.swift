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

  init(stateStore: AppStateStore, operationStore: OperationStore) {
    self.stateStore = stateStore
    self.operationStore = operationStore
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
      $0.minimized = false  // TODO: Check AXMinimized attribute
      $0.focused = false  // TODO: Check if window has focus
      $0.fullscreen = false  // TODO: Check fullscreen state
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

    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Find the window by matching CGWindowID
    var targetWindow: AXUIElement?
    for window in windows {
      // Get window's position to identify it
      var posValue: CFTypeRef?
      var sizeValue: CFTypeRef?
      if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        == .success,
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
      {
        // Store for later - we'll match by checking all windows
        // For now, just try to focus the first window as a fallback
        if targetWindow == nil {
          targetWindow = window
        }
      }
    }

    guard let windowToFocus = targetWindow else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

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

    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Use first window for now (TODO: match by windowId)
    guard let window = windows.first else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

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

    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Use first window for now (TODO: match by windowId)
    guard let window = windows.first else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

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

    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Use first window for now (TODO: match by windowId)
    guard let window = windows.first else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

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

    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Use first window for now (TODO: match by windowId)
    guard let window = windows.first else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

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

    // Get AXUIElement for application
    let appElement = AXUIElementCreateApplication(pid)

    // Get AXWindows attribute
    var windowsValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      appElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard result == .success, let windows = windowsValue as? [AXUIElement] else {
      throw GRPCStatus(code: .internalError, message: "Failed to get windows for application")
    }

    // Use first window for now (TODO: match by windowId)
    guard let window = windows.first else {
      throw GRPCStatus(code: .notFound, message: "Window not found")
    }

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
    throw GRPCStatus(code: .unimplemented, message: "findElements not yet implemented")
  }

  func findRegionElements(
    request: Macosusesdk_V1_FindRegionElementsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_FindRegionElementsResponse {
    throw GRPCStatus(code: .unimplemented, message: "findRegionElements not yet implemented")
  }

  func getElement(
    request: Macosusesdk_V1_GetElementRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_Type_Element {
    throw GRPCStatus(code: .unimplemented, message: "getElement not yet implemented")
  }

  func clickElement(
    request: Macosusesdk_V1_ClickElementRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ClickElementResponse {
    throw GRPCStatus(code: .unimplemented, message: "clickElement not yet implemented")
  }

  func writeElementValue(
    request: Macosusesdk_V1_WriteElementValueRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_WriteElementValueResponse {
    throw GRPCStatus(code: .unimplemented, message: "writeElementValue not yet implemented")
  }

  func getElementActions(
    request: Macosusesdk_V1_GetElementActionsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ElementActions {
    throw GRPCStatus(code: .unimplemented, message: "getElementActions not yet implemented")
  }

  func performElementAction(
    request: Macosusesdk_V1_PerformElementActionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_PerformElementActionResponse {
    throw GRPCStatus(code: .unimplemented, message: "performElementAction not yet implemented")
  }

  func waitElement(
    request: Macosusesdk_V1_WaitElementRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    throw GRPCStatus(code: .unimplemented, message: "waitElement not yet implemented")
  }

  func waitElementState(
    request: Macosusesdk_V1_WaitElementStateRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    throw GRPCStatus(code: .unimplemented, message: "waitElementState not yet implemented")
  }

  // MARK: - Observation Methods

  func createObservation(
    request: Macosusesdk_V1_CreateObservationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    throw GRPCStatus(code: .unimplemented, message: "createObservation not yet implemented")
  }

  func getObservation(
    request: Macosusesdk_V1_GetObservationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Observation {
    throw GRPCStatus(code: .unimplemented, message: "getObservation not yet implemented")
  }

  func listObservations(
    request: Macosusesdk_V1_ListObservationsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ListObservationsResponse {
    throw GRPCStatus(code: .unimplemented, message: "listObservations not yet implemented")
  }

  func cancelObservation(
    request: Macosusesdk_V1_CancelObservationRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Observation {
    throw GRPCStatus(code: .unimplemented, message: "cancelObservation not yet implemented")
  }

  func streamObservations(
    request: Macosusesdk_V1_StreamObservationsRequest,
    responseStream: GRPCAsyncResponseStreamWriter<Macosusesdk_V1_StreamObservationsResponse>,
    context: GRPCAsyncServerCallContext
  ) async throws {
    throw GRPCStatus(code: .unimplemented, message: "streamObservations not yet implemented")
  }

  // MARK: - Session Methods

  func createSession(
    request: Macosusesdk_V1_CreateSessionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Session {
    throw GRPCStatus(code: .unimplemented, message: "createSession not yet implemented")
  }

  func getSession(
    request: Macosusesdk_V1_GetSessionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Session {
    throw GRPCStatus(code: .unimplemented, message: "getSession not yet implemented")
  }

  func listSessions(
    request: Macosusesdk_V1_ListSessionsRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ListSessionsResponse {
    throw GRPCStatus(code: .unimplemented, message: "listSessions not yet implemented")
  }

  func deleteSession(
    request: Macosusesdk_V1_DeleteSessionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
    throw GRPCStatus(code: .unimplemented, message: "deleteSession not yet implemented")
  }

  func beginTransaction(
    request: Macosusesdk_V1_BeginTransactionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_BeginTransactionResponse {
    throw GRPCStatus(code: .unimplemented, message: "beginTransaction not yet implemented")
  }

  func commitTransaction(
    request: Macosusesdk_V1_CommitTransactionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Transaction {
    throw GRPCStatus(code: .unimplemented, message: "commitTransaction not yet implemented")
  }

  func rollbackTransaction(
    request: Macosusesdk_V1_RollbackTransactionRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Transaction {
    throw GRPCStatus(code: .unimplemented, message: "rollbackTransaction not yet implemented")
  }

  func getSessionSnapshot(
    request: Macosusesdk_V1_GetSessionSnapshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_SessionSnapshot {
    throw GRPCStatus(code: .unimplemented, message: "getSessionSnapshot not yet implemented")
  }

  // MARK: - Screenshot Methods

  func captureScreenshot(
    request: Macosusesdk_V1_CaptureScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureScreenshotResponse {
    throw GRPCStatus(code: .unimplemented, message: "captureScreenshot not yet implemented")
  }

  func captureWindowScreenshot(
    request: Macosusesdk_V1_CaptureWindowScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureWindowScreenshotResponse {
    throw GRPCStatus(code: .unimplemented, message: "captureWindowScreenshot not yet implemented")
  }

  func captureElementScreenshot(
    request: Macosusesdk_V1_CaptureElementScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureElementScreenshotResponse {
    throw GRPCStatus(code: .unimplemented, message: "captureElementScreenshot not yet implemented")
  }

  func captureRegionScreenshot(
    request: Macosusesdk_V1_CaptureRegionScreenshotRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_CaptureRegionScreenshotResponse {
    throw GRPCStatus(code: .unimplemented, message: "captureRegionScreenshot not yet implemented")
  }

  // MARK: - Clipboard Methods

  func getClipboard(
    request: Macosusesdk_V1_GetClipboardRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Clipboard {
    throw GRPCStatus(code: .unimplemented, message: "getClipboard not yet implemented")
  }

  func writeClipboard(
    request: Macosusesdk_V1_WriteClipboardRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_WriteClipboardResponse {
    throw GRPCStatus(code: .unimplemented, message: "writeClipboard not yet implemented")
  }

  func clearClipboard(
    request: Macosusesdk_V1_ClearClipboardRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ClearClipboardResponse {
    throw GRPCStatus(code: .unimplemented, message: "clearClipboard not yet implemented")
  }

  func getClipboardHistory(
    request: Macosusesdk_V1_GetClipboardHistoryRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ClipboardHistory {
    throw GRPCStatus(code: .unimplemented, message: "getClipboardHistory not yet implemented")
  }

  // MARK: - File Dialog Methods

  func automateOpenFileDialog(
    request: Macosusesdk_V1_AutomateOpenFileDialogRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_AutomateOpenFileDialogResponse {
    throw GRPCStatus(code: .unimplemented, message: "automateOpenFileDialog not yet implemented")
  }

  func automateSaveFileDialog(
    request: Macosusesdk_V1_AutomateSaveFileDialogRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_AutomateSaveFileDialogResponse {
    throw GRPCStatus(code: .unimplemented, message: "automateSaveFileDialog not yet implemented")
  }

  func selectFile(
    request: Macosusesdk_V1_SelectFileRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_SelectFileResponse {
    throw GRPCStatus(code: .unimplemented, message: "selectFile not yet implemented")
  }

  func selectDirectory(
    request: Macosusesdk_V1_SelectDirectoryRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_SelectDirectoryResponse {
    throw GRPCStatus(code: .unimplemented, message: "selectDirectory not yet implemented")
  }

  func dragFiles(
    request: Macosusesdk_V1_DragFilesRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_DragFilesResponse {
    throw GRPCStatus(code: .unimplemented, message: "dragFiles not yet implemented")
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
  ) async throws -> Macosusesdk_V1_ListMacrosResponse {
    throw GRPCStatus(code: .unimplemented, message: "listMacros not yet implemented")
  }

  func updateMacro(
    request: Macosusesdk_V1_UpdateMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_Macro {
    throw GRPCStatus(code: .unimplemented, message: "updateMacro not yet implemented")
  }

  func deleteMacro(
    request: Macosusesdk_V1_DeleteMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> SwiftProtobuf.Google_Protobuf_Empty {
    throw GRPCStatus(code: .unimplemented, message: "deleteMacro not yet implemented")
  }

  func executeMacro(
    request: Macosusesdk_V1_ExecuteMacroRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Google_Longrunning_Operation {
    throw GRPCStatus(code: .unimplemented, message: "executeMacro not yet implemented")
  }

  // MARK: - Script Methods

  func executeAppleScript(
    request: Macosusesdk_V1_ExecuteAppleScriptRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ExecuteAppleScriptResponse {
    throw GRPCStatus(code: .unimplemented, message: "executeAppleScript not yet implemented")
  }

  func executeJavaScript(
    request: Macosusesdk_V1_ExecuteJavaScriptRequest,
    context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ExecuteJavaScriptResponse {
    throw GRPCStatus(
      code: .unimplemented, message: "executeJavaScript not yet implemented")
  }

  func executeShellCommand(
    request: Macosusesdk_V1_ExecuteShellCommandRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ExecuteShellCommandResponse {
    throw GRPCStatus(code: .unimplemented, message: "executeShellCommand not yet implemented")
  }

  func validateScript(
    request: Macosusesdk_V1_ValidateScriptRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ValidateScriptResponse {
    throw GRPCStatus(code: .unimplemented, message: "validateScript not yet implemented")
  }

  func getScriptingDictionaries(
    request: Macosusesdk_V1_GetScriptingDictionariesRequest, context: GRPCAsyncServerCallContext
  ) async throws -> Macosusesdk_V1_ScriptingDictionaries {
    throw GRPCStatus(
      code: .unimplemented, message: "getScriptingDictionaries not yet implemented")
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
}
