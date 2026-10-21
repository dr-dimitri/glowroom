import Foundation
import Darwin
import CSQLite
import Testing
@testable import GlowroomCore

@Suite("Owned metadata SQLite preserves untrusted bytes")
struct PhotoMetadataStorageTests {
    @Test func existingForeignAndUnknownVersionRemainByteExact() async throws {
        for version in [Int32(0),Int32(PhotoMetadataSQLite.schemaVersion+1)] {
            let directory = MetadataFixture.directory(); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let url = directory.appendingPathComponent("photo-metadata.sqlite")
            try metadataSQL(url,"CREATE TABLE foreign_data(value TEXT);INSERT INTO foreign_data VALUES('keep');PRAGMA application_id=\(version == 0 ? 42 : PhotoMetadataSQLite.applicationID);PRAGMA user_version=\(version)")
            let bytes = try Data(contentsOf:url), repository = PhotoMetadataRepository(directory:directory)
            await metadataError(version == 0 ? .corruptStore : .unsupportedVersion) { _ = try await repository.record(assetID:"any") }
            #expect(try Data(contentsOf:url) == bytes)
        }
    }
    @Test func emptyExistingFileAndFinalAliasesNeverBecomeStores() async throws {
        for kind in ["empty","symlink","hardlink"] {
            let directory = MetadataFixture.directory(); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let url = directory.appendingPathComponent("photo-metadata.sqlite"), original = directory.appendingPathComponent("keep-original")
            let bytes = Data("foreign bytes must survive".utf8); try bytes.write(to:original)
            if kind == "empty" { try Data().write(to:url) }
            if kind == "symlink" { #expect(symlink(original.path,url.path) == 0) }
            if kind == "hardlink" { #expect(link(original.path,url.path) == 0) }
            let repository = PhotoMetadataRepository(directory:directory)
            await metadataError(.corruptStore) { _ = try await repository.record(assetID:"any") }
            #expect(try Data(contentsOf:original) == bytes)
            if kind == "empty" { #expect(try Data(contentsOf:url).isEmpty) }
        }
    }
    @Test func readonlyExistingStorePreservesBytesAndMode() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Keep"))
        let path = f.repository.fileURL.path, before = try Data(contentsOf:f.repository.fileURL)
        #expect(chmod(path,0o400) == 0); defer { _ = chmod(path,0o600) }
        let restarted = PhotoMetadataRepository(directory:f.directory)
        await metadataError(.readOnly) { _ = try await restarted.record(assetID:f.id) }
        var mode = stat(); #expect(lstat(path,&mode) == 0); #expect(mode.st_mode & 0o777 == 0o400)
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
    }
    @Test func unknownTriggerOnLiveHandleIsRejectedBeforeNextWrite() async throws {
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Before"))
        try metadataSQL(f.repository.fileURL,"CREATE TRIGGER unknown_trigger AFTER INSERT ON metadata_receipts BEGIN UPDATE metadata_state SET search_generation=999;END")
        let before = try Data(contentsOf:f.repository.fileURL)
        await metadataError(.corruptStore) { _ = try await f.confirm(.init(title:"After")) }
        #expect(try Data(contentsOf:f.repository.fileURL) == before)
    }
    @Test func corruptRecordAndMissingSchemaAreNeverReinitialized() async throws {
        for mutation in ["UPDATE metadata_records SET record=x'00'","DROP TABLE metadata_receipts"] {
            let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Before"))
            try metadataSQL(f.repository.fileURL,mutation)
            let bytes = try Data(contentsOf:f.repository.fileURL), restarted = PhotoMetadataRepository(directory:f.directory)
            await metadataError(.corruptStore) { _ = try await restarted.record(assetID:f.id) }
            #expect(try Data(contentsOf:f.repository.fileURL) == bytes)
        }
    }
    @Test func nativeJournalCrashHasExplicitReadonlyRecoveryWithoutDeletingSidecars() async throws {
        guard FileManager.default.isExecutableFile(atPath:"/usr/bin/python3") else { return }
        let f = try MetadataFixture(); try await f.bind(); _ = try await f.confirm(.init(title:"Before crash"))
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = ["-c","import sqlite3,os,sys;c=sqlite3.connect(sys.argv[1]);c.execute('PRAGMA cache_size=1');c.execute('BEGIN IMMEDIATE');c.execute('UPDATE metadata_state SET search_generation=search_generation+1');c.execute(\"INSERT INTO metadata_receipts VALUES('crash','not-a-valid-digest',zeroblob(1048576))\");os._exit(0)",f.repository.fileURL.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        let journal = URL(fileURLWithPath:f.repository.fileURL.path+"-journal")
        #expect(FileManager.default.fileExists(atPath:journal.path))
        let databaseBytes = try Data(contentsOf:f.repository.fileURL), journalBytes = try Data(contentsOf:journal)
        #expect(!journalBytes.isEmpty)
        let restart = PhotoMetadataRepository(directory:f.directory)
        await metadataError(.recoveryRequired) { _ = try await restart.record(assetID:f.id) }
        #expect(try Data(contentsOf:f.repository.fileURL) == databaseBytes)
        #expect(try Data(contentsOf:journal) == journalBytes)
    }
}
func metadataSQL(_ url:URL,_ sql:String) throws {
    var db:OpaquePointer?
    guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK, let db else { throw PhotoMetadataError.storageFailure }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw PhotoMetadataError.storageFailure }
}
