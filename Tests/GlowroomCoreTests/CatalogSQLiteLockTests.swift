import CSQLite
import Darwin
import Foundation
import Testing
@testable import GlowroomCore

@Suite("Catalog native descriptors preserve SQLite locks", .serialized, .timeLimit(.minutes(1)))
struct CatalogSQLiteLockTests {
    @Test(arguments: ["catalog.json", "catalog-write.lock"], [false, true])
    func rejectedAliasPreservesRealEditingWriter(leaf: String, raced: Bool) async throws {
        let fixture = try EditingFixture()
        let previous = try await fixture.save(exposure: 0.5)
        let catalog = CatalogRepository(directory: fixture.directory)
        let stage = try catalog.stage(catalog.prepare(LibraryCatalog()))
        defer { catalog.discard(stage) }
        let checkpoint = CatalogSQLiteCheckpoint()
        let writer = EditingRepository(directory: fixture.directory, artifacts: fixture.artifacts,
            packages: fixture.packages, gate: fixture.gate, hooks: .init(beforeCommit: {
                // This hook runs inside the actual synchronous SQL transaction.
                // Only the sqlite3 CHILD opens another SQLite connection; a
                // parent-side Data(contentsOf:) would invalidate this proof.
                checkpoint.enter()
                try checkCatalogRejection(leaf: leaf, raced: raced, main: fixture.repository.fileURL,
                                          catalog: catalog, stage: stage)
            }))
        let next = try EditingSnapshot(settings: EditSettings(exposure: 2))
        let committed: StoredEditingState?
        do {
            committed = try await writer.saveSnapshot(next, for: fixture.id, expected: .init(previous), revision: 2)
        } catch EditingRepositoryError.storageFailure { committed = nil }
        #expect(checkpoint.entered)

        let fresh = fixture.reopen()
        if let committed {
            #expect(committed.snapshot == next)
            #expect(committed.version == (try EditingStoreVersion(storeEpoch: previous.version.storeEpoch, revision: 2)))
            #expect(try await fresh.loadState().byAsset[fixture.id] == committed)
            #expect(try catalogExternalSQLiteCanBegin(fixture.repository.fileURL, phase: "writer-committed"))
        } else {
            // macOS SQLite can reject COMMIT with SQLITE_IOERR_VNODE after
            // even a temporary hardlink. Require exact rollback or preserved,
            // repeatable recovery, never infer success from the hook returning.
            do {
                #expect(try await fresh.loadState().byAsset[fixture.id] == previous)
                #expect(try catalogExternalSQLiteCanBegin(fixture.repository.fileURL, phase: "writer-returned"))
            } catch EditingRepositoryError.recoveryRequired {
                let family = try catalogSQLiteFamilyAfterWriterReturned(fixture.repository.fileURL)
                #expect(family["edits.sqlite"] != nil)
                await #expect(throws: EditingRepositoryError.recoveryRequired) { _ = try await fixture.reopen().loadState() }
                #expect(try catalogSQLiteFamilyAfterWriterReturned(fixture.repository.fileURL) == family)
            }
        }
    }

    @Test(arguments: ["catalog.json", "catalog-write.lock"])
    func stableHardlinkNeverOpensAnUnregisteredSQLiteMain(leaf: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Catalog-SQLite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("unregistered.sqlite")
        let catalog = CatalogRepository(directory: directory)
        let stage = try catalog.stage(catalog.prepare(LibraryCatalog()))
        defer { catalog.discard(stage) }
        var pointer: OpaquePointer?
        defer { sqlite3_close(pointer) }
        try #require(sqlite3_open_v2(main.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        let db = try #require(pointer)
        try catalogSQLiteExec(db, "CREATE TABLE payload(value INTEGER NOT NULL);INSERT INTO payload VALUES(7)")
        let before = try Data(contentsOf: main)
        // No registry scope: preflight must reject the alias without ever
        // opening it. BEGIN IMMEDIATE itself holds a real kernel write lock.
        try catalogSQLiteExec(db, "BEGIN IMMEDIATE")
        do {
            try checkCatalogRejection(leaf: leaf, raced: false, main: main, catalog: catalog, stage: stage)
            try catalogSQLiteExec(db, "ROLLBACK")
        } catch { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
        #expect(try catalogExternalSQLiteCanBegin(main, phase: "unregistered-returned"))
        #expect(try Data(contentsOf: main) == before)
    }
}

private func checkCatalogRejection(leaf: String, raced: Bool, main: URL,
                                   catalog: CatalogRepository, stage: StagedLibraryCatalog) throws {
    let alias = catalog.directory.appendingPathComponent(leaf)
    defer { _ = unlink(alias.path) }
    #expect(try catalogExternalSQLiteCanBegin(main, phase: "\(leaf)-parent-held") == false)
    let createAlias = { try #require(link(main.path, alias.path) == 0) }
    if !raced { try createAlias() }
    if leaf == "catalog.json" {
        if raced {
            #expect(throws: CatalogRepositoryError.self) {
                _ = try CatalogFileIO.readCatalog(directory: catalog.directory, beforeOpen: createAlias)
            }
        } else {
            #expect(throws: CatalogRepositoryError.self) { _ = try catalog.loadStored() }
        }
    } else if raced {
        #expect(throws: CatalogRepositoryError.self) {
            try CatalogFileIO.withPublicationLock(directory: catalog.directory, beforeLockOpen: createAlias) { _ in
                Issue.record("A substituted SQLite alias must never enter the catalog publication lock")
            }
        }
    } else {
        #expect(throws: CatalogRepositoryError.self) { try catalog.publish(stage, expected: .absent) }
    }
    #expect(try catalogExternalSQLiteCanBegin(main, phase: "\(leaf)-rejected") == false)
    try #require(unlink(alias.path) == 0)
    #expect(try catalogExternalSQLiteCanBegin(main, phase: "\(leaf)-alias-removed") == false)
}

private final class CatalogSQLiteCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func enter() { lock.withLock { didEnter = true } }
}

private func catalogSQLiteExec(_ db: OpaquePointer, _ sql: String) throws {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw CatalogSQLiteProbeFailure(phase: sql, status: result, output: String(cString: sqlite3_errmsg(db)))
    }
}

private func catalogExternalSQLiteCanBegin(_ url: URL, phase: String) throws -> Bool {
    let process = Process(), output = Pipe(), ended = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    // Do not run user ~/.sqliterc. Process exit rolls back a successful BEGIN;
    // adding ROLLBACK to the command can hide BEGIN's busy diagnostic.
    process.arguments = ["-batch", "-init", "/dev/null", "-cmd", ".timeout 0", url.path, "BEGIN IMMEDIATE;"]
    process.standardOutput = output; process.standardError = output
    process.terminationHandler = { _ in ended.signal() }
    try process.run()
    guard ended.wait(timeout: .now() + 5) == .success else {
        process.terminate(); process.waitUntilExit()
        throw CatalogSQLiteProbeFailure(phase: phase, status: process.terminationStatus, output: "sqlite3 child timed out")
    }
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus == 0 { return true }
    let text = String(decoding: bytes.prefix(65_536), as: UTF8.self)
    guard text.contains("database is locked") else {
        throw CatalogSQLiteProbeFailure(phase: phase, status: process.terminationStatus, output: text)
    }
    return false
}

private struct CatalogSQLiteProbeFailure: Error, CustomStringConvertible {
    let phase: String, status: Int32, output: String
    var description: String { "Catalog SQLite probe \(phase), status=\(status): \(output)" }
}

private func catalogSQLiteFamilyAfterWriterReturned(_ url: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    // This helper is used only AFTER the actual save returned, with no SQL
    // owner still running. Reading these bytes during the hook is forbidden.
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let file = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: file.path) { result[file.lastPathComponent] = try Data(contentsOf: file) }
    }
    return result
}
