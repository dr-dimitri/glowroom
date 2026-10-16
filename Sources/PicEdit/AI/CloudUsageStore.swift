import Foundation
import CSQLite
import Darwin

/// Short SQLite transactions serialize reservations across actors and processes.
/// No content, asset identity, key, or source hash is stored in this database.
actor CloudUsageStore {
    struct Reservation: Sendable { let id: UUID }
    struct Summary: Equatable, Sendable {
        let requestCount: Int
        let dispatchedCount: Int
        let inputTokens: Int64
        let outputTokens: Int64
        let chargedNanodollars: Int64
        let uncertainCount: Int
    }
    static let reservationNanodollars: Int64 = 600_000_000
    nonisolated let url: URL
    private let now: @Sendable () -> Date
    private let beforeInitialization: @Sendable () throws -> Void
    private var db: OpaquePointer?
    private var ownershipDescriptor: Int32 = -1
    private static let applicationID: Int32 = 0x50494355 // PICU, distinct from the edit database
    private static let schemaVersion: Int32 = 1
    private static let schema = """
    CREATE TABLE cloud_usage(id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL, period TEXT NOT NULL,
    state TEXT NOT NULL, amount INTEGER NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0, maximum_output INTEGER NOT NULL, pricing TEXT NOT NULL)
    """
    init(url: URL, now: @escaping @Sendable () -> Date = { Date() },
         beforeInitialization: @escaping @Sendable () throws -> Void = {}) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw AICloudError.persistence }
        self.url = url; self.now = now; self.beforeInitialization = beforeInitialization
    }
    private func openIfNeeded() throws {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw AICloudError.persistence }
        // Foundation may retain macOS /var aliases after resolving symlinks.
        // realpath resolves only the existing parent; the final database name
        // remains subject to lstat/O_NOFOLLOW/SQLITE_OPEN_NOFOLLOW checks.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw AICloudError.persistence }
        defer { free(parent) }
        let url = URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent)
        if let db {
            try Self.checkFile(ownershipDescriptor, url: url, connection: db)
            if sqlite3_get_autocommit(db) != 0 { try Self.checkSidecars(url) }
            return
        }
        try Self.checkSidecars(url)
        // SQLite's CREATE flag does not provide O_EXCL. Create our own new
        // inode explicitly; an existing empty/foreign file is never initialized.
        var created = false
        var descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 { created = true }
        else {
            guard errno == EEXIST else { throw AICloudError.persistence }
            descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw AICloudError.persistence }
        }
        var retained = false
        defer {
            if !retained {
                if created { Self.removeEmptyCreatedFile(descriptor, url: url) }
                Darwin.close(descriptor)
            }
        }
        try Self.checkFile(descriptor, url: url)
        if !created {
            // Header checks use only pread: even a read-only SQLite open may
            // otherwise touch/recover sidecars before rejecting a foreign DB.
            try Self.checkHeader(descriptor)
            try Self.checkSidecars(url)
            let readOnly = try Self.openDatabase(url, flags: SQLITE_OPEN_READONLY)
            defer { sqlite3_close(readOnly) }
            try Self.checkFile(descriptor, url: url, connection: readOnly)
            try Self.validate(readOnly)
        }
        let connection = try Self.openDatabase(url, flags: SQLITE_OPEN_READWRITE)
        var opened = false
        defer { if !opened { sqlite3_close(connection) } }
        try Self.checkFile(descriptor, url: url, connection: connection)
        if created {
            try beforeInitialization()
            let initialization = """
            PRAGMA synchronous=FULL;
            BEGIN IMMEDIATE;
            \(Self.schema);
            PRAGMA application_id=\(Self.applicationID);
            PRAGMA user_version=\(Self.schemaVersion);
            COMMIT;
            """
            guard sqlite3_exec(connection, initialization, nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
                throw AICloudError.persistence
            }
        }
        // Revalidate the writable handle before any configuration or row write.
        try Self.validate(connection)
        try Self.checkFile(descriptor, url: url, connection: connection)
        guard sqlite3_exec(connection, "PRAGMA synchronous=FULL", nil, nil, nil) == SQLITE_OK,
              fchmod(descriptor, 0o600) == 0 else { throw AICloudError.persistence }
        db = connection; ownershipDescriptor = descriptor
        opened = true; retained = true
    }
    /// Never remove an existing file or a possibly committed/recoverable DB.
    private static func removeEmptyCreatedFile(_ descriptor: Int32, url: URL) {
        do { try checkFile(descriptor, url: url); try checkSidecars(url) }
        catch { return }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_size == 0 else { return }
        _ = unlink(url.path)
    }
    private static func openDatabase(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let connection else { sqlite3_close(connection); throw AICloudError.persistence }
        sqlite3_busy_timeout(connection, 5_000)
        return connection
    }
    private static func checkFile(_ descriptor: Int32, url: URL, connection: OpaquePointer? = nil) throws {
        var pinned = stat(), current = stat()
        guard descriptor >= 0, fstat(descriptor, &pinned) == 0, lstat(url.path, &current) == 0,
              pinned.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
              pinned.st_nlink == 1, current.st_nlink == 1,
              pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino else { throw AICloudError.persistence }
        if let connection {
            var moved: Int32 = 0
            guard sqlite3_file_control(connection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK,
                  moved == 0 else { throw AICloudError.persistence }
        }
    }
    private static func checkSidecars(_ url: URL) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            var sidecar = stat()
            let result = lstat(url.path + suffix, &sidecar)
            guard result != 0, errno == ENOENT else { throw AICloudError.persistence }
        }
    }
    private static func checkHeader(_ descriptor: Int32) throws {
        var header = [UInt8](repeating: 0, count: 100)
        let count = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        func integer(_ offset: Int) -> UInt32 {
            header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard count == header.count, Array(header.prefix(16)) == Array("SQLite format 3\0".utf8),
              header[18] == 1, header[19] == 1,
              integer(60) == UInt32(schemaVersion), integer(68) == UInt32(applicationID) else { throw AICloudError.persistence }
    }
    private static func rows(_ connection: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AICloudError.persistence }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw AICloudError.persistence }
            try body(statement)
        }
    }
    private static func text(_ statement: OpaquePointer, _ index: Int32, maximum: Int) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT else { throw AICloudError.persistence }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count <= maximum,
              let bytes = sqlite3_column_text(statement, index),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { throw AICloudError.persistence }
        return value
    }
    private static func validate(_ connection: OpaquePointer) throws {
        for (sql, expected) in [("PRAGMA application_id", applicationID), ("PRAGMA user_version", schemaVersion)] {
            var matched = false
            try rows(connection, sql) { statement in matched = sqlite3_column_int64(statement, 0) == Int64(expected) }
            guard matched else { throw AICloudError.persistence }
        }
        var integrityRows = 0
        try rows(connection, "PRAGMA quick_check") { statement in
            guard try text(statement, 0, maximum: 512) == "ok" else { throw AICloudError.persistence }
            integrityRows += 1
        }
        guard integrityRows == 1 else { throw AICloudError.persistence }
        func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var tables = 0, indexes = 0
        try rows(connection, "SELECT type,name,tbl_name,sql FROM sqlite_schema") { statement in
            let kind = try text(statement, 0, maximum: 16), name = try text(statement, 1, maximum: 64)
            guard try text(statement, 2, maximum: 64) == "cloud_usage" else { throw AICloudError.persistence }
            if kind == "table", name == "cloud_usage" {
                guard normalized(try text(statement, 3, maximum: 4_096)) == normalized(schema) else { throw AICloudError.persistence }
                tables += 1
            } else {
                guard kind == "index", name == "sqlite_autoindex_cloud_usage_1",
                      sqlite3_column_type(statement, 3) == SQLITE_NULL else { throw AICloudError.persistence }
                indexes += 1
            }
        }
        guard tables == 1, indexes == 1 else { throw AICloudError.persistence }
        try rows(connection, "SELECT id,provider,period,state,amount,input_tokens,output_tokens,maximum_output,pricing FROM cloud_usage") { statement in
            let id = try text(statement, 0, maximum: 36), provider = try text(statement, 1, maximum: 16)
            let period = try text(statement, 2, maximum: 7), state = try text(statement, 3, maximum: 16)
            let pricing = try text(statement, 8, maximum: 64)
            guard id.count == 36, UUID(uuidString: id)?.uuidString == id, provider == "anthropic",
                  period.range(of: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
                  ["reserved","dispatched","uncertain","settled"].contains(state),
                  pricing == "2026-10-16-haiku5.5-global",
                  (4...7).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }) else { throw AICloudError.persistence }
            let amount = sqlite3_column_int64(statement, 4), input = sqlite3_column_int64(statement, 5)
            let output = sqlite3_column_int64(statement, 6), maximumOutput = sqlite3_column_int64(statement, 7)
            guard (0...1_048_576).contains(input), (1...2_400).contains(maximumOutput), (0...maximumOutput).contains(output),
                  (0...reservationNanodollars).contains(amount) else { throw AICloudError.persistence }
            if state == "settled" {
                let expected = input <= 100_000 ? input * 100 + output * 500 : input * 500 + output * 2_500
                guard amount == expected else { throw AICloudError.persistence }
            } else {
                guard amount == reservationNanodollars, input == 0, output == 0 else { throw AICloudError.persistence }
            }
        }
    }
    deinit {
        sqlite3_close(db)
        if ownershipDescriptor >= 0 { Darwin.close(ownershipDescriptor) }
    }
    private var period: String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month], from: now())
        return String(format: "%04d-%02d", c.year!, c.month!)
    }
    private func execute(_ sql: String) throws {
        try openIfNeeded()
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AICloudError.persistence }
    }
    private func query(_ sql: String, values: [String] = []) throws -> [[Int64]] {
        try openIfNeeded()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw AICloudError.persistence }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            guard value.withCString({ sqlite3_bind_text(statement, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }) == SQLITE_OK else { throw AICloudError.persistence }
        }
        var result: [[Int64]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw AICloudError.persistence }
            result.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) })
        }
    }
    func summary() throws -> Summary {
        try openIfNeeded()
        try Self.validate(db!)
        let row = try query("SELECT COUNT(*),COALESCE(SUM(state!='reserved'),0),COALESCE(SUM(input_tokens),0),COALESCE(SUM(output_tokens),0),COALESCE(SUM(amount),0),COALESCE(SUM(state IN ('dispatched','uncertain')),0) FROM cloud_usage WHERE provider='anthropic' AND period=?", values: [period])[0]
        return Summary(requestCount: Int(row[0]), dispatchedCount: Int(row[1]), inputTokens: row[2], outputTokens: row[3], chargedNanodollars: row[4], uncertainCount: Int(row[5]))
    }
    func reserve(requestLimit: Int, budgetNanodollars: Int64, maximumOutputTokens: Int) throws -> Reservation {
        guard (1...10_000).contains(requestLimit), (1...2_400).contains(maximumOutputTokens), budgetNanodollars >= Self.reservationNanodollars,
              budgetNanodollars <= 1_000_000_000_000 else { throw AICloudError.limitExceeded }
        try execute("BEGIN IMMEDIATE")
        do {
            let used = try summary()
            guard used.requestCount < requestLimit, used.chargedNanodollars <= budgetNanodollars - Self.reservationNanodollars else { throw AICloudError.limitExceeded }
            let id = UUID()
            _ = try query("INSERT INTO cloud_usage(id,provider,period,state,amount,maximum_output,pricing) VALUES(?,'anthropic',?,'reserved',600000000,?,'2026-10-16-haiku5.5-global')", values: [id.uuidString,period,String(maximumOutputTokens)])
            try execute("COMMIT")
            return Reservation(id: id)
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func markDispatched(id: UUID) throws {
        _ = try query("UPDATE cloud_usage SET state='dispatched' WHERE id=? AND state='reserved'", values: [id.uuidString])
        guard sqlite3_changes(db) == 1 else { throw AICloudError.persistence }
    }
    func releaseUndispatched(id: UUID) throws {
        _ = try query("DELETE FROM cloud_usage WHERE id=? AND state='reserved'", values: [id.uuidString])
    }
    /// Caller proves the operation has never been resumed, even if dispatch intent was persisted.
    func releaseBeforeResume(id: UUID) throws {
        _ = try query("DELETE FROM cloud_usage WHERE id=? AND state IN ('reserved','dispatched')", values: [id.uuidString])
    }
    func markUncertain(id: UUID) throws {
        _ = try query("UPDATE cloud_usage SET state='uncertain' WHERE id=? AND state='dispatched'", values: [id.uuidString])
    }
    func settle(id: UUID, inputTokens: Int64, outputTokens: Int64) throws {
        guard (0...1_048_576).contains(inputTokens), (0...2_400).contains(outputTokens) else { throw AICloudError.invalidResponse }
        let price = inputTokens <= 100_000 ? inputTokens * 100 + outputTokens * 500 : inputTokens * 500 + outputTokens * 2_500
        _ = try query("UPDATE cloud_usage SET state='settled',amount=?,input_tokens=?,output_tokens=? WHERE id=? AND state IN ('dispatched','uncertain') AND maximum_output>=?", values: [String(price),String(inputTokens),String(outputTokens),id.uuidString,String(outputTokens)])
        guard sqlite3_changes(db) == 1 else { throw AICloudError.invalidResponse }
    }
}
