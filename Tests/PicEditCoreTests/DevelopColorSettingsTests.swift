import Foundation
import Testing
@testable import PicEditCore

@Suite("Develop color contracts and snapshot compatibility")
struct DevelopColorSettingsTests {
    private let legacy = Data(#"{"schemaVersion":2,"settings":{"autoToneAmount":100,"blacks":7,"clarity":0,"colorNoiseReduction":0,"contrast":0,"dehaze":0,"exposure":0,"highlights":0,"luminanceNoiseReduction":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":-1},"source":{"kind":"original"}}"#.utf8)

    @Test func neutralComponentDoesNotChangeHistoricalSnapshotBytesOrDigests() throws {
        let snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: legacy)
        #expect(snapshot.settings.developColor == .neutral)
        #expect(snapshot.settings.developGeometry == .neutral)
        #expect(try ArtifactJSONCodec.encode(snapshot) == legacy)
        #expect(try ArtifactJSONCodec.digest(snapshot) == ArtifactJSONCodec.digestBytes(legacy))
        let current = try ArtifactJSONCodec.encode(EditingSnapshot())
        #expect(!String(decoding: current, as: UTF8.self).contains("developColor"))
        #expect(!String(decoding: current, as: UTF8.self).contains("developGeometry"))
    }

    @Test(arguments: DevelopColorProfile.allCases)
    func newColorStateRoundTripsWithoutLosingExistingControls(profile: DevelopColorProfile) throws {
        let settings = EditSettings(exposure: 0.4, naturalBalanceAmount: 35,
            developColor: .init(temperature: 8_300, tint: 17, profile: profile, isMonochrome: true, hdrEnabled: true))
        let snapshot = try EditingSnapshot(settings: settings)
        let bytes = try ArtifactJSONCodec.encode(snapshot)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes) == snapshot)
        #expect(try ArtifactJSONCodec.encode(ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes)) == bytes)
        #expect(try ArtifactJSONCodec.decode(EditSettings.self, from: ArtifactJSONCodec.encode(settings)) == settings)
        #expect(!settings.isNeutral)
        #expect(EditSettings(developColor: .init(hdrEnabled: true)).isNeutral == false)
        #expect(EditSettings(developColor: .init(isMonochrome: true)).isNeutral == false)
    }

    @Test func malformedAndExplicitNeutralComponentsCannotPassStrictSnapshotValidation() throws {
        let valid = try ArtifactJSONCodec.encode(EditingSnapshot(settings: .init(developColor: .init(temperature: 7_000))))
        let base = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for target in ["missing", "unknown", "temperature", "tint", "profile", "isMonochrome", "hdrEnabled", "null", "neutral"] {
            var object = base
            var settings = try #require(object["settings"] as? [String: Any])
            var component = try #require(settings["developColor"] as? [String: Any])
            switch target {
            case "missing": component.removeValue(forKey: "temperature")
            case "unknown": component["future"] = 1
            case "temperature": component["temperature"] = 15_000
            case "tint": component["tint"] = -151
            case "profile": component["profile"] = "adobeColor"
            case "isMonochrome": component["isMonochrome"] = 1
            case "hdrEnabled": component["hdrEnabled"] = "true"
            case "neutral": component["temperature"] = 6_500
            default: break
            }
            settings["developColor"] = target == "null" ? NSNull() : component
            object["settings"] = settings
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
        #expect(DevelopColorSettings(temperature: .nan, tint: .infinity).normalized == .neutral)
        #expect(throws: ArtifactContractError.self) {
            try EditingSnapshot(settings: .init(developColor: .init(temperature: .nan)))
        }
    }

    @Test func scalarEditsPreserveTheEntireDevelopColorBaseline() throws {
        let color = DevelopColorSettings(temperature: 4_500, tint: -24, profile: .portrait, isMonochrome: true, hdrEnabled: true)
        let original = EditSettings(developColor: color)
        let result = try EditParameter.exposure.applying(0.5, to: original)
        #expect(result.developColor == color)
        #expect(result.exposure == 0.5)
    }

    @Test func newColorStateSurvivesDurableSQLBackupAndRestore() async throws {
        let fixture = try EditingFixture()
        let state = try await fixture.repository.loadState()
        let snapshot = try EditingSnapshot(settings: .init(developColor: .init(temperature: 7_300, tint: 13,
            profile: .vivid, isMonochrome: true, hdrEnabled: true)))
        let stored = try await fixture.repository.saveSnapshot(snapshot, for: fixture.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let backup = try await fixture.repository.createBackup(automatic: false)
        _ = try await fixture.repository.saveSnapshot(.init(), for: fixture.id, expected: .init(stored), revision: 2)
        let restored = try await fixture.repository.restoreBackup(from: backup)
        #expect(restored.byAsset[fixture.id]?.snapshot == snapshot)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot == snapshot)
    }

    @Test func neutralMatrixIsExactAndPipetteRejectsUnreliableSamples() {
        #expect(DevelopWhiteBalance.matrix(temperature: 6_500, tint: 0) == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let neutral = DevelopWhiteBalance.neutralizing(sRGBRed: 0.5, green: 0.5, blue: 0.5)
        #expect(neutral?.temperature == 6_500 && neutral?.tint == 0 && neutral?.isClamped == false)
        #expect(DevelopWhiteBalance.neutralizing(sRGBRed: 0, green: 0, blue: 0) == nil)
        #expect(DevelopWhiteBalance.neutralizing(sRGBRed: 1, green: 0.5, blue: 0.5) == nil)
        #expect(DevelopWhiteBalance.neutralizing(sRGBRed: 0.3, green: 0.4, blue: 0.5, alpha: 0.1) == nil)
        #expect(DevelopWhiteBalance.neutralizing(sRGBRed: 0.3, green: 0.4, blue: 0.5, alpha: 1.1) == nil)
        #expect(DevelopWhiteBalance.neutralizing(sRGBRed: .nan, green: 0.4, blue: 0.5) == nil)
        let large = DevelopWhiteBalance.neutralizing(linearRed: 1e308, green: 5e307, blue: 3e307)
        #expect(large?.temperature.isFinite == true && large?.tint.isFinite == true)
    }

    @Test(arguments: [3_000.0, 4_500, 6_500, 8_500, 11_000])
    func pipetteAndBradfordMatrixAgreeForKnownIlluminants(temperature: Double) throws {
        for tint in [-60.0, 0, 60] {
            let white = DevelopWhiteBalance.sourceWhiteLinearRGB(temperature: temperature, tint: tint)
            let sample = white.map { $0 * 0.18 }
            let correction = try #require(DevelopWhiteBalance.neutralizing(linearRed: sample[0], green: sample[1], blue: sample[2]))
            #expect(abs(correction.temperature - temperature) < 2)
            #expect(abs(correction.tint - tint) < 0.1)
            #expect(!correction.isClamped)
            let matrix = DevelopWhiteBalance.matrix(temperature: correction.temperature, tint: correction.tint)
            let neutral = (0..<3).map { row in
                matrix[row * 3] * sample[0] + matrix[row * 3 + 1] * sample[1] + matrix[row * 3 + 2] * sample[2]
            }
            #expect((neutral.max()! - neutral.min()!) < 0.000_1)
        }
    }
}
