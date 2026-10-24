import Foundation
import Testing
@testable import GlowroomCore

@Suite("Levels integration with versioned tone settings")
struct LevelsProcessingVersionIntegrationTests {
    @Test(arguments: ToneProcessingVersion.allCases)
    func levelsAndProcessingVersionRoundTripTogether(version: ToneProcessingVersion) throws {
        let levels = LevelsSettings(master: .init(gamma: 1.7), red: .init(inputBlack: 0.04),
                                    green: .init(outputWhite: 0.9), blue: .init(clampInput: true))
        let settings = EditSettings(exposure: 0.7, levels: levels, toneProcessingVersion: version)
        #expect(settings.normalized == settings)
        #expect(!settings.isNeutral)
        let encodedSettings = try ArtifactJSONCodec.encode(settings)
        #expect(try ArtifactJSONCodec.decode(EditSettings.self, from: encodedSettings) == settings)
        let settingsJSON = String(decoding: encodedSettings, as: UTF8.self)
        #expect(settingsJSON.contains("\"levels\":"))
        #expect(settingsJSON.contains("\"toneProcessingVersion\":") == (version == .consistentV2))

        let snapshot = try EditingSnapshot(settings: settings)
        let encodedSnapshot = try ArtifactJSONCodec.encode(snapshot)
        let reopened = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: encodedSnapshot)
        #expect(reopened == snapshot)
        #expect(try ArtifactJSONCodec.encode(reopened) == encodedSnapshot)
        let snapshotJSON = String(decoding: encodedSnapshot, as: UTF8.self)
        #expect(snapshotJSON.contains("\"levels\":"))
        #expect(snapshotJSON.contains("\"toneProcessingVersion\":") == (version == .consistentV2))
    }

    @Test(arguments: ToneProcessingVersion.allCases)
    func normalizationResetAndUpgradePreserveTheirSeparateContracts(version: ToneProcessingVersion) throws {
        var settings = EditSettings(exposure: 1.2, levels: .init(master: .init(gamma: 1.8)),
                                    toneProcessingVersion: version)
        settings.levels.red.inputBlack = 1
        settings.levels.red.inputWhite = -1
        settings.exposure = 9
        let normalized = settings.normalized
        try normalized.levels.validate()
        #expect(normalized.toneProcessingVersion == version)
        #expect(normalized.levels == settings.levels.normalized)
        #expect(normalized.exposure == 5)

        var expectedUpgrade = normalized
        expectedUpgrade.toneProcessingVersion = .consistentV2
        #expect(normalized.upgradedToneProcessing == expectedUpgrade)
        let reset = normalized.resettingAdjustments
        #expect(reset.toneProcessingVersion == version)
        #expect(reset.levels.isNeutral && reset.isNeutral)
        #expect(!String(decoding: try ArtifactJSONCodec.encode(reset), as: UTF8.self).contains("\"levels\":"))
    }

    @Test func processingVersionRemainsPartOfIdentityWhenLevelsAreActive() throws {
        let legacy = EditSettings(levels: .init(master: .init(gamma: 1.8)))
        let upgraded = legacy.upgradedToneProcessing
        #expect(legacy.levels == upgraded.levels)
        #expect(Set([legacy, upgraded]).count == 2)
        #expect(try ArtifactJSONCodec.digest(EditingSnapshot(settings: legacy)) !=
                ArtifactJSONCodec.digest(EditingSnapshot(settings: upgraded)))
    }
}
