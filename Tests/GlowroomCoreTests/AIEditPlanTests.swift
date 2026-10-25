import Foundation
import Testing
@testable import GlowroomCore

@Suite("Atomic semantic mask edit plans")
struct AIEditPlanTests {
    @Test func strictTargetBoundaryRejectsUnknownAndUnsupportedOutput() throws {
        let valid = Data(#"{"kind":"sky","description":"Himmel","summary":"Himmel abdunkeln"}"#.utf8)
        #expect(try AIEditPlanTarget.decode(valid).kind == .sky)
        for bytes in [
            #"{"kind":"sky","description":"Himmel","summary":"x","command":"write"}"#,
            #"{"kind":"unsupported","description":"Zwei Ziele","summary":"Getrennt bearbeiten"}"#,
            #"{"kind":"sky","description":"","summary":"x"}"#,
            #"{"kind":"sky","description":42,"summary":"x"}"#,
            #"{"kind":"global","description":"Himmel","summary":"x"}"#
        ] { #expect(throws: (any Error).self) { try AIEditPlanTarget.decode(Data(bytes.utf8)) } }
        #expect(!AIEditPlanQualification.productEnabled, "Native gate is required before exposing this workflow")
    }

    @Test func completePlanPreservesEveryExistingGroupAndRejectsEqualSettingsFromAnotherEpoch() throws {
        var settings = EditSettings(exposure: 0.7, contrast: 12)
        settings.localAdjustments = [try mask(name: "Vorhanden", exposure: 0.3)]
        settings.developGeometry = DevelopGeometry(crop: try DevelopCropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
            quarterTurns: 1, flipHorizontal: true)
        let baseline = snapshot(settings)
        let draft = try mask()
        let plan = try AIEditPlan(baseline: baseline, target: target(), maskDraft: draft,
            proposal: .init(summary: "Dunkler und kühler", adjustments: .init(exposure: -0.7, temperature: 5_700)),
            provenance: provenance)
        let result = try plan.applying(to: baseline)
        #expect(result.localAdjustments.count == 2)
        #expect(result.localAdjustments[0] == settings.localAdjustments[0])
        #expect(result.localAdjustments[1].id == draft.id && result.localAdjustments[1].mask == draft.mask)
        #expect(result.localAdjustments[1].settings.exposure == -0.7)
        #expect(result.localAdjustments[1].settings.temperature == 5_700)
        var withoutNewLayer = result; withoutNewLayer.localAdjustments.removeLast()
        #expect(withoutNewLayer == settings, "No global, geometry, repair or existing mask side effects")
        let encoded = try ArtifactJSONCodec.encode(EditingSnapshot(settings: result))
        #expect(!encoded.isEmpty, "Accepted values use ordinary immutable snapshot storage")
        #expect(throws: AIEditPlanError.staleContext) { try plan.applying(to: snapshot(settings)) }
        #expect(throws: AIEditPlanError.staleContext) { try plan.applying(to: snapshot(.neutral)) }
    }

    @Test func emptyNoOpAndInvalidPlansNeverReturnAnAcceptablePartialMask() throws {
        let baseline = snapshot(.neutral)
        #expect(throws: AIEditPlanError.ineffectiveCorrection) {
            try AIEditPlan(baseline: baseline, target: target(), maskDraft: mask(),
                proposal: .init(summary: "Unverändert", adjustments: .init(exposure: 0)), provenance: provenance)
        }
        let empty = try LocalAdjustment(name: "Leer", mask: .init(shape: .sky(.init(width: 1, height: 1, bytes: Data([0])))))
        #expect(throws: AIEditPlanError.emptySelection) {
            try AIEditPlan(baseline: baseline, target: target(), maskDraft: empty,
                proposal: .init(summary: "Dunkler", adjustments: .init(exposure: -1)), provenance: provenance)
        }
        #expect(throws: AIDevelopmentError.invalidResponse) {
            try AIEditPlan(baseline: baseline, target: target(), maskDraft: mask(),
                proposal: .init(summary: "Ungültig", adjustments: .init(exposure: 500)), provenance: provenance)
        }
        #expect(baseline.settings == .neutral)
    }

    @Test func typedTargetsCannotAcceptDifferentMaskKindsOrEmptyForegroundComplements() throws {
        let baseline = snapshot(.neutral)
        let proposal = AIDevelopmentProposal(summary: "Dunkler", adjustments: .init(exposure: -1))
        for kind in [AIEditPlanTargetKind.subject, .background, .object] {
            let target = try AIEditPlanTarget(kind: kind, description: "Ziel", summary: "Dunkler")
            #expect(throws: AIEditPlanError.invalidResponse) {
                try AIEditPlan(baseline: baseline, target: target, maskDraft: mask(), proposal: proposal, provenance: provenance)
            }
        }
        let background = try AIEditPlanTarget(kind: .background, description: "Hintergrund", summary: "Dunkler")
        for byte: UInt8 in [0, 255] {
            let invalid = try LocalAdjustment(name: "Hintergrund", mask: .init(shape: .subject(.init(width: 1, height: 1, bytes: Data([byte]))), isInverted: true, feather: 0))
            #expect(throws: AIEditPlanError.emptySelection) {
                try AIEditPlan(baseline: baseline, target: background, maskDraft: invalid, proposal: proposal, provenance: provenance)
            }
        }
    }

    private var provenance: AIEditPlanProvenance {
        .init(languageModelRevision: "test", maskModelRevision: "test", preprocessingVersion: "test-v1")
    }
    private func target() throws -> AIEditPlanTarget { try .init(kind: .sky, description: "Himmel", summary: "Dunkler") }
    private func mask(name: String = "Himmel", exposure: Double = 0) throws -> LocalAdjustment {
        var values = LocalAdjustmentSettings.neutral; values.exposure = exposure
        return try .init(name: name, mask: .init(shape: .sky(.init(width: 2, height: 2, bytes: Data([255, 127, 0, 0]))), feather: 0), settings: values)
    }
    private func snapshot(_ settings: EditSettings) -> AIEditingSnapshot {
        .init(assetID: "plan", source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/plan.png"), modifiedAt: .distantPast, fileSize: 1)),
            settings: settings, token: .init(editSessionID: UUID(), editGeneration: 0, selectionSessionID: UUID(), selectionGeneration: 0))
    }
}
