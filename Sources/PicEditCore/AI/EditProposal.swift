import Foundation

/// Absolute target value, never a delta or executable formula.
public struct EditParameterChange: Codable, Hashable, Sendable {
    public let parameter: EditParameter
    public let value: Double

    public init(parameter: EditParameter, value: Double) {
        self.parameter = parameter
        self.value = value
    }
}

/// Codable describes the provider wire format, not a validation boundary.
/// Both decoded and directly constructed proposals must pass EditProposalValidator.
public struct EditProposal: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let changes: [EditParameterChange]
    public let explanation: String?

    public init(schemaVersion: Int = EditProposal.currentSchemaVersion,
                changes: [EditParameterChange], explanation: String? = nil) {
        self.schemaVersion = schemaVersion
        self.changes = changes
        self.explanation = explanation
    }
}

/// A valid target is not authority to mutate app state. Acceptance must still recheck
/// the app-owned request/snapshot and consume the result exactly once.
public enum EditProposalValidationResult: Hashable, Sendable {
    case changes(proposal: EditProposal, settings: EditSettings)
    case noChange
}

/// Content-free categories are safe to count in diagnostics; responses are never retained.
public enum AIProposalValidationError: String, Error, Hashable, Sendable {
    case malformedJSON, responseTooLarge, nestingTooDeep, tooManyJSONValues
    case duplicateField, unknownField, missingField, invalidType
    case unsupportedSchemaVersion, unknownParameter, duplicateParameter
    case nonFiniteValue, outOfRange, explanationTooLong, tooManyChanges, invalidBaseline
}
