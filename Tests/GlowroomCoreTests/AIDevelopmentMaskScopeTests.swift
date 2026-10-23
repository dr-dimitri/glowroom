import Foundation
import Testing
@testable import GlowroomCore

@Suite("AI development mask scope")
struct AIDevelopmentMaskScopeTests {
    @Test func onlySelectedMaskChangesAndPromptUsesItsValues() throws {
        let mask = try LocalAdjustmentMask(shape: .radial(center: LocalMaskPoint(x: 0.3, y: 0.2),
            radiusX: 0.2, radiusY: 0.1, rotation: 0), isInverted: true, opacity: 0.7)
        let layer = try LocalAdjustment(name: "Blumenstrauß", mask: mask,
            settings: .init(exposure: -1, texture: 15, temperature: 7_000, tint: -20))
        let other = try LocalAdjustment(name: "Hintergrund", mask: mask, settings: .init(exposure: 2))
        var baseline = EditSettings(exposure: 3, texture: 21, localAdjustments: [other, layer])
        baseline.developColor.temperature = 8_000
        var intent = AIDevelopmentIntent(); intent.targetMaskID = layer.id
        let proposal = AIDevelopmentAdjustments(exposure: 1, temperature: 8_000, tint: 20)
        let result = try proposal.applying(to: baseline, intent: intent)
        var expected = baseline
        expected.localAdjustments[1].settings.exposure = 0
        expected.localAdjustments[1].settings.temperature = 7_500
        expected.localAdjustments[1].settings.tint = 0
        #expect(result == expected)
        let prompt = try intent.prompt(settings: baseline)
        #expect(prompt.contains("Blumenstrauß") && prompt.contains("\"exposure\":-1"))
        #expect(prompt.contains("\"temperature\":7000") && prompt.contains("artificially dimmed"))
        intent.strength = 0
        #expect(try proposal.applying(to: baseline, intent: intent) == baseline)
    }

    @Test(arguments: ["missing", "disabled", "transparent"])
    func unavailableMaskNeverFallsBackToGlobal(reason: String) throws {
        var layer = try LocalAdjustment(name: "Motiv", mask: LocalAdjustmentMask(shape: .subject(
            LocalMaskRaster(width: 1, height: 1, bytes: Data([255])))))
        var intent = AIDevelopmentIntent(); intent.targetMaskID = layer.id
        if reason == "disabled" { layer.isEnabled = false }
        if reason == "transparent" { layer.mask.opacity = 0 }
        let baseline = EditSettings(localAdjustments: reason == "missing" ? [] : [layer])
        #expect(throws: AIDevelopmentError.unavailableMask) {
            try AIDevelopmentAdjustments(exposure: 1).applying(to: baseline, intent: intent)
        }
        #expect(throws: AIDevelopmentError.unavailableMask) { try intent.prompt(settings: baseline) }
    }

    @Test func maskPromptDescribesWhiteBalanceRelativeToTheDevelopedInput() throws {
        let mask = try LocalAdjustmentMask(shape: .subject(.init(width: 1, height: 1, bytes: Data([255]))))
        let preceding = try LocalAdjustment(name: "Motiv", mask: mask, settings: .init(temperature: 8_000))
        let target = try LocalAdjustment(name: "Blumenstrauß", mask: mask, settings: .init(temperature: 6_000))
        let baseline = EditSettings(localAdjustments: [preceding, target], developColor: .init(temperature: 9_000))
        var intent = AIDevelopmentIntent(); intent.targetMaskID = target.id
        let local = try intent.prompt(settings: baseline)
        #expect(local.contains("6500 at tint 0 leaves the incoming developed image unchanged"))
        #expect(local.contains("relative to the global edits and preceding mask layers"))
        #expect(local.contains("\"temperature\":6000"))
        #expect(!local.contains("preserves the camera rendering"))
        intent.targetMaskID = nil
        let global = try intent.prompt(settings: baseline)
        #expect(global.contains("6500 preserves the camera rendering"))
        #expect(global.contains("\"temperature\":9000"))
        #expect(!global.contains("preceding mask layers"))
    }
}
