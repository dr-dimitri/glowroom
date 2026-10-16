import Foundation
import Testing
@testable import PicEditCore

@Suite("AI editing contracts and strict proposal validation")
struct AIContractsTests {
    private let validator = EditProposalValidator()
    private let baseline = EditSettings(
        exposure: 1.25, contrast: -22.5, highlights: 11.5, shadows: 10,
        whites: -13, blacks: 14, texture: 15, clarity: -16, dehaze: 17,
        vibrance: -18, saturation: 19, luminanceNoiseReduction: 20,
        colorNoiseReduction: 21, autoToneAmount: 22
    )

    @Test
    func fourteenIDsAreUniqueAndExhaustive() {
        #expect(EditParameter.allCases.count == 14)
        #expect(Set(EditParameter.allCases.map(\.rawValue)).count == 14)
        #expect(Set(EditParameter.allCases.map(\.rawValue)) == [
            "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
            "texture", "clarity", "dehaze", "vibrance", "saturation",
            "luminanceNoiseReduction", "colorNoiseReduction", "autoToneAmount"
        ])
    }

    @Test(arguments: EditParameter.allCases)
    func parameterMappingAndBoundaries(_ parameter: EditParameter) throws {
        // Compare the mapping independently to EditSettings' established wire keys;
        // a bijective but swapped pair of key paths must not pass this suite.
        let encodedBaseline = try JSONEncoder().encode(baseline)
        let baselineByID = try JSONDecoder().decode([String: Double].self, from: encodedBaseline)
        let expectedBaselineValue = try #require(baselineByID[parameter.rawValue])
        #expect(parameter.value(in: baseline) == expectedBaselineValue)
        let expectedRange: ClosedRange<Double>
        switch parameter {
        case .exposure: expectedRange = -5...5
        case .luminanceNoiseReduction, .colorNoiseReduction, .autoToneAmount: expectedRange = 0...100
        default: expectedRange = -100...100
        }
        #expect(parameter.range == expectedRange)
        for value in [expectedRange.lowerBound, expectedRange.upperBound, 0.125] {
            let proposal = EditProposal(changes: [.init(parameter: parameter, value: value)])
            let result = try validator.validate(proposal, against: baseline)
            guard case .changes(let returned, let target) = result else {
                Issue.record("A distinct in-range absolute target must produce a change")
                continue
            }
            #expect(returned == proposal)
            #expect(parameter.value(in: target) == value)
            for untouched in EditParameter.allCases where untouched != parameter {
                #expect(untouched.value(in: target) == untouched.value(in: baseline))
            }
            #expect(try validator.validate(JSONEncoder().encode(proposal), against: baseline) == result)
        }
        for value in [expectedRange.lowerBound - 0.001, expectedRange.upperBound + 0.001] {
            expectFailure(.outOfRange) {
                try validator.validate(EditProposal(changes: [.init(parameter: parameter, value: value)]), against: baseline)
            }
        }
    }

    @Test
    func patchValuesAreAbsoluteAndOtherControlsStayExact() throws {
        let data = Data(#"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":30}],"explanation":"Schatten aufhellen."}"#.utf8)
        let result = try validator.validate(data, against: baseline)
        guard case .changes(let proposal, let target) = result else { Issue.record("Expected change"); return }
        #expect(target.shadows == 30)
        #expect(target.shadows - baseline.shadows == 20)
        #expect(proposal.explanation == "Schatten aufhellen.")
        var expected = baseline
        expected.shadows = 30
        #expect(target == expected)
    }

    @Test
    func emptyAndIneffectivePatchesHaveExplicitNoChangeResult() throws {
        #expect(try validator.validate(Data(#"{"schemaVersion":1,"changes":[]}"#.utf8), against: baseline) == .noChange)
        #expect(try validator.validate(EditProposal(changes: [
            .init(parameter: .shadows, value: baseline.shadows),
            .init(parameter: .exposure, value: baseline.exposure)
        ]), against: baseline) == .noChange)
        #expect(try validator.validate(EditProposal(changes: [.init(parameter: .shadows, value: -0.0)]), against: .neutral) == .noChange)
    }

    @Test(arguments: invalidResponses)
    func rawJSONRejectsInvalidSchemaWithoutRepair(_ testCase: AIInvalidResponse) {
        expectFailure(testCase.category) {
            try validator.validate(Data(testCase.json.utf8), against: baseline)
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func typedProposalsRejectNonfiniteValues(_ value: Double) {
        expectFailure(.nonFiniteValue) {
            try validator.validate(EditProposal(changes: [.init(parameter: .exposure, value: value)]), against: baseline)
        }
    }

    @Test
    func duplicateIDsAndInvalidBaselineRejectWholeTypedPatch() {
        expectFailure(.duplicateParameter) {
            try validator.validate(EditProposal(changes: [
                .init(parameter: .shadows, value: 30), .init(parameter: .shadows, value: 40)
            ]), against: baseline)
        }
        expectFailure(.outOfRange) {
            try validator.validate(EditProposal(changes: [
                .init(parameter: .shadows, value: 30), .init(parameter: .exposure, value: 6)
            ]), against: baseline)
        }
        var invalidBaseline = baseline
        invalidBaseline.clarity = .nan
        expectFailure(.invalidBaseline) {
            try validator.validate(EditProposal(changes: []), against: invalidBaseline)
        }
        #expect(baseline.shadows == 10)
        #expect(baseline.exposure == 1.25)
    }

    @Test
    func byteDepthNodeAndTextLimitsAreEnforced() throws {
        let minimal = Data(#"{"schemaVersion":1,"changes":[]}"#.utf8)
        #expect(try EditProposalValidator(maximumResponseBytes: minimal.count).validate(minimal, against: baseline) == .noChange)
        expectFailure(.responseTooLarge) {
            try EditProposalValidator(maximumResponseBytes: minimal.count - 1).validate(minimal, against: baseline)
        }
        expectFailure(.explanationTooLong) {
            try EditProposalValidator(maximumExplanationBytes: 3).validate(
                EditProposal(changes: [], explanation: "😀"), against: baseline)
        }
        #expect(try EditProposalValidator(maximumExplanationBytes: 4).validate(
            EditProposal(changes: [], explanation: "😀"), against: baseline) == .noChange)
        expectFailure(.nestingTooDeep) {
            try EditProposalValidator(maximumNestingDepth: 4).validate(
                Data(#"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":[0]}]}"#.utf8), against: baseline)
        }
        expectFailure(.tooManyJSONValues) {
            try EditProposalValidator(maximumJSONValues: 2).validate(minimal, against: baseline)
        }
        expectFailure(.tooManyChanges) {
            try validator.validate(EditProposal(changes: Array(repeating: .init(parameter: .shadows, value: 2), count: 15)), against: baseline)
        }
        #expect(throws: AIEditingError.invalidRequest) {
            try EditProposalValidator(maximumNestingDepth: 65).validate(minimal, against: baseline)
        }
    }

    @Test
    func escapedKeysUnicodeAndScientificNumbersAreValid() throws {
        let raw = #"{"schema\u0056ersion":1,"changes":[{"parameter":"shadows","value":3e1}],"explanation":"Grüße \uD83D\uDE00"}"#
        guard case .changes(let proposal, let target) = try validator.validate(Data(raw.utf8), against: baseline) else {
            Issue.record("Valid escaped JSON should decode"); return
        }
        #expect(target.shadows == 30)
        #expect(proposal.explanation == "Grüße 😀")
        let whitespace = " \t\r\n" + #"{"schemaVersion":1,"changes":[]}"# + "\r\n\t "
        #expect(try validator.validate(Data(whitespace.utf8), against: baseline) == .noChange)
    }

    @Test
    func malformedUTF8AndSurrogatesAreRejected() {
        var bytes = Array(#"{"schemaVersion":1,"changes":[],"explanation":""#.utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: [34, 125])
        expectFailure(.malformedJSON) { try validator.validate(Data(bytes), against: baseline) }
        expectFailure(.malformedJSON) {
            try validator.validate(Data(#"{"schemaVersion":1,"changes":[],"explanation":"\uD800"}"#.utf8), against: baseline)
        }
    }

    @Test
    func requestContextIsAppOwnedAndInputValidationPrecedesProviderWork() throws {
        let source = AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/tmp/album/../photo.raw"),
                                                 modifiedAt: Date(timeIntervalSince1970: 123), fileSize: 500)
        #expect(source.standardizedPath == "/tmp/photo.raw")
        let token = AIEditingToken(editSessionID: UUID(), editGeneration: 3,
                                   selectionSessionID: UUID(), selectionGeneration: 7)
        let snapshot = AIEditingSnapshot(assetID: "photo", source: .original(source), settings: baseline, token: token)
        let request = AIEditingRequest(prompt: "Helle die Schatten auf.", snapshot: snapshot)
        try request.validate()
        try snapshot.validate()
        #expect(request.snapshot == snapshot)
        #expect(request.id != AIEditingRequest(prompt: request.prompt, snapshot: snapshot).id)
        #expect(throws: AIEditingError.invalidRequest) { try request.validate(maximumPromptBytes: 1) }
        #expect(throws: AIEditingError.invalidRequest) { try AIEditingRequest(prompt: " \n\t", snapshot: snapshot).validate() }
        let remoteSource = AIOriginalSourceFingerprint(fileURL: URL(string: "https://example.invalid/photo.raw")!, modifiedAt: Date(), fileSize: 1)
        let remoteSnapshot = AIEditingSnapshot(assetID: "photo", source: .original(remoteSource), settings: baseline, token: token)
        #expect(throws: AIEditingError.invalidRequest) { try remoteSnapshot.validate() }
        #expect(throws: AIEditingError.invalidRequest) { try AIEditingRequest(prompt: "Edit", snapshot: remoteSnapshot).validate() }
        let invalidSource = AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/tmp/photo.raw"), modifiedAt: Date(), fileSize: -1)
        let invalidSnapshot = AIEditingSnapshot(assetID: "photo", source: .original(invalidSource), settings: baseline, token: token)
        #expect(throws: AIEditingError.invalidRequest) { try AIEditingRequest(prompt: "Edit", snapshot: invalidSnapshot).validate() }
        var invalidSettings = baseline
        invalidSettings.exposure = 6
        let invalidBaselineSnapshot = AIEditingSnapshot(assetID: "photo", source: .original(source), settings: invalidSettings, token: token)
        #expect(throws: AIEditingError.invalidRequest) { try invalidBaselineSnapshot.validate() }
        #expect(throws: AIEditingError.invalidRequest) { try AIEditingRequest(prompt: "Edit", snapshot: invalidBaselineSnapshot).validate() }
        let longRequest = AIEditingRequest(prompt: String(repeating: "x", count: 17_000), snapshot: snapshot)
        try longRequest.validate(maximumPromptBytes: 20_000)
        try longRequest.snapshot.validate()
        #expect(throws: AIEditingError.invalidRequest) { try longRequest.validate() }
    }

    private func expectFailure(_ category: AIProposalValidationError,
                               operation: () throws -> EditProposalValidationResult) {
        do {
            _ = try operation()
            Issue.record("Expected invalid response: \(category.rawValue)")
        } catch let error as AIEditingError {
            #expect(error == .invalidResponse(category))
        } catch {
            Issue.record("Unexpected error type")
        }
    }
}

struct AIInvalidResponse: Sendable {
    let json: String
    let category: AIProposalValidationError
}

private let invalidResponses: [AIInvalidResponse] = [
    .init(json: #"{"schemaVersion":2,"changes":[]}"#, category: .unsupportedSchemaVersion),
    .init(json: #"{"schemaVersion":1,"changes":[],"requestID":"forged"}"#, category: .unknownField),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":30,"delta":10}]}"#, category: .unknownField),
    .init(json: #"{"schemaVersion":1,"schemaVersion":1,"changes":[]}"#, category: .duplicateField),
    .init(json: #"{"schemaVersion":1,"schema\u0056ersion":1,"changes":[]}"#, category: .duplicateField),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":30,"\u0076alue":40}]}"#, category: .duplicateField),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":30},{"parameter":"shadows","value":30}]}"#, category: .duplicateParameter),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"unknown","value":30}]}"#, category: .unknownParameter),
    .init(json: #"{"schemaVersion":true,"changes":[]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":"1","changes":[]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1.0,"changes":[]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":null}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":{}}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[null]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":null,"value":3}]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":true}]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":null}]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":"30"}]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":{}}]}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[],"explanation":null}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1,"changes":[],"explanation":false}"#, category: .invalidType),
    .init(json: #"{"schemaVersion":1}"#, category: .missingField),
    .init(json: #"{"changes":[]}"#, category: .missingField),
    .init(json: #"{"schemaVersion":1,"changes":[{"value":30}]}"#, category: .missingField),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows"}]}"#, category: .missingField),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"exposure","value":5.01}]}"#, category: .outOfRange),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":1e9999}]}"#, category: .nonFiniteValue),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":NaN}]}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":Infinity}]}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":01}]}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":+1}]}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":1.}]}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[{"parameter":"shadows","value":1e}]}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[],}"#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[]} {}"#, category: .malformedJSON),
    .init(json: "```json\n" + #"{"schemaVersion":1,"changes":[]}"# + "\n```", category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":["#, category: .malformedJSON),
    .init(json: #"{"schemaVersion":1,"changes":[],"explanation":"\x"}"#, category: .malformedJSON),
    .init(json: "", category: .malformedJSON),
    .init(json: "[]", category: .invalidType)
]
