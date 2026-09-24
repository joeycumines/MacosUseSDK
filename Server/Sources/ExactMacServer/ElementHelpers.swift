import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

extension ExactMacService {
    func findMatchingElement(
        _ targetElement: Exactmac_V1_Element, in elements: [Exactmac_V1_Element],
    ) -> Exactmac_V1_Element? {
        // Simple matching by position using Euclidean distance from element centers
        guard targetElement.hasX, targetElement.hasY else { return nil }
        // Use center if dimensions available, otherwise use position
        let targetCenterX: Double
        let targetCenterY: Double
        if targetElement.hasWidth, targetElement.hasHeight {
            targetCenterX = targetElement.x + targetElement.width / 2.0
            targetCenterY = targetElement.y + targetElement.height / 2.0
        } else {
            targetCenterX = targetElement.x
            targetCenterY = targetElement.y
        }
        let tolerance = 5.0

        return elements.first { element in
            guard element.hasX, element.hasY else { return false }
            let centerX: Double
            let centerY: Double
            if element.hasWidth, element.hasHeight {
                centerX = element.x + element.width / 2.0
                centerY = element.y + element.height / 2.0
            } else {
                centerX = element.x
                centerY = element.y
            }
            // Use Euclidean distance for consistent matching
            let distance = hypot(centerX - targetCenterX, centerY - targetCenterY)
            return distance < tolerance
        }
    }

    func elementMatchesCondition(
        _ element: Exactmac_V1_Element, condition: Exactmac_V1_StateCondition,
    ) -> Bool {
        switch condition.condition {
        case let .enabled(expectedEnabled):
            return element.enabled == expectedEnabled

        case let .focused(expectedFocused):
            return element.focused == expectedFocused

        case let .text(expectedText):
            return element.text == expectedText

        case let .textSubstring(substring):
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
