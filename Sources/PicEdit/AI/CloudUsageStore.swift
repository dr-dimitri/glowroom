import Foundation
import CSQLite

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
    private var db: OpaquePointer?
    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard url.isFileURL else { throw AICloudError.persistence }
        self.url = url; self.now = now
    }
    private func openIfNeeded() throws {
        guard db == nil else { return }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw AICloudError.persistence }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(connection); throw AICloudError.persistence
        }
        db = connection
        sqlite3_busy_timeout(connection, 5_000)
        let sql = """
        PRAGMA journal_mode=DELETE;
        CREATE TABLE IF NOT EXISTS cloud_usage(id TEXT PRIMARY KEY, provider TEXT NOT NULL, period TEXT NOT NULL,
        state TEXT NOT NULL, amount INTEGER NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0, maximum_output INTEGER NOT NULL, pricing TEXT NOT NULL);
        """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection); db = nil; throw AICloudError.persistence
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
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
