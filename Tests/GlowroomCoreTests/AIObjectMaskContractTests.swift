import Foundation
import Testing
@testable import GlowroomCore

@Suite("AI object localization response boundary")
struct AIObjectMaskContractTests {
    private static let valid = #"{"summary":"Blumenstrauß im Vordergrund.","name":"Blumenstrauß","box":[100,200,800,900]}"#

    @Test func integerBoxRoundTripsInFullSourceCoordinates() throws {
        let proposal = try AIObjectMaskProposal.decode(Data(Self.valid.utf8))
        #expect(proposal.name == "Blumenstrauß")
        #expect(proposal.bounds == (try DevelopCropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.7)))
        #expect(try AIObjectMaskProposal.decode(JSONEncoder().encode(proposal)) == proposal)
        let prompt = try AIObjectMaskProposal.prompt(instruction: "Maskiere den Blumenstrauß")
        #expect(prompt.contains("TOP LEFT") && prompt.contains("separate segmentation model"))
        #expect(prompt.contains("Maskiere den Blumenstrauß") && prompt.contains("stems"))
        #expect(try JSONSerialization.jsonObject(with: Data(AIObjectMaskProposal.schema.utf8)) is [String: Any])
    }

    @Test(arguments: [
        #"{"summary":"x","name":"x","box":[]}"#,
        #"{"summary":"x","name":"x","box":[1,2,3]}"#,
        #"{"summary":"x","name":"x","box":[1,2,3,4,5]}"#,
        #"{"summary":"x","name":"x","box":[true,0,100,100]}"#,
        #"{"summary":"x","name":"x","box":["0",0,100,100]}"#,
        #"{"summary":"x","name":"x","box":[null,0,100,100]}"#,
        #"{"summary":"x","name":"x","box":[0.5,0,100,100]}"#,
        #"{"summary":"x","name":"x","box":[-1,0,100,100]}"#,
        #"{"summary":"x","name":"x","box":[0,0,1001,100]}"#,
        #"{"summary":"x","name":"x","box":[0,0,100,100],"command":"write"}"#,
        #"{"summary":"x","name":" ","box":[0,0,100,100]}"#,
        #"{"summary":" ","name":"x","box":[0,0,100,100]}"#,
        #"{"summary":"x","name":"x","box":[100,0,100,100]}"#,
        #"{"summary":"x","name":"x","box":[0,100,100,100]}"#,
        #"{"summary":"x","name":"x","box":[100,0,0,100]}"#
    ])
    func invalidResponsesAreRejected(json: String) {
        #expect(throws: AIObjectMaskError.invalidResponse) { try AIObjectMaskProposal.decode(Data(json.utf8)) }
    }

    @Test func directDecodingAlsoValidatesBoundsAndTextLimits() throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AIObjectMaskProposal.self,
                from: Data(#"{"summary":"x","name":"x","box":[0,0,1001,100]}"#.utf8))
        }
        #expect(throws: AIObjectMaskError.invalidResponse) {
            try AIObjectMaskProposal(summary: "x", name: String(repeating: "ä", count: 129), box: [0, 0, 100, 100])
        }
        #expect(throws: AIObjectMaskError.invalidInstruction) { try AIObjectMaskProposal.prompt(instruction: " \n") }
        #expect(throws: AIObjectMaskError.invalidInstruction) {
            try AIObjectMaskProposal.prompt(instruction: String(repeating: "ä", count: 1_025))
        }
        #expect(throws: AIObjectMaskError.invalidInstruction) { try AIObjectMaskProposal.prompt(instruction: "Blume\0") }
        #expect(throws: AIObjectMaskError.invalidResponse) {
            try AIObjectMaskProposal.decode(Data(repeating: 32, count: 16_385))
        }
    }
}
