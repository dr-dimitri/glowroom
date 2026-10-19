import Foundation
import Testing
@testable import PicEditCore

@Suite("Persistent local adjustment masks")
struct LocalAdjustmentTests {
    @Test func everyMaskShapeSurvivesCanonicalSettingsAndSnapshotRoundTrips() throws {
        let settings = try fixtureSettings()
        let snapshot = try EditingSnapshot(settings: settings)
        for _ in 0..<2 {
            let bytes = try ArtifactJSONCodec.encode(snapshot)
            let restored = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: bytes)
            #expect(restored == snapshot)
            #expect(try ArtifactJSONCodec.encode(restored) == bytes)
            #expect(try ArtifactJSONCodec.decode(EditSettings.self, from: ArtifactJSONCodec.encode(settings)) == settings)
        }
        #expect(settings.normalized == settings)
        #expect(!settings.isNeutral)
        var inactive = settings
        inactive.localAdjustments = inactive.localAdjustments.map { value in
            var value = value; value.isEnabled = false; value.settings = .neutral; return value
        }
        #expect(!inactive.isNeutral) // Unfinished/disabled masks must still persist.
        #expect(inactive.localAdjustments.allSatisfy { !$0.isEffective })
    }

    @Test func emptyMasksKeepHistoricalWireShapeAndExplicitEmptyIsNotCanonical() throws {
        let snapshot = try EditingSnapshot()
        let bytes = try ArtifactJSONCodec.encode(snapshot)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("localAdjustments"))
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var settings = try #require(object["settings"] as? [String: Any])
        settings["localAdjustments"] = []; object["settings"] = settings
        #expect(throws: (any Error).self) {
            try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func malformedGeometryAndAggregateLimitsRejectBeforeDurableAcceptance() throws {
        #expect(throws: ArtifactContractError.self) { try LocalMaskPoint(x: .nan, y: 0) }
        #expect(throws: ArtifactContractError.self) { try LocalMaskPoint(x: -0.01, y: 0.5) }
        let center = try LocalMaskPoint(x: 0.5, y: 0.5)
        #expect(throws: ArtifactContractError.self) { try LocalAdjustmentMask(shape: .linear(start: center, end: center)) }
        #expect(throws: ArtifactContractError.self) { try LocalAdjustmentMask(shape: .radial(center: center, radiusX: 0, radiusY: 0.2, rotation: 0)) }
        #expect(throws: ArtifactContractError.self) { try LocalMaskRaster(width: 2_049, height: 1, bytes: Data(count: 2_049)) }
        #expect(throws: ArtifactContractError.self) { try LocalMaskRaster(width: 1, height: 2, bytes: Data([0])) }
        let raster = try LocalMaskRaster(width: 2_048, height: 2_048, bytes: Data(repeating: 255, count: 2_048 * 2_048))
        let layers = try (0..<5).map { try LocalAdjustment(name: "Mask \($0)", mask: .init(shape: .subject(raster))) }
        _ = try EditingSnapshot(settings: .init(localAdjustments: Array(layers.prefix(4))))
        #expect(throws: ArtifactContractError.limitExceeded) { try EditingSnapshot(settings: .init(localAdjustments: layers)) }
        var duplicate = try fixtureSettings(); duplicate.localAdjustments.append(duplicate.localAdjustments[0])
        #expect(throws: ArtifactContractError.limitExceeded) { try EditingSnapshot(settings: duplicate) }
        var invalid = try fixtureSettings(); invalid.localAdjustments[0].mask.opacity = .infinity
        #expect(throws: ArtifactContractError.self) { try EditingSnapshot(settings: invalid) }
    }

    @Test func fullResolutionRasterRoundTripPreservesBytesAndSavedFeather() throws {
        // One maximum-size matte covers the former JSON string and snapshot
        // limits without retaining sixteen independent raster allocations.
        let side = LocalMaskRaster.maximumDimension
        let raster = try LocalMaskRaster(width: side, height: side,
            bytes: Data(repeating: 173, count: side * side))
        let layer = try LocalAdjustment(name: "Motiv", mask: .init(shape: .subject(raster), feather: 0.5))
        let snapshot = try EditingSnapshot(settings: .init(localAdjustments: [layer]))
        let encoded = try ArtifactJSONCodec.encode(snapshot)
        #expect(encoded.count > 4_194_304 && encoded.count < EditSettings.maximumEncodedBytes)
        let decoded = try ArtifactJSONCodec.decode(EditingSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
        #expect(decoded.settings.localAdjustments[0].mask.feather == 0.5)
        #expect(try ArtifactJSONCodec.encode(decoded) == encoded)

        let legacy = try LocalMaskRaster(width: 512, height: 1, bytes: Data(repeating: 77, count: 512))
        let legacyBytes = try ArtifactJSONCodec.encode(legacy)
        #expect(try ArtifactJSONCodec.encode(ArtifactJSONCodec.decode(LocalMaskRaster.self, from: legacyBytes)) == legacyBytes)
        // Non-raster text keeps the narrower preflight bound.
        let oversizedText = Data(("{\"name\":\"" + String(repeating: "a", count: 2_097_153) + "\"}").utf8)
        #expect(throws: (any Error).self) {
            var scanner = ArtifactJSONScanner(oversizedText, maximum: EditSettings.maximumEncodedBytes)
            try scanner.validate()
        }
    }

    @Test func strictNestedFieldsAndInactiveShapePayloadsCannotEnterASnapshot() throws {
        let settings = try fixtureSettings()
        let bytes = try ArtifactJSONCodec.encode(EditingSnapshot(settings: settings))
        let base = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for target in ["adjustment", "settings", "mask", "shape", "point", "raster", "inactive", "outOfRange"] {
            var object = base
            var controls = try #require(object["settings"] as? [String: Any])
            var layers = try #require(controls["localAdjustments"] as? [[String: Any]])
            var layer = layers[target == "raster" ? 3 : 1]
            var mask = try #require(layer["mask"] as? [String: Any])
            var shape = try #require(mask["shape"] as? [String: Any])
            switch target {
            case "adjustment": layer["unexpected"] = 1
            case "settings", "outOfRange":
                var values = try #require(layer["settings"] as? [String: Any])
                values[target == "settings" ? "unexpected" : "exposure"] = 900; layer["settings"] = values
            case "mask": mask["unexpected"] = 1
            case "shape": shape["unexpected"] = 1
            case "point":
                var point = try #require(shape["start"] as? [String: Any]); point["unexpected"] = 1; shape["start"] = point
            case "raster":
                var raster = try #require(shape["raster"] as? [String: Any]); raster["unexpected"] = 1; shape["raster"] = raster
            default: shape["radiusX"] = 0.4
            }
            mask["shape"] = shape; layer["mask"] = mask
            layers[target == "raster" ? 3 : 1] = layer; controls["localAdjustments"] = layers; object["settings"] = controls
            #expect(throws: (any Error).self) {
                try ArtifactJSONCodec.decode(EditingSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func largeAutomaticSelectionsSurviveRealSQLPackageBackupAndRestore() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let artifacts = try await fixture.store()
        let packages = EditingBackupPackageStore(resources: fixture.resources, catalog: CatalogRepository(directory: fixture.directory))
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let repository = EditingRepository(directory: fixture.directory, artifacts: artifacts, packages: packages, gate: gate)
        let settings = try fixtureSettings(largeRaster: true), snapshot = try EditingSnapshot(settings: settings)
        #expect(try ArtifactJSONCodec.encode(snapshot).count > 65_536)
        let empty = try await repository.loadState()
        let first = try await repository.saveSnapshot(snapshot, for: "photo", expected: .init(storeEpoch: empty.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let reopened = EditingRepository(directory: fixture.directory, artifacts: artifacts, packages: packages, gate: gate)
        #expect(try await reopened.loadState().byAsset["photo"]?.snapshot == snapshot)
        let backup = try await repository.createBackup(automatic: false)
        let updated = try await repository.saveSnapshot(.init(settings: .init(exposure: 1)), for: "photo", expected: .init(first), revision: 2)
        let restored = try await repository.restoreBackup(from: backup)
        #expect(restored.byAsset["photo"]?.snapshot == snapshot)
        #expect(restored.storeEpoch != first.version.storeEpoch)
        #expect(restored.byAsset["photo"]!.version.revision > updated.version.revision)
    }

    @Test func maskChangesParticipateInCASAndAIProposalsPreserveTheirBaselineMasks() async throws {
        let f = try EditingFixture(), state = try await f.repository.loadState()
        var settings = try fixtureSettings()
        let snapshot = try EditingSnapshot(settings: settings)
        let first = try await f.repository.saveSnapshot(snapshot, for: f.id, expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let proposal = EditProposal(changes: [.init(parameter: .exposure, value: 0.5)])
        if case .changes(_, let result) = try EditProposalValidator().validate(proposal, against: settings) {
            #expect(result.localAdjustments == settings.localAdjustments)
        } else { Issue.record("Expected an effective AI proposal") }
        settings.localAdjustments[0].mask.isInverted.toggle()
        let latest = try await f.repository.saveSnapshot(.init(settings: settings), for: f.id, expected: .init(first), revision: 2)
        let stale = try EditingExpectedState(storeEpoch: latest.version.storeEpoch, revision: latest.version.revision, snapshot: snapshot)
        await #expect(throws: ArtifactContractError.staleSnapshot) {
            try await f.repository.saveSnapshot(snapshot, for: f.id, expected: stale, revision: 3)
        }
        #expect(try await f.repository.loadState().byAsset[f.id] == latest)
    }

    @Test func generatedProvenanceKeepsLargeLocalMasksAndTheirManifestDigest() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(), image = fixture.image()
        let old = try fixture.provenance(image), snapshot = try EditingSnapshot(settings: fixtureSettings(largeRaster: true))
        let provenance = try GenerationProvenance(parentSource: old.parentSource, parentSnapshot: snapshot,
            renderedInput: old.renderedInput, placement: old.placement, pipelineVersion: old.pipelineVersion,
            parameterVersion: old.parameterVersion, parameters: old.parameters, provider: old.provider,
            prompt: old.prompt, createdAt: old.createdAt, execution: old.execution)
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: provenance)
        let publication = try await store.publish(draft, commitID: .init())
        #expect(try ArtifactJSONCodec.encode(publication.artifact).count > 65_536)
        let restarted = try await fixture.store()
        let restored = try await restarted.descriptor(publication.artifact.id)
        #expect(restored == publication.artifact)
        #expect(restored.provenance.parentSnapshot == snapshot)
        let manifest = GeneratedArtifactManifest(id: restored.id, raster: restored.raster, provenance: restored.provenance, resources: restored.resources)
        #expect(try ArtifactJSONCodec.digest(manifest) == restored.manifestSHA256)
    }

    @Test func generationReceiptsAndSavedVariantsRetainLargeMaskedParentSnapshots() async throws {
        let f = try EditingFixture(), state = try await f.repository.loadState()
        let snapshot = try EditingSnapshot(settings: fixtureSettings(largeRaster: true))
        let parent = try await f.repository.saveSnapshot(snapshot, for: f.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let draft = try await f.draft(parent: parent)
        let request = try GenerationCommitRequest(commitID: .init(), assetID: f.id, draft: draft,
            expected: .init(parent), expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 2)
        _ = try await f.repository.commitGenerated(request)
        let reopened = f.reopen()
        #expect(try await reopened.committed(request.commitID)?.previous.snapshot == snapshot)
        #expect(try await reopened.variants(for: f.id).contains { $0.snapshot == snapshot })
    }

    @Test func optionalRefinementKeepsOldMaskBytesAndEnforcesSharedPointLimits() throws {
        let plain = try LocalAdjustmentMask(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1)))
        let bytes = try ArtifactJSONCodec.encode(plain)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("refinement"))
        #expect(try ArtifactJSONCodec.encode(ArtifactJSONCodec.decode(LocalAdjustmentMask.self, from: bytes)) == bytes)
        let point = try MaskPoint(x: 0.5, y: 0.5)
        let stroke = try MaskStroke(points: Array(repeating: point, count: MaskStroke.maximumPoints), radius: 1)
        let document = try MaskDocument(canvasSize: .init(width: 2, height: 2), strokes: [stroke, stroke])
        var refined = plain; refined.refinement = document
        let encoded = try ArtifactJSONCodec.encode(refined)
        #expect(try ArtifactJSONCodec.decode(LocalAdjustmentMask.self, from: encoded) == refined)
        let layer = try LocalAdjustment(name: "Verlauf", mask: refined)
        _ = try EditingSnapshot(settings: .init(localAdjustments: [layer]))
        let extra = try LocalAdjustment(name: "Pinsel", mask: .init(shape: .brush(.init(canvasSize: document.canvasSize,
            strokes: [.init(points: [point], radius: 1)]))))
        #expect(throws: ArtifactContractError.limitExceeded) {
            try EditingSnapshot(settings: .init(localAdjustments: [layer, extra]))
        }
        refined.refinement = document.inverted()
        #expect(throws: ArtifactContractError.invalidValue("local mask refinement")) { try refined.validate() }
        var nullObject = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        nullObject["refinement"] = NSNull()
        #expect(throws: (any Error).self) {
            try ArtifactJSONCodec.decode(LocalAdjustmentMask.self, from: JSONSerialization.data(withJSONObject: nullObject))
        }
    }

    @Test func highResolutionRasterAndVectorMasksKeepLargeGenerationReceiptsAndVariantsReadable() async throws {
        let point = try MaskPoint(x: 0.12345678901234568, y: 0.9876543210987654)
        let stroke = try MaskStroke(points: Array(repeating: point, count: MaskStroke.maximumPoints), radius: 0.1)
        let refinement = try MaskDocument(canvasSize: .init(width: 1, height: 1), strokes: [stroke, stroke])
        let raster = try LocalMaskRaster(width: 2_048, height: 2_048, bytes: Data(repeating: 128, count: 2_048 * 2_048))
        let layer = try LocalAdjustment(name: "Motiv", mask: .init(shape: .subject(raster),
            refinement: refinement), settings: .init(exposure: 0.5))
        let snapshot = try EditingSnapshot(settings: .init(localAdjustments: [layer]))
        let encoded = try ArtifactJSONCodec.encode(snapshot)
        #expect(encoded.count > 4_194_304)
        #expect(encoded.count < EditSettings.maximumEncodedBytes)
        #expect(try ArtifactJSONCodec.decode(EditingSnapshot.self, from: encoded) == snapshot)
        let f = try EditingFixture(), state = try await f.repository.loadState()
        let parent = try await f.repository.saveSnapshot(snapshot, for: f.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let draft = try await f.draft(parent: parent)
        let request = try GenerationCommitRequest(commitID: .init(), assetID: f.id, draft: draft,
            expected: .init(parent), expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 2)
        _ = try await f.repository.commitGenerated(request)
        let reopened = f.reopen()
        #expect(try await reopened.committed(request.commitID)?.previous.snapshot == snapshot)
        #expect(try await reopened.variants(for: f.id).contains { $0.snapshot == snapshot })
        let receiptBytes = try editingScalar(f.repository.fileURL, "SELECT length(receipt) FROM artifact_commits")
        #expect(receiptBytes > 4_194_304 && receiptBytes < EditSettings.maximumEncodedBytes)

        // A remap journal deliberately includes both original expected state
        // and the complete resulting catalog state. Its separate 64 MiB budget
        // must admit both large snapshots. Keep this fixture to one high-detail
        // raster so repeated SQL/restart validation stays bounded in tests.
        let remap = try await EditingRemapFixture(settings: snapshot.settings)
        let prepared = try await remap.fixture.repository.prepareAssetRemap(remap.verified, preparingBy: remap.preparation)
        _ = try await remap.fixture.repository.remapAssets(prepared, armedBy: remap.armed())
        let journalBytes = try editingScalar(remap.fixture.repository.fileURL, "SELECT length(journal) FROM editing_remaps")
        #expect(journalBytes > 2 * 4_194_304 && journalBytes < 67_108_864)
        let inspection = try #require(try await remap.fixture.reopen().inspectAssetRemap(prepared.operationID,
            expectedRequestSHA256: prepared.requestSHA256))
        #expect(inspection.prepared.proposal.expectedByAsset[remap.oldID]?.snapshot == snapshot)
        #expect(inspection.databaseReceipt?.state.byAsset[remap.newID]?.snapshot == snapshot)
    }

    private func fixtureSettings(largeRaster: Bool = false) throws -> EditSettings {
        let start = try LocalMaskPoint(x: 0.2, y: 0.3), end = try LocalMaskPoint(x: 0.7, y: 0.8)
        let brush = try MaskDocument(canvasSize: .init(width: 100, height: 60), strokes: [
            .init(points: [.init(x: 20, y: 30), .init(x: 70, y: 48)], radius: 12, hardness: 0.3)
        ])
        let width = largeRaster ? 2_048 : 2, height = largeRaster ? 32 : 2
        let raster = try LocalMaskRaster(width: width, height: height, bytes: Data(repeating: 128, count: width * height))
        let shapes: [LocalMaskShape] = [.brush(brush), .linear(start: start, end: end),
            .radial(center: start, radiusX: 0.3, radiusY: 0.2, rotation: 0.4), .subject(raster), .sky(raster)]
        return try EditSettings(exposure: 0.2, localAdjustments: shapes.enumerated().map { index, shape in
            try LocalAdjustment(name: "Maske \(index)", mask: .init(shape: shape, isInverted: index == 1, opacity: 0.7, feather: 0.4,
                                                                 refinement: index >= 3 ? brush : nil),
                                settings: .init(exposure: 0.5, shadows: 15, texture: -10))
        })
    }
}
