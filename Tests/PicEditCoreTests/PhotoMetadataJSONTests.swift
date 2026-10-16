import Foundation
import Darwin
import Testing
@testable import PicEditCore

@Suite("Strict bounded metadata JSON and manual backup")
struct PhotoMetadataJSONTests {
    @Test func modelResponseNormalizesOnlyExactVersionedFields() throws {
        let json = Data(#"{"schemaVersion":1,"title":"  Ein Haus  ","description":"Am Feld","tags":["Grün","GRÜN"],"language":"de_DE"}"#.utf8)
        #expect(try PhotoMetadataModelResponseValidator.validate(json) == .init(title:"Ein Haus",description:"Am Feld",tags:["Grün"]))
        for text in [
            #"{"schemaVersion":1,"title":"A","title":"B","description":"","tags":[],"language":"de_DE"}"#,
            #"{"schemaVersion":1,"title":"A","ti\u0074le":"B","description":"","tags":[],"language":"de_DE"}"#,
            #"{"schemaVersion":1,"title":"A","description":"","tags":[],"language":"de_DE","extra":1}"#,
            #"{"schemaVersion":1.0,"title":"A","description":"","tags":[],"language":"de_DE"}"#,
            #"{"schemaVersion":1,"title":"A","description":"","tags":[],"language":"en_US"}"#,
            #"{"schemaVersion":1,"title":"","description":"","tags":[],"language":"de_DE"}"#
        ] { #expect(throws:PhotoMetadataError.self) { try PhotoMetadataModelResponseValidator.validate(Data(text.utf8)) } }
    }
    @Test func broadObjectsAndHugeNumberTokensAreRejectedBeforeDOMAllocation() throws {
        let broad = "{" + (0..<100).map { "\"key-\($0)\":0" }.joined(separator:",") + "}"
        #expect(throws:PhotoMetadataError.validation(.unknownField)) { try PhotoMetadataModelResponseValidator.validate(Data(broad.utf8)) }
        let number = String(repeating:"9",count:1_000)
        #expect(throws:PhotoMetadataError.validation(.malformedJSON)) { try PhotoMetadataModelResponseValidator.validate(Data(number.utf8)) }
    }
    @Test func characterByteAggregateAndTagBoundsAreIndependent() throws {
        #expect(try PhotoTextNormalization.normalize(.init(title:String(repeating:"a",count:120))).title.count == 120)
        #expect(throws:PhotoMetadataError.limitExceeded(.titleCharacters)) { try PhotoTextNormalization.normalize(.init(title:String(repeating:"a",count:121))) }
        let hugeGrapheme = "x" + String(repeating:"\u{301}",count:600)
        #expect(hugeGrapheme.count == 1)
        #expect(throws:PhotoMetadataError.limitExceeded(.titleBytes)) { try PhotoTextNormalization.normalize(.init(title:hugeGrapheme)) }
        #expect(throws:PhotoMetadataError.validation(.invalidControlCharacter)) { try PhotoTextNormalization.normalize(.init(title:"a\u{0}b")) }
        #expect(throws:PhotoMetadataError.validation(.emptyTag)) { try PhotoTextNormalization.normalize(.init(tags:[" "])) }
        let tags = (0..<20).map { "tag-\($0)" }
        #expect(try PhotoTextNormalization.mergingTags(existing:tags,incoming:tags.map { $0.uppercased() },policy:.append) == tags)
        #expect(throws:PhotoMetadataError.limitExceeded(.tagCount)) { try PhotoTextNormalization.mergingTags(existing:tags,incoming:["twenty-first"],policy:.append) }
        #expect(try PhotoTextNormalization.mergingTags(existing:tags,incoming:[],policy:.replace).isEmpty)
    }
    @Test func exportImportRoundtripIsConfirmedOnlyAndRetrySurvivesConsumedReview() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"A house",description:"Blue roof",tags:["roof"]))
        let current = try await f.repository.record(assetID:f.id)!
        _ = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:current.version),mutation:.save(fields:.init(title:"Secret unconfirmed"),baseConfirmedRevision:current.confirmedRevision)))
        let url = f.directory.appendingPathComponent("backup.json"), protection = MetadataFileProtectionSnapshot(originalURLs:[f.original],managedFileURLs:[],managedDirectoryURLs:[])
        let exported = try await f.repository.exportConfirmed(destination:url,protection:protection)
        #expect(exported.entryCount == 1)
        let data = try Data(contentsOf:url)
        #expect(!String(decoding:data,as:UTF8.self).contains("Secret unconfirmed"))
        let decoded = try PhotoMetadataPortableJSON.decode(data)
        #expect(decoded.document.entries[0].source?.original.standardizedPath == f.original.path)
        let imported = PhotoMetadataRepository(directory:MetadataFixture.directory())
        let review = try await imported.prepareImport(source:url,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[]))
        let operation = MetadataImportOperation(reviewID:review.id,reviewContentSHA256:review.contentSHA256,decisions:[])
        let first = try await imported.commitImport(operation)
        #expect(first.receipt.affected.count == 1)
        #expect(try await imported.record(assetID:f.id)?.confirmed == current.confirmed)
        #expect(try await imported.record(assetID:f.id)?.isOrphaned == true)
        #expect(try await imported.record(assetID:f.id)?.confirmedSource?.nativeStamp == nil)
        #expect(try await imported.commitImport(operation).receipt.disposition == .replayed)
    }
    @Test func conflictsDefaultToKeepAndExplicitReplaceBindsCurrentVersion() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Existing",tags:["old"]))
        let url = try metadataImportFile(directory:f.directory,entries:[metadataEntry(id:f.id,title:"Incoming",tags:["new"])])
        let protection = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[])
        let first = try await f.repository.prepareImport(source:url,protection:protection)
        #expect(first.conflicts.count == 1)
        _ = try await f.repository.commitImport(.init(reviewID:first.id,reviewContentSHA256:first.contentSHA256,decisions:[]))
        #expect(try await f.repository.record(assetID:f.id)?.confirmed.title == "Existing")
        let second = try await f.repository.prepareImport(source:url,protection:protection), conflict = second.conflicts[0]
        _ = try await f.repository.commitImport(.init(reviewID:second.id,reviewContentSHA256:second.contentSHA256,decisions:[.init(conflictID:conflict.id,expectedVersion:conflict.expectedVersion,action:.replace(fields:[.title,.tags],tags:.append))]))
        let value = try await f.repository.record(assetID:f.id)!
        #expect(value.confirmed.title == "Incoming")
        #expect(value.confirmed.tags == ["old","new"])
        if case .manual = value.confirmedProvenance.tags[0].origin {} else { Issue.record("Old tag provenance lost") }
        if case .imported = value.confirmedProvenance.tags[1].origin {} else { Issue.record("New imported tag lacks provenance") }
    }
    @Test func reviewedImportCASIsWholeDocumentAndEmptyTombstoneBlocksInsertMissing() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.empty)
        let url = try metadataImportFile(directory:f.directory,entries:[metadataEntry(id:f.id,title:"Resurrect"),metadataEntry(id:"unknown",title:"New")])
        let review = try await f.repository.prepareImport(source:url,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[]))
        #expect(review.conflicts.count == 1)
        _ = try await f.confirm(.init(title:"Newer"))
        await metadataError(.importConflict) { _ = try await f.repository.commitImport(.init(reviewID:review.id,reviewContentSHA256:review.contentSHA256,decisions:[])) }
        #expect(try await f.repository.record(assetID:"unknown") == nil)
        let fresh = try await f.repository.prepareImport(source:url,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[]))
        _ = try await f.repository.commitImport(.init(reviewID:fresh.id,reviewContentSHA256:fresh.contentSHA256,decisions:[]))
        #expect(try await f.repository.record(assetID:f.id)?.confirmed.title == "Newer")
        #expect(try await f.repository.record(assetID:"unknown")?.isOrphaned == true)
    }
    @Test func oldDialogCannotDiscardNewReviewAndMalformedFilesNeverWrite() async throws {
        let f = try MetadataFixture(), url = try metadataImportFile(directory:f.directory,entries:[metadataEntry(id:"other",title:"Text")])
        let p = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[])
        let a = try await f.repository.prepareImport(source:url,protection:p), b = try await f.repository.prepareImport(source:url,protection:p)
        await f.repository.discardImport(reviewID:a.id)
        _ = try await f.repository.commitImport(.init(reviewID:b.id,reviewContentSHA256:b.contentSHA256,decisions:[]))
        let malformed = f.directory.appendingPathComponent("bad.json")
        let original = try Data(contentsOf:url), text = String(decoding:original,as:UTF8.self)
        for changed in [text.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":2"),text.replacingOccurrences(of:"\"title\":\"Text\"",with:"\"title\":\"Text\",\"unknown\":1"),text.replacingOccurrences(of:"\"originalRevision\":1",with:"\"originalRevision\":1.0")] {
            try Data(changed.utf8).write(to:malformed)
            do { _ = try await f.repository.prepareImport(source:malformed,protection:p); Issue.record("Invalid JSON accepted") } catch {}
        }
        #expect(try await f.repository.record(assetID:"other")?.confirmedRevision == 1)
    }
    @Test func exportFailurePreservesTargetAndProtectedAliases() async throws {
        let failure = MetadataFailureSwitch(); var hooks = PhotoMetadataRepositoryHooks(); hooks.beforeExportPublish = { try failure.check() }
        let directory = MetadataFixture.directory(), repository = PhotoMetadataRepository(directory:directory,hooks:hooks)
        let f = try MetadataFixture(directory:directory,repository:repository); try await f.bind(); _ = try await f.confirm(.init(title:"Saved"))
        let target = directory.appendingPathComponent("existing.json"), previous = Data("previous export".utf8); try previous.write(to:target)
        let p = MetadataFileProtectionSnapshot(originalURLs:[f.original],managedFileURLs:[],managedDirectoryURLs:[])
        failure.enabled = true
        await metadataError(.storageFailure) { _ = try await repository.exportConfirmed(destination:target,protection:p) }
        #expect(try Data(contentsOf:target) == previous)
        failure.enabled = false
        let linkURL = directory.appendingPathComponent("hard.json"); #expect(link(f.original.path,linkURL.path) == 0)
        await metadataError(.protectedPath) { _ = try await repository.exportConfirmed(destination:linkURL,protection:p) }
        let symlinkURL = directory.appendingPathComponent("alias.json"); #expect(symlink(f.original.path,symlinkURL.path) == 0)
        await metadataError(.protectedPath) { _ = try await repository.exportConfirmed(destination:symlinkURL,protection:p) }
        #expect(try Data(contentsOf:f.original) == Data("synthetic source".utf8))
        let own = repository.fileURL
        await metadataError(.protectedPath) { _ = try await repository.exportConfirmed(destination:own,protection:p) }
    }
    @Test func managedDirectoryFamiliesCoverLateQuarantineAndParentAliases() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Title"))
        let directory = f.directory.appendingPathComponent("semantic-index-quarantine-later",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let alias = f.directory.appendingPathComponent("parent-alias"); #expect(symlink(directory.path,alias.path) == 0)
        let p = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[],managedDirectoryFamilies:[.init(parent:f.directory,childNamePrefix:"semantic-index-quarantine-")])
        await metadataError(.protectedPath) { _ = try await f.repository.exportConfirmed(destination:alias.appendingPathComponent("target.json"),protection:p) }
    }
    @Test func destinationAncestorWalkTerminatesAtRootAndProtectsEveryAncestor() throws {
        let directory = MetadataFixture.directory()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let nested = directory.appendingPathComponent("safe/deep",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        let target = nested.appendingPathComponent("export.json")
        let unrelated = directory.appendingPathComponent("unrelated",isDirectory:true)
        try FileManager.default.createDirectory(at:unrelated,withIntermediateDirectories:true)
        // A miss must reach '/' and return, including a nonmatching family at root.
        let allowed = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[unrelated],
            managedDirectoryFamilies:[.init(parent:URL(fileURLWithPath:"/",isDirectory:true),childNamePrefix:"not-a-managed-root-")])
        try PhotoMetadataFiles.checkDestination(target,protection:allowed,extra:[])
        try PhotoMetadataFiles.checkDestination(URL(fileURLWithPath:"/picedit-metadata-absent-\(UUID()).json",isDirectory:false),protection:allowed,extra:[])
        for ancestor in [nested,directory,URL(fileURLWithPath:"/",isDirectory:true)] {
            #expect(throws:PhotoMetadataError.protectedPath) {
                try PhotoMetadataFiles.checkDestination(target,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[ancestor]),extra:[])
            }
        }
        let family = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[],
            managedDirectoryFamilies:[.init(parent:directory,childNamePrefix:"safe")])
        #expect(throws:PhotoMetadataError.protectedPath) { try PhotoMetadataFiles.checkDestination(target,protection:family,extra:[]) }
        let immediateRootFamily = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[],
            managedDirectoryFamilies:[.init(parent:URL(fileURLWithPath:"/",isDirectory:true),childNamePrefix:directory.standardizedFileURL.resolvingSymlinksInPath().path.split(separator:"/")[0].description)])
        #expect(throws:PhotoMetadataError.protectedPath) { try PhotoMetadataFiles.checkDestination(target,protection:immediateRootFamily,extra:[]) }
    }
    @Test func missingLeavesAndDirectoryRootsUseNativeReachablePrefixComparison() throws {
        let directory = MetadataFixture.directory()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let alias = directory.appendingPathComponent("relative-dangling")
        #expect(symlink("absent/deep",alias.path) == 0)
        let original = directory.appendingPathComponent("absent/deep/more/image.png")
        let target = alias.appendingPathComponent("more/image.png")
        #expect(FilePathComparison.canonicalPath(original) == FilePathComparison.canonicalPath(target))
        let p = MetadataFileProtectionSnapshot(originalURLs:[original],managedFileURLs:[],managedDirectoryURLs:[])
        #expect(throws:PhotoMetadataError.protectedPath) { try PhotoMetadataFiles.checkDestination(target,protection:p,extra:[]) }
        let unavailableRoot = directory.appendingPathComponent("absent/deep/ModelRoot",isDirectory:true)
        let rootTarget = alias.appendingPathComponent("ModelRoot",isDirectory:false)
        let rootProtection = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[unavailableRoot])
        #expect(throws:PhotoMetadataError.protectedPath) { try PhotoMetadataFiles.checkDestination(rootTarget,protection:rootProtection,extra:[]) }
        let family = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[],
            managedDirectoryFamilies:[.init(parent:directory.appendingPathComponent("absent/deep",isDirectory:true),childNamePrefix:"Model")])
        #expect(throws:PhotoMetadataError.protectedPath) { try PhotoMetadataFiles.checkDestination(rootTarget,protection:family,extra:[]) }
        // Native private-directory aliases also compare while several leaves miss.
        let privatePath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        if privatePath.hasPrefix("/private/") {
            let abbreviated = URL(fileURLWithPath:String(privatePath.dropFirst(8)),isDirectory:true).appendingPathComponent("not-yet/another/image.png")
            let physical = URL(fileURLWithPath:privatePath,isDirectory:true).appendingPathComponent("not-yet/another/image.png")
            #expect(FilePathComparison.canonicalPath(abbreviated) == FilePathComparison.canonicalPath(physical))
            #expect(throws:PhotoMetadataError.protectedPath) { try PhotoMetadataFiles.checkDestination(abbreviated,protection:.init(originalURLs:[physical],managedFileURLs:[],managedDirectoryURLs:[]),extra:[]) }
        }
    }
    @Test func importReviewExpiryUsesContinuousElapsedTimeWithoutWriting() async throws {
        let f = try MetadataFixture()
        let url = try metadataImportFile(directory:f.directory,entries:[metadataEntry(id:"incoming",title:"Retained")])
        let review = try await f.repository.prepareImport(source:url,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[]))
        await f.repository.expireImportReviewForTest()
        await metadataError(.reviewMissingOrExpired) {
            _ = try await f.repository.commitImport(.init(reviewID:review.id,reviewContentSHA256:review.contentSHA256,decisions:[]))
        }
        #expect(try await f.repository.record(assetID:"incoming") == nil)
    }
    @Test func secondRepositoryCatalogChangeCannotUseAStaleProtectionOrSourceMap() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Before"))
        let original = f.directory.appendingPathComponent("new-original.png"), originalBytes = Data("new unannotated original".utf8)
        try originalBytes.write(to:original)
        let addedSource = try f.source(url:original)
        try Data("{\"newCatalogGeneration\":2}".utf8).write(to:f.directory.appendingPathComponent("catalog.json"))
        let reference = try PhotoMetadataFiles.reference(f.directory.appendingPathComponent("catalog.json"))
        let snapshot = MetadataCatalogSnapshot(catalogSessionID:f.session,catalogGeneration:2,persistedReference:reference,
            assets:[.init(assetID:f.id,source:try f.source()),.init(assetID:"new-original",source:addedSource)])
        let other = PhotoMetadataRepository(directory:f.directory)
        _ = try await other.reconcile(snapshot)
        let protection = MetadataFileProtectionSnapshot(originalURLs:[f.original],managedFileURLs:[],managedDirectoryURLs:[])
        await metadataError(.catalogConflict) { _ = try await f.repository.exportConfirmed(destination:original,protection:protection) }
        #expect(try Data(contentsOf:original) == originalBytes)
        let imported = try metadataImportFile(directory:f.directory,entries:[metadataEntry(id:"unassigned",title:"Incoming")])
        await metadataError(.catalogConflict) { _ = try await f.repository.prepareImport(source:imported,protection:protection) }
        let version = try #require(try await f.repository.record(assetID:f.id)).version
        await metadataError(.catalogConflict) {
            _ = try await f.repository.saveAIDraft(.init(header:.init(assetID:f.id,expectedVersion:version),
                mutation:.createSuggested(draftID:UUID(),fields:.init(title:"Stale map"),source:try f.analysisSource())))
        }
        await metadataError(.catalogConflict) { _ = try await f.confirm(.init(title:"Stale confirmation")) }
        // Pure editorial draft storage does not assert a source association.
        _ = try await f.repository.saveManualDraft(.init(header:.init(assetID:f.id,expectedVersion:version),
            mutation:.save(fields:.init(title:"Retained raw form"),baseConfirmedRevision:version.confirmedRevision)))
        #expect(try await f.repository.record(assetID:f.id)?.manualDraft?.fields.title == "Retained raw form")
        _ = try await f.repository.reconcile(snapshot)
        await metadataError(.protectedPath) { _ = try await f.repository.exportConfirmed(destination:original,protection:protection) }
        #expect(try Data(contentsOf:original) == originalBytes)
        _ = try await f.confirm(.init(title:"Current confirmation"))
        #expect(try await f.repository.record(assetID:f.id)?.confirmed.title == "Current confirmation")
        // A freshly opened actor also has no complete map until recovery binds it.
        let unopenedMap = PhotoMetadataRepository(directory:f.directory)
        await metadataError(.catalogConflict) { _ = try await unopenedMap.exportConfirmed(destination:original,protection:protection) }
    }
    @Test func historicalProtectionStreamsRowsAndStopsOnFirstMatchingSource() async throws {
        let counter = MetadataCounter(); var hooks = PhotoMetadataRepositoryHooks()
        hooks.didReadProtectionRecord = { counter.increment() }
        let directory = MetadataFixture.directory(), repository = PhotoMetadataRepository(directory:directory,hooks:hooks)
        let f = try MetadataFixture(directory:directory,repository:repository)
        // Native historical records are orphaned and not supplied in the caller
        // protection snapshot. Seed in one transaction to avoid O(N²) snapshots.
        try await repository.seedProtectionHistory(source:try f.source(),count:512)
        let protection = MetadataFileProtectionSnapshot(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[])
        await metadataError(.protectedPath) { _ = try await repository.exportConfirmed(destination:f.original,protection:protection) }
        #expect(counter.value == 1)
        #expect(try Data(contentsOf:f.original) == Data("synthetic source".utf8))
        await metadataError(.protectedPath) { _ = try await repository.prepareImport(source:f.original,protection:protection) }
        #expect(counter.value == 2)
        let target = directory.appendingPathComponent("history-backup.json")
        let exported = try await repository.exportConfirmed(destination:target,protection:protection)
        #expect(exported.entryCount == 512)
        // Initial and final pre-publish checks both stream every historical row.
        #expect(counter.value == 2 + 512 * 2)
    }
    @Test func parentDirectoryReplacementCannotPublishThroughStalePinnedFD() async throws {
        let directory = MetadataFixture.directory(), parent = directory.appendingPathComponent("Exports",isDirectory:true)
        let retired = directory.appendingPathComponent("RetiredExports",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let target = parent.appendingPathComponent("backup.json"), before = Data("previous".utf8), replacement = Data("foreign new parent".utf8)
        try before.write(to:target)
        var hooks = PhotoMetadataRepositoryHooks()
        hooks.beforeExportPublish = {
            try FileManager.default.moveItem(at:parent,to:retired)
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            try replacement.write(to:target)
        }
        let repository = PhotoMetadataRepository(directory:directory,hooks:hooks), f = try MetadataFixture(directory:directory,repository:repository)
        try await f.bind(); _ = try await f.confirm(.init(title:"Saved"))
        await metadataError(.protectedPath) { _ = try await repository.exportConfirmed(destination:target,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[])) }
        #expect(try Data(contentsOf:target) == replacement)
        #expect(try Data(contentsOf:retired.appendingPathComponent("backup.json")) == before)
    }
    @Test func replacedStageLeafIsNeitherPublishedNorDeletedAsOwnedCleanup() async throws {
        let directory = MetadataFixture.directory(), foreign = Data("foreign replacement stage".utf8)
        let replacementPath = MetadataStagePath()
        var hooks = PhotoMetadataRepositoryHooks()
        hooks.beforeExportPublish = {
            let stage = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasPrefix(".photo-metadata-export-") }!
            try FileManager.default.moveItem(at:stage,to:directory.appendingPathComponent("retained-owned-stage"))
            try foreign.write(to:stage); replacementPath.value = stage
        }
        let repository = PhotoMetadataRepository(directory:directory,hooks:hooks), f = try MetadataFixture(directory:directory,repository:repository)
        try await f.bind(); _ = try await f.confirm(.init(title:"Saved"))
        let target = directory.appendingPathComponent("backup.json"), before = Data("previous".utf8); try before.write(to:target)
        await metadataError(.protectedPath) { _ = try await repository.exportConfirmed(destination:target,protection:.init(originalURLs:[],managedFileURLs:[],managedDirectoryURLs:[])) }
        #expect(try Data(contentsOf:target) == before)
        #expect(try Data(contentsOf:replacementPath.value!) == foreign)
    }

}
func metadataEntry(id:String,title:String,tags:[String] = []) -> MetadataJSONEntry {
    .init(assetID:id,fields:.init(title:title,tags:tags),originalRevision:1,confirmedAt:Date(),provenance:.init(tags:tags.map { .init(value:$0,origin:.manual) }))
}
func metadataImportFile(directory:URL,entries:[MetadataJSONEntry]) throws -> URL {
    let url = directory.appendingPathComponent("import-\(UUID()).json")
    try PhotoMetadataPortableJSON.encoder().encode(MetadataJSONDocument(exportID:UUID(),exportedAt:Date(),entries:entries)).write(to:url)
    return url
}

final class MetadataStagePath: @unchecked Sendable {
    private let lock = NSLock(); private var stored:URL?
    var value:URL? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

private extension PhotoMetadataRepository {
    func expireImportReviewForTest() {
        retainedReview?.touchedAt = ContinuousClock.now.advanced(by:.seconds(-PhotoMetadataLimits.maximumImportReviewIdleSeconds-1))
    }
    func seedProtectionHistory(source:MetadataSourceReference,count:Int) throws {
        let db = try connection()
        try sql.transaction(db,beforeCommit:{}) {
            for ordinal in 0..<count {
                var row = PhotoMetadataRow(assetID:String(format:"historical-%05d",ordinal))
                try row.advance(confirmed:true)
                row.confirmed = .init(title:"Historical \(ordinal)")
                row.confirmedAt = Date(timeIntervalSinceReferenceDate:1)
                row.confirmedSource = source; row.associationSource = source
                try saveRow(row,on:db)
            }
            try bumpSearch(db)
        }
    }
}
