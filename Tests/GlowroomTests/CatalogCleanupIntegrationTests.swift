import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Catalog publication and complete database cleanup")
struct CatalogCleanupIntegrationTests {
    @Test @MainActor func libraryRemovalAndFreshReimportKeepBothDatabasesEmpty() async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let scanner = CatalogCleanupScanner(asset:f.asset)
        let model = LibraryModel(repository:f.repository,metadataStore:f.metadata,
            catalogCleanup:{ catalog,reference in try await f.clean(catalog,reference:reference) },
            folderScanner:{ folder in await scanner.scan(folder) })
        var preparations = 0,synchronizations = 0
        model.prepareCatalogCleanup = { preparations += 1 }
        model.synchronizeEditing = { synchronizations += 1 }
        try await waitForCatalogCleanupModel(model)
        #expect(model.assets.map(\.id) == [f.asset.id] && model.canModifyCatalog)
        try await f.seed()

        model.removeFolder(f.folder.id)
        await model.waitForProjection()
        #expect(model.assets.isEmpty && model.folders.isEmpty && model.visibleAssets.isEmpty)
        #expect(try f.repository.load() == model.catalog)
        let removedState = try await f.editing.loadState()
        #expect(removedState.byAsset.isEmpty && removedState.tombstones.isEmpty)
        #expect(try await f.metadata.record(assetID:f.asset.id) == nil)
        #expect(preparations == 2 && synchronizations == 1)

        model.importFolders([f.folder.url])
        try await waitForCatalogCleanupModel(model)
        await model.waitForProjection()
        let reimported = try #require(model.assets.first)
        #expect(reimported.id == f.asset.id && reimported.folderID != f.folder.id)
        #expect(reimported.rating == 0 && !reimported.isFavorite)
        #expect(await scanner.calls == 1)
        #expect(model.visibleAssets.map(\.id) == [f.asset.id] && model.canModifyCatalog)
        let freshState = try await f.editing.loadState()
        #expect(freshState.byAsset.isEmpty && freshState.tombstones.isEmpty)
        #expect(try await f.metadata.record(assetID:f.asset.id) == nil)
        #expect(preparations == 3 && synchronizations == 1)
        #expect(try f.repository.load() == model.catalog)
        #expect(try Data(contentsOf:f.asset.fileURL) == f.originalBytes)
    }

    @Test(arguments:[false,true]) @MainActor
    func libraryCleanupOrSynchronizationFailureRetainsCommittedRemovalAndBlocksReadd(synchronizationFailure:Bool) async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let scanner = CatalogCleanupScanner(asset:f.asset),failure = CatalogCleanupObservations()
        let model = LibraryModel(repository:f.repository,metadataStore:f.metadata,
            catalogCleanup:{ catalog,reference in
                if await failure.shouldFail { throw CatalogCleanupFailure.injected }
                return try await f.clean(catalog,reference:reference)
            },folderScanner:{ folder in await scanner.scan(folder) })
        try await waitForCatalogCleanupModel(model)
        try await f.seed()
        var synchronizations = 0
        model.synchronizeEditing = {
            synchronizations += 1
            if synchronizationFailure { throw CatalogCleanupFailure.injected }
        }
        if !synchronizationFailure { await failure.setFailure(true) }
        model.removeFolder(f.folder.id)
        await model.waitForProjection()
        #expect(model.catalog.assets.isEmpty && model.catalog.folders.isEmpty && model.visibleAssets.isEmpty)
        #expect(try f.repository.load() == model.catalog)
        #expect(model.isReadOnly && !model.canModifyCatalog)
        #expect(model.errorMessage?.contains("injected cleanup failure") == true)
        let retainedSettings = try await f.editing.loadState().byAsset[f.asset.id]
        let retainedMetadata = try await f.metadata.record(assetID:f.asset.id)
        #expect((retainedSettings == nil) == synchronizationFailure)
        #expect((retainedMetadata == nil) == synchronizationFailure)
        #expect(synchronizations == (synchronizationFailure ? 1 : 0))

        let committedReference = try f.repository.loadStored().reference
        model.importFolders([f.folder.url]); model.enqueueFolders([f.folder.url])
        await model.waitForProjection()
        #expect(!model.isImporting)
        #expect(await scanner.calls == 0)
        #expect(model.catalog.assets.isEmpty && model.catalog.folders.isEmpty)
        #expect(try f.repository.loadStored().reference == committedReference)
        #expect(try Data(contentsOf:f.asset.fileURL) == f.originalBytes)
    }

    @Test func loadCleansOrphanedSettingsAndMetadataLeftByInterruptedRemoval() async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let writer = f.writer(); _ = try await writer.load()
        try await f.seed()
        // Simulate a previous process exiting after catalog publication and
        // before either database transaction could finish.
        try f.repository.save(LibraryCatalog())
        let loaded = try await writer.load()
        #expect(loaded.catalog.assets.isEmpty)
        #expect(loaded.metadata.cleanupError == nil && loaded.metadata.editingPruned)
        let state = try await f.editing.loadState()
        #expect(state.byAsset.isEmpty && state.tombstones.isEmpty)
        #expect(try await f.metadata.record(assetID:f.asset.id) == nil)
        #expect(try Data(contentsOf:f.asset.fileURL) == f.originalBytes)
    }

    @Test func folderRemovalCleansOnlyAfterExactCatalogPublication() async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let observations = CatalogCleanupObservations()
        let writer = f.writer(cleanup:{ catalog,reference in
            let actual = try f.repository.loadStored()
            await observations.append(catalog:catalog,reference:reference,actual:actual)
            return try await f.clean(catalog,reference:reference)
        })
        let loaded = try await writer.load(); try await f.seed()
        await observations.reset()
        let removed = await LibraryCatalogWorker().removing(f.folder.id,from:loaded.catalog)
        let saved = try await writer.save(removed,revision:1)
        let calls = await observations.calls
        #expect(calls.count == 1)
        #expect(calls.first?.catalog == removed && calls.first?.actual.catalog == removed)
        #expect(calls.first?.reference == saved.reference && calls.first?.actual.reference == saved.reference)
        #expect(saved.cleanupError == nil && saved.editingPruned)
        #expect(try f.repository.load().folders.isEmpty)
        #expect(try await f.editing.loadState().byAsset.isEmpty)
        #expect(try await f.metadata.record(assetID:f.asset.id) == nil)
    }

    @Test func readdingSameFolderStartsWithoutOldSettingsDraftsOrConfirmedText() async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let writer = f.writer(); let loaded = try await writer.load(); try await f.seed()
        let oldState = try await f.editing.loadState()
        let removed = await LibraryCatalogWorker().removing(f.folder.id,from:loaded.catalog)
        #expect(try await writer.save(removed,revision:1).cleanupError == nil)
        let scannedFolder = LibraryFolder(url:f.folder.url)
        let scannedAsset = PhotoAsset(folderID:scannedFolder.id,fileURL:f.asset.fileURL,
            fileSize:f.asset.fileSize,modifiedAt:f.asset.modifiedAt)
        let merged = try await LibraryCatalogWorker().merge(.init(assets:[scannedAsset],skippedFiles:0),folder:scannedFolder,into:removed)
        #expect(merged.addedCount == 1 && merged.catalog.assets.first?.id == f.asset.id)
        #expect(try await writer.save(merged.catalog,revision:2).cleanupError == nil)
        let newState = try await f.editing.loadState()
        #expect(newState.storeEpoch != oldState.storeEpoch)
        #expect(newState.byAsset[f.asset.id] == nil && newState.tombstones[f.asset.id] == nil)
        #expect(try await f.editing.variants(for:f.asset.id).isEmpty)
        #expect(try await f.metadata.record(assetID:f.asset.id) == nil)
        #expect(merged.catalog.assets.first?.rating == 0 && merged.catalog.assets.first?.isFavorite == false)
        #expect(try Data(contentsOf:f.asset.fileURL) == f.originalBytes)
    }

    @Test func cleanupFailureAfterPublicationReportsErrorAndKeepsCommittedRemoval() async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let observations = CatalogCleanupObservations()
        let writer = f.writer(cleanup:{ catalog,reference in
            let actual = try f.repository.loadStored()
            await observations.append(catalog:catalog,reference:reference,actual:actual)
            if await observations.shouldFail { throw CatalogCleanupFailure.injected }
            return try await f.clean(catalog,reference:reference)
        })
        let loaded = try await writer.load(); try await f.seed()
        await observations.reset(); await observations.setFailure(true)
        let removed = await LibraryCatalogWorker().removing(f.folder.id,from:loaded.catalog)
        let saved = try await writer.save(removed,revision:1)
        #expect(saved.cleanupError?.contains("injected cleanup failure") == true)
        #expect(try f.repository.load() == removed)
        #expect(try f.repository.loadStored().reference == saved.reference)
        // Cleanup failure is recoverable data awaiting the next load, never a
        // reason to republish the removed membership over the committed file.
        #expect(try await f.editing.loadState().byAsset[f.asset.id] != nil)
        #expect(try await f.metadata.record(assetID:f.asset.id) != nil)
        await observations.setFailure(false)
        #expect(try await writer.load().metadata.cleanupError == nil)
        #expect(try await f.editing.loadState().byAsset[f.asset.id] == nil)
        #expect(try await f.metadata.record(assetID:f.asset.id) == nil)
    }

    @Test func preAddCleanupFailurePreventsPublishingNewMembership() async throws {
        let f = try await CatalogCleanupFixture.make(); defer { f.remove() }
        let writer = f.writer(); let loaded = try await writer.load(); try await f.seed()
        let removed = await LibraryCatalogWorker().removing(f.folder.id,from:loaded.catalog)
        _ = try await writer.save(removed,revision:1)
        let before = try f.repository.loadStored()
        let observations = CatalogCleanupObservations()
        let rejecting = f.writer(metadata:PhotoMetadataRepository(directory:f.repository.directory),cleanup:{ catalog,reference in
            await observations.append(catalog:catalog,reference:reference,actual:try f.repository.loadStored())
            throw CatalogCleanupFailure.injected
        })
        let startup = try await rejecting.load()
        #expect(startup.metadata.cleanupError != nil)
        await observations.reset()
        await #expect(throws:CatalogCleanupFailure.self) {
            _ = try await rejecting.save(loaded.catalog,revision:2)
        }
        #expect(try f.repository.loadStored().reference == before.reference)
        #expect(try f.repository.load() == removed)
        let calls = await observations.calls
        #expect(calls.count == 1 && calls.first?.catalog == removed)
        #expect(calls.first?.actual.reference == before.reference)
    }
}

@MainActor
private func waitForCatalogCleanupModel(_ model:LibraryModel) async throws {
    let clock = ContinuousClock(),deadline = clock.now.advanced(by:.seconds(10))
    while model.isLoading || model.isImporting || model.isProjecting || model.isUpdatingCatalog {
        guard clock.now < deadline else { throw CatalogCleanupFailure.timeout }
        try await Task.sleep(for:.milliseconds(5))
    }
    await model.waitForProjection()
}
private actor CatalogCleanupScanner {
    let asset:PhotoAsset
    var calls = 0
    init(asset:PhotoAsset) { self.asset = asset }
    func scan(_ folder:LibraryFolder) -> ScanResult {
        calls += 1
        let fresh = PhotoAsset(folderID:folder.id,fileURL:asset.fileURL,fileSize:asset.fileSize,modifiedAt:asset.modifiedAt)
        return .init(assets:[fresh],skippedFiles:0)
    }
}

private enum CatalogCleanupFailure:LocalizedError {
    case injected,timeout
    var errorDescription:String? { self == .injected ? "injected cleanup failure" : "catalog cleanup test timeout" }
}
private actor CatalogCleanupObservations {
    struct Call:Sendable {
        let catalog:LibraryCatalog,reference:MetadataCatalogFileReference,actual:StoredLibraryCatalog
    }
    var calls:[Call] = [],shouldFail = false
    func append(catalog:LibraryCatalog,reference:MetadataCatalogFileReference,actual:StoredLibraryCatalog) {
        calls.append(.init(catalog:catalog,reference:reference,actual:actual))
    }
    func reset() { calls = [] }
    func setFailure(_ value:Bool) { shouldFail = value }
}
private struct CatalogCleanupFixture:Sendable {
    let root:URL,repository:CatalogRepository,folder:LibraryFolder,asset:PhotoAsset
    let editing:EditingRepository,metadata:PhotoMetadataRepository
    let originalBytes = Data("synthetic original retained through cleanup".utf8)
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-cleanup-integration-\(UUID())",isDirectory:true)
        let folder = LibraryFolder(url:root.appendingPathComponent("Originals",isDirectory:true))
        try FileManager.default.createDirectory(at:folder.url,withIntermediateDirectories:true)
        let original = folder.url.appendingPathComponent("photo.raw")
        let bytes = Data("synthetic original retained through cleanup".utf8); try bytes.write(to:original)
        let attributes = try FileManager.default.attributesOfItem(atPath:original.path)
        let asset = PhotoAsset(folderID:folder.id,fileURL:original,fileSize:Int64(bytes.count),
            modifiedAt:try #require(attributes[.modificationDate] as? Date),rating:4,isFavorite:true)
        let repository = CatalogRepository(directory:root.appendingPathComponent("Data",isDirectory:true))
        try repository.save(.init(folders:[folder],assets:[asset]))
        let gate = CatalogLifecycleGate(requiresRecovery:false)
        let resources = ArtifactResourceOwner(limits:try .init())
        let artifacts = try await GeneratedArtifactStore.open(in:repository.directory,resources:resources,lifecycleGate:gate)
        let packages = EditingBackupPackageStore(resources:resources,catalog:repository)
        let editing = EditingRepository(directory:repository.directory,artifacts:artifacts,packages:packages,gate:gate)
        return .init(root:root,repository:repository,folder:folder,asset:asset,editing:editing,
            metadata:PhotoMetadataRepository(directory:repository.directory,gate:gate))
    }
    func writer(metadata alternate:PhotoMetadataRepository? = nil,cleanup:CatalogWriter.Cleanup? = nil) -> CatalogWriter {
        CatalogWriter(repository:repository,metadataStore:alternate ?? metadata,folderResolver:{ ($0,nil) },
            cleanup:cleanup ?? { catalog,reference in try await self.clean(catalog,reference:reference) })
    }
    func clean(_ catalog:LibraryCatalog,reference:MetadataCatalogFileReference) async throws -> Bool {
        let before = try await editing.loadState()
        async let state = editing.reconcileCatalog(catalog,reference:reference)
        async let deleted = metadata.purgeMissingCatalogAssets(persistedCatalog:catalog,expectedReference:reference)
        let (after,_) = try await (state,deleted)
        return before.storeEpoch != after.storeEpoch
    }
    func seed() async throws {
        let state = try await editing.loadState()
        _ = try await editing.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:1.75)),for:asset.id,
            expected:.init(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil),revision:1)
        let confirmed = try await metadata.confirm(.init(header:.init(assetID:asset.id,expectedVersion:.absent),
            values:.init(title:"Previous confirmed text",tags:["previous"]),fields:[.title,.tags],source:MetadataCatalogSources.source(asset),
            origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0)))
        _ = try await metadata.saveManualDraft(.init(header:.init(assetID:asset.id,expectedVersion:confirmed.currentRecord!.version),
            mutation:.save(fields:.init(title:"Previous draft"),baseConfirmedRevision:confirmed.currentRecord!.confirmedRevision)))
    }
    func remove() { try? FileManager.default.removeItem(at:root) }
}
