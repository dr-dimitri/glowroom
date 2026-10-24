import Foundation
import CSQLite
import Darwin

public struct SemanticIndexGeneration: Hashable, Sendable {
    public let id: UUID
    public let descriptor: SemanticModelDescriptor
    public let installationFingerprint: String
    public init(id: UUID, descriptor: SemanticModelDescriptor, installationFingerprint: String) {
        self.id = id; self.descriptor = descriptor; self.installationFingerprint = installationFingerprint
    }
}

public struct SemanticIndexCandidate: Hashable, Sendable {
    public let assetID: String
    public let source: AIOriginalSourceFingerprint
    public init(assetID: String, source: AIOriginalSourceFingerprint) { self.assetID = assetID; self.source = source }
}

public struct SemanticIndexRecord: Hashable, Sendable {
    public let assetID: String
    public let source: AIOriginalSourceFingerprint
    public let sourceRevision: String
    public let inputRasterSHA256: String
    public let vector: [Float]
    public init(assetID: String, source: AIOriginalSourceFingerprint, sourceRevision: String,
                inputRasterSHA256: String, vector: [Float]) {
        self.assetID = assetID; self.source = source; self.sourceRevision = sourceRevision
        self.inputRasterSHA256 = inputRasterSHA256; self.vector = vector
    }
}

public struct SemanticIndexMetadata: Hashable, Sendable {
    public let assetID: String
    public let source: AIOriginalSourceFingerprint
    public let sourceRevision: String
    public let inputRasterSHA256: String
    public init(assetID: String, source: AIOriginalSourceFingerprint, sourceRevision: String, inputRasterSHA256: String) {
        self.assetID = assetID; self.source = source; self.sourceRevision = sourceRevision; self.inputRasterSHA256 = inputRasterSHA256
    }
}

/// Persisted vectors only. Scope, inference, ranking and query cancellation belong
/// to the App service. Short synchronous transactions deliberately serialize DB
/// mutations; independent model/preview work uses the existing resource budget.
public actor SemanticIndexStore {
    public nonisolated let fileURL: URL
    public nonisolated static let normalizationNormTolerance: Double = 0.001
    public nonisolated static let maximumPageSize = 512
    private static let applicationID: Int32 = 0x474c5345 // GLSE, distinct from editing and metadata stores.
    private static let version: Int32 = 1
    private static let schemas: [String: String] = [
        "semantic_generations": "CREATE TABLE semantic_generations(id TEXT PRIMARY KEY NOT NULL, descriptor BLOB NOT NULL, installation TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('building','active','retired','superseded')), score_schema TEXT NOT NULL)",
        "semantic_state": "CREATE TABLE semantic_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), active_id TEXT REFERENCES semantic_generations(id))",
        "semantic_entries": "CREATE TABLE semantic_entries(generation_id TEXT NOT NULL REFERENCES semantic_generations(id) ON DELETE CASCADE, asset_id TEXT NOT NULL, source_path TEXT NOT NULL, source_mtime_reference REAL NOT NULL, source_size INTEGER NOT NULL, source_revision TEXT NOT NULL, raster_digest TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(generation_id,asset_id))"
    ]
    private static let scoreSchema = "l2-f32-cosine-v1"
    private let beforeCommit: @Sendable () throws -> Void
    private var db: OpaquePointer?
    private var ownershipDescriptor: Int32 = -1

    /// No I/O here: initialization can safely be called from UI composition.
    public init(directory: URL) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw SemanticEmbeddingError.invalidInput }
        fileURL = directory.appendingPathComponent("semantic-index.sqlite")
        beforeCommit = {}
    }
    /// Isolated failure injection; never substitutes a production backend.
    init(directory: URL, beforeCommit: @escaping @Sendable () throws -> Void) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw SemanticEmbeddingError.invalidInput }
        fileURL = directory.appendingPathComponent("semantic-index.sqlite")
        self.beforeCommit = beforeCommit
    }
    deinit { sqlite3_close(db); if ownershipDescriptor >= 0 { Darwin.close(ownershipDescriptor) } }

    public func activeGeneration() throws -> SemanticIndexGeneration? {
        let connection = try open()
        var id: String?, count = 0
        try Self.rows(connection, "SELECT active_id FROM semantic_state WHERE singleton=1") { statement in
            count += 1
            if sqlite3_column_type(statement, 0) != SQLITE_NULL { id = try Self.text(statement, 0, maximum: 36) }
        }
        guard count == 1 else { throw SemanticEmbeddingError.corruptIndex }
        guard let id else { return nil }
        guard let uuid = UUID(uuidString: id) else { throw SemanticEmbeddingError.corruptIndex }
        let value = try generation(uuid, on: connection)
        guard value.state == "active" else { throw SemanticEmbeddingError.corruptIndex }
        return value.value
    }

    public func prepareGeneration(for descriptor: SemanticModelDescriptor, installationFingerprint: String,
                                  forceNew: Bool = false) throws -> SemanticIndexGeneration {
        try descriptor.validate()
        guard Self.digest(installationFingerprint) else { throw SemanticEmbeddingError.invalidInput }
        return try transaction { connection in
            if !forceNew {
                var existing: SemanticIndexGeneration?, existingState: String?
                try Self.rows(connection, "SELECT id FROM semantic_generations WHERE state IN ('building','active') ORDER BY CASE state WHEN 'building' THEN 0 ELSE 1 END") { statement in
                    let id = try Self.uuid(statement, 0)
                    let candidate = try generation(id, on: connection)
                    if existing == nil, candidate.value.descriptor == descriptor, candidate.value.installationFingerprint == installationFingerprint {
                        existing = candidate.value; existingState = candidate.state
                    }
                }
                if let existing {
                    if existingState == "active" { try Self.execute(connection, "UPDATE semantic_generations SET state='superseded' WHERE state='building'") }
                    return existing
                }
            }
            var count: Int64 = 0
            try Self.rows(connection, "SELECT COUNT(*) FROM semantic_generations") { count = sqlite3_column_int64($0, 0) }
            guard count < 1_024 else { throw SemanticEmbeddingError.indexUnavailable }
            try Self.execute(connection, "UPDATE semantic_generations SET state='superseded' WHERE state='building'")
            let result = SemanticIndexGeneration(id: UUID(), descriptor: descriptor, installationFingerprint: installationFingerprint)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(descriptor)
            try Self.statement(connection, "INSERT INTO semantic_generations(id,descriptor,installation,state,score_schema) VALUES(?,?,?,'building',?)") { statement in
                try Self.bind(result.id.uuidString, 1, statement); try Self.bind(payload, 2, statement)
                try Self.bind(installationFingerprint, 3, statement); try Self.bind(Self.scoreSchema, 4, statement)
                try Self.done(statement)
            }
            return result
        }
    }

    public func upsert(_ record: SemanticIndexRecord, in generation: SemanticIndexGeneration) throws {
        try Self.validateMetadata(assetID: record.assetID, source: record.source, sourceRevision: record.sourceRevision, digest: record.inputRasterSHA256)
        try Self.validateVector(record.vector, dimension: generation.descriptor.dimension)
        try transaction { connection in
            try require(generation, writable: true, on: connection)
            try Self.statement(connection, "INSERT INTO semantic_entries(generation_id,asset_id,source_path,source_mtime_reference,source_size,source_revision,raster_digest,vector) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(generation_id,asset_id) DO UPDATE SET source_path=excluded.source_path,source_mtime_reference=excluded.source_mtime_reference,source_size=excluded.source_size,source_revision=excluded.source_revision,raster_digest=excluded.raster_digest,vector=excluded.vector") { statement in
                try Self.bind(generation.id.uuidString, 1, statement); try Self.bind(record.assetID, 2, statement)
                try Self.bind(record.source.standardizedPath, 3, statement)
                guard sqlite3_bind_double(statement, 4, record.source.modifiedAt.timeIntervalSinceReferenceDate) == SQLITE_OK,
                      sqlite3_bind_int64(statement, 5, record.source.fileSize) == SQLITE_OK else { throw SemanticEmbeddingError.corruptIndex }
                try Self.bind(record.sourceRevision, 6, statement); try Self.bind(record.inputRasterSHA256, 7, statement)
                try Self.bind(Self.encodeVector(record.vector), 8, statement); try Self.done(statement)
            }
        }
    }

    /// One non-suspending transaction publishes a complete generation. A cancelled
    /// or superseded caller cannot change the last active pointer.
    public func activate(_ generation: SemanticIndexGeneration) throws {
        try transaction { connection in
            try require(generation, writable: true, on: connection)
            try Self.execute(connection, "UPDATE semantic_generations SET state='retired' WHERE state='active'")
            try Self.statement(connection, "UPDATE semantic_generations SET state='active' WHERE id=?") { statement in
                try Self.bind(generation.id.uuidString, 1, statement); try Self.done(statement)
            }
            try Self.statement(connection, "UPDATE semantic_state SET active_id=? WHERE singleton=1") { statement in
                try Self.bind(generation.id.uuidString, 1, statement); try Self.done(statement)
            }
        }
    }

    public func metadata(in generation: SemanticIndexGeneration, assetIDs: [String]) throws -> [SemanticIndexMetadata] {
        guard assetIDs.count <= Self.maximumPageSize, assetIDs.allSatisfy(Self.identifier) else { throw SemanticEmbeddingError.invalidInput }
        let connection = try open(); try require(generation, writable: false, on: connection)
        if assetIDs.isEmpty { return [] }
        let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
        var result: [SemanticIndexMetadata] = []
        try Self.statement(connection, "SELECT asset_id,source_path,source_mtime_reference,source_size,source_revision,raster_digest FROM semantic_entries WHERE generation_id=? AND asset_id IN (\(placeholders)) ORDER BY asset_id COLLATE BINARY") { statement in
            try Self.bind(generation.id.uuidString, 1, statement)
            for (index, id) in assetIDs.enumerated() { try Self.bind(id, Int32(index + 2), statement) }
            try Self.consume(statement) { result.append(try Self.readMetadata($0)) }
        }
        return result
    }

    /// Indexed reference lookup; image-to-image queries never scan the index to
    /// discover their reference or decode the original again.
    public func record(in generation: SemanticIndexGeneration, assetID: String) throws -> SemanticIndexRecord? {
        guard Self.identifier(assetID) else { throw SemanticEmbeddingError.invalidInput }
        let connection = try open(); try require(generation, writable: false, on: connection)
        var result: SemanticIndexRecord?
        try Self.statement(connection, "SELECT asset_id,source_path,source_mtime_reference,source_size,source_revision,raster_digest,vector FROM semantic_entries WHERE generation_id=? AND asset_id=?") { statement in
            try Self.bind(generation.id.uuidString, 1, statement); try Self.bind(assetID, 2, statement)
            try Self.consume(statement) { row in
                if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
                let metadata = try Self.readMetadata(row)
                result = SemanticIndexRecord(assetID: metadata.assetID, source: metadata.source,
                    sourceRevision: metadata.sourceRevision, inputRasterSHA256: metadata.inputRasterSHA256,
                    vector: try Self.decodeVector(row, column: 6, dimension: generation.descriptor.dimension))
            }
        }
        return result
    }

    public func records(in generation: SemanticIndexGeneration, afterAssetID: String? = nil, limit: Int = 256) throws -> [SemanticIndexRecord] {
        guard (1...Self.maximumPageSize).contains(limit), afterAssetID.map(Self.identifier) ?? true else { throw SemanticEmbeddingError.invalidInput }
        let connection = try open(); try require(generation, writable: false, on: connection)
        var result: [SemanticIndexRecord] = []
        let cursor = afterAssetID == nil ? "" : " AND asset_id>?"
        try Self.statement(connection, "SELECT asset_id,source_path,source_mtime_reference,source_size,source_revision,raster_digest,vector FROM semantic_entries WHERE generation_id=?\(cursor) ORDER BY asset_id COLLATE BINARY LIMIT \(limit)") { statement in
            try Self.bind(generation.id.uuidString, 1, statement)
            if let afterAssetID { try Self.bind(afterAssetID, 2, statement) }
            try Self.consume(statement) { row in
                if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
                let metadata = try Self.readMetadata(row)
                let vector = try Self.decodeVector(row, column: 6, dimension: generation.descriptor.dimension)
                result.append(SemanticIndexRecord(assetID: metadata.assetID, source: metadata.source,
                    sourceRevision: metadata.sourceRevision, inputRasterSHA256: metadata.inputRasterSHA256, vector: vector))
            }
        }
        return result
    }

    public func remove(assetIDs: [String], in generation: SemanticIndexGeneration) throws {
        guard assetIDs.count <= Self.maximumPageSize, assetIDs.allSatisfy(Self.identifier) else { throw SemanticEmbeddingError.invalidInput }
        try transaction { connection in
            try require(generation, writable: true, on: connection)
            for id in assetIDs {
                try Self.statement(connection, "DELETE FROM semantic_entries WHERE generation_id=? AND asset_id=?") { statement in
                    try Self.bind(generation.id.uuidString, 1, statement); try Self.bind(id, 2, statement); try Self.done(statement)
                }
            }
        }
    }

    /// Catalog removal must erase every generation, including retired and
    /// superseded work. The service cancels/drains indexing before this barrier.
    /// Bounded ID pages avoid loading vectors or a full index into memory.
    @discardableResult
    public func retainOnlyCatalogAssets(_ assetIDs: Set<String>) throws -> Int {
        guard assetIDs.allSatisfy(Self.identifier) else { throw SemanticEmbeddingError.invalidInput }
        return try transaction { connection in
            var after:String?, removed = 0
            while true {
                let suffix = after == nil ? "" : " WHERE asset_id>?"
                let page:[String] = try Self.statement(connection, "SELECT DISTINCT asset_id FROM semantic_entries\(suffix) ORDER BY asset_id COLLATE BINARY LIMIT \(Self.maximumPageSize)") { statement in
                    if let after { try Self.bind(after, 1, statement) }
                    var page:[String] = []
                    try Self.consume(statement) { page.append(try Self.text($0, 0, maximum: 16_384)) }; return page
                }
                if page.isEmpty { break }
                for id in page where !assetIDs.contains(id) {
                    try Self.statement(connection, "DELETE FROM semantic_entries WHERE asset_id=?") { statement in
                        try Self.bind(id, 1, statement); try Self.done(statement)
                        removed += Int(sqlite3_changes(connection))
                    }
                }
                after = page.last!
            }
            return removed
        }
    }

    /// Caller quiesces its indexing/search service first. Unknown files and their
    /// sidecars are preserved rather than interpreted or deleted.
    @discardableResult public func rebuildAfterExplicitUserAction() throws -> URL? {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        try close()
        let archived = try quarantine()
        // A user-accepted filesystem replacement completes once started.
        _ = try open(checkCancellation: false)
        return archived
    }

    /// A valid owned store is cleared atomically. A rejected store is preserved
    /// in quarantine and replaced only after this explicit user action.
    @discardableResult public func deleteAfterExplicitUserAction() throws -> URL? {
        do {
            let connection = try open()
            try Self.validateDatabase(connection)
            try transaction { connection in
                try Self.execute(connection, "UPDATE semantic_state SET active_id=NULL WHERE singleton=1")
                try Self.execute(connection, "DELETE FROM semantic_entries")
                try Self.execute(connection, "DELETE FROM semantic_generations")
            }
            return nil
        } catch let error as SemanticEmbeddingError where error == .corruptIndex || error == .unsupportedVersion {
            return try rebuildAfterExplicitUserAction()
        }
    }

    private func generation(_ id: UUID, on connection: OpaquePointer) throws -> (value: SemanticIndexGeneration, state: String) {
        var result: (SemanticIndexGeneration, String)?
        try Self.statement(connection, "SELECT id,descriptor,installation,state,score_schema FROM semantic_generations WHERE id=?") { statement in
            try Self.bind(id.uuidString, 1, statement)
            try Self.consume(statement) { result = try Self.readGeneration($0) }
        }
        guard let result else { throw SemanticEmbeddingError.superseded }
        return result
    }
    private func require(_ value: SemanticIndexGeneration, writable: Bool, on connection: OpaquePointer) throws {
        let current = try generation(value.id, on: connection)
        guard current.value == value else { throw SemanticEmbeddingError.superseded }
        guard current.state != "superseded", !writable || ["active", "building"].contains(current.state) else { throw SemanticEmbeddingError.superseded }
    }
    private func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        let connection = try open()
        try Self.validateSchema(connection)
        if Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        try Self.execute(connection, "BEGIN IMMEDIATE")
        do { let result = try body(connection); try beforeCommit(); try Self.execute(connection, "COMMIT"); return result }
        catch { try? Self.execute(connection, "ROLLBACK"); throw error }
    }

    private func open(checkCancellation: Bool = true) throws -> OpaquePointer {
        if checkCancellation, Task.isCancelled { throw SemanticEmbeddingError.cancelled }
        let url = try canonicalURL()
        if let db {
            try Self.checkFile(ownershipDescriptor, url: url, connection: db)
            try Self.checkSidecars(url)
            try Self.checkHeader(ownershipDescriptor)
            return db
        }
        try Self.checkSidecars(url)
        var created = false
        var descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 { created = true }
        else {
            guard errno == EEXIST else { throw SemanticEmbeddingError.corruptIndex }
            descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw SemanticEmbeddingError.corruptIndex }
        }
        var retained = false
        defer {
            if !retained {
                if created, (try? Self.checkFile(descriptor, url: url)) != nil {
                    var info = stat()
                    if fstat(descriptor, &info) == 0, info.st_size == 0, (try? Self.checkSidecars(url)) != nil { _ = unlink(url.path) }
                }
                Darwin.close(descriptor)
            }
        }
        try Self.checkFile(descriptor, url: url)
        if !created {
            try Self.checkHeader(descriptor)
            let readOnly = try Self.openDatabase(url, flags: SQLITE_OPEN_READONLY)
            defer { sqlite3_close(readOnly) }
            try Self.checkFile(descriptor, url: url, connection: readOnly)
            try Self.validateDatabase(readOnly)
        }
        let connection = try Self.openDatabase(url, flags: SQLITE_OPEN_READWRITE)
        var retainedConnection = false
        defer { if !retainedConnection { sqlite3_close(connection) } }
        try Self.checkFile(descriptor, url: url, connection: connection)
        if created {
            let schema = ["semantic_generations", "semantic_state", "semantic_entries"].map { Self.schemas[$0]! + ";" }.joined()
            do {
                try Self.execute(connection, "PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON;BEGIN IMMEDIATE;" + schema + "INSERT INTO semantic_state(singleton,active_id) VALUES(1,NULL);PRAGMA application_id=\(Self.applicationID);PRAGMA user_version=\(Self.version);COMMIT;")
            } catch { try? Self.execute(connection, "ROLLBACK"); throw error }
        }
        try Self.validateDatabase(connection)
        try Self.checkFile(descriptor, url: url, connection: connection)
        try Self.execute(connection, "PRAGMA synchronous=FULL;PRAGMA foreign_keys=ON")
        guard fchmod(descriptor, 0o600) == 0 else { throw SemanticEmbeddingError.corruptIndex }
        db = connection; ownershipDescriptor = descriptor
        retainedConnection = true; retained = true
        return connection
    }
    private func canonicalURL() throws -> URL {
        do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw SemanticEmbeddingError.corruptIndex }
        guard let parent = realpath(fileURL.deletingLastPathComponent().path, nil) else { throw SemanticEmbeddingError.corruptIndex }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(fileURL.lastPathComponent)
    }
    private func close() throws {
        if let db {
            guard sqlite3_close(db) == SQLITE_OK else { throw SemanticEmbeddingError.corruptIndex }
            self.db = nil
        }
        if ownershipDescriptor >= 0 { Darwin.close(ownershipDescriptor); ownershipDescriptor = -1 }
    }
    private func quarantine() throws -> URL? {
        let url = try canonicalURL()
        let suffixes = ["", "-journal", "-wal", "-shm"].filter { suffix in
            var info = stat(); return lstat(url.path + suffix, &info) == 0
        }
        guard !suffixes.isEmpty else { return nil }
        let destination = url.deletingLastPathComponent().appendingPathComponent("semantic-index-quarantine-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(destination.path, 0o700) == 0 else { throw SemanticEmbeddingError.corruptIndex }
        for suffix in suffixes {
            let target = destination.appendingPathComponent(url.lastPathComponent + suffix)
            guard rename(url.path + suffix, target.path) == 0 else { throw SemanticEmbeddingError.corruptIndex }
        }
        return destination
    }

    private static func openDatabase(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let connection else { sqlite3_close(connection); throw SemanticEmbeddingError.corruptIndex }
        sqlite3_busy_timeout(connection, 5_000)
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 262_144)
        sqlite3_limit(connection, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        return connection
    }
    private static func checkFile(_ descriptor: Int32, url: URL, connection: OpaquePointer? = nil) throws {
        var pinned = stat(), current = stat()
        guard descriptor >= 0, fstat(descriptor, &pinned) == 0, lstat(url.path, &current) == 0,
              pinned.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
              pinned.st_nlink == 1, current.st_nlink == 1, pinned.st_dev == current.st_dev,
              pinned.st_ino == current.st_ino else { throw SemanticEmbeddingError.corruptIndex }
        if let connection {
            var moved: Int32 = 0
            guard sqlite3_file_control(connection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK, moved == 0 else { throw SemanticEmbeddingError.corruptIndex }
        }
    }
    private static func checkSidecars(_ url: URL) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            var info = stat()
            guard lstat(url.path + suffix, &info) != 0, errno == ENOENT else { throw SemanticEmbeddingError.corruptIndex }
        }
    }
    private static func checkHeader(_ descriptor: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: 100)
        guard bytes.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, $0.count, 0) }) == 100,
              Array(bytes.prefix(16)) == Array("SQLite format 3\0".utf8) else { throw SemanticEmbeddingError.corruptIndex }
        func integer(_ offset: Int) -> UInt32 { bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) } }
        guard integer(68) == UInt32(applicationID) else { throw SemanticEmbeddingError.corruptIndex }
        guard integer(60) == UInt32(version) else { throw SemanticEmbeddingError.unsupportedVersion }
        guard bytes[18] == 1, bytes[19] == 1 else { throw SemanticEmbeddingError.corruptIndex }
    }
    private static func validateSchema(_ connection: OpaquePointer) throws {
        for (sql, expected) in [("PRAGMA application_id", applicationID), ("PRAGMA user_version", version)] {
            var matched = false
            try rows(connection, sql) { matched = sqlite3_column_int64($0, 0) == Int64(expected) }
            guard matched else { throw sql.contains("user_version") ? SemanticEmbeddingError.unsupportedVersion : .corruptIndex }
        }
        var names = Set<String>(), indexes = Set<String>()
        func normalized(_ sql: String) -> String { sql.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        try rows(connection, "SELECT type,name,tbl_name,sql FROM sqlite_schema") { statement in
            let type = try text(statement, 0, maximum: 16), name = try text(statement, 1, maximum: 128)
            let table = try text(statement, 2, maximum: 128)
            if let expected = schemas[name], type == "table", table == name {
                guard normalized(try text(statement, 3, maximum: 4_096)) == normalized(expected), names.insert(name).inserted else { throw SemanticEmbeddingError.corruptIndex }
            } else {
                guard type == "index", ["sqlite_autoindex_semantic_generations_1", "sqlite_autoindex_semantic_entries_1"].contains(name),
                      table == (name.contains("generations") ? "semantic_generations" : "semantic_entries"),
                      sqlite3_column_type(statement, 3) == SQLITE_NULL, indexes.insert(name).inserted else { throw SemanticEmbeddingError.corruptIndex }
            }
        }
        guard names == Set(schemas.keys), indexes.count == 2 else { throw SemanticEmbeddingError.corruptIndex }
    }
    private static func validateDatabase(_ connection: OpaquePointer) throws {
        try validateSchema(connection)
        var checks = 0
        try rows(connection, "PRAGMA quick_check") { guard try text($0, 0, maximum: 512) == "ok" else { throw SemanticEmbeddingError.corruptIndex }; checks += 1 }
        guard checks == 1 else { throw SemanticEmbeddingError.corruptIndex }
        try rows(connection, "PRAGMA foreign_key_check") { _ in throw SemanticEmbeddingError.corruptIndex }
        var generations: [String: (SemanticIndexGeneration, String)] = [:]
        try rows(connection, "SELECT id,descriptor,installation,state,score_schema FROM semantic_generations") { row in
            guard generations.count < 1_024 else { throw SemanticEmbeddingError.corruptIndex }
            let value = try readGeneration(row); generations[value.0.id.uuidString] = value
        }
        guard generations.values.filter({ $0.1 == "building" }).count <= 1,
              generations.values.filter({ $0.1 == "active" }).count <= 1 else { throw SemanticEmbeddingError.corruptIndex }
        var states = 0, active: String?
        try rows(connection, "SELECT singleton,active_id FROM semantic_state") { row in
            states += 1
            guard sqlite3_column_int64(row, 0) == 1 else { throw SemanticEmbeddingError.corruptIndex }
            if sqlite3_column_type(row, 1) != SQLITE_NULL { active = try text(row, 1, maximum: 36) }
        }
        guard states == 1, Set(generations.filter({ $0.value.1 == "active" }).keys) == Set(active.map { [$0] } ?? []) else { throw SemanticEmbeddingError.corruptIndex }
        try rows(connection, "SELECT asset_id,source_path,source_mtime_reference,source_size,source_revision,raster_digest,vector,generation_id FROM semantic_entries") { row in
            _ = try readMetadata(row)
            let id = try text(row, 7, maximum: 36)
            guard let generation = generations[id] else { throw SemanticEmbeddingError.corruptIndex }
            _ = try decodeVector(row, column: 6, dimension: generation.0.descriptor.dimension)
        }
    }
    private static func readGeneration(_ row: OpaquePointer) throws -> (SemanticIndexGeneration, String) {
        let id = try uuid(row, 0), bytes = try blob(row, 1, maximum: 8_192)
        guard let descriptor = try? JSONDecoder().decode(SemanticModelDescriptor.self, from: bytes),
              (try? descriptor.validate()) != nil else { throw SemanticEmbeddingError.corruptIndex }
        let installation = try text(row, 2, maximum: 64), state = try text(row, 3, maximum: 16)
        guard digest(installation), ["building", "active", "retired", "superseded"].contains(state),
              try text(row, 4, maximum: 32) == scoreSchema else { throw SemanticEmbeddingError.corruptIndex }
        return (SemanticIndexGeneration(id: id, descriptor: descriptor, installationFingerprint: installation), state)
    }
    private static func readMetadata(_ row: OpaquePointer) throws -> SemanticIndexMetadata {
        let id = try text(row, 0, maximum: 16_384), path = try text(row, 1, maximum: 16_384)
        guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 2)), sqlite3_column_type(row, 3) == SQLITE_INTEGER else { throw SemanticEmbeddingError.corruptIndex }
        // Persist Date's native reference interval without adding/subtracting
        // the 1970 epoch offset: that round trip can lose a 119 ns Date ULP and
        // falsely reject an otherwise identical catalog source fingerprint.
        let time = sqlite3_column_double(row, 2), size = sqlite3_column_int64(row, 3)
        let revision = try text(row, 4, maximum: 512), hash = try text(row, 5, maximum: 64)
        let source = AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: path, isDirectory: false), modifiedAt: Date(timeIntervalSinceReferenceDate: time), fileSize: size)
        do { try validateMetadata(assetID: id, source: source, sourceRevision: revision, digest: hash) }
        catch { throw SemanticEmbeddingError.corruptIndex }
        guard path == source.standardizedPath else { throw SemanticEmbeddingError.corruptIndex }
        return SemanticIndexMetadata(assetID: id, source: source, sourceRevision: revision, inputRasterSHA256: hash)
    }
    private static func validateMetadata(assetID: String, source: AIOriginalSourceFingerprint, sourceRevision: String, digest hash: String) throws {
        guard identifier(assetID), source.isFileURL, source.standardizedPath.hasPrefix("/"), identifier(source.standardizedPath),
              source.modifiedAt.timeIntervalSince1970.isFinite, source.fileSize >= 0,
              !sourceRevision.isEmpty, sourceRevision.utf8.count <= 512, !sourceRevision.utf8.contains(0), digest(hash) else { throw SemanticEmbeddingError.invalidInput }
    }
    private static func identifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 16_384 && !value.utf8.contains(0) }
    private static func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func validateVector(_ vector: [Float], dimension: Int) throws {
        guard (1...4_096).contains(dimension), vector.count == dimension, vector.allSatisfy(\.isFinite) else { throw SemanticEmbeddingError.invalidVector }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0, abs(norm - 1) <= normalizationNormTolerance else { throw SemanticEmbeddingError.invalidVector }
    }
    private static func encodeVector(_ vector: [Float]) -> Data {
        var result = Data(capacity: vector.count * 4)
        for value in vector { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) } }
        return result
    }
    private static func decodeVector(_ row: OpaquePointer, column: Int32, dimension: Int) throws -> [Float] {
        let bytes = try blob(row, column, maximum: 16_384)
        guard bytes.count == dimension * 4 else { throw SemanticEmbeddingError.corruptIndex }
        let result = bytes.withUnsafeBytes { raw in (0..<dimension).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) } }
        do { try validateVector(result, dimension: dimension) } catch { throw SemanticEmbeddingError.corruptIndex }
        return result
    }
    private static func uuid(_ row: OpaquePointer, _ index: Int32) throws -> UUID {
        let value = try text(row, index, maximum: 36)
        guard let id = UUID(uuidString: value), id.uuidString == value else { throw SemanticEmbeddingError.corruptIndex }
        return id
    }
    private static func text(_ row: OpaquePointer, _ index: Int32, maximum: Int) throws -> String {
        guard sqlite3_column_type(row, index) == SQLITE_TEXT else { throw SemanticEmbeddingError.corruptIndex }
        let count = Int(sqlite3_column_bytes(row, index))
        guard count <= maximum, let bytes = sqlite3_column_text(row, index), let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { throw SemanticEmbeddingError.corruptIndex }
        return value
    }
    private static func blob(_ row: OpaquePointer, _ index: Int32, maximum: Int) throws -> Data {
        guard sqlite3_column_type(row, index) == SQLITE_BLOB else { throw SemanticEmbeddingError.corruptIndex }
        let count = Int(sqlite3_column_bytes(row, index))
        guard count > 0, count <= maximum, let bytes = sqlite3_column_blob(row, index) else { throw SemanticEmbeddingError.corruptIndex }
        return Data(bytes: bytes, count: count)
    }
    private static func execute(_ connection: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw SemanticEmbeddingError.corruptIndex }
    }
    private static func statement<T>(_ connection: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticEmbeddingError.corruptIndex }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }
    private static func rows(_ connection: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        try statement(connection, sql) { try consume($0, body) }
    }
    private static func consume(_ statement: OpaquePointer, _ body: (OpaquePointer) throws -> Void) throws {
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw SemanticEmbeddingError.corruptIndex }
            try body(statement)
        }
    }
    private static func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SemanticEmbeddingError.corruptIndex }
    }
    private static func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) throws {
        guard value.withCString({ sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw SemanticEmbeddingError.corruptIndex }
    }
    private static func bind(_ value: Data, _ index: Int32, _ statement: OpaquePointer) throws {
        guard value.withUnsafeBytes({ sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw SemanticEmbeddingError.corruptIndex }
    }
}
