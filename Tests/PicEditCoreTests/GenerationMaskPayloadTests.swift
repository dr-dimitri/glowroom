import Foundation
import Testing
@testable import PicEditCore

@Suite("Immutable mask payloads and model geometry")
struct GenerationMaskPayloadTests {
    private func mask() throws -> FrozenGenerationMask {
        let size = try ArtifactPixelSize(width: 3, height: 2)
        let stroke = try MaskStroke(points: [.init(x: 0.5, y: 0.5), .init(x: 1.5, y: 1.5)], radius: 0.8, hardness: 0.5)
        return try .capture(document: .init(canvasSize: size, strokes: [stroke]), modelSize: .init(width: 6, height: 4))
    }
    private func provenance(_ f: ArtifactTestFixture, mask: FrozenGenerationMask) throws -> GenerationProvenance {
        let p = try f.provenance(f.image(), masks: [mask.binding.resourceID])
        return try .init(parentSource: p.parentSource, parentSnapshot: p.parentSnapshot, renderedInput: p.renderedInput,
            placement: p.placement, pipelineVersion: p.pipelineVersion, parameterVersion: p.parameterVersion,
            parameters: p.parameters, provider: p.provider, createdAt: p.createdAt, execution: p.execution,
            maskResourceIDs: p.maskResourceIDs, maskBindings: [mask.binding])
    }
    @Test func nativePayloadSurvivesStoreRestartAndIgnoresLaterDraft() async throws {
        let f = try ArtifactTestFixture(); defer { f.remove() }
        let frozen = try mask(), p = try provenance(f, mask: frozen), store = try await f.store()
        let input = try frozen.artifactInput()
        let draft = try await store.stageRaster(.init(immutableImage: f.image()), provenance: p, masks: [input])
        _ = try await store.publish(draft, commitID: .init())
        let newerDraft = frozen.document.inverted()
        #expect(newerDraft != frozen.document)
        let reopened = try await f.store()
        let bytes = try ArtifactTestFixture.bytes(try await reopened.openVerifiedFile(draft.artifact.id, role: .maskDocument(input.id)))
        #expect(try ArtifactJSONCodec.decode(MaskDocument.self, from: bytes, maximum: 1_048_576) == frozen.document)
        #expect(try await reopened.descriptor(draft.artifact.id).provenance.maskBindings == [frozen.binding])
        _ = try await reopened.openVerifiedFile(draft.artifact.id, role: .mask(input.id))
        let file = f.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)/\(GeneratedArtifactStore.maskDocumentName(input.id))")
        try Data("{}".utf8).write(to: file, options: .atomic)
        await #expect(throws: (any Error).self) { _ = try await reopened.openVerifiedFile(draft.artifact.id, role: .maskDocument(input.id)) }
    }
    @Test func mismatchedRasterOrDocumentCannotBeStaged() async throws {
        let f = try ArtifactTestFixture(); defer { f.remove() }
        let frozen = try mask(), p = try provenance(f, mask: frozen), store = try await f.store()
        let wrong = ArtifactMaskInput(id: frozen.binding.resourceID, coordinateSpace: .inputCanvas,
            immutableImage: f.image(alpha: false, gray: true), document: frozen.document)
        await #expect(throws: ArtifactContractError.corruptArtifact) {
            _ = try await store.stageRaster(.init(immutableImage: f.image()), provenance: p, masks: [wrong])
        }
        let missing = ArtifactMaskInput(id: frozen.binding.resourceID, coordinateSpace: .inputCanvas,
            immutableImage: try frozen.artifactInput().image)
        await #expect(throws: (any Error).self) {
            _ = try await store.stageRaster(.init(immutableImage: f.image()), provenance: p, masks: [missing])
        }
    }
    @Test func cropModelAndNativePixelCentresShareOneTransform() throws {
        let size = try ArtifactPixelSize(width: 120, height: 80)
        let transform = try MaskRasterTransform(canvasSize: size,
            crop: .init(x: 20, y: 10, size: .init(width: 60, height: 40)), modelSize: .init(width: 30, height: 20))
        for point in [try MaskPoint(x: 20.5, y: 10.5), try MaskPoint(x: 79.5, y: 49.5)] {
            let roundtrip = try transform.canvasPoint(from: transform.modelPoint(from: point))
            #expect(abs(roundtrip.x - point.x) < 0.000_001)
            #expect(abs(roundtrip.y - point.y) < 0.000_001)
        }
        #expect(throws: (any Error).self) { try MaskRasterTransform(canvasSize: size,
            crop: .init(x: 110, y: 0, size: .init(width: 20, height: 20)), modelSize: size) }
        var object = try #require(JSONSerialization.jsonObject(with: ArtifactJSONCodec.encode(transform)) as? [String: Any])
        var crop = try #require(object["crop"] as? [String: Any]); crop["x"] = -1; object["crop"] = crop
        #expect(throws: (any Error).self) { try ArtifactJSONCodec.decode(MaskRasterTransform.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func requestFreezesInputAndMaskWithDistinctSourceRevisionAndHashToken() throws {
        let f = try ArtifactTestFixture(); defer { f.remove() }
        let frozen = try mask()
        let snapshot = AIEditingSnapshot(assetID: "fixture", source: .original(.init(fileURL: f.directory.appendingPathComponent("original.bin"),
            modifiedAt: .distantPast, fileSize: 3)), settings: .neutral,
            token: .init(editSessionID: UUID(), editGeneration: 1, selectionSessionID: UUID(), selectionGeneration: 1))
        let request = try GenerationRequest(snapshot: snapshot, immutableInput: .init(immutableImage: f.image()), mask: frozen)
        #expect(request.token.snapshot == snapshot)
        #expect(request.token.rasterSHA256 == frozen.binding.rasterSHA256)
        #expect(request.renderedInput.canonicalPixelSHA256 == (try ArtifactPNGCodec.pixelHash(f.image(), shape: ArtifactPNGCodec.shape(f.image()))))
        #expect(try request.mask.modelRaster() == frozen.raster.resampled(to: frozen.binding.transform.modelSize))
        #expect(throws: (any Error).self) { try GenerationRequest(snapshot: snapshot,
            immutableInput: .init(immutableImage: f.image(width: 2)), mask: frozen) }
    }
    @Test func realSQLCommitBackupRestorePreservesMaskDocumentAndNativeRaster() async throws {
        let f = try ArtifactTestFixture(); defer { f.remove() }
        let target = try ArtifactTestFixture(); defer { target.remove() }
        let frozen = try mask(), initial = try provenance(f, mask: frozen)
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let store = try await GeneratedArtifactStore.open(in: f.directory, resources: f.resources, lifecycleGate: gate)
        let packages = EditingBackupPackageStore(resources: f.resources, catalog: CatalogRepository(directory: f.directory))
        let repo = EditingRepository(directory: f.directory, artifacts: store, packages: packages, gate: gate, resources: f.resources)
        let state = try await repo.loadState(), id = f.directory.appendingPathComponent("original.bin").path
        let before = try await repo.saveSnapshot(.init(), for: id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let source = try AssetRemapVerifier.capture(URL(fileURLWithPath: id), referenceDate: initial.createdAt)
        let p = try GenerationProvenance(parentSource: .original(source), parentSnapshot: before.snapshot,
            renderedInput: initial.renderedInput, placement: initial.placement, pipelineVersion: 1, parameterVersion: 1,
            parameters: initial.parameters, provider: initial.provider, createdAt: initial.createdAt, execution: .local,
            maskResourceIDs: initial.maskResourceIDs, maskBindings: initial.maskBindings)
        let draft = try await store.stageRaster(.init(immutableImage: f.image()), provenance: p, masks: [frozen.artifactInput()])
        let receipt = try await repo.commitGenerated(.init(commitID: .init(), assetID: id, draft: draft,
            expected: .init(before), expectedParentSource: .original(source), nextRevision: 2))
        let backup = try await repo.createBackup()
        let targetGate = CatalogLifecycleGate(requiresRecovery: false)
        let targetStore = try await GeneratedArtifactStore.open(in: target.directory, resources: target.resources, lifecycleGate: targetGate)
        let targetPackages = EditingBackupPackageStore(resources: target.resources, catalog: CatalogRepository(directory: target.directory))
        let targetRepo = EditingRepository(directory: target.directory, artifacts: targetStore, packages: targetPackages,
            gate: targetGate, resources: target.resources)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: id))
        #expect(try await targetRepo.restoreBackup(from: backup).byAsset[id]?.snapshot == receipt.stored.snapshot)
        let doc = try await targetStore.openVerifiedFile(draft.artifact.id, role: .maskDocument(frozen.binding.resourceID))
        #expect(try ArtifactTestFixture.bytes(doc) == frozen.document.canonicalData())
        _ = try await targetStore.openVerifiedFile(draft.artifact.id, role: .mask(frozen.binding.resourceID))
        #expect(try await targetStore.descriptor(draft.artifact.id).provenance == p)
    }
}
