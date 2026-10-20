import Foundation
import Testing
@testable import PicEditCore

@Suite("Strict image editing plan envelope")
struct ImageEditingPlanEnvelopeTests {
    @Test
    func scopeFlagsAreTypedAndConsistentWithStatus() throws {
        let validator = EditProposalValidator()
        let valid = #"{"status":"proposal","background":true,"subject":false,"sky":false,"global":false}"#
        try validator.validateImageEditingScopeEnvelope(Data(valid.utf8))
        try validator.validateImageEditingScopeEnvelope(Data(valid.replacingOccurrences(of: "false", with: "true").utf8))
        for status in ["whiteBalance", "unsupported", "unsupportedLanguage", "refused"] {
            let rejected = valid.replacingOccurrences(of: "proposal", with: status).replacingOccurrences(of: "true", with: "false")
            try validator.validateImageEditingScopeEnvelope(Data(rejected.utf8))
            #expect(throws: AIEditingError.invalidResponse(.invalidType)) {
                try validator.validateImageEditingScopeEnvelope(Data(valid.replacingOccurrences(of: "proposal", with: status).utf8))
            }
        }
        for response in [valid.replacingOccurrences(of: "true", with: "false"),
                         valid.replacingOccurrences(of: "proposal", with: "execute"),
                         valid.replacingOccurrences(of: "true", with: "1"),
                         valid.replacingOccurrences(of: "true", with: "\"true\""),
                         valid.replacingOccurrences(of: "true", with: "null")] {
            #expect(throws: AIEditingError.invalidResponse(.invalidType)) {
                try validator.validateImageEditingScopeEnvelope(Data(response.utf8))
            }
        }
    }

    @Test
    func scopeEnvelopeRetainsExactFieldsAndParserBounds() {
        let valid = #"{"status":"proposal","background":true,"subject":false,"sky":false,"global":false}"#
        let data = Data(valid.utf8)
        let invalid: [(String, AIProposalValidationError)] = [
            (valid.replacingOccurrences(of: "\"background\":", with: "\"background\":false,\"backgro\\u0075nd\":"), .duplicateField),
            (valid.replacingOccurrences(of: "\"subject\":", with: "\"extra\":false,\"subject\":"), .unknownField),
            (valid.replacingOccurrences(of: ",\"subject\":false", with: ""), .missingField),
            (valid + "{}", .malformedJSON)
        ]
        for (response, error) in invalid {
            #expect(throws: AIEditingError.invalidResponse(error)) {
                try EditProposalValidator().validateImageEditingScopeEnvelope(Data(response.utf8))
            }
        }
        #expect(throws: AIEditingError.invalidResponse(.responseTooLarge)) {
            try EditProposalValidator(maximumResponseBytes: data.count - 1).validateImageEditingScopeEnvelope(data)
        }
        #expect(throws: AIEditingError.invalidResponse(.nestingTooDeep)) {
            try EditProposalValidator(maximumNestingDepth: 1).validateImageEditingScopeEnvelope(data)
        }
        #expect(throws: AIEditingError.invalidResponse(.tooManyJSONValues)) {
            try EditProposalValidator(maximumJSONValues: 4).validateImageEditingScopeEnvelope(data)
        }
    }

    @Test
    func supportedEnvelopesAndMaximumControlsFitDefaultParserBudget() throws {
        let validator = EditProposalValidator()
        try validator.validateImageEditingPlanEnvelope(Self.bytes())
        for status in ["whiteBalance", "unsupported", "unsupportedLanguage", "refused"] {
            try validator.validateImageEditingPlanEnvelope(Self.bytes(status: status, changes: "[]", regions: "[]"))
        }
        let allChanges = "[" + EditParameter.allCases.map {
            #"{"parameter":"\#($0.rawValue)","value":\#($0.range.upperBound)}"#
        }.joined(separator: ",") + "]"
        let allRegions = "[" + ["subject", "background", "sky"].map {
            #"{"target":"\#($0)","changes":\#(allChanges)}"#
        }.joined(separator: ",") + "]"
        // The app later narrows local parameters to its eleven renderable
        // controls; this core envelope validates the common scalar contract.
        try validator.validateImageEditingPlanEnvelope(Self.bytes(changes: allChanges, regions: allRegions))
    }

    @Test
    func duplicateAndUnknownFieldsAreRejectedAtEveryLevelBeforeDecoding() {
        let text = String(decoding: Self.bytes(), as: UTF8.self)
        let cases: [(String, AIProposalValidationError)] = [
            (text.replacingOccurrences(of: "\"status\":", with: "\"extra\":true,\"status\":"), .unknownField),
            (text.replacingOccurrences(of: "\"status\":", with: "\"status\":\"proposal\",\"st\\u0061tus\":"), .duplicateField),
            (text.replacingOccurrences(of: "\"target\":", with: "\"extra\":true,\"target\":"), .unknownField),
            (text.replacingOccurrences(of: "\"target\":", with: "\"target\":\"subject\",\"target\":"), .duplicateField),
            (text.replacingOccurrences(of: "\"parameter\":", with: "\"extra\":true,\"parameter\":"), .unknownField),
            (text.replacingOccurrences(of: "\"value\":", with: "\"value\":0,\"v\\u0061lue\":"), .duplicateField),
            (text.replacingOccurrences(of: ",\"explanation\":\"Vorsichtige Korrektur.\"", with: ""), .missingField),
            (text + " true", .malformedJSON)
        ]
        for (response, error) in cases {
            #expect(throws: AIEditingError.invalidResponse(error)) {
                try EditProposalValidator().validateImageEditingPlanEnvelope(Data(response.utf8))
            }
        }
    }

    @Test
    func enumsRegionCountsAndRejectedPlansCannotCarryEdits() {
        let goodRegion = #"{"target":"background","changes":[{"parameter":"exposure","value":-0.3}]}"#
        let invalid: [(Data, AIProposalValidationError)] = [
            (Self.bytes(status: "execute"), .invalidType),
            (Self.bytes(regions: #"[{"target":"car","changes":[]}]"#), .invalidType),
            (Self.bytes(regions: "[\(goodRegion),\(goodRegion)]"), .invalidType),
            (Self.bytes(regions: "[" + Array(repeating: goodRegion, count: 4).joined(separator: ",") + "]"), .tooManyChanges),
            (Self.bytes(status: "refused"), .invalidType),
            (Self.bytes(status: "unsupported", changes: "[]"), .invalidType),
            (Self.bytes(status: "whiteBalance", regions: "[]"), .invalidType),
            (Self.bytes(regions: #"[{"target":"background"}]"#), .missingField),
            (Self.bytes(regions: "[null]"), .invalidType),
            (Self.bytes(changes: "{}"), .invalidType),
            (Self.bytes(regions: #"[{"target":"background","changes":null}]"#), .invalidType)
        ]
        for (data, error) in invalid {
            #expect(throws: AIEditingError.invalidResponse(error)) {
                try EditProposalValidator().validateImageEditingPlanEnvelope(data)
            }
        }
    }

    @Test
    func globalAndRegionalScalarsUseTheSameStrictValueContract() {
        let invalid: [(String, AIProposalValidationError)] = [
            (#"[{"parameter":"filePath","value":1}]"#, .unknownParameter),
            (#"[{"parameter":"exposure","value":9}]"#, .outOfRange),
            (#"[{"parameter":"shadows","value":1e999}]"#, .nonFiniteValue),
            (#"[{"parameter":"shadows","value":"20"}]"#, .invalidType),
            (#"[{"parameter":"shadows","value":20},{"parameter":"shadows","value":30}]"#, .duplicateParameter),
            (#"[{"parameter":"shadows"}]"#, .missingField)
        ]
        for (changes, error) in invalid {
            for data in [Self.bytes(changes: changes), Self.bytes(regions: #"[{"target":"background","changes":\#(changes)}]"#)] {
                #expect(throws: AIEditingError.invalidResponse(error)) {
                    try EditProposalValidator().validateImageEditingPlanEnvelope(data)
                }
            }
        }
    }

    @Test
    func bytesExplanationNestingAndValueBudgetsRemainBounded() {
        let data = Self.bytes()
        #expect(throws: AIEditingError.invalidResponse(.responseTooLarge)) {
            try EditProposalValidator(maximumResponseBytes: data.count - 1).validateImageEditingPlanEnvelope(data)
        }
        #expect(throws: AIEditingError.invalidResponse(.explanationTooLong)) {
            try EditProposalValidator(maximumExplanationBytes: 2).validateImageEditingPlanEnvelope(Self.bytes(explanation: "ää"))
        }
        #expect(throws: AIEditingError.invalidResponse(.nestingTooDeep)) {
            try EditProposalValidator(maximumNestingDepth: 4).validateImageEditingPlanEnvelope(data)
        }
        #expect(throws: AIEditingError.invalidResponse(.tooManyJSONValues)) {
            try EditProposalValidator(maximumJSONValues: 4).validateImageEditingPlanEnvelope(data)
        }
        #expect(throws: AIEditingError.invalidRequest) {
            try EditProposalValidator(maximumJSONValues: 0).validateImageEditingPlanEnvelope(data)
        }
    }

    @Test
    func imagePlanFieldsDoNotExtendExistingScalarWireSchema() {
        #expect(throws: AIEditingError.invalidResponse(.unknownField)) {
            try EditProposalValidator().validate(Self.bytes(), against: .neutral)
        }
    }

    private static func bytes(status: String = "proposal",
                              changes: String = #"[{"parameter":"shadows","value":20}]"#,
                              regions: String = #"[{"target":"background","changes":[{"parameter":"highlights","value":-30}]}]"#,
                              explanation: String = "Vorsichtige Korrektur.") -> Data {
        Data(#"{"status":"\#(status)","changes":\#(changes),"regions":\#(regions),"explanation":"\#(explanation)"}"#.utf8)
    }
}
