import CoreGraphics
import Foundation
import ImageIO
import GlowroomCore
import Testing
import UniformTypeIdentifiers
@testable import Glowroom

// LibraryModel touches AppKit focus state, so these simulated app sessions run
// serially. Editing and text cleanup remain independent repository operations.
@Suite("Refresh retains unavailable originals and durable user data", .serialized)
@MainActor
struct CatalogRefreshRetentionTests {
    @Test(arguments: [false, true], [false, true])
    func movedOriginalSurvivesRefreshRestartAndOverlappingFolderRemoval(overlap: Bool, restart: Bool) async throws {
        var fixture = try await RefreshRetentionFixture.make()
        defer { fixture.remove() }
        var model = fixture.model()
        try await refreshRetentionWait(model)
        model.importFolders([fixture.photos])
        try await refreshRetentionWait(model)
        if overlap {
            model.importFolders([fixture.trip])
            try await refreshRetentionWait(model)
        }
        let imported = try #require(model.assets.first)
        model.setRating(4, for: imported.id)
        model.toggleFavorite(imported.id)
        #expect(await model.finishSaving())
        let saved = try #require(model.assets.first)
        try await fixture.seed(saved)
        let metadataBefore = try #require(await fixture.metadata.record(assetID: saved.id))
        let editingBefore = try await fixture.editing.loadState()

        let parked = fixture.root.appendingPathComponent("parked.png")
        try FileManager.default.moveItem(at: fixture.original, to: parked)
        model.refreshCurrentFolder()
        try await refreshRetentionWait(model)
        #expect(model.assets == [saved])
        #expect(try fixture.repository.load().assets == [saved])
        #expect(model.errorMessage == nil && model.canModifyCatalog)
        #expect(try await fixture.editing.loadState().byAsset[saved.id] == editingBefore.byAsset[saved.id])
        try await fixture.expectMetadataPreserved(metadataBefore)

        if restart {
            model.beginTermination()
            #expect(await model.finishSaving())
            fixture = try await fixture.reopened()
            model = fixture.model()
            try await refreshRetentionWait(model)
            #expect(model.assets == [saved])
            #expect(try await fixture.editing.loadState().byAsset[saved.id] == editingBefore.byAsset[saved.id])
            try await fixture.expectMetadataPreserved(metadataBefore)
            if overlap {
                model.selection = .folder(try #require(model.folders.first {
                    LibraryProjectionWorker.filePath($0.url) == LibraryProjectionWorker.filePath(fixture.trip)
                }).id)
                await model.waitForProjection()
            }
        }

        try FileManager.default.moveItem(at: parked, to: fixture.original)
        model.refreshCurrentFolder()
        try await refreshRetentionWait(model)
        #expect(model.assets == [saved], "A successful rescan keeps the saved ID, URL, owner, rating and favorite")
        #expect(try await fixture.editing.loadState().byAsset[saved.id] == editingBefore.byAsset[saved.id])
        try await fixture.expectMetadataPreserved(metadataBefore)
        #expect(try Data(contentsOf: fixture.original) == fixture.originalBytes)

        let parent = try #require(model.folders.first {
            LibraryProjectionWorker.filePath($0.url) == LibraryProjectionWorker.filePath(fixture.photos)
        })
        model.removeFolder(parent.id)
        try await refreshRetentionWait(model)
        if overlap {
            let child = try #require(model.folders.first)
            #expect(model.assets.first?.folderID == child.id)
            #expect(try await fixture.editing.loadState().byAsset[saved.id] == editingBefore.byAsset[saved.id])
            try await fixture.expectMetadataPreserved(metadataBefore)
            model.removeFolder(child.id)
            try await refreshRetentionWait(model)
        }
        #expect(model.assets.isEmpty && model.folders.isEmpty)
        #expect(try await fixture.editing.loadState().byAsset[saved.id] == nil)
        #expect(try await fixture.metadata.record(assetID: saved.id) == nil)
        #expect(try Data(contentsOf: fixture.original) == fixture.originalBytes)
        #expect(await model.finishSaving())
    }

    @Test
    func corruptAndOfflineSourcesRetainDataAndSuccessfulRescanUpdatesImageMetadata() async throws {
        let fixture = try await RefreshRetentionFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await refreshRetentionWait(model)
        model.importFolders([fixture.photos])
        try await refreshRetentionWait(model)
        let original = try #require(model.assets.first)
        try await fixture.seed(original)
        let metadataBefore = try #require(await fixture.metadata.record(assetID: original.id))
        let editingBefore = try await fixture.editing.loadState()

        try Data("temporarily corrupt PNG".utf8).write(to: fixture.original)
        model.refreshCurrentFolder()
        try await refreshRetentionWait(model)
        #expect(model.assets == [original])
        #expect(try await fixture.editing.loadState().byAsset[original.id] == editingBefore.byAsset[original.id])
        try await fixture.expectMetadataPreserved(metadataBefore)
        try fixture.originalBytes.write(to: fixture.original)

        let beforeOffline = model.catalog
        let offline = fixture.root.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.photos, to: offline)
        model.refreshCurrentFolder()
        try await refreshRetentionWait(model)
        #expect(model.catalog == beforeOffline)
        #expect(model.errorMessage != nil)
        #expect(try await fixture.editing.loadState().byAsset[original.id] == editingBefore.byAsset[original.id])
        try await fixture.expectMetadataPreserved(metadataBefore)
        try FileManager.default.moveItem(at: offline, to: fixture.photos)

        // Existing identities still receive new scanner metadata; retaining
        // unavailable files cannot freeze successful future scan results.
        try RefreshRetentionFixture.writeImage(fixture.original, width: 32)
        let added = fixture.photos.appendingPathComponent("new.png")
        try RefreshRetentionFixture.writeImage(added, width: 12)
        model.refreshCurrentFolder()
        try await refreshRetentionWait(model)
        let updated = try #require(model.assets.first { $0.id == original.id })
        #expect(updated.pixelWidth == 32 && updated.pixelHeight == 16)
        #expect(updated.folderID == original.folderID && updated.fileURL == original.fileURL)
        #expect(model.assets.count == 2)
        #expect(try await fixture.editing.loadState().byAsset[original.id] == editingBefore.byAsset[original.id])
        let updatedMetadata = try #require(await fixture.metadata.record(assetID: original.id))
        #expect(updatedMetadata.confirmed == metadataBefore.confirmed)
        #expect(updatedMetadata.manualDraft == metadataBefore.manualDraft)
        #expect(updatedMetadata.sourceChanged)
        #expect(await model.finishSaving())
    }
}

private enum RefreshRetentionFailure: Error { case timeout }

@MainActor
private func refreshRetentionWait(_ model: LibraryModel) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while model.isLoading || model.isImporting || model.isProjecting || model.isUpdatingCatalog {
        guard ContinuousClock.now < deadline else { throw RefreshRetentionFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
    await model.waitForProjection()
}

private struct RefreshRetentionFixture: Sendable {
    let root: URL
    let repository: CatalogRepository
    let editing: EditingRepository
    let metadata: PhotoMetadataRepository
    let originalBytes: Data
    var photos: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    var trip: URL { photos.appendingPathComponent("Trip", isDirectory: true) }
    var original: URL { trip.appendingPathComponent("photo.png") }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-refresh-retention-\(UUID())", isDirectory: true)
        let original = root.appendingPathComponent("Photos/Trip/photo.png")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeImage(original, width: 24)
        let repository = CatalogRepository(directory: root.appendingPathComponent("Data", isDirectory: true))
        return try await open(root: root, repository: repository, bytes: Data(contentsOf: original))
    }

    func reopened() async throws -> Self {
        try await Self.open(root: root, repository: repository, bytes: originalBytes)
    }

    private static func open(root: URL, repository: CatalogRepository, bytes: Data) async throws -> Self {
        let gate = CatalogLifecycleGate(requiresRecovery: false)
        let resources = ArtifactResourceOwner(limits: try .init())
        let artifacts = try await GeneratedArtifactStore.open(in: repository.directory, resources: resources, lifecycleGate: gate)
        let packages = EditingBackupPackageStore(resources: resources, catalog: repository)
        let editing = EditingRepository(directory: repository.directory, artifacts: artifacts, packages: packages, gate: gate)
        return .init(root: root, repository: repository, editing: editing,
                     metadata: PhotoMetadataRepository(directory: repository.directory, gate: gate), originalBytes: bytes)
    }

    @MainActor func model() -> LibraryModel {
        // No injected scanner: exercise the production FolderScanner, writer,
        // startup reconciliation and both durable repositories together.
        LibraryModel(repository: repository, metadataStore: metadata,
            catalogCleanup: { catalog, reference in try await self.clean(catalog, reference: reference) })
    }

    func clean(_ catalog: LibraryCatalog, reference: MetadataCatalogFileReference) async throws -> Bool {
        let before = try await editing.loadState()
        async let state = editing.reconcileCatalog(catalog, reference: reference)
        async let deleted = metadata.purgeMissingCatalogAssets(persistedCatalog: catalog, expectedReference: reference)
        let (after, _) = try await (state, deleted)
        return before.storeEpoch != after.storeEpoch
    }

    func seed(_ asset: PhotoAsset) async throws {
        let state = try await editing.loadState()
        _ = try await editing.saveSnapshot(EditingSnapshot(settings: EditSettings(exposure: 1.75)), for: asset.id,
            expected: .init(storeEpoch: state.storeEpoch, revision: nil, snapshot: nil), revision: 1)
        let confirmed = try await metadata.confirm(.init(header: .init(assetID: asset.id, expectedVersion: .absent),
            values: .init(title: "Previous confirmed text", tags: ["previous"]), fields: [.title, .tags],
            source: MetadataCatalogSources.source(asset), origin: .manual(expectedManualDraftRevision: nil, reviewedConfirmedRevision: 0)))
        _ = try await metadata.saveManualDraft(.init(header: .init(assetID: asset.id, expectedVersion: confirmed.currentRecord!.version),
            mutation: .save(fields: .init(title: "Previous draft"), baseConfirmedRevision: confirmed.currentRecord!.confirmedRevision)))
    }

    func expectMetadataPreserved(_ before: PhotoMetadataRecord) async throws {
        let record = try #require(await metadata.record(assetID: before.assetID))
        #expect(record.assetID == before.assetID && !record.isOrphaned)
        #expect(record.confirmed == before.confirmed)
        #expect(record.confirmedSource == before.confirmedSource)
        #expect(record.associationSource == before.associationSource)
        #expect(record.manualDraft == before.manualDraft)
        #expect(record.version.confirmedRevision == before.version.confirmedRevision)
        #expect(record.version.manualDraftRevision == before.version.manualDraftRevision)
        // Native file stamps can change while moving/repairing a file. A
        // source-change warning may advance the record without losing its data.
    }

    static func writeImage(_ url: URL, width: Int) throws {
        let context = try #require(CGContext(data: nil, width: width, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
