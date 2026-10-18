import CSQLite
import Foundation

public enum EditDatabaseError: LocalizedError {
    case sqlite(operation: String, code: Int32, message: String)
    case unsupportedVersion(Int)
    case invalidDatabase(String)
    case invalidAssetID
    case invalidRevision
    case staleRevision(assetID: String, current: Int64, attempted: Int64)
    case invalidBackup(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(_, _, let message): return "Die Bearbeitungsdatenbank konnte nicht verarbeitet werden: \(message)"
        case .unsupportedVersion(let version): return "Die Bearbeitungsdatenbank verwendet die nicht unterstützte Version \(version)."
        case .invalidDatabase(let reason): return "Die Bearbeitungsdatenbank ist ungültig: \(reason) Die vorhandene Datei bleibt erhalten."
        case .invalidAssetID: return "Die Bildkennung ist ungültig."
        case .invalidRevision: return "Die Änderungsversion ist ungültig oder ausgeschöpft."
        case .staleRevision: return "Für dieses Bild sind bereits neuere oder abweichende Änderungen gespeichert. Bitte die Bibliothek neu laden, bevor du weiter bearbeitest."
        case .invalidBackup(let reason): return "Die Sicherung konnte nicht wiederhergestellt werden: \(reason)"
        }
    }
}

/// A separate transactional store for non-destructive adjustments. Photo files
/// and catalog.json are deliberately outside this database's responsibility.
public actor EditDatabase {
    public nonisolated let fileURL: URL
    public nonisolated let backupsDirectory: URL
    private let connection: EditSQLiteConnection
    private struct AutomaticBackup {
        let day: String
        let url: URL
        let size: Int
        let modifiedAt: Date
    }
    private var automaticBackup: AutomaticBackup?
    private static let schemaVersion: Int32 = 1
    private static let applicationID: Int32 = 0x50494345

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw EditDatabaseError.invalidDatabase("Kein lokales Datenverzeichnis.") }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        fileURL = directory.appendingPathComponent("edits.sqlite")
        backupsDirectory = directory.appendingPathComponent("EditBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if exists {
            // Validate before enabling WAL or running any mutating SQL. In
            // particular an empty/corrupt existing file is never reinitialized.
            let readOnly = try EditSQLiteConnection(url: fileURL, readOnly: true)
            try Self.validate(readOnly)
        }
        let opened = try EditSQLiteConnection(url: fileURL, readOnly: false, create: !exists)
        try opened.execute("PRAGMA journal_mode=WAL")
        try opened.execute("PRAGMA synchronous=FULL")
        try opened.execute("PRAGMA foreign_keys=ON")
        if !exists {
            try opened.transaction {
                try opened.execute("CREATE TABLE IF NOT EXISTS edit_revisions (asset_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision >= 0))")
                try opened.execute("CREATE TABLE IF NOT EXISTS adjustments (asset_id TEXT PRIMARY KEY NOT NULL REFERENCES edit_revisions(asset_id), settings BLOB NOT NULL, updated_at REAL NOT NULL)")
                try opened.execute("PRAGMA application_id=\(Self.applicationID)")
                try opened.execute("PRAGMA user_version=\(Self.schemaVersion)")
            }
        }
        try Self.validate(opened)
        connection = opened
    }

    public func loadAll() throws -> [String: EditSettings] { try Self.readSettings(connection) }

    /// Includes revision tombstones for assets removed by a restored snapshot.
    public func revisions() throws -> [String: Int64] { try Self.readRevisions(connection) }

    /// Equal revisions are idempotent only for identical settings. Conflicting
    /// writers receive an explicit error rather than a false success signal.
    public func save(_ settings: EditSettings, for assetID: String, revision: Int64) throws {
        try Self.validateID(assetID)
        guard revision >= 0 else { throw EditDatabaseError.invalidRevision }
        try settings.normalized.validateLocalAdjustments()
        let payload = try JSONEncoder().encode(settings.normalized)
        guard payload.count <= EditSettings.maximumEncodedBytes else { throw ArtifactContractError.limitExceeded }
        try connection.transaction {
            try connection.statement("INSERT INTO edit_revisions(asset_id,revision) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET revision=excluded.revision WHERE excluded.revision > edit_revisions.revision") { statement in
                try connection.bind(assetID, at: 1, to: statement)
                try connection.check(sqlite3_bind_int64(statement, 2, revision), operation: "bind revision")
                try connection.stepDone(statement)
            }
            guard sqlite3_changes(connection.handle) > 0 else {
                try connection.statement("SELECT r.revision,a.settings FROM edit_revisions r LEFT JOIN adjustments a ON a.asset_id=r.asset_id WHERE r.asset_id=?") { statement in
                    try connection.bind(assetID, at: 1, to: statement)
                    guard try connection.next(statement) else { throw EditDatabaseError.invalidRevision }
                    let current = sqlite3_column_int64(statement, 0)
                    if current == revision, let bytes = sqlite3_column_blob(statement, 1) {
                        let saved = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                        if let previous = try? JSONDecoder().decode(EditSettings.self, from: saved), previous == settings.normalized { return }
                    }
                    throw EditDatabaseError.staleRevision(assetID: assetID, current: current, attempted: revision)
                }
                return
            }
            try Self.writeSettings(payload, assetID: assetID, to: connection)
        }
    }

    public func createBackup(automatic: Bool = false) throws -> URL {
        let day = Self.dayStamp()
        if automatic {
            if let cached = automaticBackup, cached.day == day,
               let current = Self.backupFingerprint(cached.url, day: day),
               current.size == cached.size, current.modifiedAt == cached.modifiedAt { return cached.url }
            for backup in try backups() where backup.lastPathComponent.hasPrefix("auto-\(day)-") {
                if let existing = try? EditSQLiteConnection(url: backup, readOnly: true),
                   (try? Self.validate(existing)) != nil {
                    automaticBackup = Self.backupFingerprint(backup, day: day)
                    return backup
                }
            }
        }
        let result = try makeBackup(prefix: automatic ? "auto" : "manual", day: day)
        if automatic {
            automaticBackup = Self.backupFingerprint(result, day: day)
            pruneAutomaticBackups()
        }
        return result
    }

    private nonisolated static func backupFingerprint(_ url: URL, day: String) -> AutomaticBackup? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let modifiedAt = values.contentModificationDate else { return nil }
        return AutomaticBackup(day: day, url: url, size: size, modifiedAt: modifiedAt)
    }

    public func backups() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            .map { backupsDirectory.appendingPathComponent($0.lastPathComponent) }
            .filter { Self.isOwnedBackup($0, directory: backupsDirectory) }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
            }
    }

    public func restoreBackup(from url: URL) throws -> [String: EditSettings] {
        guard url.isFileURL, url.standardizedFileURL.path != fileURL.standardizedFileURL.path else {
            throw EditDatabaseError.invalidBackup("Bitte eine abgeschlossene Sicherung auswählen.")
        }
        let backup = try EditSQLiteConnection(url: url, readOnly: true)
        try Self.validate(backup)
        let restored = try Self.readSettings(backup)
        let backupRevisions = try Self.readRevisions(backup)
        // Only a fully checked backup can reach this point. If the safety
        // snapshot cannot be completed, leave the active adjustments untouched.
        _ = try makeBackup(prefix: "safety", day: Self.dayStamp())
        try connection.transaction {
            let currentRevisions = try Self.readRevisions(connection)
            var nextRevisions: [String: Int64] = [:]
            for id in Set(currentRevisions.keys).union(backupRevisions.keys) {
                let previous = max(currentRevisions[id] ?? -1, backupRevisions[id] ?? -1)
                guard previous < Int64.max else { throw EditDatabaseError.invalidRevision }
                nextRevisions[id] = previous + 1
            }
            try connection.execute("DELETE FROM adjustments")
            for (id, revision) in nextRevisions {
                try connection.statement("INSERT INTO edit_revisions(asset_id,revision) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET revision=excluded.revision") { statement in
                    try connection.bind(id, at: 1, to: statement)
                    try connection.check(sqlite3_bind_int64(statement, 2, revision), operation: "bind revision")
                    try connection.stepDone(statement)
                }
            }
            for (id, settings) in restored {
                try Self.writeSettings(JSONEncoder().encode(settings), assetID: id, to: connection)
            }
        }
        return restored
    }

    /// Explicit recovery after initialization failed. The caller must hold no
    /// live EditDatabase for this directory. A healthy database is rejected here
    /// and must instead use its actor's transactional restoreBackup method.
    public nonisolated static func recoverDatabase(in directory: URL, from backupURL: URL) throws -> EditDatabase {
        guard directory.isFileURL, backupURL.isFileURL else { throw EditDatabaseError.invalidBackup("Kein lokaler Dateipfad.") }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let active = directory.appendingPathComponent("edits.sqlite")
        guard active.standardizedFileURL.path != backupURL.standardizedFileURL.path else {
            throw EditDatabaseError.invalidBackup("Die aktive Datenbank ist keine Sicherung.")
        }
        let source = try EditSQLiteConnection(url: backupURL, readOnly: true)
        try validate(source)
        if try existingDatabaseIsHealthyWithoutChangingSidecars(active) {
            throw EditDatabaseError.invalidBackup("Die aktive Datenbank ist lesbar. Bitte die reguläre Wiederherstellung verwenden.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let candidate = directory.appendingPathComponent(".edits-recovery-\(token).sqlite")
        let archive = directory.appendingPathComponent("Recovery/Before-\(token)", isDirectory: true)
        let suffixes = ["", "-wal", "-shm", "-journal"]
        defer {
            for suffix in suffixes { try? FileManager.default.removeItem(atPath: candidate.path + suffix) }
        }
        try copyDatabase(source, to: candidate)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var moved: [(original: URL, saved: URL)] = []
        var installed = false
        do {
            for suffix in suffixes {
                let original = URL(fileURLWithPath: active.path + suffix)
                // Resource lookup includes symlinks; their contents are never
                // followed or rewritten while preserving the original files.
                guard (try? original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])) != nil else { continue }
                let saved = archive.appendingPathComponent("edits.sqlite" + suffix)
                try FileManager.default.moveItem(at: original, to: saved)
                moved.append((original, saved))
            }
            try FileManager.default.moveItem(at: candidate, to: active)
            installed = true
            return try EditDatabase(directory: directory)
        } catch {
            // Put the rejected candidate aside before restoring byte-for-byte
            // originals. Never replace an original with an empty database.
            do {
                if installed {
                    for suffix in suffixes {
                        let file = URL(fileURLWithPath: active.path + suffix)
                        if FileManager.default.fileExists(atPath: file.path) {
                            try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent("Rejected-candidate.sqlite" + suffix))
                        }
                    }
                }
                for item in moved.reversed() { try FileManager.default.moveItem(at: item.saved, to: item.original) }
            } catch {
                throw EditDatabaseError.invalidBackup("Die Originaldaten liegen unverändert unter \(archive.path). Das Zurückverschieben ist fehlgeschlagen.")
            }
            throw error
        }
    }

    private nonisolated static func existingDatabaseIsHealthyWithoutChangingSidecars(_ active: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: active.path) else { return false }
        // Even a read-only SQLite connection can rebuild its shared-memory
        // index. Probe a disposable diagnostic copy of the disconnected store
        // so recovery preserves every original sidecar byte. This copy is never
        // used as a backup or installed as a database.
        let probeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Recovery-Probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        let probe = probeDirectory.appendingPathComponent("edits.sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: active.path + suffix)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw EditDatabaseError.invalidBackup("Die aktive Datenbank enthält unerwartete Dateiverweise.")
            }
            try FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: probe.path + suffix))
        }
        guard let existing = try? EditSQLiteConnection(url: probe, readOnly: true) else { return false }
        return (try? validate(existing)) != nil
    }

    private func makeBackup(prefix: String, day: String) throws -> URL {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let partial = backupsDirectory.appendingPathComponent(".backup-\(token).partial.sqlite")
        let completed = backupsDirectory.appendingPathComponent("\(prefix)-\(day)-\(token).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: partial.path + suffix)
            }
        }
        try Self.copyDatabase(connection, to: partial)
        // The destination connection has closed before the atomic rename.
        try FileManager.default.moveItem(at: partial, to: completed)
        return completed
    }

    private nonisolated static func copyDatabase(_ source: EditSQLiteConnection, to url: URL) throws {
        let destination = try EditSQLiteConnection(url: url, readOnly: false, create: true)
        guard let copy = sqlite3_backup_init(destination.handle, "main", source.handle, "main") else {
            throw destination.error(operation: "start backup")
        }
        var status: Int32 = SQLITE_OK
        let deadline = Date().addingTimeInterval(5)
        repeat {
            status = sqlite3_backup_step(copy, 128)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01) }
        } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && Date() < deadline
        let finished = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE else { throw destination.error(operation: "copy backup", code: status) }
        try destination.check(finished, operation: "finish backup")
        // A completed backup must be a self-contained SQLite file. Never
        // copy an active main file while its newest pages live in a WAL.
        try destination.execute("PRAGMA journal_mode=DELETE")
        try destination.execute("PRAGMA synchronous=FULL")
        try Self.validate(destination)
        try destination.check(sqlite3_db_cacheflush(destination.handle), operation: "flush backup")
    }

    private func pruneAutomaticBackups() {
        guard let automatic = try? backups().filter({ $0.lastPathComponent.hasPrefix("auto-") }) else { return }
        for backup in automatic.dropFirst(7) where Self.isOwnedBackup(backup, directory: backupsDirectory) {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func isOwnedBackup(_ url: URL, directory: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              url.lastPathComponent.range(of: #"^(auto|manual|safety)-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9A-Fa-f-]{36}\.sqlite$"#, options: .regularExpression) != nil,
              UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.suffix(36))) != nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func validate(_ database: EditSQLiteConnection) throws {
        let version = try database.scalarInt("PRAGMA user_version")
        guard version == Int64(schemaVersion) else { throw EditDatabaseError.unsupportedVersion(Int(version)) }
        guard try database.scalarInt("PRAGMA application_id") == Int64(applicationID) else {
            throw EditDatabaseError.invalidDatabase("Die Datei ist keine PicEdit-Bearbeitungsdatenbank.")
        }
        var integrity: [String] = []
        try database.statement("PRAGMA integrity_check") { statement in
            while try database.next(statement) { integrity.append(try database.string(statement, column: 0)) }
        }
        guard integrity == ["ok"] else { throw EditDatabaseError.invalidDatabase("Die Integritätsprüfung ist fehlgeschlagen.") }
        try database.statement("PRAGMA foreign_key_check") { statement in
            guard try !database.next(statement) else { throw EditDatabaseError.invalidDatabase("Ungültige Bildverknüpfung.") }
        }
        let revisions = try readRevisions(database)
        let settings = try readSettings(database)
        guard settings.keys.allSatisfy({ revisions[$0] != nil }) else {
            throw EditDatabaseError.invalidDatabase("Änderungsversionen fehlen.")
        }
    }

    private static func readSettings(_ database: EditSQLiteConnection) throws -> [String: EditSettings] {
        var result: [String: EditSettings] = [:]
        try database.statement("SELECT asset_id,settings FROM adjustments") { statement in
            while try database.next(statement) {
                let id = try database.string(statement, column: 0)
                try validateID(id)
                guard sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                      sqlite3_column_bytes(statement, 1) <= EditSettings.maximumEncodedBytes,
                      let bytes = sqlite3_column_blob(statement, 1) else {
                    throw EditDatabaseError.invalidDatabase("Ungültige Bearbeitungswerte.")
                }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                guard let settings = try? JSONDecoder().decode(EditSettings.self, from: data), settings == settings.normalized else {
                    throw EditDatabaseError.invalidDatabase("Beschädigte Bearbeitungswerte.")
                }
                result[id] = settings
            }
        }
        return result
    }

    private static func readRevisions(_ database: EditSQLiteConnection) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        try database.statement("SELECT asset_id,revision FROM edit_revisions") { statement in
            while try database.next(statement) {
                let id = try database.string(statement, column: 0)
                try validateID(id)
                let revision = sqlite3_column_int64(statement, 1)
                guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER, revision >= 0 else { throw EditDatabaseError.invalidRevision }
                result[id] = revision
            }
        }
        return result
    }

    private static func writeSettings(_ data: Data, assetID: String, to database: EditSQLiteConnection) throws {
        try database.statement("INSERT INTO adjustments(asset_id,settings,updated_at) VALUES(?,?,?) ON CONFLICT(asset_id) DO UPDATE SET settings=excluded.settings,updated_at=excluded.updated_at") { statement in
            try database.bind(assetID, at: 1, to: statement)
            try data.withUnsafeBytes { bytes in
                try database.check(sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), editSQLiteTransient), operation: "bind settings")
            }
            try database.check(sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970), operation: "bind timestamp")
            try database.stepDone(statement)
        }
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty, !id.contains("\0") else { throw EditDatabaseError.invalidAssetID }
    }
}

private let editSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Connections never escape their owning actor or a synchronous backup scope.
private final class EditSQLiteConnection {
    let handle: OpaquePointer

    init(url: URL, readOnly: Bool, create: Bool = false) throws {
        var opened: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
            | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Die Datei konnte nicht geöffnet werden."
            if let opened { sqlite3_close_v2(opened) }
            throw EditDatabaseError.sqlite(operation: "open", code: status, message: message)
        }
        handle = opened
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func error(operation: String, code: Int32? = nil) -> EditDatabaseError {
        .sqlite(operation: operation, code: code ?? sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    func check(_ status: Int32, operation: String) throws {
        guard status == SQLITE_OK else { throw error(operation: operation, code: status) }
    }

    func execute(_ sql: String) throws { try check(sqlite3_exec(handle, sql, nil, nil, nil), operation: sql) }

    func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &prepared, nil), operation: "prepare")
        guard let prepared else { throw EditDatabaseError.invalidDatabase("Leere Datenbankabfrage.") }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }

    func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_text(statement, index, text, -1, editSQLiteTransient), operation: "bind text")
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw error(operation: "read", code: status)
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw error(operation: "write", code: status) }
    }

    func string(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column),
              let value = String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
            throw EditDatabaseError.invalidDatabase("Ungültiger Textwert.")
        }
        return value
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        try statement(sql) { statement in
            guard try next(statement) else { throw EditDatabaseError.invalidDatabase("Fehlender Datenbankwert.") }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
