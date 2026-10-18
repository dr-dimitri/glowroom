import Foundation
import CSQLite
import Testing
@testable import PicEditCore

@Suite("Permanent metadata catalog removal")
struct PhotoMetadataCatalogPurgeTests {
    @Test func removalDeletesAllPhotoContentAndReceiptsWhileRetainedPhotoIsUnchanged() async throws {
        let f = try MetadataFixture(), keptID = "kept-photo"
        let original = metadataPurgeCatalog(f, ids:[f.id,keptID])
        let initial = try await bindPurgeCatalog(original,f:f,generation:1)
        let saved = try await f.confirm(.init(title:"Removed title",description:"Removed text",tags:["Removed tag"]))
        let draft = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:saved.currentRecord!.version),
            mutation:.createSuggested(draftID:UUID(),fields:.init(title:"Removed AI draft"),source:try f.analysisSource())))
        _ = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:draft.currentRecord!.version),
            mutation:.save(fields:.init(title:"Removed manual draft"),baseConfirmedRevision:saved.currentRecord!.confirmedRevision)))
        let kept = try await f.repository.confirm(.init(header:.init(assetID:keptID,expectedVersion:.absent),values:.init(title:"Kept title"),fields:[.title],
            source:try f.source(),origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0)))
        let removed = metadataPurgeCatalog(f,ids:[keptID])
        try CatalogRepository(directory:f.directory).save(removed)
        let reference = try CatalogRepository(directory:f.directory).loadStored().reference
        let before = await f.repository.searchState().version
        #expect(try await f.repository.purgeMissingCatalogAssets(persistedCatalog:removed,expectedReference:reference) == 1)
        #expect(try await f.repository.record(assetID:f.id) == nil)
        #expect(try await f.repository.record(assetID:keptID) == kept.currentRecord)
        #expect(try purgeScalar(f.repository.fileURL,"SELECT COUNT(*) FROM metadata_records") == 1)
        #expect(try purgeScalar(f.repository.fileURL,"SELECT COUNT(*) FROM metadata_receipts") == 1)
        #expect(await f.repository.searchState().version.generation > before.generation)
        if case .available(let search) = await f.repository.searchState() {
            #expect(search.confirmedByAssetID == [keptID:kept.currentRecord!.confirmed])
            #expect(search.catalogReference == reference)
        } else { Issue.record("Expected purged search snapshot") }
        #expect(initial != reference)
        #expect(try Data(contentsOf:f.original) == Data("synthetic source".utf8))

        _ = try await bindPurgeCatalog(original,f:f,generation:3)
        #expect(try await f.repository.record(assetID:f.id) == nil)
        let fresh = try await f.confirm(.init(title:"New capture"))
        #expect(fresh.currentRecord?.version.recordRevision == 1)
        #expect(fresh.currentRecord?.draft == nil && fresh.currentRecord?.manualDraft == nil)
        #expect(fresh.currentRecord?.confirmed.description.isEmpty == true)
        let restarted = PhotoMetadataRepository(directory:f.directory)
        #expect(try await restarted.record(assetID:f.id) == fresh.currentRecord)
    }

    @Test func removalErasesReceiptsBeforeRetry() async throws {
        let f = try MetadataFixture()
        _ = try await bindPurgeCatalog(metadataPurgeCatalog(f,ids:[f.id]),f:f,generation:1)
        let operation = MetadataConfirmOperation(header:.init(assetID:f.id,expectedVersion:.absent),values:.init(title:"Old title"),fields:[.title],
            source:try f.source(),origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:0))
        _ = try await f.repository.confirm(operation)
        let empty = LibraryCatalog()
        let reference = try await bindPurgeCatalog(empty,f:f,generation:2)
        #expect(try await f.repository.purgeMissingCatalogAssets(persistedCatalog:empty,expectedReference:reference) == 1)
        await metadataError(.sourceChanged) { _ = try await f.repository.confirm(operation) }
        #expect(try await f.repository.record(assetID:f.id) == nil)
        #expect(try purgeScalar(f.repository.fileURL,"SELECT COUNT(*) FROM metadata_receipts") == 0)
    }

    @Test func wrongReferenceOrNonAuthoritativeAssetSetCannotDeleteMetadata() async throws {
        let f = try MetadataFixture(), original = metadataPurgeCatalog(f,ids:[f.id])
        let reference = try await bindPurgeCatalog(original,f:f,generation:1)
        let saved = try await f.confirm(.init(title:"Keep"))
        await metadataError(.catalogConflict) {
            _ = try await f.repository.purgeMissingCatalogAssets(persistedCatalog:LibraryCatalog(),expectedReference:reference)
        }
        try CatalogRepository(directory:f.directory).save(LibraryCatalog())
        await metadataError(.catalogConflict) {
            _ = try await f.repository.purgeMissingCatalogAssets(persistedCatalog:original,expectedReference:reference)
        }
        #expect(try await f.repository.record(assetID:f.id) == saved.currentRecord)
    }

    @Test func stagedAndConflictedRelocationsBlockDestructivePurge() async throws {
        let f = try MetadataFixture()
        _ = try await bindPurgeCatalog(metadataPurgeCatalog(f,ids:[f.id]),f:f,generation:1)
        let saved = try await f.confirm(.init(title:"Protected relocation"))
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:2)
        _ = try await f.repository.stageCatalogChange(move.change)
        let empty = LibraryCatalog()
        try CatalogRepository(directory:f.directory).save(empty)
        let reference = try CatalogRepository(directory:f.directory).loadStored().reference
        await metadataError(.relocationInProgress) {
            _ = try await f.repository.purgeMissingCatalogAssets(persistedCatalog:empty,expectedReference:reference)
        }
        let recovery = try await f.repository.recoverCatalogChanges(persistedCatalog:.init(catalogSessionID:f.session,catalogGeneration:3,persistedReference:reference,assets:[]))
        #expect(recovery.changes.first?.state == .conflicted)
        await metadataError(.relocationInProgress) {
            _ = try await f.repository.purgeMissingCatalogAssets(persistedCatalog:empty,expectedReference:reference)
        }
        #expect(try await f.repository.record(assetID:f.id)?.confirmed == saved.currentRecord?.confirmed)
        #expect(try purgeScalar(f.repository.fileURL,"SELECT COUNT(*) FROM metadata_catalog_changes") == 1)
    }

    @Test func terminalRelocationJournalsAndTheirCoordinationLinksArePurged() async throws {
        let f = try MetadataFixture()
        _ = try await bindPurgeCatalog(metadataPurgeCatalog(f,ids:[f.id]),f:f,generation:1)
        _ = try await f.confirm(.init(title:"Relocated title"))
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:2)
        _ = try await f.repository.stageCatalogChange(move.change); try move.publish()
        _ = try await f.repository.completeCatalogChange(id:move.change.id,persistedCatalog:move.snapshot)
        let folder = LibraryFolder(url:move.destination.deletingLastPathComponent())
        let retained = LibraryCatalog(folders:[folder],assets:[PhotoAsset(id:"moved",folderID:folder.id,fileURL:move.destination)])
        // MetadataMove uses synthetic catalog bytes. Publish a real catalog
        // through their exact known reference rather than trying to decode them.
        let repository = CatalogRepository(directory:f.directory)
        let stage = try repository.stage(repository.prepare(retained)); defer { repository.discard(stage) }
        try repository.publish(stage,expected:move.snapshot.persistedReference)
        let reference = try repository.loadStored().reference
        try purgeMutate(f.repository.fileURL,"INSERT INTO metadata_coordinations(id,coordinator_sha) VALUES('\(move.change.id.uuidString.lowercased())','\(String(repeating:"a",count:64))')")
        #expect(try await f.repository.purgeMissingCatalogAssets(persistedCatalog:retained,expectedReference:reference) == 1)
        #expect(try await f.repository.record(assetID:"moved")?.confirmed.title == "Relocated title")
        #expect(try await f.repository.record(assetID:f.id) == nil)
        for table in ["metadata_catalog_changes","metadata_coordinations","metadata_receipts"] {
            #expect(try purgeScalar(f.repository.fileURL,"SELECT COUNT(*) FROM \(table)") == 0)
        }
    }

    @Test func failedCommitRollsBackRemovalAndReceipts() async throws {
        let failure = MetadataFailureSwitch(), directory = MetadataFixture.directory()
        var hooks = PhotoMetadataRepositoryHooks(); hooks.beforeCommit = { try failure.check() }
        let repository = PhotoMetadataRepository(directory:directory,hooks:hooks)
        let f = try MetadataFixture(directory:directory,repository:repository)
        _ = try await bindPurgeCatalog(metadataPurgeCatalog(f,ids:[f.id]),f:f,generation:1)
        let saved = try await f.confirm(.init(title:"Retained on failure"))
        let empty = LibraryCatalog(); try CatalogRepository(directory:directory).save(empty)
        let reference = try CatalogRepository(directory:directory).loadStored().reference
        failure.enabled = true
        await metadataError(.storageFailure) {
            _ = try await repository.purgeMissingCatalogAssets(persistedCatalog:empty,expectedReference:reference)
        }
        failure.enabled = false
        #expect(try await repository.record(assetID:f.id) == saved.currentRecord)
        #expect(try purgeScalar(repository.fileURL,"SELECT COUNT(*) FROM metadata_receipts") == 1)
        #expect(try await repository.purgeMissingCatalogAssets(persistedCatalog:empty,expectedReference:reference) == 1)
    }
}

private func metadataPurgeCatalog(_ f:MetadataFixture,ids:[String]) -> LibraryCatalog {
    let folder = LibraryFolder(id:UUID(uuidString:"10000000-0000-0000-0000-000000000001")!,url:f.original.deletingLastPathComponent(),addedAt:Date(timeIntervalSince1970:1))
    return LibraryCatalog(folders:[folder],assets:ids.map {
        PhotoAsset(id:$0,folderID:folder.id,fileURL:f.original,createdAt:Date(timeIntervalSince1970:1),modifiedAt:Date(timeIntervalSince1970:1))
    })
}
@discardableResult
private func bindPurgeCatalog(_ catalog:LibraryCatalog,f:MetadataFixture,generation:Int) async throws -> MetadataCatalogFileReference {
    let repository = CatalogRepository(directory:f.directory)
    try repository.save(catalog)
    let reference = try repository.loadStored().reference
    let assets = try catalog.assets.map { MetadataCatalogAsset(assetID:$0.id,source:try f.source(url:$0.fileURL)) }
    _ = try await f.repository.reconcile(.init(catalogSessionID:f.session,catalogGeneration:generation,persistedReference:reference,assets:assets))
    return reference
}
private func purgeScalar(_ file:URL,_ sql:String) throws -> Int {
    var db:OpaquePointer?,statement:OpaquePointer?
    guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { sqlite3_close(db); throw PhotoMetadataError.storageFailure }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK,sqlite3_step(statement) == SQLITE_ROW else { throw PhotoMetadataError.storageFailure }
    return Int(sqlite3_column_int64(statement,0))
}
private func purgeMutate(_ file:URL,_ sql:String) throws {
    var db:OpaquePointer?
    guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READWRITE,nil) == SQLITE_OK else { sqlite3_close(db); throw PhotoMetadataError.storageFailure }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw PhotoMetadataError.storageFailure }
}
