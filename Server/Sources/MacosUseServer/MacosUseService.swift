import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

final class MacosUseService: Macosusesdk_V1_MacosUse.ServiceProtocol {
    static let logger = MacosUseSDK.sdkLogger(category: "MacosUseService")
    let stateStore: AppStateStore
    let operationStore: OperationStore
    let windowRegistry: WindowRegistry
    let system: SystemOperations

    init(stateStore: AppStateStore, operationStore: OperationStore, windowRegistry: WindowRegistry, system: SystemOperations = ProductionSystemOperations.shared) {
        self.stateStore = stateStore
        self.operationStore = operationStore
        self.windowRegistry = windowRegistry
        self.system = system
    }
}
