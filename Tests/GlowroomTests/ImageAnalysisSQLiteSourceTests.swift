import CSQLite
import Darwin
import Foundation
import Testing
@testable import Glowroom
@testable import GlowroomCore

// Keep these tiny fixtures ordered to bound native child-process launches in
// the otherwise parallel suite; each lock checkpoint must also be sequential.
@Suite("Image source metadata preserves native SQLite locks", .serialized, .timeLimit(.minutes(1)))
struct ImageAnalysisSQLiteSourceTests {
    @Test(arguments: ["hardlink", "symlink"], ["current", "stale-size", "stale-date"])
    func originalAliasCannotReleaseRegisteredParentWriter(aliasKind: String, fingerprintKind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Analysis-SQLite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("synthetic.sqlite")
        let alias = directory.appendingPathComponent("synthetic-source.png")
        var pointer: OpaquePointer?
        try #require(sqlite3_open_v2(main.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        let db = try #require(pointer)
        var parentIsOpen = true
        defer { if parentIsOpen { sqlite3_close(db) } }
        try analysisSQLiteExec(db, "PRAGMA journal_mode=DELETE;CREATE TABLE payload(value INTEGER NOT NULL);INSERT INTO payload VALUES(7)")
        let originalBytes = try Data(contentsOf: main)

        // Register the real parent inode before beginning SQL. This descriptor
        // and the SQLite connection stay alive until the actual rollback; no
        // parent-side content read/close may invalidate the kernel-lock proof.
        let native = try EditingDatabaseAccess.reserveNativeFile()
        let fd = open(main.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        try #require(fd >= 0)
        native.own(fd)
        defer { native.close() }
        let owner = try EditingDatabaseAccess.acquire(fd: fd, url: main)
        defer { owner.release() }
        try analysisSQLiteExec(db, "BEGIN IMMEDIATE;UPDATE payload SET value=8")
        var transactionHeld = true
        defer { if transactionHeld { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        try #require(sqlite3_get_autocommit(db) == 0)
        #expect(try !analysisSQLiteChildCanBegin(main, phase: "parent-held"))

        if aliasKind == "hardlink" { try #require(link(main.path, alias.path) == 0) }
        else { try #require(symlink(main.path, alias.path) == 0) }
        defer { _ = unlink(alias.path) }
        let observed = try #require(MetadataCatalogSourceReader.nativeStamp(alias))
        let modified = Date(timeIntervalSince1970: Double(observed.modifiedAt.seconds) + Double(observed.modifiedAt.nanoseconds) / 1_000_000_000)
        let source = AIOriginalSourceFingerprint(fileURL: alias,
            modifiedAt: fingerprintKind == "stale-date" ? modified.addingTimeInterval(5) : modified,
            fileSize: observed.byteCount + (fingerprintKind == "stale-size" ? 1 : 0))
        let request = ImageAnalysisRequest(snapshot: AIEditingSnapshot(assetID: "synthetic-sqlite-source", source: .original(source),
            settings: .neutral, token: AIEditingToken(editSessionID: UUID(), editGeneration: 0,
                selectionSessionID: UUID(), selectionGeneration: 0)), lifecycleID: UUID())
        try request.validate()
        let analysis = ImageAnalysisPreparer()
        let semantic = SemanticImagePreprocessor()
        let current = fingerprintKind == "current"
        if current {
            let stamp = try await analysis.sourceStamp(for: request)
            guard case .original(let nativeStamp) = stamp else { Issue.record("Expected original native stamp"); return }
            #expect(nativeStamp.inode == observed.identity.inode)
        } else {
            await #expect(throws: ImageAnalysisError.staleSource) { try await analysis.sourceStamp(for: request) }
        }
        #expect(try !analysisSQLiteChildCanBegin(main, phase: "after-analysis-stamp"))
        if current { #expect(try await semantic.sourceStamp(source: source).isEmpty == false) }
        else { await #expect(throws: SemanticEmbeddingError.staleSource) { try await semantic.sourceStamp(source: source) } }
        #expect(try !analysisSQLiteChildCanBegin(main, phase: "after-semantic-stamp"))
        let batch = try await semantic.sourceStamps(sources: [source])
        #expect(batch.count == 1)
        #expect((batch[0] != nil) == current)
        #expect(try !analysisSQLiteChildCanBegin(main, phase: "after-semantic-batch"))
        #expect(sqlite3_get_autocommit(db) == 0)

        try #require(unlink(alias.path) == 0)
        #expect(try !analysisSQLiteChildCanBegin(main, phase: "alias-removed-parent-held"))
        try analysisSQLiteExec(db, "ROLLBACK")
        transactionHeld = false
        #expect(sqlite3_get_autocommit(db) != 0)
        #expect(try analysisSQLiteChildCanBegin(main, phase: "parent-rolled-back"))
        // Apple's VFS can mark an existing handle IOERR_VNODE after a temporary
        // hardlink even when rollback succeeded. Verify persisted contents on
        // a fresh connection after the real parent and its native scope return.
        try #require(sqlite3_close(db) == SQLITE_OK)
        parentIsOpen = false
        owner.release()
        native.close()
        #expect(try Data(contentsOf: main) == originalBytes)
        #expect(try analysisSQLiteStoredValue(main) == 7)
    }
}

private func analysisSQLiteStoredValue(_ url: URL) throws -> Int64 {
    var pointer: OpaquePointer?
    let status = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let db = pointer else {
        sqlite3_close(pointer)
        throw AnalysisSQLiteProbeFailure(phase: "reopen-after-rollback", status: status, output: "Could not reopen synthetic database")
    }
    defer { sqlite3_close(db) }
    do { return try EditingSQLite.scalar(db, "SELECT value FROM payload") }
    catch {
        throw AnalysisSQLiteProbeFailure(phase: "read-after-rollback", status: sqlite3_extended_errcode(db), output: String(cString: sqlite3_errmsg(db)))
    }
}

private func analysisSQLiteExec(_ db: OpaquePointer, _ sql: String) throws {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw AnalysisSQLiteProbeFailure(phase: sql, status: result, output: String(cString: sqlite3_errmsg(db)))
    }
}

/// Only a separate native SQLite process probes the parent's kernel write lock.
/// These dependent checkpoints stay serial; concurrent probes could contend
/// with each other and make a missing parent lock appear to be preserved.
private func analysisSQLiteChildCanBegin(_ url: URL, phase: String) throws -> Bool {
    let process = Process(), output = Pipe(), ended = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-init", "/dev/null", "-batch", "-cmd", ".timeout 0", url.path, "BEGIN IMMEDIATE;"]
    process.standardOutput = output; process.standardError = output
    process.terminationHandler = { _ in ended.signal() }
    try process.run()
    guard ended.wait(timeout: .now() + 5) == .success else {
        process.terminate(); process.waitUntilExit()
        throw AnalysisSQLiteProbeFailure(phase: phase, status: process.terminationStatus, output: "sqlite3 child timed out")
    }
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus == 0 { return true }
    let text = String(decoding: bytes.prefix(65_536), as: UTF8.self)
    guard text.contains("database is locked") else {
        throw AnalysisSQLiteProbeFailure(phase: phase, status: process.terminationStatus, output: text)
    }
    return false
}

private struct AnalysisSQLiteProbeFailure: Error, CustomStringConvertible {
    let phase: String, status: Int32, output: String
    var description: String { "Image source SQLite probe \(phase), status=\(status): \(output)" }
}
