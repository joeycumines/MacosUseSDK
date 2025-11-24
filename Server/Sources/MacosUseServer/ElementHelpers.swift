import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRPCCore
import MacosUseProto
import MacosUseSDK
import OSLog
import SwiftProtobuf

extension MacosUseServiceProvider {
    func findMatchingElement(
        _ targetElement: Macosusesdk_Type_Element, in elements: [Macosusesdk_Type_Element],
    ) -> Macosusesdk_Type_Element? {
        // Simple matching by position (not ideal but works for basic cases)
        guard targetElement.hasX, targetElement.hasY else { return nil }
        let targetX = targetElement.x
        let targetY = targetElement.y

        return elements.first { element in
            guard element.hasX, element.hasY else { return false }
            let x = element.x
            let y = element.y
            // Allow small tolerance for position matching
            return abs(x - targetX) < 5 && abs(y - targetY) < 5
        }
    }

    func elementMatchesCondition(
        _ element: Macosusesdk_Type_Element, condition: Macosusesdk_V1_StateCondition,
    ) -> Bool {
        switch condition.condition {
        case let .enabled(expectedEnabled):
            return element.enabled == expectedEnabled

        case let .focused(expectedFocused):
            return element.focused == expectedFocused

        case let .textEquals(expectedText):
            return element.text == expectedText

        case let .textContains(substring):
            guard element.hasText else { return false }
            let text = element.text
            return text.contains(substring)

        case let .attribute(attributeCondition):
            guard let actualValue = element.attributes[attributeCondition.attribute] else { return false }
            return actualValue == attributeCondition.value

        case .none:
            return true
        }
    }
}
