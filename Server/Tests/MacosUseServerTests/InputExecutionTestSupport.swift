import CoreGraphics
import MacosUseProto
import MacosUseSDK
@testable import MacosUseServer

func committedInputExecutionReceipt(
    for action: MacosUseSDK.InputAction,
    route: InputDeliveryRoute,
) -> InputExecutionReceipt {
    InputExecutionReceipt(
        route: route,
        postedEventCount: action.expectedPostedEventCount,
        routedDeliveryObserved: true,
    )
}

func makeTestInputTransactionExecutor(
    stateStore: AppStateStore = AppStateStore(),
    windowRegistry: WindowRegistry = WindowRegistry(),
    system: SystemOperations = MockSystemOperations(),
    automationCoordinator: AutomationCoordinator = AutomationCoordinator(),
    inputOverlayPresenter: InputOverlayPresenter = InputOverlayPresenter(),
) -> InputTransactionExecutor {
    let clipboardManager = ClipboardManager(
        mutationGate: automationCoordinator.mutationGate,
        historyManager: ClipboardHistoryManager(),
        pasteboard: InputExecutionTestPasteboard(),
    )
    return InputTransactionExecutor(
        stateStore: stateStore,
        legacyPIDResourceNamesForTests: false,
        windowRegistry: windowRegistry,
        system: system,
        displayTopologyProvider: InputExecutionTestTopology(),
        automationCoordinator: automationCoordinator,
        inputOverlayPresenter: inputOverlayPresenter,
        clipboardManager: clipboardManager,
        windowMutationConvergencePolicy: .production,
    )
}

private struct InputExecutionTestTopology: DisplayTopologyProviding {
    func snapshot() async throws -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780),
                isMain: true,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 100, y: 100)
    }
}

private actor InputExecutionTestPasteboard: ClipboardPasteboard {
    private var content: Macosusesdk_V1_ClipboardContent?
    private var changeCountValue = 0

    func read() -> Macosusesdk_V1_Clipboard {
        Macosusesdk_V1_Clipboard.with {
            $0.name = "clipboard"
            if let content {
                $0.content = content
                $0.availableTypes = [content.type]
            }
        }
    }

    func changeCount() -> Int {
        changeCountValue
    }

    func clear() {
        changeCountValue += 1
        content = nil
    }

    func write(_ content: Macosusesdk_V1_ClipboardContent) -> Bool {
        self.content = content
        return true
    }
}
