import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Metadata catalog integration", .serialized)
struct MetadataCatalogIntegrationTests {
    @Test func nativeRenameTransfersConfirmedTextExactlyOnceAfterRestart() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try await fixture.seedConfirmed()
        let destination = try fixture.moveFolder()
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let writer = fixture.movedWriter(store: store, destination: destination)
        let loaded = try await writer.load()
        let new = try #require(loaded.catalog.assets.first)
        #expect(new.id != old.id)
        #expect(loaded.metadata.error == nil)
        #expect(loaded.metadata.changes.isEmpty)
        #expect(try await store.record(assetID: new.id)?.confirmed.title == "Bestätigter Berg")
        #expect(try await store.record(assetID: old.id)?.isOrphaned == true)
        let reloaded = try await CatalogWriter(repository: fixture.repository,
            metadataStore: PhotoMetadataRepository(directory: fixture.repository.directory),
            folderResolver: { ($0, nil) }).load()
        #expect(reloaded.catalog.assets.first?.id == new.id)
        #expect(loaded.metadata.reference == reloaded.metadata.reference)
    }

    @Test func twoBookmarkRelocationsAfterRestartRetainOriginalProvenance() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.seedConfirmed()
        let destination = try fixture.moveFolder()
        let firstStore = PhotoMetadataRepository(directory: fixture.repository.directory)
        let first = try await fixture.movedWriter(store: firstStore, destination: destination).load()
        let intermediate = try #require(first.catalog.assets.first)
        #expect(first.metadata.changes.isEmpty)
        let secondDestination = fixture.root.appendingPathComponent("Third", isDirectory: true)
        try FileManager.default.moveItem(at: destination, to: secondDestination)
        let secondStore = PhotoMetadataRepository(directory: fixture.repository.directory)
        let second = try await fixture.movedWriter(store: secondStore, destination: secondDestination).load()
        let final = try #require(second.catalog.assets.first)
        #expect(second.metadata.error == nil)
        #expect(second.metadata.changes.isEmpty)
        #expect(final.id != intermediate.id)
        let record = try #require(try await secondStore.record(assetID: final.id))
        #expect(record.confirmed.title == "Bestätigter Berg")
        #expect(record.confirmedSource?.original.standardizedPath == original.fileURL.path)
        #expect(record.associationSource?.original.standardizedPath == final.fileURL.path)
        #expect(try await secondStore.record(assetID: intermediate.id)?.isOrphaned == true)
    }

    @Test(arguments: [CatalogWriteCheckpoint.afterMetadataStage, .afterCatalogPublish])
    func crashBoundaryRecoveryUsesPersistedBytes(_ checkpoint: CatalogWriteCheckpoint) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try await fixture.seedConfirmed(); let before = try fixture.repository.loadStored().reference
        let destination = try fixture.moveFolder()
        let writer = fixture.movedWriter(store: PhotoMetadataRepository(directory: fixture.repository.directory),
            destination: destination, checkpoint: { value in if value == checkpoint { throw SimulatedCrash.stop } })
        let interrupted = try await writer.load()
        #expect(interrupted.metadata.error != nil)
        #expect(interrupted.metadata.changes.contains { $0.state == .staged })
        if checkpoint == .afterMetadataStage {
            #expect(try fixture.repository.loadStored().reference == before)
            #expect(interrupted.catalog.assets.first?.id == old.id)
        } else {
            #expect(try fixture.repository.loadStored().reference != before)
            #expect(interrupted.catalog.assets.first?.id != old.id)
        }
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let restarted = try await fixture.movedWriter(store: store, destination: destination).load()
        let new = try #require(restarted.catalog.assets.first)
        #expect(restarted.metadata.error == nil)
        #expect(restarted.metadata.changes.isEmpty)
        #expect(try await store.record(assetID: new.id)?.confirmed.title == "Bestätigter Berg")
        #expect(try await store.record(assetID: old.id)?.isOrphaned == true)
    }

    @Test func destinationTombstoneCreatesResolvableBarrierWithoutMerging() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try await fixture.seedConfirmed(); let destination = try fixture.moveFolder()
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let newURL = destination.appendingPathComponent(old.fileURL.lastPathComponent)
        let newID = newURL.resolvingSymlinksInPath().standardizedFileURL.path
        var new = old; new.id = newID; new.fileURL = newURL
        // Explicit confirmed blank content still owns a revision and blocks
        // automatic assignment. This is intentionally seeded before binding.
        _ = try await store.confirm(.init(header: .init(assetID: newID, expectedVersion: .absent), values: .empty,
            fields: [.title], source: MetadataCatalogSources.source(new), origin: .manual(expectedManualDraftRevision: nil, reviewedConfirmedRevision: 0)))
        let writer = fixture.movedWriter(store: store, destination: destination)
        let loaded = try await writer.load()
        let receipt = try #require(loaded.metadata.changes.first)
        #expect(receipt.state == .conflicted)
        #expect(receipt.protectedSourceURLs.contains(old.fileURL))
        #expect(receipt.protectedSourceURLs.contains(newURL))
        let drained = try await writer.save(loaded.catalog, revision: 1)
        #expect(drained.changes == loaded.metadata.changes, "Shutdown drains without resolving a durable conflict")
        var changed = loaded.catalog; changed.assets[0].rating = 5
        await #expect(throws: PhotoMetadataError.relocationInProgress) { _ = try await writer.save(changed, revision: 2) }
        let conflict = try #require(receipt.conflicts.first)
        let result = try await writer.resolve(.init(changeID: receipt.changeID, expectedChangeRevision: receipt.revision,
            persistedReference: loaded.metadata.reference, decisions: [.init(conflictID: conflict.id,
                sourceVersion: conflict.sourceVersion, destinationVersion: conflict.destinationVersion, action: .keepSeparate)]))
        #expect(result.changes.isEmpty)
        #expect(try await store.record(assetID: old.id)?.confirmed.title == "Bestätigter Berg")
        #expect(try await store.record(assetID: newID)?.confirmed.title == "")
        _ = try await writer.save(loaded.catalog, revision: 3)
    }

    @Test @MainActor func confirmedTextsFilterBeforeSemanticAndDraftsRemainInvisible() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let model = LibraryModel(repository: fixture.repository, metadataStore: store)
        try await ready(model)
        let asset = fixture.asset
        let source = MetadataCatalogSources.source(asset)
        _ = try await store.saveManualDraft(.init(header: .init(assetID: asset.id, expectedVersion: .absent), mutation: .save(fields: .init(title: "Nur Entwurf"), baseConfirmedRevision: 0)))
        model.search = "Entwurf"; await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty)
        let version = try #require(try await store.record(assetID: asset.id)).version
        let previousGeneration = model.metadataGeneration.generation
        _ = try await store.confirm(.init(header: .init(assetID: asset.id, expectedVersion: version),
            values: .init(title: "Gipfel", description: "Aufnahme im Morgenlicht", tags: ["Berg"]),
            fields: [.title, .description, .tags], source: source,
            origin: .manual(expectedManualDraftRevision: version.manualDraftRevision, reviewedConfirmedRevision: 0)))
        for _ in 0..<1_000 { if model.metadataGeneration.generation > previousGeneration { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        model.search = "Berg"; await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [asset.id])
        model.minimumRating = 5; await model.waitForProjection()
        #expect(model.visibleAssets.isEmpty, "Other filters remain AND conditions")
        model.minimumRating = 0
        let projection = try await LibraryProjectionWorker().candidates(model.catalog, snapshotSessionID: UUID(), generation: 1,
            key: .init(selection: .all, query: "Morgenlicht", sort: .name, minimumRating: 0,
                       searchMode: .semantic, semanticQuery: "mountain"), date: Date(), overrides: [:],
            metadata: try #require(available(model.metadataSearchState)))
        #expect(projection.assets.map(\.id) == [asset.id], "Confirmed predicate is applied before semantic ranking")
        #expect(await model.finishSaving())
    }

    @Test @MainActor func unavailableMetadataPreservesLiteralSearchAndCatalogWrites() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let broken = fixture.repository.directory.appendingPathComponent("photo-metadata.sqlite")
        try Data("not-a-database".utf8).write(to: broken)
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let model = LibraryModel(repository: fixture.repository, metadataStore: store)
        try await ready(model)
        if case .unavailable = model.metadataSearchState {} else { Issue.record("Metadata failure must be visible") }
        #expect(!model.isReadOnly)
        model.search = fixture.asset.fileName; await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [fixture.asset.id])
        model.setRating(4, for: fixture.asset.id)
        #expect(await model.finishSaving())
        #expect(try fixture.repository.load().assets.first?.rating == 4)
        #expect(try Data(contentsOf: broken) == Data("not-a-database".utf8))
    }

    @Test @MainActor func changedOriginalAtStartupMarksSourceWithoutDisablingSearch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try await fixture.seedConfirmed()
        let originalSource = MetadataCatalogSources.source(old)
        #expect(originalSource.original.modifiedAt.timeIntervalSinceReferenceDate.bitPattern == old.modifiedAt.timeIntervalSinceReferenceDate.bitPattern)
        try Data("larger changed synthetic-original-data".utf8).write(to: old.fileURL)
        try FileManager.default.setAttributes([.modificationDate: old.modifiedAt.addingTimeInterval(5)], ofItemAtPath: old.fileURL.path)
        let observed = MetadataCatalogSources.source(old)
        #expect(observed.original.fileSize == observed.nativeStamp?.byteCount)
        #expect(observed.original.fileSize != old.fileSize)
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let model = LibraryModel(repository: fixture.repository, metadataStore: store)
        try await ready(model)
        #expect(try await store.record(assetID: old.id)?.sourceChanged == true)
        #expect(model.metadataError == nil)
        model.search = "Bestätigter Berg"; await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [old.id], "Existing confirmed descriptions remain searchable with a changed-source warning")
        model.search = old.fileName; await model.waitForProjection()
        #expect(model.visibleAssets.map(\.id) == [old.id])
        #expect(!model.isReadOnly)
        #expect(await model.finishSaving())
    }

    @Test func metadataRetryCannotRebaseAnOlderCatalogOverExternalBytes() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let writer = CatalogWriter(repository: fixture.repository,
            metadataStore: PhotoMetadataRepository(directory: fixture.repository.directory), folderResolver: { ($0, nil) })
        let loaded = try await writer.load()
        var external = loaded.catalog; external.assets[0].isFavorite = true
        try fixture.repository.save(external)
        let foreignBytes = try Data(contentsOf: fixture.repository.fileURL)
        await #expect(throws: CatalogRepositoryError.self) { _ = try await writer.retryMetadataReconciliation() }
        var olderUI = loaded.catalog; olderUI.assets[0].rating = 5
        await #expect(throws: CatalogRepositoryError.self) { _ = try await writer.save(olderUI, revision: 1) }
        #expect(try Data(contentsOf: fixture.repository.fileURL) == foreignBytes)
        #expect(try fixture.repository.load().assets[0].isFavorite)
        #expect(try fixture.repository.load().assets[0].rating == 0)
    }

    @Test func optionalNativeIdentityFieldsDoNotBlockFreshCatalogSource() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = PhotoMetadataRepository(directory: fixture.repository.directory)
        let writer = CatalogWriter(repository: fixture.repository, metadataStore: store, folderResolver: { ($0, nil) })
        _ = try await writer.load()
        let source = MetadataCatalogSources.source(fixture.asset), native = try #require(source.nativeStamp)
        let minimal = MetadataSourceReference(original: source.original,
            nativeStamp: .init(identity: native.identity, byteCount: native.byteCount, modifiedAt: native.modifiedAt, changedAt: native.changedAt))
        let result = try await store.confirm(.init(header: .init(assetID: fixture.asset.id, expectedVersion: .absent),
            values: .init(title: "Gleiche Quelle"), fields: [.title], source: minimal,
            origin: .manual(expectedManualDraftRevision: nil, reviewedConfirmedRevision: 0)))
        #expect(result.currentRecord?.confirmed.title == "Gleiche Quelle")
        #expect(result.currentRecord?.sourceChanged == false)
    }

    @MainActor private func ready(_ model: LibraryModel) async throws {
        for _ in 0..<2_000 { if !model.isLoading { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(!model.isLoading); await model.waitForProjection()
    }
    private func available(_ state: PhotoMetadataSearchState) -> PhotoMetadataSearchSnapshot? {
        if case .available(let snapshot) = state { return snapshot }; return nil
    }
}

private enum SimulatedCrash: Error { case stop }
private struct Fixture {
    let root: URL, repository: CatalogRepository, folder: LibraryFolder, asset: PhotoAsset
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-catalog-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        repository = CatalogRepository(directory: root.appendingPathComponent("Data", isDirectory: true))
        folder = LibraryFolder(url: root.appendingPathComponent("Old", isDirectory: true), bookmarkData: Data("synthetic-bookmark".utf8), subdirectoryPaths: ["Empty"])
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appendingPathComponent("a.raw")
        try Data("synthetic-original".utf8).write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        asset = PhotoAsset(folderID: folder.id, fileURL: file, fileSize: Int64(try Data(contentsOf: file).count),
            modifiedAt: try #require(attributes[.modificationDate] as? Date), cameraModel: "Synthetic Camera")
        try repository.save(.init(folders: [folder], assets: [asset]))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func seedConfirmed() async throws -> PhotoAsset {
        let store = PhotoMetadataRepository(directory: repository.directory)
        _ = try await CatalogWriter(repository: repository, metadataStore: store, folderResolver: { ($0, nil) }).load()
        _ = try await store.confirm(.init(header: .init(assetID: asset.id, expectedVersion: .absent),
            values: .init(title: "Bestätigter Berg"), fields: [.title], source: MetadataCatalogSources.source(asset),
            origin: .manual(expectedManualDraftRevision: nil, reviewedConfirmedRevision: 0)))
        return asset
    }
    func moveFolder() throws -> URL {
        let destination = root.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.moveItem(at: folder.url, to: destination); return destination
    }
    func movedWriter(store: PhotoMetadataRepository, destination: URL,
                     checkpoint: @escaping @Sendable (CatalogWriteCheckpoint) throws -> Void = { _ in }) -> CatalogWriter {
        CatalogWriter(repository: repository, metadataStore: store, folderResolver: { original in
            var changed = original; changed.url = destination; return (changed, nil)
        }, checkpoint: checkpoint)
    }
}
