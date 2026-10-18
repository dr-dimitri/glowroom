import Foundation
import Darwin
import CSQLite

public enum EditingRepositoryError: LocalizedError, Equatable, Sendable {
    case invalidDatabase, unsupportedVersion(Int), readOnly, recoveryRequired, storageFailure, databaseBusy
    public var errorDescription:String? {
        switch self {
        case .invalidDatabase: return "Die Bearbeitungsdatenbank ist ungültig. Die vorhandenen Dateien bleiben erhalten."
        case .unsupportedVersion(let n): return "Die Bearbeitungsdatenbank verwendet die nicht unterstützte Version \(n)."
        case .readOnly: return "Die Bearbeitungsdatenbank ist schreibgeschützt."
        case .recoveryRequired: return "Die Bearbeitungsdatenbank benötigt eine ausdrückliche Wiederherstellung. Vorhandene Dateien bleiben erhalten."
        case .storageFailure: return "Die Bearbeitungsdaten konnten nicht sicher gespeichert werden."
        case .databaseBusy: return "Die Bearbeitungsdatenbank wird gerade von einem anderen Vorgang verwendet. Bitte nach dessen Abschluss erneut versuchen."
        }
    }
}

/// Only a repository actor or a closed-copy validation scope owns this handle.
/// DELETE journaling keeps each committed database self-contained. A hot journal
/// is preserved and reported, never implicitly replayed into an unknown file.
final class EditingSQLite: @unchecked Sendable {
    static let applicationID:Int32 = 0x50494345
    static let schemas:[String:String] = [
        "editing_state":"CREATE TABLE editing_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), store_id TEXT NOT NULL, store_epoch TEXT NOT NULL)",
        "edit_revisions":"CREATE TABLE edit_revisions (asset_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision >= 0))",
        "editing_snapshots":"CREATE TABLE editing_snapshots(asset_id TEXT PRIMARY KEY NOT NULL REFERENCES edit_revisions(asset_id), snapshot BLOB NOT NULL)",
        "generated_artifacts":"CREATE TABLE generated_artifacts(id TEXT PRIMARY KEY NOT NULL, descriptor BLOB NOT NULL)",
        "editing_variants":"CREATE TABLE editing_variants(id TEXT PRIMARY KEY NOT NULL, asset_id TEXT NOT NULL, snapshot BLOB NOT NULL, created_at REAL NOT NULL)",
        "artifact_commits":"CREATE TABLE artifact_commits(id TEXT PRIMARY KEY NOT NULL, request_sha TEXT NOT NULL, receipt BLOB NOT NULL)",
        "editing_remaps":"CREATE TABLE editing_remaps(id TEXT PRIMARY KEY NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('prepared','databaseCommitted','catalogCommitted','completed','aborted')), journal BLOB NOT NULL)"
    ]
    static let legacySchemas = [
        "edit_revisions":"CREATE TABLE edit_revisions (asset_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision >= 0))",
        "adjustments":"CREATE TABLE adjustments (asset_id TEXT PRIMARY KEY NOT NULL REFERENCES edit_revisions(asset_id), settings BLOB NOT NULL, updated_at REAL NOT NULL)"
    ]
    let url:URL
    private var handle:OpaquePointer?
    private var fd:Int32 = -1
    private var nativeFile:EditingNativeFileReservation?
    let legacyCheckpoint:@Sendable(EditingLegacyMigrationCheckpoint)throws->Void
    let onContention:@Sendable () -> Void
    init(directory:URL,legacyCheckpoint:@escaping @Sendable(EditingLegacyMigrationCheckpoint)throws->Void = {_ in},onContention:@escaping @Sendable () -> Void = {}) {
        url = directory.appendingPathComponent("edits.sqlite",isDirectory:false);self.legacyCheckpoint = legacyCheckpoint;self.onContention = onContention
    }
    deinit {sqlite3_close(handle);nativeFile?.close()}
    func open(validateRows:(OpaquePointer,Int) throws -> Void) throws -> OpaquePointer {
        guard url.isFileURL,!url.path.utf8.contains(0) else { throw EditingRepositoryError.invalidDatabase }
        try EditingRecoveryIntent.requireAbsent(for:url)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let handle {
            let admission = try EditingDatabaseAccess.acquire(fd:fd,url:url,onContention:onContention)
            defer{admission.release()}
            try Self.sidecars(url);try Self.checkFile(fd,url:url,db:handle);try Self.schema(handle,version:2);try Self.writable(fd,db:handle)
            return handle
        }
        guard let pinned = try EditingDatabaseAccess.pin(url,creating:true,onContention:onContention) else {throw EditingRepositoryError.storageFailure}
        let owned = pinned.fd,created = pinned.created,admission = pinned.admission
        var retained = false
        defer { if !retained {
            // A failed initialization can remove only its own unchanged empty
            // inode, never a raced replacement or meaningful original database.
            var s = stat()
            if created,(try? Self.checkFile(owned,url:url)) != nil,fstat(owned,&s) == 0,s.st_size == 0,(try? Self.sidecars(url)) != nil { _ = unlink(url.path) }
        }
            if !retained {pinned.ownership.close()}
            admission.release()
        }
        try Task.checkCancellation();try Self.checkFile(owned,url:url)
        var oldVersion = 2
        if created {try Self.sidecars(url)}
        if !created {
            if try EditingLegacyWALMigration.isLegacyWAL(owned) {
                try EditingLegacyWALMigration.prepare(url,mainFD:owned,validateRows:validateRows,checkpoint:legacyCheckpoint)
            }
            try Self.sidecars(url);try Self.header(owned)
            let ro = try Self.connect(url,readOnly:true); defer { sqlite3_close(ro) }
            try Self.checkFile(owned,url:url,db:ro)
            oldVersion = Int(try Self.scalar(ro,"PRAGMA user_version"))
            try Self.schema(ro,version:oldVersion); try Self.integrity(ro); try validateRows(ro,oldVersion)
        }
        try Self.writable(owned)
        let db = try Self.connect(url,readOnly:false)
        var keep = false; defer { if !keep { sqlite3_close(db) } }
        try Self.checkFile(owned,url:url,db:db); try Self.writable(owned,db:db)
        if created || oldVersion == 1 {
            try Self.exec(db,"PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON;BEGIN IMMEDIATE")
            do {
                if !created { try Self.schema(db,version:1); try validateRows(db,1) }
                for key in Self.schemas.keys.sorted() where created || key != "edit_revisions" { try Self.exec(db,Self.schemas[key]!) }
                try Self.statement(db,"INSERT INTO editing_state(singleton,store_id,store_epoch) VALUES(1,?,?)") { s in
                    try Self.bind(UUID().uuidString.lowercased(),1,s); try Self.bind(UUID().uuidString.lowercased(),2,s); try Self.done(s)
                }
                if !created {
                    try Self.rows(db,"SELECT asset_id,settings FROM adjustments") { s in
                        let id = try Self.text(s,0,maximum:16_384)
                        let settings = try JSONDecoder().decode(EditSettings.self,from:Self.blob(s,1,maximum:EditSettings.maximumEncodedBytes))
                        let snapshot = try EditingSnapshot(settings:settings)
                        try Self.statement(db,"INSERT INTO editing_snapshots(asset_id,snapshot) VALUES(?,?)") { out in
                            try Self.bind(id,1,out); try Self.bind(ArtifactJSONCodec.encode(snapshot),2,out); try Self.done(out)
                        }
                    }
                    try Self.exec(db,"DROP TABLE adjustments")
                }
                try Self.exec(db,"PRAGMA application_id=\(Self.applicationID);PRAGMA user_version=2")
                try Self.schema(db,version:2); try validateRows(db,2)
                if !created {try legacyCheckpoint(.beforeCommit)}
                try Self.exec(db,"COMMIT")
            } catch { try? Self.exec(db,"ROLLBACK"); throw error }
        }
        let pageSize = try Self.scalar(db,"PRAGMA page_size")
        guard pageSize > 0,pageSize <= 65_536 else {throw EditingRepositoryError.invalidDatabase}
        try Self.exec(db,"PRAGMA max_page_count=\(536_870_912/pageSize);PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON;PRAGMA trusted_schema=OFF")
        try Self.schema(db,version:2); try Self.integrity(db); try validateRows(db,2)
        try Self.checkFile(owned,url:url,db:db)
        handle = db;fd = owned;nativeFile = pinned.ownership;retained = true;keep = true
        return db
    }
    func closeForReplacement() throws {
        if let handle {
            guard sqlite3_close(handle) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}
            self.handle = nil
        }
        nativeFile?.close();nativeFile = nil;fd = -1
    }
    /// The read-only handle never migrates, configures journals, creates files or
    /// changes sidecars. nil means absent final entry only, never invalid content.
    static func readOnly<T>(_ url:URL,onContention:@Sendable () -> Void = {},_ body:(OpaquePointer,Int) throws -> T) throws -> T? {
        try EditingRecoveryIntent.requireAbsent(for:url)
        guard let pinned = try EditingDatabaseAccess.pin(url,creating:false,onContention:onContention) else {return nil}
        let fd = pinned.fd
        defer{pinned.ownership.close()}
        let admission = pinned.admission;defer{admission.release()}
        try Task.checkCancellation()
        try sidecars(url);try checkFile(fd,url:url);try header(fd)
        let db = try connect(url,readOnly:true); defer { sqlite3_close(db) }
        try checkFile(fd,url:url,db:db)
        let version = Int(try scalar(db,"PRAGMA user_version")); try schema(db,version:version); try integrity(db)
        let result = try body(db,version); try checkFile(fd,url:url,db:db); return result
    }
    /// A synchronous reader holds the same process identity admission as writers.
    /// The handle can have crossed an await, so recheck every boundary here.
    func read<T>(_ db:OpaquePointer,_ body:() throws -> T) throws -> T {
        let admission = try EditingDatabaseAccess.acquire(fd:fd,url:url,onContention:onContention)
        defer{admission.release()}
        try Self.sidecars(url);try Self.checkFile(fd,url:url,db:db);try Self.schema(db,version:2)
        let result = try body()
        try Self.sidecars(url);try Self.checkFile(fd,url:url,db:db)
        return result
    }
    func transaction<T>(_ db:OpaquePointer,beforeCommit:() throws -> Void = {},_ body:() throws -> T) throws -> T {
        let admission = try EditingDatabaseAccess.acquire(fd:fd,url:url,onContention:onContention)
        defer{admission.release()}
        // A caller may retain db across artifact/package awaits. Reject new
        // unowned journals BEFORE even schema/file-control SQLite operations.
        try Task.checkCancellation();try Self.sidecars(url)
        try Self.checkFile(fd,url:url,db:db);try Self.schema(db,version:2)
        try Task.checkCancellation(); try Self.exec(db,"BEGIN IMMEDIATE")
        do { let v = try body(); try beforeCommit(); try Self.exec(db,"COMMIT"); return v }
        catch { try? Self.exec(db,"ROLLBACK"); throw error }
    }
    static func schema(_ db:OpaquePointer,version:Int) throws {
        guard version == 1 || version == 2 else { throw EditingRepositoryError.unsupportedVersion(version) }
        guard try scalar(db,"PRAGMA application_id") == Int64(applicationID),try scalar(db,"PRAGMA user_version") == Int64(version) else { throw EditingRepositoryError.invalidDatabase }
        let expected = version == 1 ? legacySchemas : schemas
        func normal(_ text:String) -> String { text.replacingOccurrences(of:"IF NOT EXISTS ",with:"").split(whereSeparator:\.isWhitespace).joined(separator:" ") }
        var names = Set<String>(), indexes = Set<String>()
        try rows(db,"SELECT type,name,tbl_name,sql FROM sqlite_schema") { s in
            let type = try text(s,0,maximum:32),name = try text(s,1,maximum:128),table = try text(s,2,maximum:128)
            if type == "table",let sql = expected[name],table == name {
                guard try normal(text(s,3,maximum:4_096)) == normal(sql),names.insert(name).inserted else { throw EditingRepositoryError.invalidDatabase }
            } else {
                guard type == "index",name == "sqlite_autoindex_\(table)_1",expected[table] != nil,table != "editing_state",sqlite3_column_type(s,3) == SQLITE_NULL,indexes.insert(name).inserted else { throw EditingRepositoryError.invalidDatabase }
            }
        }
        guard names == Set(expected.keys),indexes.count == expected.count-(version == 2 ? 1 : 0) else { throw EditingRepositoryError.invalidDatabase }
    }
    static func integrity(_ db:OpaquePointer) throws {
        var count = 0
        try rows(db,"PRAGMA quick_check") { guard try text($0,0,maximum:128) == "ok" else { throw EditingRepositoryError.invalidDatabase }; count += 1 }
        guard count == 1 else { throw EditingRepositoryError.invalidDatabase }
        try rows(db,"PRAGMA foreign_key_check") { _ in throw EditingRepositoryError.invalidDatabase }
    }
    static func connect(_ url:URL,readOnly:Bool) throws -> OpaquePointer {
        guard let parent = realpath(url.deletingLastPathComponent().path,nil) else {throw EditingRepositoryError.storageFailure}
        defer{free(parent)}
        let physicalPath = URL(fileURLWithPath:String(cString:parent),isDirectory:true).appendingPathComponent(url.lastPathComponent,isDirectory:false).path
        var db:OpaquePointer?
        let result = sqlite3_open_v2(physicalPath,&db,(readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)|SQLITE_OPEN_NOFOLLOW|SQLITE_OPEN_FULLMUTEX,nil)
        guard result == SQLITE_OK,let db else { sqlite3_close(db); throw EditingRepositoryError.storageFailure }
        sqlite3_busy_timeout(db,2_000); sqlite3_limit(db,SQLITE_LIMIT_LENGTH,67_109_888); sqlite3_limit(db,SQLITE_LIMIT_SQL_LENGTH,65_536); sqlite3_limit(db,SQLITE_LIMIT_COLUMN,32)
        return db
    }
    static func header(_ fd:Int32) throws {
        var b = [UInt8](repeating:0,count:100)
        guard b.withUnsafeMutableBytes({pread(fd,$0.baseAddress,100,0)}) == 100,Array(b.prefix(16)) == Array("SQLite format 3\0".utf8) else { throw EditingRepositoryError.invalidDatabase }
        func n(_ offset:Int) -> UInt32 { b[offset..<(offset+4)].reduce(0){$0 << 8 | UInt32($1)} }
        guard n(68) == UInt32(applicationID) else { throw EditingRepositoryError.invalidDatabase }
        guard n(60) == 1 || n(60) == 2 else { throw EditingRepositoryError.unsupportedVersion(Int(n(60))) }
        guard b[18] == 1,b[19] == 1 else { throw EditingRepositoryError.recoveryRequired }
    }
    static func sidecars(_ url:URL) throws {
        try EditingRecoveryIntent.requireAbsent(for:url)
        for suffix in ["-journal","-wal","-shm"] { var s = stat(); if lstat(url.path+suffix,&s) == 0 { throw EditingRepositoryError.recoveryRequired }; guard errno == ENOENT else { throw EditingRepositoryError.storageFailure } }
    }
    static func writable(_ fd:Int32,db:OpaquePointer? = nil) throws {
        var s = stat(); guard fstat(fd,&s) == 0 else { throw EditingRepositoryError.storageFailure }
        guard s.st_mode & (S_IWUSR|S_IWGRP|S_IWOTH) != 0,db.map({sqlite3_db_readonly($0,"main") == 0}) ?? true else { throw EditingRepositoryError.readOnly }
    }
    static func checkFile(_ fd:Int32,url:URL,db:OpaquePointer? = nil) throws {
        var a = stat(),b = stat()
        guard fstat(fd,&a) == 0,lstat(url.path,&b) == 0,a.st_mode & S_IFMT == S_IFREG,b.st_mode & S_IFMT == S_IFREG,a.st_nlink == 1,b.st_nlink == 1,a.st_dev == b.st_dev,a.st_ino == b.st_ino,a.st_size <= 536_870_912 else { throw EditingRepositoryError.invalidDatabase }
        if let db { var moved:Int32 = 0; guard sqlite3_file_control(db,"main",SQLITE_FCNTL_HAS_MOVED,&moved) == SQLITE_OK,moved == 0 else { throw EditingRepositoryError.invalidDatabase } }
    }
    static func exec(_ db:OpaquePointer,_ sql:String) throws {guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else {throw EditingRepositoryError.storageFailure}}
    static func statement<T>(_ db:OpaquePointer,_ sql:String,_ body:(OpaquePointer)throws->T) throws -> T {
        var s:OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&s,nil) == SQLITE_OK,let s else { throw EditingRepositoryError.storageFailure }; defer { sqlite3_finalize(s) }; return try body(s)
    }
    static func rows(_ db:OpaquePointer,_ sql:String,_ body:(OpaquePointer)throws->Void) throws { try statement(db,sql){try consume($0,body)} }
    static func consume(_ s:OpaquePointer,_ body:(OpaquePointer)throws->Void) throws { while true { let r = sqlite3_step(s); if r == SQLITE_DONE { return }; guard r == SQLITE_ROW else { throw EditingRepositoryError.storageFailure }; try autoreleasepool {try body(s)} } }
    static func done(_ s:OpaquePointer) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw EditingRepositoryError.storageFailure } }
    static func scalar(_ db:OpaquePointer,_ sql:String) throws -> Int64 { var result:Int64?; try rows(db,sql){guard sqlite3_column_type($0,0) == SQLITE_INTEGER,result == nil else {throw EditingRepositoryError.invalidDatabase};result = sqlite3_column_int64($0,0)}; guard let result else {throw EditingRepositoryError.invalidDatabase};return result }
    static func text(_ s:OpaquePointer,_ c:Int32,maximum:Int) throws -> String { guard sqlite3_column_type(s,c) == SQLITE_TEXT else {throw EditingRepositoryError.invalidDatabase};let n = Int(sqlite3_column_bytes(s,c));guard n <= maximum,let p = sqlite3_column_text(s,c),let v = String(data:Data(bytes:p,count:n),encoding:.utf8),!v.utf8.contains(0) else {throw EditingRepositoryError.invalidDatabase};return v }
    static func blob(_ s:OpaquePointer,_ c:Int32,maximum:Int) throws -> Data { guard sqlite3_column_type(s,c) == SQLITE_BLOB else {throw EditingRepositoryError.invalidDatabase};let n = Int(sqlite3_column_bytes(s,c));guard n > 0,n <= maximum,let p = sqlite3_column_blob(s,c) else {throw EditingRepositoryError.invalidDatabase};return Data(bytes:p,count:n) }
    static func bind(_ v:String,_ i:Int32,_ s:OpaquePointer) throws { guard v.withCString({sqlite3_bind_text(s,i,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}) == SQLITE_OK else {throw EditingRepositoryError.storageFailure} }
    static func bind(_ v:Data,_ i:Int32,_ s:OpaquePointer) throws {guard v.withUnsafeBytes({sqlite3_bind_blob(s,i,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}) == SQLITE_OK else {throw EditingRepositoryError.storageFailure} }
}
