import Foundation
import GRPC
import MacosUseSDKProtos

/// Component for parsing and validating ElementSelector proto messages.
/// Provides validation, optimization, and preprocessing of selectors.
public struct SelectorParser {
    public static let shared = SelectorParser()

    private init() {}

    /// Parse and validate an ElementSelector.
    /// - Parameter selector: The selector to parse
    /// - Throws: GRPCStatus if the selector is invalid
    /// - Returns: A validated and potentially optimized selector
    public func parseSelector(_ selector: Macosusesdk_Type_ElementSelector) throws
        -> Macosusesdk_Type_ElementSelector
    {
        fputs("info: [SelectorParser] Parsing selector\n", stderr)

        // Validate the selector structure
        try validateSelector(selector)

        // For now, just return the selector as-is
        // In the future, we could optimize compound selectors, etc.
        return selector
    }

    /// Validate that a selector is well-formed.
    /// - Parameter selector: The selector to validate
    /// - Throws: GRPCStatus if validation fails
    private func validateSelector(_ selector: Macosusesdk_Type_ElementSelector) throws {
        switch selector.criteria {
        case let .role(role):
            if role.isEmpty {
                throw GRPCStatus(code: .invalidArgument, message: "Role selector cannot be empty")
            }

        case .text:
            // Text can be empty (match elements with no text)
            break

        case let .textContains(substring):
            if substring.isEmpty {
                throw GRPCStatus(code: .invalidArgument, message: "Text contains selector cannot be empty")
            }

        case let .textRegex(pattern):
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                throw GRPCStatus(code: .invalidArgument, message: "Invalid regex pattern: \(pattern)")
            }

        case let .position(positionSelector):
            if positionSelector.tolerance < 0 {
                throw GRPCStatus(code: .invalidArgument, message: "Position tolerance cannot be negative")
            }

        case let .attributes(attributeSelector):
            if attributeSelector.attributes.isEmpty {
                throw GRPCStatus(code: .invalidArgument, message: "Attribute selector cannot be empty")
            }

        case let .compound(compoundSelector):
            if compoundSelector.selectors.isEmpty {
                throw GRPCStatus(code: .invalidArgument, message: "Compound selector cannot be empty")
            }

            // Validate NOT operator has exactly one selector
            if compoundSelector.operator == .not, compoundSelector.selectors.count != 1 {
                throw GRPCStatus(
                    code: .invalidArgument, message: "NOT operator requires exactly one selector",
                )
            }

            // Recursively validate all sub-selectors
            for subSelector in compoundSelector.selectors {
                try validateSelector(subSelector)
            }

        case .none:
            // Empty selector is valid (matches all elements)
            break
        }
    }

    /// Check if a selector is simple (can be optimized).
    /// - Parameter selector: The selector to check
    /// - Returns: True if the selector is simple
    public func isSimpleSelector(_ selector: Macosusesdk_Type_ElementSelector) -> Bool {
        switch selector.criteria {
        case .role, .text, .textContains, .position:
            true
        case .textRegex, .attributes, .compound:
            false
        case .none:
            true
        }
    }

    /// Get a description of the selector for logging/debugging.
    /// - Parameter selector: The selector to describe
    /// - Returns: Human-readable description
    public func describeSelector(_ selector: Macosusesdk_Type_ElementSelector) -> String {
        switch selector.criteria {
        case let .role(role):
            return "role='\(role)'"
        case let .text(text):
            return "text='\(text)'"
        case let .textContains(substring):
            return "textContains='\(substring)'"
        case let .textRegex(pattern):
            return "textRegex='\(pattern)'"
        case let .position(position):
            return "position=(\(position.x), \(position.y), tolerance=\(position.tolerance))"
        case let .attributes(attributes):
            let attrStr = attributes.attributes.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            return "attributes={\(attrStr)}"
        case let .compound(compound):
            let opStr =
                compound.operator == .and
                    ? "AND" : compound.operator == .or ? "OR" : compound.operator == .not ? "NOT" : "UNKNOWN"
            return "compound(\(opStr), \(compound.selectors.count) selectors)"
        case .none:
            return "matchAll"
        }
    }
}

extension SelectorParser: Sendable {}
