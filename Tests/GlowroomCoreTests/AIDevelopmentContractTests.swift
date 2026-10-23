import Foundation
import Testing
@testable import GlowroomCore

@Suite("AI development response boundary")
struct AIDevelopmentContractTests {
    @Test func absoluteTargetsBlendWithoutTouchingUnrelatedEdits() throws {
        var baseline = EditSettings(exposure: 1, shadows: 20, texture: 42, naturalBalanceAmount: 30)
        baseline.developColor.temperature = 7_000
        let proposal = try AIDevelopmentProposal.decode(Data(#"{"summary":"Schatten behutsam öffnen.","adjustments":{"exposure":2,"shadows":40,"temperature":6000}}"#.utf8))
        let result = try proposal.adjustments.applying(to: baseline, strength: 0.5)
        var expected = baseline; expected.exposure = 1.5; expected.shadows = 30; expected.developColor.temperature = 6_500
        #expect(result == expected)
        #expect(try proposal.adjustments.applying(to: baseline, strength: 0) == baseline)
    }

    @Test(arguments: [
        #"{"summary":"x","adjustments":{"exposure":6}}"#,
        #"{"summary":"x","adjustments":{"exposure":true}}"#,
        #"{"summary":"x","adjustments":{"exposure":"1"}}"#,
        #"{"summary":"x","adjustments":{"exposure":null}}"#,
        #"{"summary":"x","adjustments":{"unknown":1}}"#,
        #"{"summary":"x","adjustments":{},"shell":"rm"}"#,
        #"{"summary":" ","adjustments":{}}"#,
        #"{"summary":"x","adjustments":{"temperature":1999}}"#,
        #"{"summary":"x","adjustments":{"tint":151}}"#,
        #"{"summary":"x","adjustments":{"shadows":-101}}"#,
        #"{"summary":"x","adjustments":{"exposure":1}"#
    ])
    func malformedOrUnsupportedResponseIsRejected(json: String) {
        #expect(throws: AIDevelopmentError.invalidResponse) { try AIDevelopmentProposal.decode(Data(json.utf8)) }
    }

    @Test func noOpIsValidAndPromptContainsOnlySupportedCurrentValues() throws {
        let result = try AIDevelopmentProposal.decode(Data(#"{"summary":"Die aktuelle Stimmung bleibt erhalten.","adjustments":{}}"#.utf8))
        #expect(try result.adjustments.applying(to: .neutral) == .neutral)
        var intent = AIDevelopmentIntent(); intent.brightness = 0.7; intent.instruction = "Etwas heller"
        let prompt = try intent.prompt(settings: EditSettings(exposure: 1))
        #expect(prompt.contains("brightness=0.7") && prompt.contains("Etwas heller") && prompt.contains("\"exposure\":1"))
        #expect(!prompt.contains("fileURL") && !prompt.contains("assetID"))
        #expect(try JSONSerialization.jsonObject(with: Data(AIDevelopmentProposal.schema.utf8)) is [String: Any])
        intent.instruction = String(repeating: "ä", count: 1_025)
        #expect(throws: AIDevelopmentError.invalidIntent) { try intent.validate() }
        intent.instruction = ""; intent.brightness = .nan
        #expect(throws: AIDevelopmentError.invalidIntent) { try intent.validate() }
    }
}
