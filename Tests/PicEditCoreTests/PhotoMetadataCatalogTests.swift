import Foundation
import Testing
@testable import PicEditCore

@Suite("Crash-safe metadata catalog barriers and relocation")
struct PhotoMetadataCatalogTests {
    @Test func removeRefreshAndLateCatalogKeepConfirmedData() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Retained"))
        try Data("{\"removed\":true}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let removed = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:2,persistedReference:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),assets:[])
        _ = try await f.repository.reconcile(removed)
        #expect(try await f.repository.record(assetID:f.id)?.isOrphaned == true)
        #expect(try await f.repository.record(assetID:f.id)?.confirmed.title == "Retained")
        await metadataError(.staleCatalog) { _ = try await f.repository.reconcile(f.snapshot(source:try f.source(),generation:1)) }
        #expect(try await f.repository.record(assetID:f.id)?.isOrphaned == true)
    }
    @Test func stagedMappingBlocksOnlyAffectedMetadataAndCrashBeforePublishAbandons() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Retained"))
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:2)
        let receipt = try await f.repository.stageCatalogChange(move.change)
        #expect(receipt.state == .staged); #expect(receipt.protectedSourceURLs.count == 2)
        await metadataError(.relocationInProgress) { _ = try await f.confirm(.init(title:"Blocked")) }
        _ = try await f.repository.saveManualDraft(.init(header:.init(assetID:"unaffected",expectedVersion:.absent),mutation:.save(fields:.init(title:"Allowed"),baseConfirmedRevision:0)))
        let restart = PhotoMetadataRepository(directory:f.directory)
        let old = try f.snapshot(source:move.oldSource,generation:1)
        let recovered = try await restart.recoverCatalogChanges(persistedCatalog:old)
        #expect(recovered.changes.isEmpty)
        #expect(try await restart.record(assetID:f.id)?.confirmed.title == "Retained")
        #expect(try await restart.stageCatalogChange(move.change).state == .abandoned)
    }
    @Test func crashAfterCatalogPublishReplaysExactlyOnceAndPreservesHistoricalProvenance() async throws {
        let f = try MetadataFixture(); try await f.bind()
        let draft = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:.absent),mutation:.createSuggested(draftID:UUID(),fields:.init(title:"Blue house"),source:try f.analysisSource())))
        let d = draft.currentRecord!.draft!
        let confirmed = try await f.repository.confirm(.init(header:.init(assetID:f.id,expectedVersion:draft.currentRecord!.version),values:d.fields,fields:Set(PhotoMetadataField.allCases),source:d.source,origin:.proposal(draftID:d.id,expectedDraftRevision:d.revision)))
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:2)
        _ = try await f.repository.stageCatalogChange(move.change); try move.publish()
        let restart = PhotoMetadataRepository(directory:f.directory)
        let result = try await restart.recoverCatalogChanges(persistedCatalog:move.snapshot)
        #expect(result.changes.isEmpty)
        let value = try #require(try await restart.record(assetID:"moved"))
        #expect(value.confirmed == confirmed.currentRecord?.confirmed)
        #expect(value.confirmedSource == confirmed.currentRecord?.confirmedSource)
        #expect(value.confirmedSource?.original.standardizedPath == f.original.path)
        #expect(value.associationSource?.original.standardizedPath == move.destination.path)
        #expect(value.sourceChanged == false)
        let old = try #require(try await restart.record(assetID:f.id))
        #expect(old.confirmed.title.isEmpty && old.isOrphaned && old.confirmedRevision > 0)
        _ = try await restart.completeCatalogChange(id:move.change.id,persistedCatalog:move.snapshot)
        #expect(try await restart.record(assetID:"moved")?.version == value.version)
        try Data("{\"laterRating\":1}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let later = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:3,persistedReference:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),assets:move.snapshot.assets)
        _ = try await restart.reconcile(later)
        #expect(try await restart.stageCatalogChange(move.change).state == .completed)
        #expect(try await restart.record(assetID:"moved")?.version == value.version)
    }
    @Test func secondRelocationAfterRestartUsesCurrentAssociationNotOldAnalysisPath() async throws {
        let f = try MetadataFixture(); try await f.bind(); let saved = try await f.confirm(.init(title:"History"))
        let first = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved-1",generation:2)
        _ = try await f.repository.stageCatalogChange(first.change); try first.publish()
        _ = try await f.repository.completeCatalogChange(id:first.change.id,persistedCatalog:first.snapshot)
        let restart = PhotoMetadataRepository(directory:f.directory)
        _ = try await restart.recoverCatalogChanges(persistedCatalog:first.snapshot)
        let second = try await MetadataMove.prepare(f:f,repository:restart,from:first.destination,oldID:"moved-1",newID:"moved-2",generation:3)
        _ = try await restart.stageCatalogChange(second.change); try second.publish()
        _ = try await restart.completeCatalogChange(id:second.change.id,persistedCatalog:second.snapshot)
        let final = try #require(try await restart.record(assetID:"moved-2"))
        #expect(final.confirmed.title == "History" && !final.sourceChanged)
        #expect(final.confirmedSource == saved.currentRecord?.confirmedSource)
        #expect(final.associationSource?.original.standardizedPath == second.destination.path)
        try Data("different after relocation".utf8).write(to:second.destination)
        let changed = try f.source(url:second.destination)
        try Data("{\"generation\":4}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let refresh = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:4,persistedReference:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),assets:[.init(assetID:"moved-2",source:changed)])
        _ = try await restart.reconcile(refresh)
        #expect(try await restart.record(assetID:"moved-2")?.sourceChanged == true)
        #expect(try await restart.record(assetID:"moved-2")?.confirmedSource == saved.currentRecord?.confirmedSource)
    }
    @Test func knownOverwriteWarningSurvivesSameNativeRelocationAndRestartUntilTextConfirmation() async throws {
        let f = try MetadataFixture(); try await f.bind()
        let confirmed = try await f.confirm(.init(title:"Historical description"))
        let identity = confirmed.currentRecord?.associationSource?.nativeStamp?.identity
        try Data("changed pixels at the same inode".utf8).write(to:f.original)
        let changed = try f.source(); #expect(changed.nativeStamp?.identity == identity)
        try await f.bind(source:changed,generation:2)
        #expect(try await f.repository.record(assetID:f.id)?.sourceChanged == true)
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:3,sourceBeforeMove:changed)
        #expect(move.change.relocations[0].newSource.nativeStamp?.identity == identity)
        _ = try await f.repository.stageCatalogChange(move.change); try move.publish()
        let result = try await f.repository.completeCatalogChange(id:move.change.id,persistedCatalog:move.snapshot)
        // The native file moved, but the historical pre-overwrite stamp cannot
        // silently authorize its text. Explicit assignment is not text review.
        let receipt = try #require(result.changes.first), conflict = try #require(receipt.conflicts.first)
        #expect(conflict.reason == .unverifiedSource)
        _ = try await f.repository.resolveCatalogChange(.init(changeID:receipt.changeID,expectedChangeRevision:receipt.revision,persistedReference:move.snapshot.persistedReference,
            decisions:[.init(conflictID:conflict.id,sourceVersion:conflict.sourceVersion,destinationVersion:conflict.destinationVersion,action:.assignIfDestinationVacant)]))
        let moved = try #require(try await f.repository.record(assetID:"moved"))
        #expect(moved.sourceChanged && moved.confirmedSource == confirmed.currentRecord?.confirmedSource)
        #expect(moved.associationSource == move.snapshot.assets[0].source)
        let restart = PhotoMetadataRepository(directory:f.directory)
        _ = try await restart.recoverCatalogChanges(persistedCatalog:move.snapshot)
        #expect(try await restart.record(assetID:"moved")?.sourceChanged == true)
        _ = try await restart.reconcile(move.snapshot)
        #expect(try await restart.record(assetID:"moved")?.sourceChanged == true)
        let current = try #require(try await restart.record(assetID:"moved"))
        _ = try await restart.confirm(.init(header:.init(assetID:"moved",expectedVersion:current.version),values:current.confirmed,fields:Set(PhotoMetadataField.allCases),source:move.snapshot.assets[0].source,
            origin:.manual(expectedManualDraftRevision:nil,reviewedConfirmedRevision:current.confirmedRevision)))
        #expect(try await restart.record(assetID:"moved")?.sourceChanged == false)
    }
    @Test func unverifiedMappingKeepsBothRecordsAndResolutionUsesCurrentCAS() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Original"))
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:2,verified:false)
        _ = try await f.repository.stageCatalogChange(move.change); try move.publish()
        let recovery = try await f.repository.completeCatalogChange(id:move.change.id,persistedCatalog:move.snapshot)
        let change = try #require(recovery.changes.first), conflict = try #require(change.conflicts.first)
        #expect(conflict.reason == .unverifiedSource)
        #expect(try await f.repository.record(assetID:f.id)?.confirmed.title == "Original")
        #expect(try await f.repository.record(assetID:"moved") == nil)
        let operation = MetadataCatalogResolutionOperation(changeID:change.changeID,expectedChangeRevision:change.revision,persistedReference:move.snapshot.persistedReference,
            decisions:[.init(conflictID:conflict.id,sourceVersion:conflict.sourceVersion,destinationVersion:conflict.destinationVersion,action:.keepSeparate)])
        let resolved = try await f.repository.resolveCatalogChange(operation)
        #expect(resolved.changes.isEmpty && resolved.receipt?.disposition == .applied)
        #expect(try await f.repository.resolveCatalogChange(operation).receipt?.disposition == .replayed)
        #expect(try await f.repository.record(assetID:f.id)?.isOrphaned == true)
        try Data("{\"laterRating\":1}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let later = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:3,persistedReference:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),assets:move.snapshot.assets)
        _ = try await f.repository.reconcile(later)
        let retry = try await f.repository.resolveCatalogChange(operation)
        #expect(retry.receipt?.disposition == .replayed)
        if case .available(let snapshot) = retry.searchState { #expect(snapshot.catalogReference == later.persistedReference) } else { Issue.record("Expected current search state after receipt replay") }
    }
    @Test func unexpectedCatalogDigestIsConflictAndCannotGuessMapping() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Keep"))
        let move = try await MetadataMove.prepare(f:f,from:f.original,oldID:f.id,newID:"moved",generation:2)
        _ = try await f.repository.stageCatalogChange(move.change)
        try Data("{\"unrelated\":true}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let snapshot = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:3,persistedReference:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),assets:[])
        let restart = PhotoMetadataRepository(directory:f.directory), recovery = try await restart.recoverCatalogChanges(persistedCatalog:snapshot)
        #expect(recovery.changes.first?.conflicts.first?.reason == .catalogDigestMismatch)
        #expect(try await restart.record(assetID:f.id)?.confirmed.title == "Keep")
        #expect(try await restart.record(assetID:"moved") == nil)
    }
}
struct MetadataMove: Sendable {
    let change:MetadataCatalogChange, snapshot:MetadataCatalogSnapshot
    let oldSource:MetadataSourceReference, destination:URL, catalogURL:URL, data:Data
    static func prepare(f:MetadataFixture,repository:PhotoMetadataRepository? = nil,from:URL,oldID:String,newID:String,generation:Int,verified:Bool = true,sourceBeforeMove:MetadataSourceReference? = nil) async throws -> Self {
        let repository = repository ?? f.repository
        let row = try await repository.record(assetID:oldID)
        let oldSource = try sourceBeforeMove ?? row?.associationSource ?? row?.confirmedSource ?? f.source(url:from)
        let folder = f.directory.appendingPathComponent("Moved-\(generation)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let target = folder.appendingPathComponent(from.lastPathComponent)
        try FileManager.default.moveItem(at:from,to:target)
        let new = try f.source(url:target)
        let data = Data("{\"syntheticCatalogGeneration\":\(generation)}".utf8)
        let reference = MetadataCatalogFileReference.present(sha256:PhotoMetadataInternalCodec.sha256(data),byteCount:Int64(data.count))
        let move = MetadataRelocation(oldAssetID:oldID,newAssetID:newID,oldSource:oldSource,newSource:new,
            proof:.init(folderID:UUID(),bookmarkSHA256:String(repeating:"b",count:64),oldRoot:from.deletingLastPathComponent(),newRoot:folder,relativePath:from.lastPathComponent,
                verification:verified ? .sameNativeIdentity(before:oldSource.nativeStamp!,after:new.nativeStamp!) : .unresolved))
        return .init(change:.init(before:try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json")),after:reference,relocations:[move],expectedRecords:[.init(assetID:oldID,version:row?.version ?? .absent),.init(assetID:newID,version:.absent)]),
            snapshot:.init(catalogSessionID:f.session,catalogGeneration:generation,persistedReference:reference,assets:[.init(assetID:newID,source:new)]),oldSource:oldSource,destination:target,catalogURL:f.directory.appendingPathComponent("catalog.json"),data:data)
    }
    func publish() throws { try data.write(to:catalogURL) }
}
