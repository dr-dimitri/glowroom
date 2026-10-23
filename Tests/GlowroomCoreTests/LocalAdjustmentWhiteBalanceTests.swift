import Foundation
import Testing
@testable import GlowroomCore

@Suite("Persistent mask white balance")
struct LocalAdjustmentWhiteBalanceTests {
    @Test func historicMaskControlsKeepTheirCanonicalBytes() throws {
        let bytes = Data(#"{"blacks":0,"clarity":0,"contrast":0,"dehaze":0,"exposure":1,"highlights":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":0}"#.utf8)
        let restored = try ArtifactJSONCodec.decode(LocalAdjustmentSettings.self, from: bytes)
        #expect(restored.temperature == 6_500 && restored.tint == 0)
        #expect(restored == LocalAdjustmentSettings(exposure: 1))
        #expect(try ArtifactJSONCodec.encode(restored) == bytes)
    }

    @Test func whiteBalanceSurvivesSnapshotAndReusesTheColorGraph() throws {
        let controls = LocalAdjustmentSettings(temperature: 8_500, tint: -40)
        let layer = try LocalAdjustment(name: "Blumenstrauß", mask: .init(shape: .subject(
            .init(width: 2, height: 1, bytes: Data([255, 0])))), settings: controls)
        let snapshot = try EditingSnapshot(settings: .init(localAdjustments: [layer]))
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(snapshot)) == snapshot)
        #expect(controls.editSettings.developColor == DevelopColorSettings(temperature: 8_500, tint: -40))
        #expect(controls.normalized == controls)
        #expect(!controls.isNeutral && layer.isEffective)
        #expect(snapshot.settings.developColor == .neutral)
    }

    @Test func malformedNewFieldsNeverSilentlyBecomeNeutral() throws {
        let bytes = try ArtifactJSONCodec.encode(LocalAdjustmentSettings.neutral)
        let baseline = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (field, value) in [("temperature", 1_999 as Any), ("tint", 151 as Any),
                               ("temperature", NSNull() as Any), ("tint", "0" as Any),
                               ("temperature", true as Any)] {
            var invalid = baseline; invalid[field] = value
            let data = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(LocalAdjustmentSettings.self, from: data) }
        }
        #expect(LocalAdjustmentSettings(temperature: .nan, tint: .infinity).normalized == .neutral)
        #expect(LocalAdjustmentSettings(temperature: 20_000, tint: -200).normalized == .init(temperature: 12_000, tint: -150))
    }
}
