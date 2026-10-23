import Foundation
import Darwin
import CSQLite
import Testing
@testable import GlowroomCore

@Suite("Schema 2 editing source persistence and full CAS")
struct EditingRepositoryTests {
    @Test func freshIdentityRejectsPreRenameDatabaseWithoutChangingIt() async throws {
        let f = try EditingFixture()
        _ = try await f.repository.loadState()
        #expect(try editingScalar(f.repository.fileURL, "PRAGMA application_id") == 0x474c4f57)
        // Historical PICE signature: the development rename has no import path.
        try editingSQL(f.repository.fileURL, "PRAGMA application_id=1346978629")
        let before = try Data(contentsOf: f.repository.fileURL)
        await #expect(throws: EditingRepositoryError.invalidDatabase) {
            _ = try await f.reopen().loadState()
        }
        #expect(try Data(contentsOf: f.repository.fileURL) == before)
    }

    @Test func defaultCatalogUsesIndependentApplicationSupportRoot() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(CatalogRepository().directory == support.appendingPathComponent("Glowroom", isDirectory: true))
        #expect(EditingSQLite.applicationID == 0x474c4f57)
        #expect(PhotoMetadataSQLite.applicationID == 0x474c4d44)
    }

    @Test func lazyInitAndStableIdentityAcrossRestart() async throws {
        let f = try EditingFixture(createDirectory:false)
        #expect(!FileManager.default.fileExists(atPath:f.directory.path))
        let empty = try await f.repository.loadState()
        #expect(empty.byAsset.isEmpty && empty.tombstones.isEmpty)
        let first = try await f.repository.participantStoreIdentity()
        let restarted = f.reopen()
        #expect(try await restarted.participantStoreIdentity() == first)
        #expect(try await restarted.loadState().storeEpoch == empty.storeEpoch)
        #expect(try await restarted.inspectParticipantIdentity() == first)
    }
    @Test func legacyMigrationPreservesSettingsRevisionsAndTombstones() async throws {
        let f = try EditingFixture();var settings = EditSettings.neutral;settings.exposure = 1.25;settings.saturation = -24
        try editingLegacy(f.directory,settings:settings)
        let migrated = try await f.repository.loadState()
        #expect(migrated.byAsset["photo"]?.snapshot == (try EditingSnapshot(settings:settings)))
        #expect(migrated.byAsset["photo"]?.version.revision == 17)
        #expect(migrated.tombstones["deleted"] == 23)
        let epoch = migrated.storeEpoch
        #expect(try await f.reopen().loadState().storeEpoch == epoch)
        #expect(try editingScalar(f.repository.fileURL,"PRAGMA user_version") == 2)
        #expect(try editingScalar(f.repository.fileURL,"SELECT count(*) FROM sqlite_schema WHERE name='adjustments'") == 0)
    }
    @Test func unknownSchemaAndForeignAndCorruptBytesAreNeverMutated() async throws {
        for kind in ["unknown","foreign","corrupt"] {
            let f = try EditingFixture()
            if kind == "corrupt" {try Data("not SQLite".utf8).write(to:f.repository.fileURL)}
            else {
                try editingLegacy(f.directory)
                try editingSQL(f.repository.fileURL,kind == "unknown" ? "PRAGMA user_version=99" : "PRAGMA application_id=123")
            }
            let bytes = try Data(contentsOf:f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("Expected \(kind) rejection")}catch{}
            #expect(try Data(contentsOf:f.repository.fileURL) == bytes)
            #expect(!FileManager.default.fileExists(atPath:f.repository.fileURL.path+"-journal"))
        }
    }
    @Test func finalSymlinkHardlinkReadOnlyAndHotJournalArePreserved() async throws {
        for kind in ["symlink","hardlink","readonly","journal"] {
            let f = try EditingFixture();let source = f.directory.appendingPathComponent("external.sqlite")
            try editingLegacy(f.directory)
            if kind == "symlink" || kind == "hardlink" {
                try FileManager.default.moveItem(at:f.repository.fileURL,to:source)
                if kind == "symlink" {try FileManager.default.createSymbolicLink(at:f.repository.fileURL,withDestinationURL:source)}
                else {#expect(link(source.path,f.repository.fileURL.path) == 0)}
            }
            if kind == "readonly" {#expect(chmod(f.repository.fileURL.path,0o400) == 0)}
            if kind == "journal" {try Data([1,2,3,4]).write(to:URL(fileURLWithPath:f.repository.fileURL.path+"-journal"))}
            let data = try Data(contentsOf:f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("Expected \(kind) rejection")}catch {
                if kind == "readonly" {#expect(error as? EditingRepositoryError == .readOnly)}
                if kind == "journal" {#expect(error as? EditingRepositoryError == .recoveryRequired)}
            }
            #expect(try Data(contentsOf:f.repository.fileURL) == data)
            if kind == "readonly" {var s = stat();let fd = open(f.repository.fileURL.path,O_RDONLY);defer{close(fd)};#expect(fstat(fd,&s) == 0);#expect(s.st_mode & 0o777 == 0o400)}
            if kind == "journal" {#expect(try Data(contentsOf:URL(fileURLWithPath:f.repository.fileURL.path+"-journal")) == Data([1,2,3,4]))}
        }
    }
    @Test func fullSnapshotCASRejectsStaleAndCompetingWriters() async throws {
        let f = try EditingFixture(),initial = try await f.repository.loadState()
        let expected = try EditingExpectedState(storeEpoch:initial.storeEpoch,revision:nil,snapshot:nil)
        let a = try EditingSnapshot(settings:EditSettings(exposure:1)),b = try EditingSnapshot(settings:EditSettings(exposure:2))
        let second = f.reopen()
        let wins = try await withThrowingTaskGroup(of:Bool.self) {group in
            for (repo,snapshot) in [(f.repository,a),(second,b)] {group.addTask {
                do {_ = try await repo.saveSnapshot(snapshot,for:"asset",expected:expected,revision:1);return true}
                catch ArtifactContractError.staleSnapshot {return false}
            }}
            var results:[Bool] = [];for try await win in group {results.append(win)};return results
        }
        #expect(wins.filter{$0}.count == 1)
        let stored = try #require(try await f.repository.loadState().byAsset["asset"])
        let wrong = try EditingExpectedState(storeEpoch:initial.storeEpoch,revision:stored.version.revision,snapshot:stored.snapshot == a ? b : a)
        await editingError(.staleSnapshot) {_ = try await f.repository.saveSnapshot(a,for:"asset",expected:wrong,revision:2)}
        let replay = try await f.repository.saveSnapshot(stored.snapshot,for:"asset",expected:expected,revision:1)
        #expect(replay == stored)
    }
    @Test func acceptedGeneratedIsFlatNeutralOneReceiptAndPersistentVariants() async throws {
        let f = try EditingFixture();let parent = try await f.save(exposure:1.5)
        let draft = try await f.draft(parent:parent)
        let request = try GenerationCommitRequest(commitID:.init(),assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
        let accepted = try await f.repository.commitGenerated(request)
        #expect(accepted.stored.snapshot.settings == .newEditingSettings)
        #expect(accepted.stored.snapshot.settings.isNeutral)
        #expect(accepted.stored.snapshot.source == .artifact(draft.artifact.id))
        #expect(try await f.repository.commitGenerated(request).stored == accepted.stored)
        #expect(try await f.repository.variants(for:f.id).count == 2)
        #expect(try await f.reopen().committed(request.commitID)?.stored == accepted.stored)
        let conflict = try GenerationCommitRequest(commitID:request.commitID,assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:request.expectedParentSource,nextRevision:3)
        await editingError(.conflictingCommit) {_ = try await f.repository.commitGenerated(conflict)}
        #expect(try await f.repository.loadState().byAsset[f.id] == accepted.stored)
    }
    @Test func lateGenerationAndSameSizeRestoredMtimeOverwriteCannotCommit() async throws {
        let f = try EditingFixture();let parent = try await f.save(exposure:0.75),draft = try await f.draft(parent:parent)
        let request = try GenerationCommitRequest(commitID:.init(),assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
        var newer = parent.snapshot.settings;newer.contrast = 10
        let latest = try await f.repository.saveSnapshot(EditingSnapshot(settings:newer),for:f.id,expected:.init(parent),revision:2)
        await editingError(.staleSnapshot) {_ = try await f.repository.commitGenerated(request)}
        #expect(try await f.repository.loadState().byAsset[f.id] == latest)
        let f2 = try EditingFixture();let p2 = try await f2.save(exposure:0),d2 = try await f2.draft(parent:p2)
        let r2 = try GenerationCommitRequest(commitID:.init(),assetID:f2.id,draft:d2,expected:.init(p2),expectedParentSource:d2.artifact.provenance.parentSource,nextRevision:2)
        let attributes = try FileManager.default.attributesOfItem(atPath:f2.original.path)
        try Data([9,8,7,6]).write(to:f2.original)
        try FileManager.default.setAttributes([.modificationDate:attributes[.modificationDate]!],ofItemAtPath:f2.original.path)
        await editingError(.sourceChanged) {_ = try await f2.repository.commitGenerated(r2)}
        #expect(try await f2.repository.loadState().byAsset[f2.id] == p2)
    }
    @Test func publicationAndSQLFailuresLeavePriorStateAndRepeatSafely() async throws {
        let fail = EditingFailureSwitch(),f = try EditingFixture(hooks:.init(beforeCommit:{try fail.check()},afterPublication:{}))
        let parent = try await f.save(exposure:0.5),draft = try await f.draft(parent:parent)
        let request = try GenerationCommitRequest(commitID:.init(),assetID:f.id,draft:draft,expected:.init(parent),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
        fail.enabled = true
        do {_ = try await f.repository.commitGenerated(request);Issue.record("Expected SQL rollback")}catch{}
        #expect(try await f.repository.loadState().byAsset[f.id] == parent)
        #expect(try await f.repository.committed(request.commitID) == nil)
        #expect(await f.artifacts.wasPublished(draft.artifact.id))
        fail.enabled = false
        #expect(try await f.repository.commitGenerated(request).stored.snapshot.source == .artifact(draft.artifact.id))
    }
    @Test func backupRestoreRotatesEpochAndKeepsDurableStoreIdentityAndSafetyPackage() async throws {
        let f = try EditingFixture();let first = try await f.save(exposure:1)
        let identity = try await f.repository.participantStoreIdentity()
        let url = try await f.repository.createBackup(automatic:false)
        let second = try await f.repository.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:2)),for:f.id,expected:.init(first),revision:8)
        let restored = try await f.repository.restoreBackup(from:url)
        #expect(restored.storeEpoch != first.version.storeEpoch)
        #expect(restored.byAsset[f.id]?.snapshot == first.snapshot)
        #expect(restored.byAsset[f.id]!.version.revision > second.version.revision)
        #expect(try await f.repository.participantStoreIdentity() == identity)
        #expect(await f.packages.kinds == [.manual,.safety])
        await editingError(.staleEpoch) {_ = try await f.repository.saveSnapshot(first.snapshot,for:f.id,expected:.init(second),revision:9)}
    }
    @Test func closedCopyUsesOnlySnapshotClosureAndOriginalPinnedHandle() async throws {
        let f = try EditingFixture();_ = try await f.save(exposure:0)
        let copy = try await f.repository.copyForTest(directory:f.directory.appendingPathComponent("Snapshots"))
        let handle = try copy.handle()
        let checked = try await EditingClosedSQLValidator.validate(privateStagedSQLURL:copy.url,pinnedOwnership:handle)
        #expect(checked.database === handle)
        #expect(checked.referencedArtifacts.isEmpty)
        var bytes = try Data(contentsOf:copy.url);bytes[bytes.count-1] ^= 1;try bytes.write(to:copy.url)
        do {_ = try await EditingClosedSQLValidator.validate(privateStagedSQLURL:copy.url,pinnedOwnership:handle);Issue.record("Expected corrupted copy rejection")}catch{}
    }
    @Test func externalTriggerOnLiveHandleIsRejectedBeforeAnyWrite() async throws {
        let f = try EditingFixture();let initial = try await f.repository.loadState()
        try editingSQL(f.repository.fileURL,"CREATE TABLE foreign_data(value TEXT);CREATE TRIGGER unexpected AFTER INSERT ON edit_revisions BEGIN INSERT INTO foreign_data VALUES('bad');END")
        let before = try Data(contentsOf:f.repository.fileURL)
        do {_ = try await f.repository.saveSnapshot(EditingSnapshot(),for:"asset",expected:.init(storeEpoch:initial.storeEpoch,revision:nil,snapshot:nil),revision:1);Issue.record("Expected schema rejection")}catch{}
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
        #expect(try editingScalar(f.repository.fileURL,"SELECT count(*) FROM foreign_data") == 0)
    }
    @Test func canceledQueuedAdmissionDoesNotWriteAndUnavailableArtifactNeverBecomesOriginal() async throws {
        let f = try EditingFixture(),state = try await f.repository.loadState()
        let task = Task {try Task.checkCancellation();return try await f.repository.saveSnapshot(EditingSnapshot(source:.artifact(.init())),for:"asset",expected:.init(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil),revision:1)}
        task.cancel();do {_ = try await task.value;Issue.record("Expected cancellation")}catch{}
        #expect(try await f.repository.loadState().byAsset.isEmpty)
        await editingError(.missingArtifact) {_ = try await f.repository.saveSnapshot(EditingSnapshot(source:.artifact(.init())),for:"asset",expected:.init(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil),revision:1)}
        #expect(try await f.repository.loadState().byAsset.isEmpty)
    }
}

extension EditingRepository {func copyForTest(directory:URL) throws -> EditingSQLCopy {try EditingSQLCopy.online(connection(),directory:directory)}}

final class EditingFixture:@unchecked Sendable {
    let directory:URL,original:URL
    var id:String {original.standardizedFileURL.path}
    let artifacts = EditingFakeArtifacts(),packages = EditingFakePackages(),gate = CatalogLifecycleGate(requiresRecovery:false)
    let repository:EditingRepository
    init(createDirectory:Bool = true,hooks:EditingRepositoryHooks = .init()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("editing-v2-\(UUID())",isDirectory:true)
        original = directory.appendingPathComponent("original.bin")
        if createDirectory {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try Data([1,2,3,4]).write(to:original)}
        repository = EditingRepository(directory:directory,artifacts:artifacts,packages:packages,gate:gate,hooks:hooks)
    }
    deinit {try? FileManager.default.removeItem(at:directory)}
    func reopen() -> EditingRepository {.init(directory:directory,artifacts:artifacts,packages:packages,gate:gate)}
    func save(exposure:Double) async throws -> StoredEditingState {
        let state = try await repository.loadState()
        return try await repository.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:exposure)),for:id,expected:.init(storeEpoch:state.storeEpoch,revision:nil,snapshot:nil),revision:1)
    }
    func draft(parent:StoredEditingState) async throws -> ArtifactDraft {
        let source = try AssetRemapVerifier.capture(original,referenceDate:Date(timeIntervalSinceReferenceDate:750_000_000.0.nextUp))
        let digest = try ArtifactDigest(sha256:String(repeating:"a",count:64)),size = try ArtifactPixelSize(width:2,height:2)
        let format = ArtifactRasterFormat(size:size,bitDepth:.eight,channels:.rgba,profile:.displayP3,iccSHA256:digest)
        let p = try GenerationProvenance(parentSource:.original(source),parentSnapshot:parent.snapshot,renderedInput:.init(format:format,canonicalPixelSHA256:digest,pipelineVersion:1),placement:.init(inputSize:size,outputSize:size,inputOriginX:0,inputOriginY:0),pipelineVersion:1,parameterVersion:1,parameters:.init(values:[]),provider:.init(providerID:"test.fake"),prompt:"synthetic",createdAt:source.modifiedAt,execution:.local)
        return try await artifacts.fakeDraft(provenance:p,format:format)
    }
}

actor EditingFakeArtifacts:GeneratedArtifactStoring {
    nonisolated let storeID = ArtifactStoreID()
    var values:[GeneratedArtifactID:GeneratedArtifact] = [:],published = Set<GeneratedArtifactID>()
    private var nextDescriptorHook:(@Sendable () throws -> Void)?
    private var nextMaterializeHook:(@Sendable () throws -> Void)?
    func afterNextDescriptor(_ hook:@escaping @Sendable () throws -> Void){nextDescriptorHook = hook}
    func afterNextMaterialize(_ hook:@escaping @Sendable () throws -> Void){nextMaterializeHook = hook}
    func fakeDraft(provenance:GenerationProvenance,format:ArtifactRasterFormat) throws -> ArtifactDraft {
        let id = GeneratedArtifactID(),file = try ArtifactFileDescriptor(sha256:.init(sha256:String(repeating:"b",count:64)),bytes:32),raster = RasterDescriptor(format:format,file:file)
        let body = GeneratedArtifactManifest(id:id,raster:raster,provenance:provenance)
        let artifact = try GeneratedArtifact(id:id,raster:raster,provenance:provenance,manifestSHA256:ArtifactJSONCodec.digest(body))
        values[id] = artifact;return .init(id:.init(),artifact:artifact,ownerID:storeID,nonce:UUID(),ownership:lease([id],.draft))
    }
    func stageRaster(_ input:ArtifactRasterInput,provenance:GenerationProvenance,masks:[ArtifactMaskInput]) throws -> ArtifactDraft {throw ArtifactContractError.unsupportedFormat}
    func publish(_ draft:ArtifactDraft,commitID:EditingCommitID) throws -> PublishedArtifact {
        guard draft.ownerID == storeID,values[draft.artifact.id] == draft.artifact else {throw ArtifactContractError.invalidCapability}
        published.insert(draft.artifact.id);return .init(artifact:draft.artifact,commitID:commitID,ownerID:storeID,nonce:UUID(),ownership:lease([draft.artifact.id],.acceptedCommit))
    }
    func validatePublication(_ p:PublishedArtifact) throws {guard p.ownerID == storeID,published.contains(p.artifact.id) else {throw ArtifactContractError.invalidCapability}}
    func descriptor(_ id:GeneratedArtifactID) throws -> GeneratedArtifact {
        guard let a = values[id],published.contains(id) else {throw ArtifactContractError.missingArtifact}
        if let hook = nextDescriptorHook {nextDescriptorHook = nil;try hook()};return a
    }
    func acquireLease(ids:Set<GeneratedArtifactID>,purpose:ArtifactLeasePurpose) -> ArtifactLease {lease(ids,purpose)}
    func lease(_ ids:Set<GeneratedArtifactID>,_ purpose:ArtifactLeasePurpose) -> ArtifactLease {.init(storeID:storeID,artifactIDs:ids,purpose:purpose,nonce:UUID(),releaseOwnership:{})}
    func openVerifiedRaster(_ id:GeneratedArtifactID) throws -> ArtifactReadHandle {let a = try descriptor(id);return .init(artifact:a,file:.init(bytes:32,sha256:a.raster.file.sha256,ownership:lease([id],.nativeRead),reader:{_,_ in Data(repeating:0,count:32)}))}
    func openVerifiedFile(_ id:GeneratedArtifactID,role:ArtifactPayloadRole) throws -> ArtifactFileReadHandle {try openVerifiedRaster(id).file}
    func openVerifiedDraft(_ draft:ArtifactDraft) throws -> ArtifactReadHandle {throw ArtifactContractError.unsupportedFormat}
    func materialize(_ backup:ValidatedEditingBackup) throws -> PublishedArtifactSet {
        if let hook = nextMaterializeHook {nextMaterializeHook = nil;try hook()}
        for a in backup.snapshot.referencedArtifacts {values[a.id] = a;published.insert(a.id)}
        return .init(artifacts:backup.snapshot.referencedArtifacts,ownerID:storeID,nonce:UUID(),ownership:lease(Set(backup.snapshot.referencedArtifacts.map(\.id)),.restore))
    }
    func recoverStagingAndReportOrphans(referenced:Set<GeneratedArtifactID>) -> ArtifactRecoveryReport {.init(retainedOrphans:published.subtracting(referenced),removedOwnedStagingCount:0,unrecognizedEntries:[])}
    func wasPublished(_ id:GeneratedArtifactID) -> Bool {published.contains(id)}
}
actor EditingFakePackages:EditingBackupPackageIO {
    var saved:[URL:EditingBackupSource] = [:],kinds:[EditingBackupKind] = []
    var nextWriteGate:EditingBackupLatch?
    var failWrites = false,failPrune = false
    var automaticByDay:[String:URL] = [:]
    func setFailWrites(_ value:Bool){failWrites = value}
    func setFailPrune(_ value:Bool){failPrune = value}
    func reusableAutomaticBackup(in directory:URL,day:String) -> URL? {automaticByDay[day]}
    func pruneAutomaticBackups(in directory:URL,keepingNewest:Int) throws {if failPrune {throw EditingRepositoryError.storageFailure}}
    func blockNextWrite(_ gate:EditingBackupLatch){nextWriteGate = gate}
    func write(_ source:EditingBackupSource,toNew destination:URL,limits:EditingPackageLimits) async throws -> PublishedEditingBackup {
        if failWrites {throw EditingRepositoryError.storageFailure}
        if let gate = nextWriteGate {nextWriteGate = nil;await gate.wait()}
        saved[destination] = source;kinds.append(source.kind)
        if source.kind == .automatic {let parts = destination.lastPathComponent.split(separator:"-");if parts.count >= 4 {automaticByDay[parts[1...3].joined(separator:"-")] = destination}}
        return .init(url:destination,manifest:.init(kind:source.kind,createdAt:Date(),sourceStoreEpoch:source.snapshot.sourceStoreEpoch,database:try! .init(sha256:source.snapshot.database.sha256,bytes:source.snapshot.database.bytes),artifacts:source.snapshot.referencedArtifacts))
    }
    func export(from source:URL,toNew destination:URL,limits:EditingPackageLimits) async throws -> PublishedEditingBackup {
        guard let value = saved[source] else {throw ArtifactContractError.invalidCapability}
        return try await write(value,toNew:destination,limits:limits)
    }
    func validate(from url:URL,limits:EditingPackageLimits) throws -> ValidatedEditingBackup {
        guard let source = saved[url] else {throw ArtifactContractError.invalidValue("fake package")}
        let manifest = EditingBackupManifest(kind:source.kind,createdAt:Date(),sourceStoreEpoch:source.snapshot.sourceStoreEpoch,database:try .init(sha256:source.snapshot.database.sha256,bytes:source.snapshot.database.bytes),artifacts:source.snapshot.referencedArtifacts)
        return .init(manifest:manifest,snapshot:source.snapshot,openArtifactFile:{id,role in try await source.artifactStore.openVerifiedFile(id,role:role)},stagingOwnership:source.lease)
    }
}
final class EditingFailureSwitch:@unchecked Sendable {
    private let lock = NSLock();private var active = false
    var enabled:Bool {get {lock.withLock{active}} set {lock.withLock{active = newValue}}}
    func check() throws {if enabled {throw EditingRepositoryError.storageFailure}}
}
func editingLegacy(_ directory:URL,settings:EditSettings = .neutral) throws {
    let url = directory.appendingPathComponent("edits.sqlite")
    try editingSQL(url,"PRAGMA application_id=\(EditingSQLite.applicationID);PRAGMA user_version=1;\(EditingSQLite.legacySchemas["edit_revisions"]!);\(EditingSQLite.legacySchemas["adjustments"]!);INSERT INTO edit_revisions VALUES('photo',17);INSERT INTO edit_revisions VALUES('deleted',23)")
    var db:OpaquePointer?;#expect(sqlite3_open(url.path,&db) == SQLITE_OK);defer{sqlite3_close(db)}
    try EditingSQLite.statement(try #require(db),"INSERT INTO adjustments VALUES('photo',?,0)") {s in try EditingSQLite.bind(JSONEncoder().encode(settings),1,s);try EditingSQLite.done(s)}
}
func editingSQL(_ url:URL,_ sql:String) throws {var db:OpaquePointer?;guard sqlite3_open(url.path,&db) == SQLITE_OK,let db else {throw EditingRepositoryError.storageFailure};defer{sqlite3_close(db)};try EditingSQLite.exec(db,sql)}
func editingScalar(_ url:URL,_ sql:String) throws -> Int64 {var db:OpaquePointer?;guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil) == SQLITE_OK,let db else {throw EditingRepositoryError.storageFailure};defer{sqlite3_close(db)};return try EditingSQLite.scalar(db,sql)}
func editingError(_ expected:ArtifactContractError,_ action:() async throws->Void) async {do {try await action();Issue.record("Expected \(expected)")}catch{#expect(error as? ArtifactContractError == expected)}}
