import CSQLite
import Foundation
import Testing
@testable import PicEditCore

@Suite("Automatic tone persistence and compatibility")
final class AutoTonePersistenceTests {
    private let root: URL

    // Frozen pre-Auto payload. Building it with today's encoder would hide a
    // missing-key migration regression when a new control is introduced.
    private let legacyJSON = Data("""
        {"exposure":0.75,"contrast":12,"highlights":-35,"shadows":28,
         "whites":-8,"blacks":-5,"texture":10,"clarity":6,"dehaze":4,
         "vibrance":9,"saturation":-3,"luminanceNoiseReduction":15,
         "colorNoiseReduction":20}
        """.utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit Auto Tone \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test
    func legacySettingsDefaultOnlyNewControlWithoutChangingExistingEdits() throws {
        let decoded = try JSONDecoder().decode(EditSettings.self, from: legacyJSON)
        #expect(decoded == legacySettings)
        #expect(decoded.autoToneAmount == 0)
        #expect(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    @Test
    func malformedSettingsRemainRejectedInsteadOfSilentlyResettingEdits() throws {
        var object = try #require(JSONSerialization.jsonObject(with: legacyJSON) as? [String: Any])
        object["autoToneAmount"] = "very strong"
        let invalidType = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditSettings.self, from: invalidType) }
        object["autoToneAmount"] = NSNull()
        let nullValue = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditSettings.self, from: nullValue) }
        object.removeValue(forKey: "autoToneAmount")
        object.removeValue(forKey: "exposure")
        let incompleteLegacy = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditSettings.self, from: incompleteLegacy) }
    }

    @Test
    func automaticAmountParticipatesInNormalizationAndSettingsIdentity() {
        var active = EditSettings.neutral
        active.autoToneAmount = 65
        #expect(!active.isNeutral)
        #expect(Set([EditSettings.neutral, active]).count == 2)
        var invalid = active
        invalid.autoToneAmount = 150
        #expect(invalid.normalized.autoToneAmount == 100)
        invalid.autoToneAmount = -1
        #expect(invalid.normalized.isNeutral)
        invalid.autoToneAmount = .nan
        #expect(invalid.normalized.isNeutral)
        invalid.autoToneAmount = .infinity
        #expect(invalid.normalized.isNeutral)
    }

    @Test
    func automaticToneSurvivesWALReopenBackupAndRestore() async throws {
        let database = try EditDatabase(directory: root)
        var settings = legacySettings
        settings.autoToneAmount = 73
        try await database.save(settings, for: "landscape.raw", revision: 7)
        let reopened = try EditDatabase(directory: root)
        #expect(try await reopened.loadAll() == ["landscape.raw": settings])
        let manual = try await reopened.createBackup()
        let automatic = try await reopened.createBackup(automatic: true)
        try await reopened.save(.neutral, for: "landscape.raw", revision: 8)

        #expect(try await reopened.restoreBackup(from: manual) == ["landscape.raw": settings])
        let restored = try EditDatabase(directory: root.appendingPathComponent("Restored automatic backup"))
        #expect(try await restored.restoreBackup(from: automatic) == ["landscape.raw": settings])
        let anotherReopen = try EditDatabase(directory: root)
        #expect(try await anotherReopen.loadAll() == ["landscape.raw": settings])
        #expect(try await anotherReopen.revisions()["landscape.raw"] == 9)
    }

    @Test
    func legacyDatabaseAndBackupOpenAndRestoreWithoutMigrationLoss() async throws {
        let source = try EditDatabase(directory: root.appendingPathComponent("Source"))
        try await source.save(legacySettings, for: "existing.raw", revision: 12)
        let legacyBackup = try await source.createBackup()
        try replaceSettingsPayload(at: legacyBackup, with: legacyJSON)

        let legacyDirectory = root.appendingPathComponent("Existing catalog")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: legacyBackup, to: legacyDirectory.appendingPathComponent("edits.sqlite"))
        let migrated = try EditDatabase(directory: legacyDirectory)
        #expect(try await migrated.loadAll() == ["existing.raw": legacySettings])
        var edited = legacySettings
        edited.autoToneAmount = 80
        try await migrated.save(edited, for: "existing.raw", revision: 13)
        #expect(try await migrated.restoreBackup(from: legacyBackup) == ["existing.raw": legacySettings])
        #expect(try await migrated.revisions()["existing.raw"] == 14)

        let safety = try #require(try await migrated.backups().first { $0.lastPathComponent.hasPrefix("safety-") })
        let safetyReader = try EditDatabase(directory: root.appendingPathComponent("Read safety"))
        #expect(try await safetyReader.restoreBackup(from: safety) == ["existing.raw": edited])
    }

    private var legacySettings: EditSettings {
        EditSettings(exposure: 0.75, contrast: 12, highlights: -35, shadows: 28,
                     whites: -8, blacks: -5, texture: 10, clarity: 6, dehaze: 4,
                     vibrance: 9, saturation: -3, luminanceNoiseReduction: 15,
                     colorNoiseReduction: 20)
    }

    private func replaceSettingsPayload(at url: URL, with data: Data) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw AutoTonePersistenceError.sqlite
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE adjustments SET settings=? WHERE asset_id='existing.raw'", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AutoTonePersistenceError.sqlite }
        defer { sqlite3_finalize(statement) }
        try data.withUnsafeBytes { buffer in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE,
                  sqlite3_changes(handle) == 1 else { throw AutoTonePersistenceError.sqlite }
        }
    }
}

private enum AutoTonePersistenceError: Error { case sqlite }
