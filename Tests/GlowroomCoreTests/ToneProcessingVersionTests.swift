import Foundation
import Testing
@testable import GlowroomCore

@Suite("Versioned tone settings and historical canonical payloads")
struct ToneProcessingVersionTests {
    // Captured schema-2 shape predating version metadata and later controls.
    private let legacy = Data(#"{"schemaVersion":2,"settings":{"autoToneAmount":100,"blacks":7,"clarity":0,"colorNoiseReduction":0,"contrast":0,"dehaze":0,"exposure":0,"highlights":0,"luminanceNoiseReduction":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":-1},"source":{"kind":"original"}}"#.utf8)

    @Test func missingVersionRetainsFrozenBytesAndDigest() throws {
        let snapshot = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: legacy)
        #expect(snapshot.settings.toneProcessingVersion == .legacyV1)
        #expect(try ArtifactJSONCodec.encode(snapshot) == legacy)
        #expect(try ArtifactJSONCodec.digest(snapshot).sha256 == "607f6260d8379f78cc13fbe17e5cd65e26e3f6552b27eaa18191fd6a769f0d5b")
        let settingsBytes = try ArtifactJSONCodec.encode(snapshot.settings)
        let settings = try ArtifactJSONCodec.decode(EditSettings.self, from: settingsBytes)
        #expect(settings == snapshot.settings)
        #expect(!String(decoding: settingsBytes, as: UTF8.self).contains("toneProcessingVersion"))
    }

    @Test func newEditingDefaultUpgradeResetNormalizationAndIdentityAreExplicit() throws {
        #expect(EditSettings().toneProcessingVersion == .legacyV1)
        #expect(EditSettings.neutral.isNeutral)
        #expect(EditSettings.newEditingSettings.isNeutral)
        #expect(EditSettings.newEditingSettings.toneProcessingVersion == .consistentV2)
        #expect(EditSettings.neutral != .newEditingSettings)
        #expect(Set([EditSettings.neutral, .newEditingSettings]).count == 2)
        var old = EditSettings(exposure: 1.25, contrast: 30, sharpeningRadius: 2)
        old.developColor.temperature = 5_500
        old.developGeometry.flipHorizontal = true
        let upgraded = old.upgradedToneProcessing
        #expect(old.toneProcessingVersion == .legacyV1)
        #expect(upgraded.toneProcessingVersion == .consistentV2)
        var revertedVersion = upgraded
        revertedVersion.toneProcessingVersion = .legacyV1
        #expect(revertedVersion == old)
        #expect(upgraded.resettingAdjustments == .newEditingSettings)
        #expect(old.resettingAdjustments == .neutral)
        var invalid = upgraded
        invalid.exposure = 100
        #expect(invalid.normalized.exposure == 5)
        #expect(invalid.normalized.toneProcessingVersion == .consistentV2)
        let oldSnapshot = try EditingSnapshot(settings: old)
        let upgradedSnapshot = try EditingSnapshot(settings: upgraded)
        #expect(Set([oldSnapshot, upgradedSnapshot]).count == 2)
        #expect(try ArtifactJSONCodec.digest(oldSnapshot) != ArtifactJSONCodec.digest(upgradedSnapshot))
        let decoded = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: ArtifactJSONCodec.encode(upgradedSnapshot))
        #expect(decoded == upgradedSnapshot)
        #expect(String(decoding: try ArtifactJSONCodec.encode(decoded), as: UTF8.self).contains("\"toneProcessingVersion\":2"))
    }

    @Test func unknownAndMalformedVersionsFailAtBothSettingsBoundaries() throws {
        let base = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        for invalid in [3, -1, 0, 2.5, "consistentV2", true, NSNull()] as [Any] {
            var snapshot = base
            var settings = try #require(snapshot["settings"] as? [String: Any])
            settings["toneProcessingVersion"] = invalid
            snapshot["settings"] = settings
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: canonical(snapshot))
            }
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(EditSettings.self, from: canonical(settings))
            }
        }
        #expect(throws: ArtifactContractError.unsupportedVersion(3)) {
            try JSONDecoder().decode(ToneProcessingVersion.self, from: Data("3".utf8))
        }
        // Explicit V1 is not the historical canonical wire shape. V1 always
        // re-encodes without this field rather than changing signed manifests.
        var explicit = try #require(base["settings"] as? [String: Any])
        explicit["toneProcessingVersion"] = 1
        #expect(throws: (any Error).self) {
            try ArtifactJSONCodec.decode(EditSettings.self, from: canonical(explicit))
        }
    }

    @Test func frozenNestedProvenanceRetainsOriginalManifestHash() throws {
        let manifest = try ArtifactJSONCodec.decode(GeneratedArtifactManifest.self, from: frozenManifest)
        #expect(manifest.provenance.parentSnapshot.settings.toneProcessingVersion == .legacyV1)
        #expect(try ArtifactJSONCodec.encode(manifest) == frozenManifest)
        #expect(try ArtifactJSONCodec.digest(manifest).sha256 == "ce87d122525bbf4731308094909379c1c36f6470e9174cbf3cce0d918a6fd4ca")
        #expect(try ArtifactJSONCodec.encode(manifest.provenance.parentSnapshot) == legacy)
        // Foundation's general JSONSerialization writer is not the canonical
        // EditingContractJSON encoder. Insert the one new key into the frozen
        // bytes directly, preserving every other token and its representation.
        let upgradedText = String(decoding: frozenManifest, as: UTF8.self)
            .replacingOccurrences(of: "\"texture\":0,\"vibrance\"",
                                  with: "\"texture\":0,\"toneProcessingVersion\":2,\"vibrance\"")
        let upgradedBytes = Data(upgradedText.utf8)
        let upgraded = try ArtifactJSONCodec.decode(GeneratedArtifactManifest.self, from: upgradedBytes)
        #expect(upgraded.provenance.parentSnapshot.settings.toneProcessingVersion == .consistentV2)
        #expect(try ArtifactJSONCodec.encode(upgraded) == upgradedBytes)
        #expect(try ArtifactJSONCodec.digest(upgraded).sha256 == "b913a4ea829729c32e9db6174327b1b9593f9b8c99a59fdf63627ea0081f6e63")
        #expect(try ArtifactJSONCodec.digest(upgraded) != ArtifactJSONCodec.digest(manifest))
        let futureBytes = Data(upgradedText.replacingOccurrences(of: "\"toneProcessingVersion\":2",
                                                                 with: "\"toneProcessingVersion\":99").utf8)
        #expect(throws: ArtifactContractError.unsupportedVersion(99)) {
            try ArtifactJSONCodec.decode(GeneratedArtifactManifest.self, from: futureBytes)
        }
    }

    @Test func processingVersionSurvivesReopenBackupExportAndRestore() async throws {
        let fixture = try EditingFixture()
        let initial = try await fixture.repository.loadState()
        let legacySnapshot = try EditingSnapshot(settings: EditSettings(exposure: 1))
        let old = try await fixture.repository.saveSnapshot(legacySnapshot, for: fixture.id,
            expected: .init(storeEpoch: initial.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let upgradedSnapshot = try EditingSnapshot(settings: old.snapshot.settings.upgradedToneProcessing)
        let upgraded = try await fixture.repository.saveSnapshot(upgradedSnapshot, for: fixture.id, expected: .init(old), revision: 2)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot == upgradedSnapshot)
        let backup = try await fixture.repository.createBackup()
        let exported = fixture.directory.appendingPathComponent("exported-tones.glowroombackup")
        _ = try await fixture.repository.exportBackup(from: backup, toNew: exported)
        _ = try await fixture.repository.saveSnapshot(legacySnapshot, for: fixture.id, expected: .init(upgraded), revision: 3)
        let restored = try await fixture.repository.restoreBackup(from: exported)
        #expect(restored.byAsset[fixture.id]?.snapshot == upgradedSnapshot)
        #expect(try await fixture.reopen().loadState().byAsset[fixture.id]?.snapshot.settings.toneProcessingVersion == .consistentV2)
    }

    @Test(arguments: ToneProcessingVersion.allCases)
    func newGeneratedSourceUsesV2AndUndoRetainsItsParentsVersion(version: ToneProcessingVersion) async throws {
        let fixture = try EditingFixture()
        let initial = try await fixture.repository.loadState()
        let settings = EditSettings(exposure: 0.75, toneProcessingVersion: version)
        let parent = try await fixture.repository.saveSnapshot(EditingSnapshot(settings: settings), for: fixture.id,
            expected: .init(storeEpoch: initial.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let draft = try await fixture.draft(parent: parent)
        let request = try GenerationCommitRequest(commitID: .init(), assetID: fixture.id, draft: draft,
            expected: .init(parent), expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 2)
        let accepted = try await fixture.repository.commitGenerated(request)
        #expect(accepted.stored.snapshot.settings == .newEditingSettings)
        #expect(try await fixture.reopen().committed(request.commitID)?.stored.snapshot == accepted.stored.snapshot)
        let variants = try await fixture.repository.variants(for: fixture.id)
        #expect(variants.contains { $0.snapshot == parent.snapshot })
        #expect(variants.contains { $0.snapshot == accepted.stored.snapshot })
        let undone = try await fixture.repository.saveSnapshot(parent.snapshot, for: fixture.id, expected: .init(accepted.stored), revision: 3)
        #expect(undone.snapshot.settings.toneProcessingVersion == version)
    }

    @Test(arguments: ToneProcessingVersion.allCases)
    func pristineUnsavedGenerationParentsRetainTheirCapturedVersion(version: ToneProcessingVersion) async throws {
        let fixture = try EditingFixture()
        let initial = try await fixture.repository.loadState()
        let parent = StoredEditingState(snapshot: try EditingSnapshot(settings: EditSettings(toneProcessingVersion: version)),
            version: try .init(storeEpoch: initial.storeEpoch, revision: 0))
        let draft = try await fixture.draft(parent: parent)
        let request = try GenerationCommitRequest(commitID: .init(), assetID: fixture.id, draft: draft,
            expected: .init(storeEpoch: initial.storeEpoch, revision: nil, snapshot: nil),
            expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 1)
        let accepted = try await fixture.repository.commitGenerated(request)
        #expect(accepted.stored.snapshot.settings == .newEditingSettings)
        #expect(draft.artifact.provenance.parentSnapshot.settings.toneProcessingVersion == version)
    }

    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // Fixed complete pre-version manifest, including a parent with older
    // omitted controls. Its digest is independent of today's Swift encoder.
    private let frozenManifest = Data(#"{"id":"00000000-0000-0000-0000-000000000001","provenance":{"createdAt":"0000000000000000","execution":"local","maskResourceIDs":[],"parameterVersion":1,"parameters":{"schemaVersion":1,"values":[]},"parentSnapshot":{"schemaVersion":2,"settings":{"autoToneAmount":100,"blacks":7,"clarity":0,"colorNoiseReduction":0,"contrast":0,"dehaze":0,"exposure":0,"highlights":0,"luminanceNoiseReduction":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":-1},"source":{"kind":"original"}},"parentSource":{"kind":"original","value":{"fileSize":4,"modifiedAt":"0000000000000000","nativeRevision":{"changedNanoseconds":0,"changedSeconds":0,"device":1,"fileSize":4,"inode":2,"modifiedNanoseconds":0,"modifiedSeconds":0},"schemaVersion":1,"standardizedPath":"/frozen/original.bin"}},"pipelineVersion":1,"placement":{"inputOriginX":0,"inputOriginY":0,"inputSize":{"height":2,"width":2},"outputSize":{"height":2,"width":2},"schemaVersion":1},"provider":{"providerID":"test.frozen"},"renderedInput":{"canonicalPixelSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","format":{"alpha":"straight","bitDepth":8,"channels":"rgba","iccSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","orientation":"up","profile":"displayP3","schemaVersion":1,"size":{"height":2,"width":2}},"pipelineVersion":1,"schemaVersion":1},"schemaVersion":1},"raster":{"codec":"png","codecVersion":1,"file":{"bytes":32,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"format":{"alpha":"straight","bitDepth":8,"channels":"rgba","iccSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","orientation":"up","profile":"displayP3","schemaVersion":1,"size":{"height":2,"width":2}},"schemaVersion":1},"resources":[],"schemaVersion":1}"#.utf8)
}

@Suite("Signed sRGB transfer for the consistent tone domain")
struct SignedSRGBTests {
    @Test func transferKnotsAndKnownReferenceValues() {
        #expect(SignedSRGB.encode(0) == 0)
        #expect(SignedSRGB.decode(0) == 0)
        #expect(abs(SignedSRGB.encode(0.003_130_8) - 0.040_449_936) < 1e-12)
        #expect(abs(SignedSRGB.decode(0.040_45) - 0.003_130_804_953_560_371_3) < 1e-12)
        #expect(abs(SignedSRGB.encode(0.18) - 0.461_356_129_500_441_64) < 1e-12)
        #expect(abs(SignedSRGB.decode(0.5) - 0.214_041_140_482_232_55) < 1e-12)
    }

    @Test(arguments: [-10.0, -2, -1, -0.18, -0.003_130_8, -0.000_001, 0, 0.000_001, 0.003_130_8, 0.18, 1, 2, 10])
    func negativeGamutAndExtendedValuesRoundtripWithoutClipping(linear: Double) {
        let encoded = SignedSRGB.encode(linear)
        #expect(encoded.isFinite)
        #expect(abs(SignedSRGB.decode(encoded) - linear) < 5e-8)
        #expect(SignedSRGB.encode(-linear) == -encoded)
        #expect(SignedSRGB.decode(-encoded) == -SignedSRGB.decode(encoded))
        if abs(linear) > 1 { #expect(abs(encoded) > 1) }
    }

    @Test func fineRampIsMonotoneAndRetainsSubEightBitDifferences() {
        let ramp = (0...1_024).map { 0.18 + Double($0) * 0.000_001 }
        let encoded = ramp.map(SignedSRGB.encode)
        for index in 1..<encoded.count { #expect(encoded[index] > encoded[index - 1]) }
        #expect(encoded[1] - encoded[0] < 1 / 255)
        #expect(SignedSRGB.encode(-0.0).sign == .minus)
        #expect(SignedSRGB.decode(-0.0).sign == .minus)
        // Invalid inputs remain invalid for the caller's explicit validation;
        // they must never turn into plausible black or a finite estimate.
        #expect(SignedSRGB.encode(.nan).isNaN)
        #expect(SignedSRGB.decode(.nan).isNaN)
        #expect(!SignedSRGB.encode(.infinity).isFinite)
        #expect(!SignedSRGB.decode(-.infinity).isFinite)
    }
}
