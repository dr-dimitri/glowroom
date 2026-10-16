import Foundation

/// Stable ordering and identity; names are model-provided presentation data only.
public enum AILookID: String, CaseIterable, Codable, Hashable, Sendable {
    case natural, contrasty, desaturated
}

public struct AILookProposal: Codable, Hashable, Sendable {
    public let id: AILookID
    public let name: String
    public let proposal: EditProposal

    public init(id: AILookID, name: String, proposal: EditProposal) {
        self.id = id
        self.name = name
        self.proposal = proposal
    }
}

public struct AILookProposalGroup: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let variants: [AILookProposal]

    public init(schemaVersion: Int = Self.currentSchemaVersion, variants: [AILookProposal]) {
        self.schemaVersion = schemaVersion
        self.variants = variants
    }
}

public struct AIValidatedLook: Hashable, Sendable {
    public let proposal: AILookProposal
    public let target: EditSettings

    public init(proposal: AILookProposal, target: EditSettings) {
        self.proposal = proposal
        self.target = target
    }
}

/// All targets derive independently from one app-owned snapshot. Validation publishes
/// the group atomically and returns variants in AILookID.allCases order.
public struct AIValidatedLookGroup: Hashable, Sendable {
    public let variants: [AIValidatedLook]

    public init(variants: [AIValidatedLook]) { self.variants = variants }
}
