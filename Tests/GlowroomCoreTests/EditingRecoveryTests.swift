import Foundation
import Testing
@testable import GlowroomCore

@Suite("Explicit damaged editing recovery keeps raw originals")
struct EditingRecoveryTests {
    @Test func opaqueFamilyRecoveryUsesRootPermitAndRetainsEveryOriginalByte() async throws {
        let f = try EditingFixture();let original = try await f.save(exposure:1.75)
        let backup = try await f.repository.createBackup(automatic:false)
        let corrupt = Data("opaque damaged editing bytes".utf8);try corrupt.write(to:f.repository.fileURL,options:.atomic)
        let journal = Data([9,7,5,3]);try journal.write(to:URL(fileURLWithPath:f.repository.fileURL.path+"-journal"))
        let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:f.repository,gate:f.gate)
        let restored = try await coordinator.recoverEditingDatabase(from:backup)
        #expect(restored.storeEpoch != original.version.storeEpoch)
        #expect(restored.byAsset[f.id]?.snapshot == original.snapshot)
        #expect(try await f.repository.loadState().byAsset == restored.byAsset)
        let archives = try FileManager.default.contentsOfDirectory(at:f.directory.appendingPathComponent("EditingRecoveryArchives"),includingPropertiesForKeys:nil)
        let archive = try #require(archives.first)
        #expect(try Data(contentsOf:archive.appendingPathComponent("edits.sqlite")) == corrupt)
        #expect(try Data(contentsOf:archive.appendingPathComponent("edits.sqlite-journal")) == journal)
        #expect(try Data(contentsOf:archive.appendingPathComponent("original-inodes/edits.sqlite")) == corrupt)
        #expect(try Data(contentsOf:archive.appendingPathComponent("original-inodes/edits.sqlite-journal")) == journal)
        #expect(try Data(contentsOf:f.original) == Data([1,2,3,4]))
    }
    @Test func emptyOpaqueFileCanBeExplicitlyRecoveredButNeverAutomaticallyReinitialized() async throws {
        let f = try EditingFixture();let stored = try await f.save(exposure:1)
        let backup = try await f.repository.createBackup(automatic:false)
        try Data().write(to:f.repository.fileURL,options:.atomic)
        do {_ = try await f.reopen().loadState();Issue.record("Empty existing file must not initialize")}
        catch {#expect(error as? EditingRepositoryError == .invalidDatabase)}
        #expect(try Data(contentsOf:f.repository.fileURL).isEmpty)
        let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:f.repository,gate:f.gate)
        let restored = try await coordinator.recoverEditingDatabase(from:backup)
        #expect(restored.byAsset[f.id]?.snapshot == stored.snapshot)
    }
    @Test func validForeignAndFutureSQLiteAreNeverOpaqueRecoveryFallbacks() async throws {
        for mutation in ["PRAGMA application_id=42","PRAGMA user_version=99"] {
            let f = try EditingFixture();_ = try await f.save(exposure:0.5)
            let backup = try await f.repository.createBackup(automatic:false)
            try editingSQL(f.repository.fileURL,mutation)
            let bytes = try Data(contentsOf:f.repository.fileURL)
            let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:f.repository,gate:f.gate)
            do {_ = try await coordinator.recoverEditingDatabase(from:backup);Issue.record("Foreign/future SQLite must remain at original path")}catch{}
            #expect(try Data(contentsOf:f.repository.fileURL) == bytes)
        }
    }
    @Test func changedNativeFamilyBeforeFinalInstallIsPreservedAndNotOverwritten() async throws {
        let target = EditingRecoverySwap()
        let f = try EditingFixture(hooks:.init(beforeRecoveryInstall:{try target.swap()}))
        _ = try await f.save(exposure:1)
        let backup = try await f.repository.createBackup(automatic:false)
        try Data("damaged before".utf8).write(to:f.repository.fileURL,options:.atomic)
        target.url = f.repository.fileURL
        let coordinator = JointCatalogCoordinator(repository:.init(directory:f.directory),editing:f.repository,gate:f.gate)
        do {_ = try await coordinator.recoverEditingDatabase(from:backup);Issue.record("Raced family must not be replaced")}catch{}
        #expect(try Data(contentsOf:f.repository.fileURL) == Data("external newer bytes".utf8))
        let archives = try FileManager.default.contentsOfDirectory(at:f.directory.appendingPathComponent("EditingRecoveryArchives"),includingPropertiesForKeys:nil)
        #expect(archives.count == 1)
        #expect(try Data(contentsOf:archives[0].appendingPathComponent("edits.sqlite")) == Data("damaged before".utf8))
    }
    @Test func backupPackageCopyDoesNotHoldTheLiveEditingMaintenanceFence() async throws {
        let f = try EditingFixture();let first = try await f.save(exposure:0.5),latch = EditingBackupLatch()
        await f.packages.blockNextWrite(latch)
        let backup = Task{try await f.repository.createBackup(automatic:false)}
        for _ in 0..<20_000 {if await latch.entered {break};await Task.yield()}
        #expect(await latch.entered)
        do {
            let session = try await f.gate.waitForStartup()
            let admitted = try f.gate.registerAcceptedWrite(domain:.editing,session:session)
            let saved = try await f.gate.withAcceptedWrite(admitted) {
                try await f.repository.saveSnapshot(EditingSnapshot(settings:EditSettings(exposure:1.5)),for:f.id,expected:.init(first),revision:2)
            }
            #expect(saved.snapshot.settings.exposure == 1.5)
            await latch.release();_ = try await backup.value
            #expect(try await f.repository.loadState().byAsset[f.id] == saved)
        }catch{await latch.release();_ = try? await backup.value;throw error}
    }
    @Test func generatedParentFingerprintCannotBeAppliedToDifferentOriginalAsset() async throws {
        let a = try EditingFixture(),b = try EditingFixture()
        let expected = try await a.save(exposure:1),other = try await b.save(exposure:1),draft = try await b.draft(parent:other)
        let request = try GenerationCommitRequest(commitID:.init(),assetID:a.id,draft:draft,expected:.init(expected),expectedParentSource:draft.artifact.provenance.parentSource,nextRevision:2)
        await editingError(.sourceChanged){_ = try await a.repository.commitGenerated(request)}
        #expect(try await a.repository.loadState().byAsset[a.id] == expected)
        #expect(await b.artifacts.wasPublished(draft.artifact.id) == false)
    }
}
final class EditingRecoverySwap:@unchecked Sendable {
    private let lock = NSLock();private var value:URL?
    var url:URL?{get{lock.withLock{value}}set{lock.withLock{value = newValue}}}
    func swap() throws {if let url {try Data("external newer bytes".utf8).write(to:url,options:.atomic)}}
}
actor EditingBackupLatch {
    var entered = false,done = false
    var continuation:CheckedContinuation<Void,Never>?
    func wait() async {entered = true;if !done {await withCheckedContinuation{continuation = $0}}}
    func release(){done = true;continuation?.resume();continuation = nil}
}
