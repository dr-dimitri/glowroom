import Foundation
import Testing
@testable import GlowroomCore

@Suite("Persisted snapshot compatibility across added controls")
struct EditingSnapshotCompatibilityTests {
    // Frozen schema-2 payload from before natural balance. Using today's
    // encoder here would conceal the production strict-shape regression.
    private let legacy = Data(#"{"schemaVersion":2,"settings":{"autoToneAmount":100,"blacks":7,"clarity":0,"colorNoiseReduction":0,"contrast":0,"dehaze":0,"exposure":0,"highlights":0,"luminanceNoiseReduction":0,"saturation":0,"shadows":0,"texture":0,"vibrance":0,"whites":-1},"source":{"kind":"original"}}"#.utf8)

    @Test func frozenSnapshotRetainsSettingsIdentityAndCanonicalBytes() throws {
        let decoded = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: legacy)
        let expected = try EditingSnapshot(settings: .init(whites: -1, blacks: 7, autoToneAmount: 100))
        #expect(decoded == expected)
        #expect(Set([decoded, expected]).count == 1)
        #expect(decoded.settings.naturalBalanceAmount == 0)
        #expect(decoded.settings.naturalBalanceColorAmount == 50)
        #expect(try ArtifactJSONCodec.encode(decoded) == legacy)
        #expect(try ArtifactJSONCodec.digest(decoded) == ArtifactJSONCodec.digestBytes(legacy))
    }

    @Test(arguments: 0..<128)
    func absentAndExplicitDefaultControlsPreserveTheirOwnShape(mask: Int) throws {
        var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        var settings = try #require(object["settings"] as? [String: Any])
        let defaults: [(Int, String, Double)] = [
            (0, "autoToneAmount", 0), (1, "naturalBalanceAmount", 0), (2, "naturalBalanceColorAmount", 50),
            (3, "sharpeningAmount", 0), (4, "sharpeningRadius", 1), (5, "sharpeningDetail", 25), (6, "sharpeningMasking", 0)
        ]
        for (bit, key, value) in defaults {
            if mask & (1 << bit) == 0 { settings.removeValue(forKey: key) }
            else { settings[key] = value }
        }
        object["settings"] = settings
        let bytes = try canonical(object)
        let decoded = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes)
        #expect(decoded.settings == EditSettings(whites: -1, blacks: 7))
        #expect(try ArtifactJSONCodec.encode(decoded) == bytes)
    }

    @Test func currentNondefaultControlsRemainExplicit() throws {
        let snapshot = try EditingSnapshot(settings: .init(autoToneAmount: 60, naturalBalanceAmount: 70, naturalBalanceColorAmount: 25))
        let bytes = try ArtifactJSONCodec.encode(snapshot)
        let decoded = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes)
        #expect(decoded == snapshot)
        #expect(try ArtifactJSONCodec.encode(decoded) == bytes)
    }

    @Test func missingRequiredUnknownNullAndWrongTypedControlsStillReject() throws {
        let base = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        for key in ["autoToneAmount", "naturalBalanceAmount", "naturalBalanceColorAmount",
                    "sharpeningAmount", "sharpeningRadius", "sharpeningDetail", "sharpeningMasking"] {
            for invalid in [NSNull(), "strong", true] as [Any] {
                var object = base
                var settings = try #require(object["settings"] as? [String: Any])
                settings[key] = invalid; object["settings"] = settings
                #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(EditingSnapshot.self, from: canonical(object)) }
            }
        }
        for key in ["exposure", "unexpected"] {
            var object = base
            var settings = try #require(object["settings"] as? [String: Any])
            if key == "exposure" { settings.removeValue(forKey: key) }
            else { settings[key] = 0 }
            object["settings"] = settings
            #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(EditingSnapshot.self, from: canonical(object)) }
        }
    }

    @Test func realSchemaTwoReopenPreservesLegacySnapshotsRevisionsAndFileBytes() async throws {
        let fixture = try EditingFixture()
        let empty = try await fixture.repository.loadState()
        let hex = legacy.map { String(format: "%02x", $0) }.joined()
        try editingSQL(fixture.repository.fileURL, "INSERT INTO edit_revisions(asset_id,revision) VALUES('legacy-photo',559); INSERT INTO editing_snapshots(asset_id,snapshot) VALUES('legacy-photo',X'\(hex)')")
        let originalBytes = try Data(contentsOf: fixture.repository.fileURL)
        let loaded = try await fixture.reopen().loadState()
        #expect(loaded.storeEpoch == empty.storeEpoch)
        #expect(loaded.byAsset["legacy-photo"]?.version.revision == 559)
        #expect(loaded.byAsset["legacy-photo"]?.snapshot.settings.autoToneAmount == 100)
        #expect(try Data(contentsOf: fixture.repository.fileURL) == originalBytes)
    }

    @Test func historicalArtifactManifestRetainsItsOriginalDigest() async throws {
        let fixture = try EditingFixture()
        let parent = try await fixture.save(exposure: 0)
        let draft = try await fixture.draft(parent: parent)
        var object = try #require(JSONSerialization.jsonObject(with: ArtifactJSONCodec.encode(draft.artifact)) as? [String: Any])
        var provenance = try #require(object["provenance"] as? [String: Any])
        provenance["parentSnapshot"] = try JSONSerialization.jsonObject(with: legacy)
        object["provenance"] = provenance
        var manifest = object
        manifest.removeValue(forKey: "manifestSHA256")
        // Foundation's general JSON writer is not the production canonical
        // encoder used to sign artifact manifests. Keep the frozen nested
        // snapshot shape, then construct the historical signature with that
        // exact encoder before exercising the strict validation boundary.
        let historical = try EditingContractJSON.decoder().decode(GeneratedArtifactManifest.self, from: canonical(manifest))
        #expect(try ArtifactJSONCodec.encode(historical.provenance.parentSnapshot) == legacy)
        let manifestBytes = try ArtifactJSONCodec.encode(historical)
        let digest = try ArtifactJSONCodec.digestBytes(manifestBytes)
        object["manifestSHA256"] = digest.sha256
        let bytes = try canonical(object)
        let decoded = try ArtifactJSONCodec.decode(GeneratedArtifact.self, from: bytes)
        #expect(decoded.manifestSHA256 == digest)
        #expect(try ArtifactJSONCodec.encode(decoded.provenance.parentSnapshot) == legacy)
        let restored = GeneratedArtifactManifest(id: decoded.id, raster: decoded.raster, provenance: decoded.provenance, resources: decoded.resources)
        #expect(try ArtifactJSONCodec.encode(restored) == manifestBytes)
        #expect(try ArtifactJSONCodec.digest(restored) == digest)
    }

    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
