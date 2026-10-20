import Foundation
import Darwin
import CSQLite

/// One repository actor owns this connection. Transactions are synchronous so
/// accepted writes cannot be interrupted between BEGIN and COMMIT.
final class PhotoMetadataSQLite: @unchecked Sendable {
    let fileURL: URL
    private var db: OpaquePointer?
    private var fd: Int32 = -1
    static let applicationID: Int32 = 0x474c4d44 // GLMD, distinct from editing and semantic stores.
    static let schemaVersion: Int32 = 2
    static let legacySchemas = [
        "metadata_state": "CREATE TABLE metadata_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), search_generation INTEGER NOT NULL CHECK(search_generation>=0), catalog_reference BLOB NOT NULL)",
        "metadata_records": "CREATE TABLE metadata_records(asset_id TEXT PRIMARY KEY NOT NULL, record BLOB NOT NULL)",
        "metadata_receipts": "CREATE TABLE metadata_receipts(id TEXT PRIMARY KEY NOT NULL, digest TEXT NOT NULL, receipt BLOB NOT NULL)",
        "metadata_catalog_changes": "CREATE TABLE metadata_catalog_changes(id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL CHECK(state IN ('staged','conflicted','completed','abandoned')), journal BLOB NOT NULL)"
    ]
    static let schemas = legacySchemas.merging([
        "metadata_identity":"CREATE TABLE metadata_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1), store_id TEXT NOT NULL)",
        "metadata_coordinations":"CREATE TABLE metadata_coordinations(id TEXT PRIMARY KEY NOT NULL, coordinator_sha TEXT NOT NULL)"
    ]) { _,new in new }
    init(directory: URL) { fileURL = directory.appendingPathComponent("photo-metadata.sqlite") }
    deinit { sqlite3_close(db); if fd >= 0 { Darwin.close(fd) } }

    func open(validateRows: (OpaquePointer) throws -> Void) throws -> OpaquePointer {
        guard fileURL.isFileURL, !fileURL.path.utf8.contains(0) else { throw PhotoMetadataError.validation(.invalidSource) }
        let parent = fileURL.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw PhotoMetadataError.storageFailure }
        guard let physical = realpath(parent.path, nil) else { throw PhotoMetadataError.storageFailure }
        defer { free(physical) }
        let url = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent(fileURL.lastPathComponent)
        if let db {
            try Self.checkFile(fd, url: url, connection: db)
            try Self.header(fd)
            var permissions = stat()
            guard fstat(fd,&permissions) == 0 else { throw PhotoMetadataError.storageFailure }
            guard permissions.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) != 0, sqlite3_db_readonly(db,"main") == 0 else { throw PhotoMetadataError.readOnly }
            try Self.sidecars(url)
            // A second process may have added a trigger while our handle lived.
            try Self.validateSchema(db)
            return db
        }
        // A durable metadata store is never regenerated. Existing sidecars are
        // preserved for explicit SQLite recovery; opening read-write would
        // otherwise roll a journal forward/back before ownership was proven.
        try Self.sidecars(url)
        var created = false
        var descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 { created = true }
        else {
            guard errno == EEXIST else { throw PhotoMetadataError.storageFailure }
            descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw PhotoMetadataError.corruptStore }
        }
        var retained = false
        defer {
            if !retained {
                // Remove only this attempt's untouched empty inode. An
                // initialized/ambiguous database is retained for recovery.
                if created, (try? Self.checkFile(descriptor, url: url)) != nil {
                    var info = stat()
                    if fstat(descriptor, &info) == 0, info.st_size == 0,
                       (try? Self.sidecars(url)) != nil { _ = unlink(url.path) }
                }
                Darwin.close(descriptor)
            }
        }
        try Self.checkFile(descriptor, url: url)
        if !created {
            try Self.header(descriptor)
            let ro = try Self.connection(url, flags: SQLITE_OPEN_READONLY)
            defer { sqlite3_close(ro) }
            try Self.checkFile(descriptor, url: url, connection: ro)
            try Self.validateSchema(ro,allowLegacy:true)
            try Self.integrity(ro)
            try validateRows(ro)
        }
        var permissions = stat()
        guard fstat(descriptor,&permissions) == 0 else { throw PhotoMetadataError.storageFailure }
        if !created, permissions.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 { throw PhotoMetadataError.readOnly }
        let opened = try Self.connection(url, flags: SQLITE_OPEN_READWRITE)
        var keepConnection = false
        defer { if !keepConnection { sqlite3_close(opened) } }
        try Self.checkFile(descriptor, url: url, connection: opened)
        guard sqlite3_db_readonly(opened,"main") == 0 else { throw PhotoMetadataError.readOnly }
        let existingVersion = created ? Int32(2) : try Self.version(opened)
        let migrating = !created && existingVersion == 1
        if created || migrating {
            try Self.exec(opened, "PRAGMA synchronous=FULL;BEGIN IMMEDIATE")
            do {
                if migrating {try Self.validateSchema(opened,allowLegacy:true);try validateRows(opened)}
                for name in Self.schemas.keys.sorted() where created || Self.legacySchemas[name] == nil {try Self.exec(opened,Self.schemas[name]!)}
                try Self.statement(opened,"INSERT INTO metadata_identity(singleton,store_id) VALUES(1,?)") {s in
                    try Self.bind(UUID().uuidString.lowercased(),1,s);try Self.done(s)
                }
                let initial = try PhotoMetadataInternalCodec.encode(MetadataCatalogFileReference.absent)
                if created { try Self.statement(opened, "INSERT INTO metadata_state(singleton,search_generation,catalog_reference) VALUES(1,0,?)") { s in
                    try Self.bind(initial, 1, s); try Self.done(s)
                } }
                try Self.exec(opened, "PRAGMA application_id=\(Self.applicationID);PRAGMA user_version=\(Self.schemaVersion);COMMIT")
            } catch { try? Self.exec(opened, "ROLLBACK"); throw error }
        }
        try Self.validateSchema(opened); try Self.integrity(opened); try validateRows(opened)
        try Self.exec(opened, "PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON;PRAGMA trusted_schema=OFF")
        try Self.checkFile(descriptor, url: url, connection: opened)
        if created { guard fchmod(descriptor, 0o600) == 0 else { throw PhotoMetadataError.storageFailure } }
        fd = descriptor; db = opened; retained = true; keepConnection = true
        return opened
    }
    func transaction<T>(_ connection: OpaquePointer, beforeCommit: () throws -> Void,
                        body: () throws -> T) throws -> T {
        if Task.isCancelled { throw PhotoMetadataError.cancelled }
        try Self.validateSchema(connection)
        if Task.isCancelled { throw PhotoMetadataError.cancelled }
        try Self.exec(connection, "BEGIN IMMEDIATE")
        do {
            let value = try body(); try beforeCommit()
            try Self.exec(connection, "COMMIT")
            // No throwable cleanup after COMMIT may turn durable success into
            // a reported failed command. Receipts resolve lost caller replies.
            return value
        } catch { try? Self.exec(connection, "ROLLBACK"); throw error }
    }
    private static func connection(_ url: URL, flags: Int32) throws -> OpaquePointer {
        guard let parent = realpath(url.deletingLastPathComponent().path,nil) else {throw PhotoMetadataError.storageFailure}
        defer{free(parent)}
        let physicalPath = URL(fileURLWithPath:String(cString:parent),isDirectory:true).appendingPathComponent(url.lastPathComponent,isDirectory:false).path
        var value: OpaquePointer?
        guard sqlite3_open_v2(physicalPath, &value, flags | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let value else { sqlite3_close(value); throw PhotoMetadataError.storageFailure }
        sqlite3_busy_timeout(value, 2_000)
        sqlite3_limit(value, SQLITE_LIMIT_LENGTH, Int32(PhotoMetadataLimits.maximumJournalBytes + 1_024))
        sqlite3_limit(value, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        sqlite3_limit(value, SQLITE_LIMIT_COLUMN, 32)
        return value
    }
    private static func checkFile(_ descriptor: Int32, url: URL, connection: OpaquePointer? = nil) throws {
        var pinned = stat(), current = stat()
        guard fstat(descriptor, &pinned) == 0, lstat(url.path, &current) == 0,
              pinned.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
              pinned.st_nlink == 1, current.st_nlink == 1,
              pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino else { throw PhotoMetadataError.corruptStore }
        if let connection {
            var moved: Int32 = 0
            guard sqlite3_file_control(connection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK, moved == 0 else { throw PhotoMetadataError.corruptStore }
        }
    }
    private static func sidecars(_ url: URL) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            var info = stat()
            if lstat(url.path + suffix, &info) == 0 { throw PhotoMetadataError.recoveryRequired }
            guard errno == ENOENT else { throw PhotoMetadataError.storageFailure }
        }
    }
    private static func header(_ descriptor: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: 100)
        guard bytes.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, $0.count, 0) }) == 100,
              Array(bytes.prefix(16)) == Array("SQLite format 3\0".utf8) else { throw PhotoMetadataError.corruptStore }
        func number(_ offset: Int) -> UInt32 { bytes[offset..<(offset+4)].reduce(0) { $0 << 8 | UInt32($1) } }
        guard number(68) == UInt32(applicationID) else { throw PhotoMetadataError.corruptStore }
        guard number(60) == 1 || number(60) == UInt32(schemaVersion) else { throw PhotoMetadataError.unsupportedVersion }
        guard bytes[18] == 1, bytes[19] == 1 else { throw PhotoMetadataError.recoveryRequired }
    }
    static func version(_ db:OpaquePointer) throws -> Int32 {
        var result:Int32 = -1
        try rows(db,"PRAGMA user_version") {result = sqlite3_column_int($0,0)};return result
    }
    static func validateSchema(_ db: OpaquePointer,allowLegacy:Bool = false) throws {
        let actual = try version(db)
        guard actual == schemaVersion || allowLegacy && actual == 1 else {throw PhotoMetadataError.unsupportedVersion}
        let expectedSchemas = actual == 1 ? legacySchemas : schemas
        for (sql, value) in [("PRAGMA application_id",applicationID),("PRAGMA user_version",actual)] {
            var valid = false
            try rows(db, sql) { valid = sqlite3_column_type($0,0) == SQLITE_INTEGER && sqlite3_column_int64($0,0) == Int64(value) }
            guard valid else { throw sql.contains("user_version") ? PhotoMetadataError.unsupportedVersion : .corruptStore }
        }
        var names = Set<String>(), indexes = Set<String>()
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        try rows(db, "SELECT type,name,tbl_name,sql FROM sqlite_schema") { s in
            let type = try text(s,0,maximum:32), name = try text(s,1,maximum:128), table = try text(s,2,maximum:128)
            if let expected = expectedSchemas[name], type == "table", table == name {
                guard normalized(try text(s,3,maximum:4_096)) == normalized(expected), names.insert(name).inserted else { throw PhotoMetadataError.corruptStore }
            } else {
                let expectedIndexes = (actual == 1 ? ["metadata_records","metadata_receipts","metadata_catalog_changes"] : ["metadata_records","metadata_receipts","metadata_catalog_changes","metadata_coordinations"]).map { "sqlite_autoindex_\($0)_1" }
                guard type == "index", expectedIndexes.contains(name), name == "sqlite_autoindex_\(table)_1",
                      sqlite3_column_type(s,3) == SQLITE_NULL, indexes.insert(name).inserted else { throw PhotoMetadataError.corruptStore }
            }
        }
        guard names == Set(expectedSchemas.keys), indexes.count == (actual == 1 ? 3 : 4) else { throw PhotoMetadataError.corruptStore }
    }
    /// Pure participant lookup. No creation, migration or implicit recovery.
    static func inspect<T>(at url:URL,_ body:(OpaquePointer,Int32)throws->T) throws -> T? {
        let descriptor = Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard descriptor >= 0 else {if errno == ENOENT {return nil};throw PhotoMetadataError.corruptStore}
        defer{Darwin.close(descriptor)}
        try sidecars(url);try checkFile(descriptor,url:url);try header(descriptor)
        let db = try connection(url,flags:SQLITE_OPEN_READONLY);defer{sqlite3_close(db)}
        try checkFile(descriptor,url:url,connection:db);try validateSchema(db,allowLegacy:true);try integrity(db)
        let value = try body(db,version(db));try checkFile(descriptor,url:url,connection:db);return value
    }
    static func integrity(_ db: OpaquePointer) throws {
        var count = 0
        try rows(db,"PRAGMA quick_check") { guard try text($0,0,maximum:128) == "ok" else { throw PhotoMetadataError.corruptStore }; count += 1 }
        guard count == 1 else { throw PhotoMetadataError.corruptStore }
    }
    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw PhotoMetadataError.storageFailure }
    }
    static func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw PhotoMetadataError.storageFailure }
        defer { sqlite3_finalize(statement) }; return try body(statement)
    }
    static func rows(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        try statement(db,sql) { try consume($0,body) }
    }
    static func consume(_ s: OpaquePointer, _ body: (OpaquePointer) throws -> Void) throws {
        while true { let status = sqlite3_step(s); if status == SQLITE_DONE { return }; guard status == SQLITE_ROW else { throw PhotoMetadataError.storageFailure }; try autoreleasepool { try body(s) } }
    }
    static func done(_ s: OpaquePointer) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw PhotoMetadataError.storageFailure } }
    static func text(_ s: OpaquePointer, _ column: Int32, maximum: Int) throws -> String {
        guard sqlite3_column_type(s,column) == SQLITE_TEXT else { throw PhotoMetadataError.corruptStore }
        let count = Int(sqlite3_column_bytes(s,column))
        guard count <= maximum, let pointer = sqlite3_column_text(s,column),
              let value = String(data: Data(bytes:pointer,count:count),encoding:.utf8), !value.utf8.contains(0) else { throw PhotoMetadataError.corruptStore }
        return value
    }
    static func blob(_ s: OpaquePointer, _ column: Int32, maximum: Int) throws -> Data {
        guard sqlite3_column_type(s,column) == SQLITE_BLOB else { throw PhotoMetadataError.corruptStore }
        let count = Int(sqlite3_column_bytes(s,column))
        guard count > 0, count <= maximum, let pointer = sqlite3_column_blob(s,column) else { throw PhotoMetadataError.corruptStore }
        return Data(bytes:pointer,count:count)
    }
    static func bind(_ text: String, _ index: Int32, _ s: OpaquePointer) throws {
        guard text.withCString({ sqlite3_bind_text(s,index,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw PhotoMetadataError.storageFailure }
    }
    static func bind(_ data: Data, _ index: Int32, _ s: OpaquePointer) throws {
        guard data.withUnsafeBytes({ sqlite3_bind_blob(s,index,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw PhotoMetadataError.storageFailure }
    }
}
