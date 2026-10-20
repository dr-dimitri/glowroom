import Foundation
import Testing
@testable import PicEditCore

@Suite("Sharpening persistence and editing contracts")
struct SharpeningSettingsTests {
    // Historical bytes predate all optional editing controls. Keep this frozen
    // so decoding tests cannot accidentally gain sharpening from today's encoder.
    private let legacy = Data(#"{"exposure":0.75,"contrast":12,"highlights":-35,"shadows":28,"whites":-8,"blacks":-5,"texture":10,"clarity":6,"dehaze":4,"vibrance":9,"saturation":-3,"luminanceNoiseReduction":15,"colorNoiseReduction":20}"#.utf8)

    @Test func oldEditsKeepTheirValuesAndDoNotEnableSharpening() throws {
        let settings = try JSONDecoder().decode(EditSettings.self, from: legacy)
        #expect(settings == EditSettings(exposure: 0.75, contrast: 12, highlights: -35,
            shadows: 28, whites: -8, blacks: -5, texture: 10, clarity: 6,
            dehaze: 4, vibrance: 9, saturation: -3,
            luminanceNoiseReduction: 15, colorNoiseReduction: 20))
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.keys.allSatisfy { !$0.hasPrefix("sharpening") })
    }

    @Test(arguments: ["sharpeningAmount", "sharpeningRadius", "sharpeningDetail", "sharpeningMasking"])
    func onlyMissingKeysReceiveDefaults(key: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        for invalid in [NSNull(), "strong", true] as [Any] {
            object[key] = invalid
            let bytes = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(EditSettings.self, from: bytes) }
        }
    }

    @Test func preferencesAreDormantAtZeroAndSurviveDisablingTheEffect() throws {
        let dormant = EditSettings(sharpeningRadius: 2.4, sharpeningDetail: 70, sharpeningMasking: 85)
        #expect(dormant.isNeutral)
        #expect(dormant.normalized == dormant)
        #expect(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(dormant)) == dormant)
        let active = try EditParameter.sharpeningAmount.applying(40, to: dormant)
        #expect(!active.isNeutral)
        #expect(active.sharpeningRadius == 2.4 && active.sharpeningDetail == 70 && active.sharpeningMasking == 85)
        #expect(try EditParameter.sharpeningAmount.applying(0, to: active) == dormant)
        #expect(Set([dormant, active, .neutral]).count == 3)
    }

    @Test func normalizationHandlesFiniteLimitsAndUsesValidNonfiniteDefaults() {
        let high = EditSettings(sharpeningAmount: 200, sharpeningRadius: 10,
            sharpeningDetail: 200, sharpeningMasking: 200).normalized
        #expect(high == EditSettings(sharpeningAmount: 150, sharpeningRadius: 3,
            sharpeningDetail: 100, sharpeningMasking: 100))
        let low = EditSettings(sharpeningAmount: -1, sharpeningRadius: -1,
            sharpeningDetail: -1, sharpeningMasking: -1).normalized
        #expect(low == EditSettings(sharpeningRadius: 0.5, sharpeningDetail: 0))
        #expect(low.isNeutral)
        for nonfinite in [Double.nan, .infinity, -.infinity] {
            let invalid = EditSettings(sharpeningAmount: nonfinite, sharpeningRadius: nonfinite,
                sharpeningDetail: nonfinite, sharpeningMasking: nonfinite)
            #expect(invalid.normalized == .neutral)
        }
    }

    @Test func snapshotAndDurableBackupKeepAllSharpeningPreferences() async throws {
        let fixture = try EditingFixture()
        let settings = EditSettings(exposure: 0.4, sharpeningAmount: 60,
            sharpeningRadius: 1.7, sharpeningDetail: 42, sharpeningMasking: 73)
        let snapshot = try EditingSnapshot(settings: settings)
        let bytes = try ArtifactJSONCodec.encode(snapshot)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes) == snapshot)
        let state = try await fixture.repository.loadState()
        let stored = try await fixture.repository.saveSnapshot(snapshot, for: fixture.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let backup = try await fixture.repository.createBackup(automatic: false)
        _ = try await fixture.repository.saveSnapshot(.init(), for: fixture.id, expected: .init(stored), revision: 2)
        let restored = try await fixture.repository.restoreBackup(from: backup)
        #expect(restored.byAsset[fixture.id]?.snapshot.settings == settings)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot.settings == settings)
    }
}
