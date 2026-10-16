import Foundation
import Testing
@testable import PicEditCore

@Suite("Strict three-look proposal boundary")
struct AILookProposalTests {
    @Test
    func canonicalOrderAndEveryTargetUsesTheSameBaseline() throws {
        let baseline = EditSettings(exposure: 0.7, contrast: 3, shadows: 12, texture: 9)
        let group = AILookProposalGroup(variants: Array(Self.group.variants.reversed()))
        let validated = try EditProposalValidator().validateLookGroup(try JSONEncoder().encode(group), against: baseline)
        #expect(validated.variants.map(\.proposal.id) == AILookID.allCases)
        #expect(validated.variants.map(\.target.contrast) == [8, 35, 3])
        #expect(validated.variants.map(\.target.saturation) == [0, 0, -35])
        #expect(validated.variants.allSatisfy { $0.target.exposure == 0.7 && $0.target.shadows == 12 && $0.target.texture == 9 })
        #expect(Set(validated.variants.map(\.target)).count == 3)
    }

    @Test
    func countsAndIDsAreExactWithoutFillingOrDiscarding() throws {
        let validator = EditProposalValidator()
        for count in [0, 1, 2, 4] {
            let looks = (0..<count).map { Self.group.variants[$0 % 3] }
            #expect(throws: AIEditingError.invalidResponse(.invalidLookCount)) {
                try validator.validateLookGroup(AILookProposalGroup(variants: looks), against: .neutral)
            }
        }
        let duplicate = AILookProposalGroup(variants: [Self.group.variants[0], Self.group.variants[0], Self.group.variants[2]])
        #expect(throws: AIEditingError.invalidResponse(.invalidLookID)) {
            try validator.validateLookGroup(duplicate, against: .neutral)
        }
        let text = String(decoding: try JSONEncoder().encode(Self.group), as: UTF8.self)
        #expect(throws: AIEditingError.invalidResponse(.invalidLookID)) {
            try validator.validateLookGroup(Data(text.replacingOccurrences(of: "natural", with: "invented").utf8), against: .neutral)
        }
    }

    @Test
    func unknownAndDuplicateFieldsAreRejectedAtEveryLevel() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(Self.group), as: UTF8.self)
        let malformed: [(String, AIProposalValidationError)] = [
            ("not JSON", .malformedJSON),
            (text.replacingOccurrences(of: "{\"schemaVersion\"", with: "{\"extra\":true,\"schemaVersion\""), .unknownField),
            (text.replacingOccurrences(of: "\"variants\":", with: "\"variants\":[],\"variants\":"), .duplicateField),
            (text.replacingOccurrences(of: "\"name\":", with: "\"extra\":true,\"name\":"), .unknownField),
            (text.replacingOccurrences(of: "\"changes\":", with: "\"extra\":true,\"changes\":"), .unknownField),
            (text.replacingOccurrences(of: "\"parameter\":", with: "\"extra\":true,\"parameter\":"), .unknownField),
            (text.replacingOccurrences(of: "\"parameter\":", with: "\"parameter\":\"exposure\",\"p\\u0061rameter\":"), .duplicateField)
        ]
        for (response, category) in malformed {
            #expect(throws: AIEditingError.invalidResponse(category)) {
                try EditProposalValidator().validateLookGroup(Data(response.utf8), against: .neutral)
            }
        }
    }

    @Test
    func invalidPatchRejectsWholeGroupAndNoEffectIsAnError() throws {
        let invalid: [(EditProposal, AIProposalValidationError)] = [
            (EditProposal(changes: [.init(parameter: .exposure, value: 500)]), .outOfRange),
            (EditProposal(changes: [.init(parameter: .exposure, value: .nan)]), .nonFiniteValue),
            (EditProposal(changes: [.init(parameter: .contrast, value: 1), .init(parameter: .contrast, value: 2)]), .duplicateParameter),
            (EditProposal(changes: []), .ineffectiveLook),
            (EditProposal(changes: [.init(parameter: .contrast, value: 0)]), .ineffectiveLook),
            (EditProposal(changes: [.init(parameter: .contrast, value: 2)], explanation: String(repeating: "x", count: 513)), .explanationTooLong),
            (EditProposal(schemaVersion: 2, changes: [.init(parameter: .contrast, value: 2)]), .unsupportedSchemaVersion)
        ]
        for (patch, category) in invalid {
            var variants = Self.group.variants
            variants[2] = AILookProposal(id: .desaturated, name: "Entsättigt", proposal: patch)
            #expect(throws: AIEditingError.invalidResponse(category)) {
                try EditProposalValidator().validateLookGroup(AILookProposalGroup(variants: variants), against: .neutral)
            }
        }
        var variants = Self.group.variants
        variants[2] = AILookProposal(id: .desaturated, name: "Andere Darstellung desselben Ziels",
                                    proposal: EditProposal(changes: [.init(parameter: .exposure, value: 0), .init(parameter: .contrast, value: 8)]))
        #expect(throws: AIEditingError.invalidResponse(.duplicateLookTargets)) {
            try EditProposalValidator().validateLookGroup(AILookProposalGroup(variants: variants), against: .neutral)
        }
    }

    @Test
    func namesExplanationsAndWireLimitsRemainBounded() throws {
        for name in ["", " \n ", String(repeating: "ä", count: 33)] {
            var variants = Self.group.variants
            variants[0] = AILookProposal(id: .natural, name: name, proposal: variants[0].proposal)
            #expect(throws: AIEditingError.invalidResponse(.invalidLookName)) {
                try EditProposalValidator().validateLookGroup(AILookProposalGroup(variants: variants), against: .neutral)
            }
        }
        let data = try JSONEncoder().encode(Self.group)
        #expect(throws: AIEditingError.invalidResponse(.responseTooLarge)) {
            try EditProposalValidator(maximumResponseBytes: data.count - 1).validateLookGroup(data, against: .neutral)
        }
        #expect(throws: AIEditingError.invalidResponse(.nestingTooDeep)) {
            try EditProposalValidator(maximumNestingDepth: 6).validateLookGroup(data, against: .neutral)
        }
        #expect(throws: AIEditingError.invalidResponse(.tooManyJSONValues)) {
            try EditProposalValidator(maximumJSONValues: 4).validateLookGroup(data, against: .neutral)
        }
        #expect(throws: AIEditingError.invalidResponse(.unsupportedSchemaVersion)) {
            try EditProposalValidator().validateLookGroup(AILookProposalGroup(schemaVersion: 2, variants: Self.group.variants), against: .neutral)
        }
    }

    @Test
    func modeAllowsAnEmptyLookRequestWhileRetainingInputAndSnapshotChecks() throws {
        let snapshot = AIEditingSnapshot(assetID: "a", source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/a.nef"), modifiedAt: .distantPast, fileSize: 1)),
                                         settings: .neutral, token: AIEditingToken(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0))
        try AIEditingRequest(prompt: "", snapshot: snapshot, mode: .lookGroup).validate()
        #expect(throws: AIEditingError.invalidRequest) { try AIEditingRequest(prompt: "", snapshot: snapshot).validate() }
        #expect(throws: AIEditingError.invalidRequest) {
            try AIEditingRequest(prompt: "12345", snapshot: snapshot, mode: .lookGroup).validate(maximumPromptBytes: 4)
        }
        let invalid = AIEditingSnapshot(assetID: "a", source: snapshot.source, settings: EditSettings(exposure: .infinity), token: snapshot.token)
        #expect(throws: AIEditingError.invalidRequest) { try AIEditingRequest(prompt: "", snapshot: invalid, mode: .lookGroup).validate() }
    }

    private static var group: AILookProposalGroup {
        AILookProposalGroup(variants: [
            AILookProposal(id: .natural, name: "Natürlich", proposal: EditProposal(changes: [.init(parameter: .contrast, value: 8)])),
            AILookProposal(id: .contrasty, name: "Kontrastreich", proposal: EditProposal(changes: [.init(parameter: .contrast, value: 35)])),
            AILookProposal(id: .desaturated, name: "Entsättigt", proposal: EditProposal(changes: [.init(parameter: .saturation, value: -35)]))
        ])
    }
}
