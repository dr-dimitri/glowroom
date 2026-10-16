import Foundation
import Darwin
import Testing
@testable import PicEditCore

@Suite("Real legacy EditDatabase WAL migration preserves committed pages")
struct EditingLegacyWALMigrationTests {
    @Test func firstRealLegacyOpenCommitAndProcessExitMigrateHeaderZeroWAL() async throws {
        guard ProcessInfo.processInfo.environment[legacyFirstOpenChildDirectory] == nil else {return}
        let f = try EditingFixture()
        try runFirstOpenWALChild(f.directory)
        let family = try legacyFamily(f.repository.fileURL),main = try #require(family["edits.sqlite"])
        try #require(main.count >= 100)
        #expect(main[18] == 2 && main[19] == 2)
        #expect(main[60..<64].allSatisfy{$0 == 0})
        #expect(main[68..<72].allSatisfy{$0 == 0})
        #expect(try #require(family["edits.sqlite-wal"]).count > 32)
        let migrated = try await f.repository.loadState()
        #expect(migrated.byAsset["first-open"]?.snapshot.settings.exposure == 1.875)
        #expect(migrated.byAsset["first-open"]?.version.revision == 31)
        try expectLegacyArchive(f.directory,contains:family)
    }
    @Test func foreignAndFutureFirstOpenLogicalWALFamiliesRemainByteIdentical() async throws {
        guard ProcessInfo.processInfo.environment[legacyFirstOpenChildDirectory] == nil else {return}
        for change in ["PRAGMA application_id=42","PRAGMA user_version=99"] {
            let f = try EditingFixture();try runFirstOpenWALChild(f.directory,change:change)
            let family = try legacyFamily(f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("Foreign/future logical WAL must not migrate") }catch{}
            #expect(try legacyFamily(f.repository.fileURL) == family)
            #expect(!FileManager.default.fileExists(atPath:f.directory.appendingPathComponent("EditMigrationArchives").path))
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment[legacyFirstOpenChildDirectory] != nil))
    func firstOpenWALChildOnly() async throws {
        let path = try #require(ProcessInfo.processInfo.environment[legacyFirstOpenChildDirectory])
        let legacy = try EditDatabase(directory:URL(fileURLWithPath:path,isDirectory:true))
        try await legacy.save(EditSettings(exposure:1.875),for:"first-open",revision:31)
        if let change = ProcessInfo.processInfo.environment[legacyFirstOpenChildMutation] {
            try editingSQL(legacy.fileURL,change)
        }
        // This is the REAL old actor, not a second schema implementation. End
        // the process with its live SQLite connection before deinit checkpoints.
        withExtendedLifetime(legacy) {Darwin._exit(0)}
    }
    @Test func orderlyClosedRealLegacyActorRetainsWALHeaderAndMigrates() async throws {
        let f = try EditingFixture();try await createRealLegacyDatabase(f.directory)
        let original = try Data(contentsOf:f.repository.fileURL)
        #expect(original[18] == 2 && original[19] == 2)
        let migrated = try await f.repository.loadState()
        #expect(migrated.byAsset["real"]?.snapshot.settings.exposure == 1.25)
        #expect(migrated.byAsset["real"]?.version.revision == 17)
        #expect(try editingScalar(f.repository.fileURL,"PRAGMA user_version") == 2)
        #expect(try Data(contentsOf:f.repository.fileURL)[18] == 1)
        try expectLegacyArchive(f.directory,contains:["edits.sqlite":original])
    }
    @Test func committedUncheckpointedWALUsesLatestSettingsAndRevisions() async throws {
        let f = try EditingFixture();try await createRealLegacyDatabase(f.directory)
        try legacyWALChild(f.repository.fileURL)
        let family = try legacyFamily(f.repository.fileURL)
        #expect(family["edits.sqlite-wal"]!.count > 32)
        let migrated = try await f.repository.loadState()
        #expect(migrated.byAsset["real"]?.snapshot.settings.exposure == 2.5)
        #expect(migrated.byAsset["real"]?.version.revision == 29)
        try expectLegacyArchive(f.directory,contains:family)
        #expect(!FileManager.default.fileExists(atPath:f.repository.fileURL.path+"-wal"))
        #expect(!FileManager.default.fileExists(atPath:f.repository.fileURL.path+"-shm"))
    }
    @Test func unknownLogicalSchemaInWALNeverMutatesAnyOriginalFamilyByte() async throws {
        let f = try EditingFixture();try await createRealLegacyDatabase(f.directory)
        try legacyWALChild(f.repository.fileURL,extra:"PRAGMA user_version=99")
        let family = try legacyFamily(f.repository.fileURL)
        do {_ = try await f.repository.loadState();Issue.record("Unknown logical WAL schema must fail closed")}catch{}
        #expect(try legacyFamily(f.repository.fileURL) == family)
        #expect(!FileManager.default.fileExists(atPath:f.directory.appendingPathComponent("EditMigrationArchives").path))
    }
    @Test func readOnlyAndAliasedWALFamiliesAreNotCheckpointed() async throws {
        for kind in ["readonly","hardlink","symlink"] {
            let f = try EditingFixture();try await createRealLegacyDatabase(f.directory)
            try legacyWALChild(f.repository.fileURL)
            if kind == "readonly" {#expect(chmod(f.repository.fileURL.path,0o400) == 0)}
            else {
                let wal = URL(fileURLWithPath:f.repository.fileURL.path+"-wal"),retained = f.directory.appendingPathComponent("retain.wal")
                if kind == "hardlink" {try FileManager.default.linkItem(at:wal,to:retained)}
                else {try FileManager.default.moveItem(at:wal,to:retained);try FileManager.default.createSymbolicLink(at:wal,withDestinationURL:retained)}
            }
            let family = try legacyFamily(f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("Unsafe WAL family must be preserved")}catch{}
            #expect(try legacyFamily(f.repository.fileURL) == family)
        }
    }
    @Test func newlyAppearingWALAndJournalAfterArchiveNeverReachWritableSQLite() async throws {
        for suffix in ["-wal","-journal"] {
            let replacement = LegacySHMReplacement()
            let f = try EditingFixture(hooks:.init(legacyMigration:{if $0 == .archived {try replacement.replace()}}))
            try await createRealLegacyDatabase(f.directory)
            let unexpected = URL(fileURLWithPath:f.repository.fileURL.path+suffix)
            if FileManager.default.fileExists(atPath:unexpected.path) {try FileManager.default.removeItem(at:unexpected)}
            replacement.url = unexpected
            let family = try legacyFamily(f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("New unarchived sidecars must reject before SQLite open")}
            catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
            for (name,bytes) in family {#expect(try Data(contentsOf:f.directory.appendingPathComponent(name)) == bytes)}
            #expect(try Data(contentsOf:unexpected) == replacement.bytes)
            try expectLegacyArchive(f.directory,contains:family)
        }
    }
    @Test func unknownAndReplacedSharedMemoryAreRetainedInsteadOfDeleted() async throws {
        for phase in [EditingLegacyMigrationCheckpoint.archived,.beforeSharedMemoryCleanup] {
            let replacement = LegacySHMReplacement()
            let f = try EditingFixture(hooks:.init(legacyMigration:{if $0 == phase {try replacement.replace()}}))
            try await createRealLegacyDatabase(f.directory)
            let shm = URL(fileURLWithPath:f.repository.fileURL.path+"-shm")
            // First case proves an initially absent entry cannot be adopted by
            // a post-archive scan. The second swaps our actual creation inode.
            if FileManager.default.fileExists(atPath:shm.path) {try FileManager.default.removeItem(at:shm)}
            replacement.url = shm
            let family = try legacyFamily(f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("Unowned/replaced SHM must reject cleanup")}
            catch {#expect(error as? EditingRepositoryError == .recoveryRequired)}
            #expect(try Data(contentsOf:shm) == replacement.bytes)
            try expectLegacyArchive(f.directory,contains:family)
            if phase == .archived {#expect(try Data(contentsOf:f.repository.fileURL) == family["edits.sqlite"])}
        }
    }
    @Test func failuresAroundArchiveCheckpointAndCommitRetainLatestDataAndExactArchive() async throws {
        for phase in [EditingLegacyMigrationCheckpoint.archived,.checkpointed,.beforeCommit] {
            let hooks = EditingRepositoryHooks(legacyMigration:{if $0 == phase {throw EditingRepositoryError.storageFailure}})
            let f = try EditingFixture(hooks:hooks);try await createRealLegacyDatabase(f.directory);try legacyWALChild(f.repository.fileURL)
            let family = try legacyFamily(f.repository.fileURL)
            do {_ = try await f.repository.loadState();Issue.record("Injected migration failure must be observed")}catch{}
            try expectLegacyArchive(f.directory,contains:family)
            if phase == .archived {#expect(try legacyFamily(f.repository.fileURL) == family)}
            let restarted = f.reopen(),state = try await restarted.loadState()
            #expect(state.byAsset["real"]?.snapshot.settings.exposure == 2.5)
            #expect(state.byAsset["real"]?.version.revision == 29)
        }
    }
}
private let legacyFirstOpenChildDirectory = "PICEDIT_TEST_LEGACY_FIRST_OPEN_WAL_DIRECTORY"
private let legacyFirstOpenChildMutation = "PICEDIT_TEST_LEGACY_FIRST_OPEN_WAL_MUTATION"
private func runFirstOpenWALChild(_ directory:URL,change:String? = nil) throws {
    let invocation = CommandLine.arguments
    let child = Process();child.executableURL = URL(fileURLWithPath:invocation[0])
    // Native SwiftPM loads the Mach-O test bundle through this helper. Preserve
    // its exact already running bundle argument; older direct runners need none.
    var arguments:[String] = []
    if let index = invocation.firstIndex(of:"--test-bundle-path"),index+1 < invocation.count {
        arguments = ["--test-bundle-path",invocation[index+1]]
    }
    child.arguments = arguments+["--testing-library","swift-testing","--filter","firstOpenWALChildOnly"]
    var environment = ProcessInfo.processInfo.environment;environment[legacyFirstOpenChildDirectory] = directory.path
    environment[legacyFirstOpenChildMutation] = change
    child.environment = environment;child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
    try child.run();child.waitUntilExit();#expect(child.terminationStatus == 0)
}

private func createRealLegacyDatabase(_ directory:URL) async throws {
    // Its last SQLite actor reference ends at this function boundary. This is
    // the production schema-1 implementation, including journal_mode=WAL.
    let legacy = try EditDatabase(directory:directory)
    try await legacy.save(EditSettings(exposure:1.25),for:"real",revision:17)
    #expect(try await legacy.loadAll()["real"]?.exposure == 1.25)
}
private func legacyWALChild(_ url:URL,extra:String = "") throws {
    let data = try JSONEncoder().encode(EditSettings(exposure:2.5)).base64EncodedString()
    let child = Process();child.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
    child.arguments = ["-c","import sqlite3,os,sys,base64;c=sqlite3.connect(sys.argv[1]);c.execute('PRAGMA journal_mode=WAL');c.execute('PRAGMA wal_autocheckpoint=0');c.execute('BEGIN IMMEDIATE');c.execute('UPDATE edit_revisions SET revision=29 WHERE asset_id=?',('real',));c.execute('UPDATE adjustments SET settings=? WHERE asset_id=?',(sqlite3.Binary(base64.b64decode(sys.argv[2])),'real'));c.commit();c.execute(sys.argv[3]) if sys.argv[3] else None;os._exit(0)",url.path,data,extra]
    let errors = Pipe();child.standardError = errors;child.standardOutput = FileHandle.nullDevice
    try child.run();child.waitUntilExit();#expect(child.terminationStatus == 0)
}
private func legacyFamily(_ url:URL) throws -> [String:Data] {
    var result:[String:Data] = [:]
    for suffix in ["","-wal","-shm"] {let path = URL(fileURLWithPath:url.path+suffix);if FileManager.default.fileExists(atPath:path.path) {result["edits.sqlite"+suffix] = try Data(contentsOf:path)}}
    return result
}
private func expectLegacyArchive(_ directory:URL,contains family:[String:Data]) throws {
    let archives = directory.appendingPathComponent("EditMigrationArchives",isDirectory:true)
    let entries = try FileManager.default.contentsOfDirectory(at:archives,includingPropertiesForKeys:nil)
    let matches = try entries.contains {entry in
        try family.allSatisfy {name,data in try Data(contentsOf:entry.appendingPathComponent(name)) == data}
    }
    #expect(matches)
}

private final class LegacySHMReplacement:@unchecked Sendable {
    private let lock = NSLock();private var target:URL?
    let bytes = Data("foreign shared-memory entry must survive".utf8)
    var url:URL? {get{lock.withLock{target}}set{lock.withLock{target = newValue}}}
    func replace() throws {if let url {try bytes.write(to:url,options:.atomic)}}
}
