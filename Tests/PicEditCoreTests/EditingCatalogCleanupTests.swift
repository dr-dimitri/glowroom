import Foundation
import Testing
@testable import PicEditCore

@Suite("Editing catalog cleanup")
struct EditingCatalogCleanupTests {
    @Test func removalForgetsEditsVariantsReceiptsAndReimportStartsFresh() async throws {
        let f = try EditingFixture(), parent = try await f.save(exposure: 1.25)
        let draft = try await f.draft(parent: parent)
        let request = try GenerationCommitRequest(commitID: .init(), assetID: f.id, draft: draft,
            expected: .init(parent), expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 2)
        let generated = try await f.repository.commitGenerated(request)
        let backup = f.directory.appendingPathComponent("manual-retained.piceditbackup")
        let backupBytes = Data("explicit backup remains available".utf8)
        try backupBytes.write(to: backup)
        let empty = try publish([], in: f)
        let cleaned = try await f.repository.reconcileCatalog(empty.catalog, reference: empty.reference)
        #expect(cleaned.byAsset.isEmpty && cleaned.tombstones.isEmpty)
        #expect(cleaned.storeEpoch != generated.stored.version.storeEpoch)
        for table in ["edit_revisions", "editing_snapshots", "editing_variants", "artifact_commits", "generated_artifacts"] {
            #expect(try editingScalar(f.repository.fileURL, "SELECT count(*) FROM \(table)") == 0)
        }
        #expect(try await f.repository.committed(request.commitID) == nil)
        #expect(try await f.repository.variants(for: f.id).isEmpty)
        #expect(try Data(contentsOf: f.original) == Data([1, 2, 3, 4]))
        #expect(try Data(contentsOf: backup) == backupBytes)
        #expect(await f.artifacts.wasPublished(draft.artifact.id))
        await editingError(.staleEpoch) {
            _ = try await f.repository.saveSnapshot(parent.snapshot, for: f.id, expected: .init(parent), revision: 3)
        }
        let reimported = try publish([f.id], in: f)
        let fresh = try await f.reopen().reconcileCatalog(reimported.catalog, reference: reimported.reference)
        #expect(fresh.byAsset.isEmpty && fresh.tombstones.isEmpty)
        #expect(fresh.storeEpoch == cleaned.storeEpoch)
        let saved = try await f.repository.saveSnapshot(EditingSnapshot(settings: EditSettings(exposure: 0.25)),
            for: f.id, expected: .init(storeEpoch: fresh.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        #expect(saved.version.revision == 1)
        let unchanged = try await f.repository.reconcileCatalog(reimported.catalog, reference: reimported.reference)
        #expect(unchanged.storeEpoch == fresh.storeEpoch)
        #expect(unchanged.byAsset[f.id] == saved)
    }

    @Test func activeGeneratedSourceRetainsItsEntireProvenanceChain() async throws {
        let f = try EditingFixture(), parent = try await f.save(exposure: 0.5)
        let first = try await f.draft(parent: parent)
        let committed = try await f.repository.commitGenerated(.init(commitID: .init(), assetID: f.id, draft: first,
            expected: .init(parent), expectedParentSource: first.artifact.provenance.parentSource, nextRevision: 2))
        let ancestor = first.artifact, source = EditingSourceFingerprint.artifact(.init(storeID: f.artifacts.storeID,
            artifactID: ancestor.id, manifestSHA256: ancestor.manifestSHA256, raster: ancestor.raster))
        let inherited = ancestor.provenance
        let provenance = try GenerationProvenance(parentSource: source, parentSnapshot: committed.stored.snapshot,
            renderedInput: inherited.renderedInput, placement: inherited.placement, pipelineVersion: 1,
            parameterVersion: 1, parameters: inherited.parameters, provider: inherited.provider,
            createdAt: inherited.createdAt, execution: .local)
        let child = try await f.artifacts.fakeDraft(provenance: provenance, format: ancestor.raster.format)
        _ = try await f.artifacts.publish(child, commitID: .init())
        try await f.repository.registerForCatalogCleanupTest(child.artifact)
        let activeID = f.directory.appendingPathComponent("retained.bin").path
        let active = try await f.repository.saveSnapshot(EditingSnapshot(source: .artifact(child.artifact.id)), for: activeID,
            expected: .init(storeEpoch: parent.version.storeEpoch, revision: nil, snapshot: nil), revision: 4)
        let catalog = try publish([activeID], in: f)
        let cleaned = try await f.repository.reconcileCatalog(catalog.catalog, reference: catalog.reference)
        #expect(cleaned.byAsset[f.id] == nil && cleaned.tombstones[f.id] == nil)
        #expect(cleaned.byAsset[activeID]?.snapshot == active.snapshot)
        #expect(cleaned.byAsset[activeID]?.version.revision == 4)
        #expect(try editingScalar(f.repository.fileURL, "SELECT count(*) FROM generated_artifacts") == 2)
        #expect(try editingScalar(f.repository.fileURL, "SELECT count(*) FROM artifact_commits") == 0)
        let restarted = try await f.reopen().loadState()
        #expect(restarted.byAsset[activeID] == cleaned.byAsset[activeID])
    }

    @Test func staleOrMismatchedCatalogCannotAuthorizeDeletion() async throws {
        let f = try EditingFixture(), saved = try await f.save(exposure: 1)
        let prior = try publish([], in: f)
        let current = try publish([f.id], in: f)
        await #expect(throws: CatalogRepositoryError.self) {
            _ = try await f.repository.reconcileCatalog(prior.catalog, reference: prior.reference)
        }
        await #expect(throws: CatalogRepositoryError.self) {
            _ = try await f.repository.reconcileCatalog(prior.catalog, reference: current.reference)
        }
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
    }

    @Test func retainedCommitReceiptKeepsAnOtherwiseUnusedHistoricalSource() async throws {
        let f = try EditingFixture(), parent = try await f.save(exposure: 0.5)
        let draft = try await f.draft(parent: parent)
        let request = try GenerationCommitRequest(commitID: .init(), assetID: f.id, draft: draft,
            expected: .init(parent), expectedParentSource: draft.artifact.provenance.parentSource, nextRevision: 2)
        let committed = try await f.repository.commitGenerated(request)
        let original = try await f.repository.saveSnapshot(parent.snapshot, for: f.id,
            expected: .init(committed.stored), revision: 3)
        // The schema admits exact commit receipts independently of variants.
        // Exercise that durable state so retry history remains a GC root.
        try editingSQL(f.repository.fileURL, "DELETE FROM editing_variants")
        let unused = try await f.draft(parent: parent)
        try await f.repository.registerForCatalogCleanupTest(unused.artifact)
        let catalog = try publish([f.id], in: f)
        let cleaned = try await f.repository.reconcileCatalog(catalog.catalog, reference: catalog.reference)
        #expect(cleaned.byAsset[f.id]?.snapshot == original.snapshot)
        #expect(try editingScalar(f.repository.fileURL, "SELECT count(*) FROM generated_artifacts") == 1)
        #expect(try await f.repository.committed(request.commitID)?.artifactID == draft.artifact.id)
        #expect(try await f.repository.commitGenerated(request).artifactID == draft.artifact.id)
        #expect(try await f.reopen().loadState().byAsset[f.id] == cleaned.byAsset[f.id])
    }

    @Test func failedCleanupRollsBackRowsAndEpoch() async throws {
        let failure = EditingFailureSwitch()
        let f = try EditingFixture(hooks: .init(beforeCommit: { try failure.check() }))
        let saved = try await f.save(exposure: 0.75), empty = try publish([], in: f)
        failure.enabled = true
        await #expect(throws: EditingRepositoryError.storageFailure) {
            _ = try await f.repository.reconcileCatalog(empty.catalog, reference: empty.reference)
        }
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        failure.enabled = false
        #expect(try await f.repository.reconcileCatalog(empty.catalog, reference: empty.reference).byAsset.isEmpty)
    }

    @Test func catalogReplacementBeforeCommitRollsBackCleanup() async throws {
        let boundary = CatalogCleanupBoundarySwitch()
        let f = try EditingFixture(hooks: .init(beforeCommit: { try boundary.run() }))
        let saved = try await f.save(exposure: 0.75), empty = try publish([], in: f)
        let repository = CatalogRepository(directory: f.directory)
        let folder = empty.catalog.folders[0]
        let replacement = try repository.prepare(.init(folders: [folder], assets: [
            PhotoAsset(id: f.id, folderID: folder.id, fileURL: f.original)
        ]))
        boundary.install { try replacement.bytes.write(to: repository.fileURL, options: .atomic) }
        await #expect(throws: CatalogRepositoryError.self) {
            _ = try await f.repository.reconcileCatalog(empty.catalog, reference: empty.reference)
        }
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        #expect(try repository.loadStored().reference == replacement.reference)
    }

    @Test func pendingRemapBlocksCleanupAndTerminalReceiptForgetsRemovedImages() async throws {
        let f = try EditingFixture(), saved = try await f.save(exposure: 1)
        let oldID = f.directory.appendingPathComponent("old.bin").path
        let newID = f.directory.appendingPathComponent("new.bin").path
        let catalog = try publish([oldID, newID], in: f)
        let source = try AssetRemapVerifier.capture(f.original, referenceDate: Date(timeIntervalSinceReferenceDate: 750_000_000))
        let operation = EditingRemapID(), bookmark = Data([1, 2, 3])
        let proposal = try AssetRemapProposal(operationID: operation,
            catalog: .init(operationID: operation.rawValue, rootOwnerID: UUID(), before: .absent, after: catalog.reference),
            folderID: catalog.catalog.folders[0].id, bookmarkSHA256: ArtifactJSONCodec.digestBytes(bookmark),
            bookmarkData: bookmark, resolvedFolderURL: f.directory, catalogSessionID: UUID(), catalogGeneration: 1,
            expectedStoreEpoch: saved.version.storeEpoch,
            expectedByAsset: [oldID: .init(storeEpoch: saved.version.storeEpoch, revision: nil, snapshot: nil),
                              newID: .init(storeEpoch: saved.version.storeEpoch, revision: nil, snapshot: nil)],
            entries: [.init(oldAssetID: oldID, newAssetID: newID, relativePath: "original.bin", previous: source, relocated: source)])
        let digest = try ArtifactJSONCodec.digest(proposal)
        var wire = EditingRemapWire(proposal: proposal, requestSHA256: digest, coordinatorRequestSHA256: digest,
            nonce: UUID(), phase: .prepared, receipt: nil)
        // Unit injection isolates the participant's pending/terminal policy;
        // the joint coordinator suite verifies command and native authority.
        try await f.repository.installForCatalogCleanupTest(wire)
        await #expect(throws: CatalogCoordinationError.recoveryRequired) {
            _ = try await f.repository.reconcileCatalog(catalog.catalog, reference: catalog.reference)
        }
        #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        wire.phase = .completed
        wire.receipt = EditingStateWire(try await f.repository.loadState())
        try await f.repository.installForCatalogCleanupTest(wire)
        let cleaned = try await f.repository.reconcileCatalog(catalog.catalog, reference: catalog.reference)
        #expect(cleaned.byAsset.isEmpty && cleaned.tombstones.isEmpty)
        #expect(try editingScalar(f.repository.fileURL, "SELECT count(*) FROM editing_remaps") == 0)
    }

    private func publish(_ ids: [String], in fixture: EditingFixture) throws -> StoredLibraryCatalog {
        let repository = CatalogRepository(directory: fixture.directory), folder = LibraryFolder(url: fixture.directory)
        try repository.save(.init(folders: [folder], assets: ids.map {
            PhotoAsset(id: $0, folderID: folder.id, fileURL: URL(fileURLWithPath: $0))
        }))
        return try repository.loadStored()
    }
}

private extension EditingRepository {
    func registerForCatalogCleanupTest(_ artifact: GeneratedArtifact) throws {
        let db = try connection()
        try sql.transaction(db) { try Self.register(artifact, on: db) }
    }
    func installForCatalogCleanupTest(_ remap: EditingRemapWire) throws {
        let db = try connection()
        try sql.transaction(db) { try saveRemap(remap, on: db) }
    }
}

private final class CatalogCleanupBoundarySwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () throws -> Void)?
    func install(_ operation: @escaping @Sendable () throws -> Void) { lock.withLock { self.operation = operation } }
    func run() throws {
        let action = lock.withLock { let action = operation; operation = nil; return action }
        try action?()
    }
}
