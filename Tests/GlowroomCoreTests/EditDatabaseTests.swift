import CSQLite
import Foundation
import Testing
@testable import GlowroomCore

@Suite("Non-destructive editing database")
final class EditDatabaseTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom O'Brien's edits \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test
    func normalizationClampsEveryControlAndRejectsNonfiniteValues() {
        let settings = EditSettings(exposure: 99, contrast: -999, highlights: 999,
                                    shadows: -.infinity, whites: .nan, blacks: -999,
                                    texture: 999, clarity: -999, dehaze: 999,
                                    vibrance: -999, saturation: 999,
                                    luminanceNoiseReduction: -20, colorNoiseReduction: 200).normalized
        #expect(settings == EditSettings(exposure: 5, contrast: -100, highlights: 100,
                                         shadows: 0, whites: 0, blacks: -100,
                                         texture: 100, clarity: -100, dehaze: 100,
                                         vibrance: -100, saturation: 100,
                                         luminanceNoiseReduction: 0, colorNoiseReduction: 100))
        #expect(EditSettings(exposure: -.infinity, colorNoiseReduction: .nan).isNeutral)
        #expect(EditSettings.neutral.isNeutral)
        #expect(!EditSettings(exposure: 0.1).isNeutral)
    }

    @Test
    func savesSurviveReopenWhileNewestPagesAreStillInWAL() async throws {
        let database = try EditDatabase(directory: root)
        let id = "O'Brien's/image'; DROP TABLE adjustments; --.raw"
        let settings = EditSettings(exposure: 1.25, shadows: 30, luminanceNoiseReduction: 28)
        try await database.save(settings, for: id, revision: 4)
        let wal = URL(fileURLWithPath: database.fileURL.path + "-wal")
        #expect(try wal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 0)
        #expect(try scalarText(database.fileURL, "PRAGMA journal_mode") == "wal")
        let reopened = try EditDatabase(directory: root)
        #expect(try await reopened.loadAll() == [id: settings])
        #expect(try await reopened.revisions() == [id: 4])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.json").path))
    }

    @Test
    func staleAndEqualRevisionsCannotOverwriteNewerSettings() async throws {
        let database = try EditDatabase(directory: root)
        try await database.save(EditSettings(exposure: 2), for: "a", revision: 20)
        await #expect(throws: (any Error).self) { try await database.save(EditSettings(exposure: -2), for: "a", revision: 19) }
        await #expect(throws: (any Error).self) { try await database.save(.neutral, for: "a", revision: 20) }
        try await database.save(EditSettings(exposure: 2), for: "a", revision: 20)
        let reopened = try EditDatabase(directory: root)
        await #expect(throws: (any Error).self) { try await reopened.save(.neutral, for: "a", revision: 10) }
        #expect(try await reopened.loadAll()["a"]?.exposure == 2)
        #expect(try await reopened.revisions()["a"] == 20)
        try await reopened.save(EditSettings(exposure: 200, saturation: .infinity), for: "a", revision: 21)
        #expect(try await reopened.loadAll()["a"] == EditSettings(exposure: 5))
    }

    @Test
    func concurrentArrivalsRetainHighestRevision() async throws {
        let database = try EditDatabase(directory: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 0..<40 {
                group.addTask {
                    do { try await database.save(EditSettings(contrast: Double(revision)), for: "a", revision: Int64(revision)) }
                    catch EditDatabaseError.staleRevision { /* Out-of-order conflicts are expected. */ }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await database.revisions()["a"] == 39)
        #expect(try await database.loadAll()["a"]?.contrast == 39)
    }

    @Test
    func failedSaveRollsBackRevisionAndSettingsTogether() async throws {
        let database = try EditDatabase(directory: root)
        try await database.save(EditSettings(exposure: 1), for: "existing", revision: 1)
        try sql(database.fileURL, "CREATE TRIGGER reject_edits BEFORE INSERT ON adjustments BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END")
        await #expect(throws: (any Error).self) { try await database.save(EditSettings(exposure: 2), for: "new", revision: 2) }
        #expect(try await database.revisions()["new"] == nil)
        #expect(try await database.loadAll() == ["existing": EditSettings(exposure: 1)])
    }

    @Test
    func backupIsStandaloneVerifiedSnapshotOfLiveWAL() async throws {
        let database = try EditDatabase(directory: root)
        let settings = EditSettings(exposure: 0.75, texture: 14, colorNoiseReduction: 25)
        try await database.save(settings, for: "a", revision: 2)
        let backup = try await database.createBackup()
        #expect(try scalarText(backup, "PRAGMA integrity_check") == "ok")
        #expect(try scalarText(backup, "PRAGMA journal_mode") == "delete")
        #expect(!FileManager.default.fileExists(atPath: backup.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: backup.path + "-shm"))
        try await database.save(.neutral, for: "a", revision: 3)
        let separate = try EditDatabase(directory: root.appendingPathComponent("Restored separately"))
        #expect(try await separate.restoreBackup(from: backup) == ["a": settings])
        #expect(try await database.loadAll() == ["a": .neutral])
        #expect(try FileManager.default.contentsOfDirectory(atPath: database.backupsDirectory.path).allSatisfy { !$0.contains("partial") })
    }

    @Test
    func restoreMakesSafetyBackupAndKeepsRevisionsMonotonicIncludingRemovedAssets() async throws {
        let database = try EditDatabase(directory: root)
        let older = EditSettings(exposure: 1)
        let newer = EditSettings(exposure: 2)
        try await database.save(older, for: "a", revision: 2)
        let backup = try await database.createBackup()
        try await database.save(newer, for: "a", revision: 5)
        try await database.save(newer, for: "b", revision: 7)
        #expect(try await database.restoreBackup(from: backup) == ["a": older])
        #expect(try await database.revisions() == ["a": 6, "b": 8])
        await #expect(throws: (any Error).self) { try await database.save(.neutral, for: "a", revision: 5) }
        await #expect(throws: (any Error).self) { try await database.save(.neutral, for: "b", revision: 7) }
        #expect(try await database.loadAll() == ["a": older])
        let safety = try #require(try await database.backups().first { $0.lastPathComponent.hasPrefix("safety-") })
        #expect(try await database.restoreBackup(from: safety) == ["a": newer, "b": newer])
        #expect(try await database.revisions()["a"] == 7)
        #expect(try await database.revisions()["b"] == 9)
    }

    @Test
    func corruptFutureAndInvalidPayloadBackupsNeverModifyActiveData() async throws {
        let database = try EditDatabase(directory: root)
        let settings = EditSettings(exposure: 1)
        try await database.save(settings, for: "a", revision: 5)
        let valid = try await database.createBackup()
        let corrupt = root.appendingPathComponent("corrupt.sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        let future = root.appendingPathComponent("future.sqlite")
        try FileManager.default.copyItem(at: valid, to: future)
        try sql(future, "PRAGMA user_version=999")
        let invalidPayload = root.appendingPathComponent("invalid-payload.sqlite")
        try FileManager.default.copyItem(at: valid, to: invalidPayload)
        try sql(invalidPayload, "UPDATE adjustments SET settings=x'7b62726f6b656e7d'")
        for invalid in [corrupt, future, invalidPayload] {
            await #expect(throws: (any Error).self) { try await database.restoreBackup(from: invalid) }
            #expect(try await database.loadAll() == ["a": settings])
            #expect(try await database.revisions() == ["a": 5])
            #expect(try await database.backups().count == 1)
        }
    }

    @Test
    func corruptAndFutureActiveDatabasesAreNeverReinitialized() async throws {
        let corruptDirectory = root.appendingPathComponent("Corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corrupt = corruptDirectory.appendingPathComponent("edits.sqlite")
        let bytes = Data("broken database must stay intact".utf8)
        try bytes.write(to: corrupt)
        #expect(throws: (any Error).self) { try EditDatabase(directory: corruptDirectory) }
        #expect(try Data(contentsOf: corrupt) == bytes)

        let valid = try EditDatabase(directory: root)
        let backup = try await valid.createBackup()
        let futureDirectory = root.appendingPathComponent("Future")
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let future = futureDirectory.appendingPathComponent("edits.sqlite")
        try FileManager.default.copyItem(at: backup, to: future)
        try sql(future, "PRAGMA user_version=999")
        let before = try Data(contentsOf: future)
        #expect(throws: (any Error).self) { try EditDatabase(directory: futureDirectory) }
        #expect(try Data(contentsOf: future) == before)
    }

    @Test
    func automaticBackupsAreDailyAndRetainSevenWhileManualFilesRemain() async throws {
        let database = try EditDatabase(directory: root)
        try await database.save(EditSettings(exposure: 1), for: "a", revision: 1)
        let manual = try await database.createBackup()
        for day in 1...10 {
            let old = database.backupsDirectory.appendingPathComponent(String(format: "auto-2001-01-%02d-", day) + UUID().uuidString + ".sqlite")
            try FileManager.default.copyItem(at: manual, to: old)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(day))], ofItemAtPath: old.path)
        }
        let unowned = database.backupsDirectory.appendingPathComponent("auto-important.sqlite")
        try Data("personal file".utf8).write(to: unowned)
        let automatic = try await database.createBackup(automatic: true)
        try await database.save(EditSettings(exposure: 2), for: "a", revision: 2)
        #expect(try await database.createBackup(automatic: true) == automatic)
        let listed = try await database.backups()
        #expect(listed.filter { $0.lastPathComponent.hasPrefix("auto-") }.count == 7)
        #expect(listed.contains(manual))
        #expect(listed.contains(automatic))
        #expect(try String(contentsOf: unowned, encoding: .utf8) == "personal file")
    }

    @Test
    func dailyBackupMemoDetectsDeletedAndChangedFiles() async throws {
        let database = try EditDatabase(directory: root)
        try await database.save(EditSettings(exposure: 1), for: "a", revision: 1)
        let first = try await database.createBackup(automatic: true)
        #expect(try await database.createBackup(automatic: true) == first)
        try FileManager.default.removeItem(at: first)
        let replacement = try await database.createBackup(automatic: true)
        #expect(replacement != first)
        try Data("damaged automatic backup".utf8).write(to: replacement)
        let repaired = try await database.createBackup(automatic: true)
        #expect(repaired != replacement)
        #expect(try scalarText(repaired, "PRAGMA integrity_check") == "ok")
        #expect(try await database.loadAll() == ["a": EditSettings(exposure: 1)])
    }

    @Test
    func failedSafetyBackupPreventsRestoreAndDoesNotDisableSaving() async throws {
        let database = try EditDatabase(directory: root)
        try await database.save(EditSettings(exposure: 1), for: "a", revision: 1)
        let backup = try await database.createBackup()
        let external = root.appendingPathComponent("external-backup.sqlite")
        try FileManager.default.copyItem(at: backup, to: external)
        try FileManager.default.removeItem(at: database.backupsDirectory)
        try Data("directory is unavailable".utf8).write(to: database.backupsDirectory)
        try await database.save(EditSettings(exposure: 2), for: "a", revision: 2)
        await #expect(throws: (any Error).self) { try await database.restoreBackup(from: external) }
        #expect(try await database.loadAll() == ["a": EditSettings(exposure: 2)])
        try await database.save(EditSettings(exposure: 3), for: "a", revision: 3)
        #expect(try await database.loadAll()["a"]?.exposure == 3)
    }

    @Test
    func explicitRecoveryPreservesCorruptDatabaseAndSidecars() async throws {
        let source = try EditDatabase(directory: root.appendingPathComponent("Source"))
        let settings = EditSettings(exposure: 1.5, shadows: 24)
        try await source.save(settings, for: "a", revision: 7)
        let backup = try await source.createBackup()
        let target = root.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = Data("corrupt original database".utf8)
        let wal = Data("unreadable original WAL".utf8)
        let shm = Data("unreadable original SHM".utf8)
        try original.write(to: target.appendingPathComponent("edits.sqlite"))
        try wal.write(to: target.appendingPathComponent("edits.sqlite-wal"))
        try shm.write(to: target.appendingPathComponent("edits.sqlite-shm"))
        let catalog = Data("catalog is not part of recovery".utf8)
        try catalog.write(to: target.appendingPathComponent("catalog.json"))

        let recovered = try EditDatabase.recoverDatabase(in: target, from: backup)
        #expect(try await recovered.loadAll() == ["a": settings])
        #expect(try await recovered.revisions() == ["a": 7])
        let archive = try #require(FileManager.default.contentsOfDirectory(at: target.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: archive.appendingPathComponent("edits.sqlite")) == original)
        #expect(try Data(contentsOf: archive.appendingPathComponent("edits.sqlite-wal")) == wal)
        #expect(try Data(contentsOf: archive.appendingPathComponent("edits.sqlite-shm")) == shm)
        #expect(try Data(contentsOf: target.appendingPathComponent("catalog.json")) == catalog)
        try await recovered.save(EditSettings(exposure: 2), for: "a", revision: 8)
        #expect(try await recovered.loadAll()["a"]?.exposure == 2)
    }

    @Test
    func invalidRecoveryCandidateAndHealthyActiveDatabaseRemainUntouched() async throws {
        let healthy = try EditDatabase(directory: root)
        let settings = EditSettings(exposure: 2)
        try await healthy.save(settings, for: "a", revision: 3)
        let backup = try await healthy.createBackup()
        #expect(throws: (any Error).self) { try EditDatabase.recoverDatabase(in: root, from: backup) }
        #expect(try await healthy.loadAll() == ["a": settings])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery").path))

        let broken = root.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let original = Data("preserve broken bytes".utf8)
        let active = broken.appendingPathComponent("edits.sqlite")
        try original.write(to: active)
        let invalid = root.appendingPathComponent("invalid.sqlite")
        try Data("bad backup".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try EditDatabase.recoverDatabase(in: broken, from: invalid) }
        #expect(try Data(contentsOf: active) == original)
        #expect(!FileManager.default.fileExists(atPath: broken.appendingPathComponent("Recovery").path))
    }

    private func sql(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw TestDatabaseError.sqlite
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw TestDatabaseError.sqlite }
    }

    private func scalarText(_ url: URL, _ query: String) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw TestDatabaseError.sqlite
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw TestDatabaseError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw TestDatabaseError.sqlite }
        return String(cString: text)
    }
}

private enum TestDatabaseError: Error { case sqlite }
