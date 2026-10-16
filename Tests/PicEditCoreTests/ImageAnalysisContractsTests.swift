import Foundation
import Testing
@testable import PicEditCore

@Suite("Image analysis bounded contracts")
struct ImageAnalysisContractsTests {
    @Test
    func originalIgnoresSlidersButRejectsSelectionRestoreSourceAndLifecycleChanges() throws {
        let request = analysisContractRequest()
        try request.validate()
        let snapshot = request.snapshot
        let token = snapshot.token
        let slid = AIEditingSnapshot(assetID: snapshot.assetID, source: snapshot.source, settings: EditSettings(exposure: 1),
            token: AIEditingToken(editSessionID: token.editSessionID, editGeneration: token.editGeneration + 1,
                                  selectionSessionID: token.selectionSessionID, selectionGeneration: token.selectionGeneration))
        #expect(request.matches(current: slid, lifecycleID: request.lifecycleID))
        let edited = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: request.lifecycleID)
        #expect(!edited.matches(current: slid, lifecycleID: request.lifecycleID))
        #expect(!request.matches(current: snapshot, lifecycleID: UUID()))
        for changed in [
            AIEditingToken(editSessionID: UUID(), editGeneration: token.editGeneration, selectionSessionID: token.selectionSessionID, selectionGeneration: token.selectionGeneration),
            AIEditingToken(editSessionID: token.editSessionID, editGeneration: token.editGeneration, selectionSessionID: UUID(), selectionGeneration: token.selectionGeneration),
            AIEditingToken(editSessionID: token.editSessionID, editGeneration: token.editGeneration, selectionSessionID: token.selectionSessionID, selectionGeneration: token.selectionGeneration + 2)
        ] {
            #expect(!request.matches(current: AIEditingSnapshot(assetID: snapshot.assetID, source: snapshot.source, settings: snapshot.settings, token: changed), lifecycleID: request.lifecycleID))
        }
        let changedSource = AIEditingSnapshot(assetID: snapshot.assetID,
            source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/tmp/different.png"), modifiedAt: Date(), fileSize: 1)), settings: snapshot.settings, token: token)
        #expect(!request.matches(current: changedSource, lifecycleID: request.lifecycleID))
    }

    @Test
    func languageAndCapabilitiesAreExplicit() {
        let base = analysisContractRequest()
        #expect(ImageAnalysisProviderDescriptor(providerID: "local", modelID: "vision").capabilities == [.imageUnderstanding])
        #expect(throws: ImageAnalysisError.unavailable(.unsupportedLanguage)) {
            try ImageAnalysisRequest(snapshot: base.snapshot, language: "en_US", lifecycleID: base.lifecycleID).validate()
        }
        for reason in [ImageAnalysisUnavailableReason.unsupportedSystem, .sdkUnavailable, .unsupportedHardware, .disabled, .modelUnavailable, .unsupportedLanguage, .unsupportedCapability, .temporaryFailure, .unknown] {
            #expect(!reason.localizedDescription.isEmpty)
            #expect(ImageAnalysisError.unavailable(reason).localizedDescription == reason.localizedDescription)
        }
    }

    @Test
    func strictSchemaHasNoModelOwnedIdentityAndKeepsUnicode() throws {
        let data = Data(#"{"schemaVersion":1,"description":"Ein roter Kreis.","attributes":[{"category":"color","value":"Rot und Blau – sichtbar"}]}"#.utf8)
        let result = try ImageAnalysisSuggestionValidator().validate(data)
        #expect(result.description == "Ein roter Kreis.")
        #expect(result.attributes == [.init(category: .color, value: "Rot und Blau – sichtbar")])
        #expect(throws: ImageAnalysisError.invalidResponse) { try ImageAnalysisSuggestionValidator(maximumResponseBytes: data.count - 1).validate(data) }
        #expect(try ImageAnalysisSuggestionValidator(maximumResponseBytes: data.count).validate(data) == result)
    }

    @Test(arguments: [
        #"{"schemaVersion":1,"description":"x","description":"y","attributes":[]}"#,
        #"{"schemaVersion":1,"description":"x","attributes":[],"rasterSHA256":"forged"}"#,
        #"{"schemaVersion":1,"description":"x","attributes":[],"source":"/secret"}"#,
        #"{"schemaVersion":1,"description":"x","attributes":[{"category":"identity","value":"Name"}]}"#,
        #"{"schemaVersion":1,"description":"x","attributes":[{"category":"color","value":"Rot","confidence":1}]}"#,
        #"{"schemaVersion":1,"description":"x","attributes":[{"category":"color","value":"Rot"},{"category":"color","value":"Rot"}]}"#,
        #"{"schemaVersion":1,"description":" ","attributes":[]}"#,
        #"{"schemaVersion":1.0,"description":"x","attributes":[]}"#,
        #"{"schemaVersion":2,"description":"x","attributes":[]}"#,
        #"{"schemaVersion":1,"description":"x","attributes":[]} trailing"#,
        #"{"schemaVersion":1,"description":"x","attributes":[],"deep":[[[[[[[[[[0]]]]]]]]]]}"#
    ])
    func malformedUnknownAndDuplicateValuesRejectWholeResponse(_ json: String) {
        #expect(throws: ImageAnalysisError.invalidResponse) { try ImageAnalysisSuggestionValidator().validate(Data(json.utf8)) }
    }

    @Test
    func typedByteAndCountLimitsRejectRatherThanTruncate() throws {
        try ImageAnalysisSuggestions(description: String(repeating: "ä", count: 1_024), attributes: [.init(category: .subject, value: String(repeating: "ä", count: 128))]).validate()
        for suggestions in [
            ImageAnalysisSuggestions(description: String(repeating: "ä", count: 1_025), attributes: []),
            ImageAnalysisSuggestions(description: "x", attributes: [.init(category: .color, value: String(repeating: "ä", count: 129))]),
            ImageAnalysisSuggestions(description: "x", attributes: [.init(category: .color, value: " \n")]),
            ImageAnalysisSuggestions(description: "x", attributes: (0..<13).map { .init(category: .color, value: "\($0)") })
        ] { #expect(throws: ImageAnalysisError.invalidResponse) { try suggestions.validate() } }
    }
}

private func analysisContractRequest() -> ImageAnalysisRequest {
    ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: "synthetic",
        source: .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/tmp/synthetic.png"), modifiedAt: Date(timeIntervalSince1970: 100), fileSize: 10)), settings: .neutral,
        token: AIEditingToken(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1)), lifecycleID: UUID())
}
