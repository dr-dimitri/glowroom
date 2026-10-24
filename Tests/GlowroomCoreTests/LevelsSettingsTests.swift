import Foundation
import Testing
@testable import GlowroomCore

@Suite("Global levels mathematical and persistence contracts")
struct LevelsSettingsTests {
    private let legacy = Data(#"{"schemaVersion":2,"settings":{"autoToneAmount":100,"blacks":7,"clarity":0,"colorNoiseReduction":0,"contrast":0,"dehaze":0,"exposure":0,"highlights":0,"luminanceNoiseReduction":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":-1},"source":{"kind":"original"}}"#.utf8)

    @Test func neutralLevelsPreserveHistoricalSnapshotBytesAndDigest() throws {
        let snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: legacy)
        #expect(snapshot.settings.levels == .neutral)
        #expect(try ArtifactJSONCodec.encode(snapshot) == legacy)
        #expect(try ArtifactJSONCodec.digest(snapshot) == ArtifactJSONCodec.digestBytes(legacy))
        let settingsBytes = try ArtifactJSONCodec.encode(EditSettings.neutral)
        #expect(!String(decoding: settingsBytes, as: UTF8.self).contains("levels"))
        #expect(try ArtifactJSONCodec.decode(EditSettings.self, from: settingsBytes).levels == .neutral)
    }

    @Test func nonNeutralLevelsRoundTripAndChangeSnapshotIdentity() throws {
        let levels = sampleLevels()
        let settings = EditSettings(exposure: 0.6, naturalBalanceAmount: 31, levels: levels)
        let snapshot = try EditingSnapshot(settings: settings)
        let encoded = try ArtifactJSONCodec.encode(snapshot)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: encoded) == snapshot)
        #expect(try ArtifactJSONCodec.encode(ArtifactJSONCodec.decode(EditingSnapshot.self, from: encoded)) == encoded)
        #expect(try ArtifactJSONCodec.decode(EditSettings.self, from: ArtifactJSONCodec.encode(settings)) == settings)
        #expect(try ArtifactJSONCodec.decode(LevelsSettings.self, from: ArtifactJSONCodec.encode(levels)) == levels)
        #expect(!settings.isNeutral)
        #expect(try EditingSnapshot(settings: .init()).settings.levels.isNeutral)
        #expect(snapshot != (try EditingSnapshot(settings: .init(exposure: 0.6, naturalBalanceAmount: 31))))
        #expect(try ArtifactJSONCodec.digest(snapshot) != ArtifactJSONCodec.digest(EditingSnapshot(settings: .init())))
        let edited = try EditParameter.exposure.applying(-1.2, to: settings)
        #expect(edited.levels == levels && edited.naturalBalanceAmount == settings.naturalBalanceAmount)
    }

    @Test func malformedPresentLevelsNeverBecomeNeutralDefaults() throws {
        let bytes = try ArtifactJSONCodec.encode(EditingSnapshot(settings: .init(levels: sampleLevels())))
        let base = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for target in ["missingCurve", "missingField", "unknown", "futureVersion", "futureTRC", "null", "gamma", "span", "reversed", "type", "neutral"] {
            var object = base
            var settings = try #require(object["settings"] as? [String: Any])
            var levels = try #require(settings["levels"] as? [String: Any])
            var master = try #require(levels["master"] as? [String: Any])
            switch target {
            case "missingCurve": levels.removeValue(forKey: "blue")
            case "missingField": master.removeValue(forKey: "gamma")
            case "unknown": levels["unexpected"] = true
            case "futureVersion": levels["version"] = 2
            case "futureTRC": levels["transferFunction"] = "linearFuture"
            case "gamma": master["gamma"] = 0
            case "span": master["inputWhite"] = 0.100_001; master["inputBlack"] = 0.1
            case "reversed": master["outputBlack"] = 0.9; master["outputWhite"] = 0.1
            case "type": master["clampInput"] = 1
            case "neutral": levels = try #require(JSONSerialization.jsonObject(with: ArtifactJSONCodec.encode(LevelsSettings.neutral)) as? [String: Any])
            default: break
            }
            if target != "neutral" { levels["master"] = master }
            settings["levels"] = target == "null" ? NSNull() : levels
            object["settings"] = settings
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
        let invalid = LevelsCurve(gamma: .nan)
        #expect(throws: (any Error).self) { try JSONEncoder().encode(invalid) }
        #expect(throws: (any Error).self) { try EditingSnapshot(settings: .init(levels: .init(master: invalid))) }
    }

    @Test func normalizationIsDeterministicFiniteAndIdempotent() throws {
        let samples = [
            LevelsCurve(inputBlack: .nan, inputWhite: .infinity, gamma: -.infinity, outputBlack: .nan, outputWhite: .infinity),
            LevelsCurve(inputBlack: 1, inputWhite: -1, gamma: 0.01, outputBlack: 2, outputWhite: -1),
            LevelsCurve(inputBlack: 0.0003, inputWhite: 0.0004, gamma: 20),
            LevelsCurve(inputBlack: 0.9999, inputWhite: 1),
            LevelsCurve(inputBlack: 0.5, inputWhite: 0.5)
        ]
        for sample in samples {
            let value = sample.normalized
            try value.validate()
            #expect(value == value.normalized)
            #expect(value.inputWhite >= value.inputBlack + LevelsCurve.minimumInputSpan)
            #expect(value.inputWhite - value.inputBlack >= LevelsCurve.minimumInputSpan)
            #expect(Float(value.inputWhite) - Float(value.inputBlack) >= Float(LevelsCurve.minimumInputSpan))
            #expect(value.outputWhite >= value.outputBlack)
        }
        #expect(samples[0].normalized == .neutral)
        #expect(throws: LevelsValidationError.invalidCurve) { try samples[2].validate() }
        let settings = EditSettings(levels: .init(master: samples[1], red: samples[0]))
        #expect(settings.normalized.levels == settings.levels.normalized)
    }

    @Test(arguments: [0.1, 1.0, 10.0])
    func scalarReferenceMatchesIndependentFormulaAndIsMonotone(gamma: Double) throws {
        let curve = LevelsCurve(inputBlack: 0.05, inputWhite: 0.95, gamma: gamma, outputBlack: 0.1, outputWhite: 0.9)
        var previous = -Double.infinity
        for index in 0..<1_024 {
            let input = Double(index) / 1_023
            let u = (input - 0.05) / 0.9
            let expected = 0.1 + (u > 0 ? pow(u, 1 / gamma) : u) * 0.8
            let actual = try curve.value(for: input)
            #expect(abs(actual - expected) < 1e-12)
            #expect(actual >= previous)
            previous = actual
        }
        #expect(abs(try curve.value(for: 0.05) - 0.1) < 1e-12)
        #expect(abs(try curve.value(for: 0.95) - 0.9) < 1e-12)
        #expect(try LevelsCurve.neutral.value(for: 0.500_001) != LevelsCurve.neutral.value(for: 0.500_002))
    }

    @Test func negativeValuesAndHDRRemainExtendedUnlessExplicitlyClamped() throws {
        #expect(try LevelsCurve.neutral.value(for: -0.25) == -0.25)
        #expect(try LevelsCurve.neutral.value(for: 4) == 4)
        #expect(try LevelsCurve(gamma: 2).value(for: -0.25) == -0.25)
        #expect(try LevelsCurve(gamma: 2).value(for: 0.25) == 0.5)
        #expect(try LevelsCurve(gamma: 2).value(for: 4) == 2)
        for inputClamp in [false, true] {
            for outputClamp in [false, true] {
                let curve = LevelsCurve(inputBlack: 0.1, inputWhite: 0.9,
                    outputBlack: 0.2, outputWhite: 0.8, clampInput: inputClamp, clampOutput: outputClamp)
                for input in [-1.0, 0, 0.5, 1, 2] {
                    var u = (input - 0.1) / 0.8
                    if inputClamp { u = min(max(u, 0), 1) }
                    var expected = 0.2 + u * 0.6
                    if outputClamp { expected = min(max(expected, 0), 1) }
                    #expect(abs(try curve.value(for: input) - expected) < 1e-12)
                }
            }
        }
        let constant = LevelsCurve(outputBlack: 0.4, outputWhite: 0.4)
        for input in [-2.0, 0, 4] { #expect(try constant.value(for: input) == 0.4) }
    }

    @Test func channelsRunBeforeMasterAndChannelResetIsIsolated() throws {
        var levels = LevelsSettings(master: .init(gamma: 2), red: .init(gamma: 2), green: .init(inputWhite: 0.5))
        let value = try levels.rgb(red: 0.0625, green: 0.125, blue: 0.25)
        #expect(abs(value.red - 0.5) < 1e-12)
        #expect(abs(value.green - 0.5) < 1e-12)
        #expect(abs(value.blue - 0.5) < 1e-12)
        levels[.red] = .neutral
        #expect(levels.red == .neutral && levels.master.gamma == 2 && levels.green.inputWhite == 0.5)
        #expect(LevelsSettings.neutral.isNeutral)
        #expect(!levels.isNeutral)
    }

    @Test func floatIntervalCertifiesEveryChannelAndIntermediate() throws {
        let levels = sampleLevels()
        let bounds = try levels.validatedOutputRanges(red: -0.5...4, green: -0.5...4, blue: -0.5...4)
        for index in 0..<1_024 {
            let input = Float(-0.5 + 4.5 * Double(index) / 1_023)
            let r = floatReference(floatReference(input, curve: levels.red), curve: levels.master)
            let g = floatReference(floatReference(input, curve: levels.green), curve: levels.master)
            let b = floatReference(floatReference(input, curve: levels.blue), curve: levels.master)
            #expect(bounds.red.contains(Double(r)))
            #expect(bounds.green.contains(Double(g)))
            #expect(bounds.blue.contains(Double(b)))
        }
        let extreme = LevelsCurve(inputWhite: 0.0001, gamma: 0.1)
        #expect(throws: LevelsValidationError.unrepresentableValue) { try extreme.validatedOutputRange(for: 0...4) }
        #expect(throws: LevelsValidationError.unrepresentableValue) { try LevelsCurve(gamma: 0.1, clampOutput: true).validatedOutputRange(for: 0...1e10) }
        #expect(throws: LevelsValidationError.unrepresentableValue) { try LevelsCurve.neutral.value(for: .nan) }
        #expect(throws: LevelsValidationError.unrepresentableValue) { try LevelsCurve.neutral.value(for: .infinity) }
        #expect(throws: LevelsValidationError.unrepresentableValue) { try LevelsCurve.neutral.validatedOutputRange(for: 0...Double.infinity) }
        let clamped = try LevelsCurve(inputWhite: 0.0001, gamma: 0.1, clampInput: true).validatedOutputRange(for: 0...4)
        #expect(clamped == (0...1))
        // Per-channel output is safe, but applying the master power again is not.
        let compounded = LevelsSettings(master: .init(gamma: 0.1), red: .init(gamma: 0.1))
        #expect(throws: LevelsValidationError.unrepresentableValue) { try compounded.validatedOutputRanges(red: 0...4, green: 0...1, blue: 0...1) }
    }

    @Test func levelsSurviveDurableBackupRestoreAndReopen() async throws {
        let fixture = try EditingFixture()
        let state = try await fixture.repository.loadState()
        let original = try EditingSnapshot(settings: .init(exposure: 0.5, levels: sampleLevels()))
        let stored = try await fixture.repository.saveSnapshot(original, for: fixture.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let backup = try await fixture.repository.createBackup(automatic: false)
        _ = try await fixture.repository.saveSnapshot(.init(), for: fixture.id, expected: .init(stored), revision: 2)
        let restored = try await fixture.repository.restoreBackup(from: backup)
        #expect(restored.byAsset[fixture.id]?.snapshot == original)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot == original)
    }

    private func sampleLevels() -> LevelsSettings {
        .init(master: .init(inputBlack: 0.03, inputWhite: 0.97, gamma: 1.3, outputBlack: 0.02, outputWhite: 0.98),
              red: .init(gamma: 1.2), green: .init(inputBlack: 0.02),
              blue: .init(outputBlack: 0.01, outputWhite: 0.96, clampInput: true, clampOutput: true))
    }

    private func floatReference(_ input: Float, curve: LevelsCurve) -> Float {
        var u = (input - Float(curve.inputBlack)) / (Float(curve.inputWhite) - Float(curve.inputBlack))
        if curve.clampInput { u = min(max(u, 0), 1) }
        let v = u > 0 ? pow(u, 1 / Float(curve.gamma)) : u
        let result = Float(curve.outputBlack) + v * (Float(curve.outputWhite) - Float(curve.outputBlack))
        return curve.clampOutput ? min(max(result, 0), 1) : result
    }
}
