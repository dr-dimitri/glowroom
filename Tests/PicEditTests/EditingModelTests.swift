import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Editing controller", .serialized)
@MainActor
final class EditingModelTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-EditingModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func loadsExistingRevisionsAndDebouncesLatestValuesPerImage() async throws {
        let legacyWasReleased = try await seedClosedLegacyDatabase(in: directory)
        // Observe the real actor lifetime. Closed legacy WAL/SHM files may
        // legitimately remain; only strict migration decides their validity.
        try await waitUntil { legacyWasReleased() }
        let model = EditingModel(directory: directory)
        try await waitLoaded(model)
        #expect(model.settings(for: "A").exposure == 0.5)
        #expect(model.settings(for: "missing").isNeutral)
        for index in 1...20 {
            model.setSettings(exposure(Double(index) / 10), for: "A")
            model.setSettings(exposure(-Double(index) / 10), for: "B")
        }
        #expect(model.hasPendingChanges)
        try await waitUntil { !model.hasPendingChanges && !model.isSaving }
        let stored = try await loadStoredState()
        #expect(stored.byAsset["A"]?.snapshot.settings.exposure == 2)
        #expect(stored.byAsset["B"]?.snapshot.settings.exposure == -2)
        #expect(stored.byAsset["A"]?.version.revision == 60)
        #expect(stored.byAsset["B"]?.version.revision == 20)
        let reloaded = EditingModel(directory: directory)
        try await waitLoaded(reloaded)
        #expect(reloaded.settings(for: "A").exposure == 2)
        #expect(reloaded.settings(for: "B").exposure == -2)
        #expect(!reloaded.canUndo(assetID: "A"))
    }

    @Test
    func dragUndoRedoAndResetRemainIndependentPerImage() async throws {
        let store = ControlledEditStore()
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        model.beginEditing(assetID: "A")
        model.beginEditing(assetID: "A") // Repeated begin must not lose the original value.
        for index in 1...25 { model.setSettings(exposure(Double(index) / 10), for: "A") }
        model.setSettings(exposure(-1), for: "B")
        #expect(model.canUndo(assetID: "A"))
        model.endEditing(assetID: "A")
        model.undo(assetID: "A")
        #expect(model.settings(for: "A").isNeutral)
        #expect(model.settings(for: "B").exposure == -1)
        #expect(!model.canUndo(assetID: "A"))
        #expect(model.canRedo(assetID: "A"))
        model.redo(assetID: "A")
        #expect(model.settings(for: "A").exposure == 2.5)
        model.reset(assetID: "A")
        #expect(model.settings(for: "A").isNeutral)
        model.undo(assetID: "A")
        #expect(model.settings(for: "A").exposure == 2.5)
        model.setSettings(exposure(9), for: "A")
        #expect(model.settings(for: "A").exposure == 5)
        #expect(!model.canRedo(assetID: "A"))
        model.setSettings(exposure(90), for: "A") // The same normalized value is a no-op.
        model.undo(assetID: "A")
        #expect(model.settings(for: "A").exposure == 2.5)
        model.undo(assetID: "B")
        #expect(model.settings(for: "B").isNeutral)
        #expect(await model.flush())
    }

    @Test
    func autoToneKeepsManualEditsAndSupportsGroupedUndoResetAndReload() async throws {
        let model = EditingModel(directory: directory)
        try await waitLoaded(model)
        let manual = EditSettings(exposure: 0.25, highlights: -12, texture: 18, colorNoiseReduction: 20)
        model.setSettings(manual, for: "A")
        var automatic = manual
        automatic.autoToneAmount = 100
        model.setSettings(automatic, for: "A")
        model.beginEditing(assetID: "A")
        for amount in stride(from: 95, through: 55, by: -5) {
            automatic.autoToneAmount = Double(amount)
            model.setSettings(automatic, for: "A")
        }
        model.endEditing(assetID: "A")
        model.undo(assetID: "A")
        #expect(model.settings(for: "A").autoToneAmount == 100)
        model.undo(assetID: "A")
        #expect(model.settings(for: "A") == manual)
        model.redo(assetID: "A")
        model.redo(assetID: "A")
        #expect(model.settings(for: "A") == automatic)
        #expect(model.settings(for: "B").isNeutral)
        model.reset(assetID: "A")
        #expect(model.settings(for: "A").isNeutral)
        model.undo(assetID: "A")
        #expect(model.settings(for: "A") == automatic)
        #expect(await model.flush())
        let reloaded = EditingModel(directory: directory)
        try await waitLoaded(reloaded)
        #expect(reloaded.settings(for: "A") == automatic)
        #expect(reloaded.settings(for: "B").isNeutral)
    }

    @Test
    func naturalBalanceReplacementAndColorGestureShareNormalUndoAndPersistence() async throws {
        let model = EditingModel(directory: directory)
        try await waitLoaded(model)
        let legacy = EditSettings(exposure: 0.25, shadows: 12, autoToneAmount: 63)
        model.setSettings(legacy, for: "A")
        var balance = legacy
        balance.autoToneAmount = 0
        balance.naturalBalanceAmount = 70
        model.setSettings(balance, for: "A")
        model.beginEditing(assetID: "A")
        for color in stride(from: 45, through: 25, by: -5) {
            balance.naturalBalanceColorAmount = Double(color)
            model.setSettings(balance, for: "A")
        }
        model.endEditing(assetID: "A")
        model.undo(assetID: "A")
        #expect(model.settings(for: "A").naturalBalanceColorAmount == 50)
        #expect(model.settings(for: "A").naturalBalanceAmount == 70)
        model.undo(assetID: "A")
        #expect(model.settings(for: "A") == legacy)
        model.redo(assetID: "A")
        model.redo(assetID: "A")
        #expect(model.settings(for: "A") == balance)
        #expect(await model.flush())
        let reopened = EditingModel(directory: directory)
        try await waitLoaded(reopened)
        #expect(reopened.settings(for: "A") == balance)
        #expect(reopened.settings(for: "B").isNeutral)
    }

    @Test
    func concurrentFlushAndCancellationStillPersistEditsArrivingDuringSave() async throws {
        let store = ControlledEditStore()
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        await store.blockNextSave()
        model.setSettings(exposure(1), for: "A")
        let firstFlush = Task { await model.flush() }
        try await waitUntil { await store.isSaveBlocked() }
        model.setSettings(exposure(2), for: "A")
        model.setSettings(exposure(-2), for: "B")
        let secondFlush = Task { await model.flush() }
        firstFlush.cancel()
        await store.releaseSave()
        #expect(await firstFlush.value)
        #expect(await secondFlush.value)
        #expect(await store.savedSettings()["A"]?.exposure == 2)
        #expect(await store.savedSettings()["B"]?.exposure == -2)
        #expect(await store.savedRevisions()["A"] == 2)
        #expect(await store.maximumConcurrentSaves() == 1)
        #expect(!(await store.observedCancellation()))
        #expect(!model.hasPendingChanges)
        #expect(!model.isSaving)
    }

    @Test
    func failedSavePreservesLatestPendingValuesAndExplicitFlushRecovers() async throws {
        let store = ControlledEditStore(failSaveCount: 1)
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        model.setSettings(exposure(1), for: "A")
        model.setSettings(exposure(3), for: "A")
        #expect(!(await model.flush()))
        #expect(model.isReadOnly)
        #expect(!model.canEdit)
        #expect(model.hasPendingChanges)
        #expect(model.errorMessage != nil)
        #expect(model.settings(for: "A").exposure == 3)
        model.setSettings(exposure(4), for: "A")
        #expect(model.settings(for: "A").exposure == 3)
        #expect(await model.flush())
        #expect(!model.isReadOnly)
        #expect(!model.hasPendingChanges)
        #expect(await store.savedSettings()["A"]?.exposure == 3)
        #expect(await store.savedRevisions()["A"] == 2)
    }

    @Test
    func loadingFailureDisablesChangesWithoutReplacingExistingStore() async throws {
        let store = ControlledEditStore(initial: ["A": exposure(2)], failLoad: true)
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        model.setSettings(exposure(1), for: "A")
        try await waitLoaded(model)
        #expect(model.isReadOnly)
        #expect(!model.canEdit)
        #expect(!(await model.flush()))
        model.setSettings(exposure(-2), for: "A")
        #expect(await store.savedSettings()["A"]?.exposure == 2)
        #expect(await store.totalSaveCalls() == 0)
        #expect(model.errorMessage != nil)
    }

    @Test
    func automaticBackupFailureKeepsSuccessfulEditsUsable() async throws {
        let store = ControlledEditStore(failAutomaticBackup: true)
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        model.setSettings(exposure(1), for: "A")
        #expect(await model.flush())
        #expect(!model.hasPendingChanges)
        #expect(model.canEdit)
        #expect(!model.isReadOnly)
        try await waitUntil { model.errorMessage?.contains("automatische Backup") == true }
        #expect(await store.savedSettings()["A"]?.exposure == 1)
        #expect(await model.createBackup() != nil)
        #expect(await store.latestManualBackup()["A"]?.exposure == 1)
    }

    @Test
    func backupFlushesPendingValuesAndRestoreReloadsSettingsAndRevisionHighWater() async throws {
        let model = EditingModel(directory: directory)
        try await waitLoaded(model)
        model.setSettings(exposure(1), for: "A")
        let backup = try #require(await model.createBackup())
        #expect(!model.hasPendingChanges)
        model.setSettings(exposure(2), for: "A")
        model.setSettings(exposure(3), for: "B")
        #expect(await model.restoreBackup(from: backup))
        #expect(model.settings(for: "A").exposure == 1)
        #expect(model.settings(for: "B").isNeutral)
        #expect(!model.canUndo(assetID: "A"))
        #expect(!model.canRedo(assetID: "A"))
        #expect(!model.isRestoring)
        #expect(model.canEdit)
        let revisionsAfterRestore = try await loadStoredState()
        model.setSettings(exposure(4), for: "A")
        model.setSettings(exposure(-1), for: "B")
        #expect(await model.flush())
        let stored = try await loadStoredState()
        #expect(stored.byAsset["A"]?.snapshot.settings.exposure == 4)
        #expect(stored.byAsset["B"]?.snapshot.settings.exposure == -1)
        #expect(stored.byAsset["A"]?.version.revision == (revisionsAfterRestore.byAsset["A"]?.version.revision ?? revisionsAfterRestore.tombstones["A"] ?? 0) + 1)
        #expect(stored.byAsset["B"]?.version.revision == (revisionsAfterRestore.byAsset["B"]?.version.revision ?? revisionsAfterRestore.tombstones["B"] ?? 0) + 1)
    }

    @Test
    func manualBackupLocksEditingUntilPendingSnapshotIsComplete() async throws {
        let store = ControlledEditStore()
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        await store.blockNextSave()
        model.setSettings(exposure(2), for: "A")
        let backup = Task { await model.createBackup() }
        try await waitUntil { await store.isSaveBlocked() }
        #expect(model.isBackingUp)
        #expect(!model.canEdit)
        #expect(!model.canBackUp)
        #expect(!model.canRestore)
        model.setSettings(exposure(4), for: "A")
        await store.releaseSave()
        #expect(await backup.value != nil)
        #expect(await store.latestManualBackup()["A"]?.exposure == 2)
        #expect(model.settings(for: "A").exposure == 2)
        #expect(model.canEdit)
        #expect(!model.isBackingUp)
    }

    @Test
    func backupExportPublishesLatestVerifiedPackageToNewName() async throws {
        let model = EditingModel(directory: directory.appendingPathComponent("catalog"))
        try await waitLoaded(model)
        model.setSettings(exposure(2), for: "A")
        let exported = directory.appendingPathComponent("export.piceditbackup", isDirectory: true)
        #expect(await model.createBackup(exportTo: exported) == exported)
        #expect(model.canEdit)
        #expect(!model.isBackingUp)
        #expect(!model.hasPendingChanges)
        model.setSettings(exposure(3), for: "A")
        #expect(await model.restoreBackup(from: exported))
        #expect(model.settings(for: "A").exposure == 2)
        try await waitUntil {
            let temporaryFiles = try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)
            return temporaryFiles?.contains { $0.hasPrefix(".piceditbackup-") } == false
        }
    }

    @Test
    func backupExportRejectsActiveFilesAndSymlinksWithoutChangingThem() async throws {
        let model = EditingModel(directory: directory)
        try await waitLoaded(model)
        model.setSettings(exposure(2), for: "A")
        #expect(await model.flush())
        let databaseURL = directory.appendingPathComponent("edits.sqlite")
        let catalogURL = directory.appendingPathComponent("catalog.json")
        let catalogBytes = Data("catalog must remain unchanged".utf8)
        try catalogBytes.write(to: catalogURL)
        let databaseBytes = try Data(contentsOf: databaseURL)
        let databaseAlias = directory.appendingPathComponent("database-alias.piceditbackup")
        let catalogAlias = directory.appendingPathComponent("catalog-alias.piceditbackup")
        try FileManager.default.createSymbolicLink(at: databaseAlias, withDestinationURL: databaseURL)
        try FileManager.default.createSymbolicLink(at: catalogAlias, withDestinationURL: catalogURL)

        for target in [databaseURL, databaseAlias, catalogAlias] {
            #expect(await model.createBackup(exportTo: target) == nil)
            #expect(!model.isBackingUp)
            #expect(model.canEdit)
            #expect(model.errorMessage != nil)
            #expect(try Data(contentsOf: databaseURL) == databaseBytes)
            #expect(try Data(contentsOf: catalogURL) == catalogBytes)
        }
        #expect(try await loadStoredState().byAsset["A"]?.snapshot.settings == exposure(2))
    }

    @Test
    func failedExportPreservesLocalBackupAndExistingDestination() async throws {
        let catalogDirectory = directory.appendingPathComponent("catalog")
        let model = EditingModel(directory: catalogDirectory)
        try await waitLoaded(model)
        model.setSettings(exposure(2), for: "A")
        // A published package always uses a new name; an existing foreign tree is preserved.
        let blocked = directory.appendingPathComponent("blocked.piceditbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let marker = blocked.appendingPathComponent("keep.txt")
        try Data("keep me".utf8).write(to: marker)
        #expect(await model.createBackup(exportTo: blocked) == nil)
        #expect(model.canEdit)
        #expect(!model.isBackingUp)
        #expect(model.errorMessage?.contains("lokale Backup bleibt") == true)
        #expect(try String(contentsOf: marker) == "keep me")
        let backups = try FileManager.default.contentsOfDirectory(at: catalogDirectory.appendingPathComponent("EditBackups"), includingPropertiesForKeys: nil)
        let local = try #require(backups.first { $0.lastPathComponent.hasPrefix("manual-") })
        model.setSettings(exposure(3), for: "A")
        #expect(await model.restoreBackup(from: local))
        #expect(model.settings(for: "A").exposure == 2)
        try await waitUntil {
            let temporaryFiles = try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)
            return temporaryFiles?.contains { $0.hasPrefix(".piceditbackup-") } == false
        }
    }

    @Test
    func rejectedBackupKeepsHealthyEditingAndUndoHistoryAvailable() async throws {
        let store = ControlledEditStore(failRestore: true)
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        model.setSettings(exposure(2), for: "A")
        #expect(!(await model.restoreBackup(from: directory.appendingPathComponent("bad.sqlite"))))
        #expect(model.settings(for: "A").exposure == 2)
        #expect(model.canEdit)
        #expect(!model.isReadOnly)
        #expect(model.canUndo(assetID: "A"))
        #expect(model.errorMessage != nil)
        model.undo(assetID: "A")
        #expect(model.settings(for: "A").isNeutral)
        #expect(await model.flush())
    }

    @Test
    func corruptInitialDatabaseCanBeRecoveredWithoutOpeningAnEmptyReplacement() async throws {
        let damaged = directory.appendingPathComponent("damaged", isDirectory: true)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        let databaseURL = damaged.appendingPathComponent("edits.sqlite")
        let originalBytes = Data("a damaged database that must be preserved".utf8)
        try originalBytes.write(to: databaseURL)
        let valid = try EditDatabase(directory: directory.appendingPathComponent("valid"))
        try await valid.save(exposure(2), for: "A", revision: 15)
        let backup = try await valid.createBackup()
        let model = EditingModel(directory: damaged)
        try await waitLoaded(model)
        #expect(model.isReadOnly)
        #expect(!model.canBackUp)
        #expect(model.canRestore)
        #expect(try Data(contentsOf: databaseURL) == originalBytes)

        let invalidBackup = directory.appendingPathComponent("invalid.sqlite")
        try Data("also invalid".utf8).write(to: invalidBackup)
        #expect(!(await model.restoreBackup(from: invalidBackup)))
        #expect(try Data(contentsOf: databaseURL) == originalBytes)
        #expect(model.canRestore)
        #expect(model.isReadOnly)

        #expect(await model.restoreBackup(from: backup))
        #expect(model.settings(for: "A").exposure == 2)
        #expect(model.notice?.contains("Recovery") == true)
        #expect(model.canEdit)
        #expect(model.canBackUp)
        #expect(!model.isReadOnly)
        model.setSettings(exposure(3), for: "A")
        #expect(await model.flush())
        let recovered = try await loadStoredState(in: damaged)
        #expect(recovered.byAsset["A"]?.snapshot.settings.exposure == 3)
        #expect((recovered.byAsset["A"]?.version.revision ?? 0) > 15)
    }

    @Test
    func restoreLocksEditingAndWaitsForCurrentValuesBeforeReplacement() async throws {
        let store = ControlledEditStore(restored: ["A": exposure(-1)])
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        await store.blockNextSave()
        model.setSettings(exposure(2), for: "A")
        let restore = Task { await model.restoreBackup(from: directory.appendingPathComponent("backup.sqlite")) }
        try await waitUntil { await store.isSaveBlocked() }
        #expect(model.isRestoring)
        #expect(!model.canEdit)
        #expect(!model.canBackUp)
        model.setSettings(exposure(4), for: "A")
        await store.releaseSave()
        #expect(await restore.value)
        #expect(await store.settingsBeforeRestore()["A"]?.exposure == 2)
        #expect(model.settings(for: "A").exposure == -1)
        #expect(!model.hasPendingChanges)
        #expect(!model.canUndo(assetID: "A"))
    }

    @Test
    func restoreDoesNotDiscardPendingValuesWhenFlushFails() async throws {
        let store = ControlledEditStore(failSaveCount: 1, restored: ["A": exposure(-1)])
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        model.setSettings(exposure(2), for: "A")
        #expect(!(await model.restoreBackup(from: directory.appendingPathComponent("backup.sqlite"))))
        #expect(model.settings(for: "A").exposure == 2)
        #expect(model.hasPendingChanges)
        #expect(await store.totalRestoreCalls() == 0)
        #expect(!model.isRestoring)
        #expect(await model.flush())
    }

    @Test
    func terminationPreventsLateEditsButStillFlushesAndCanBeCanceled() async throws {
        let store = ControlledEditStore()
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        model.setSettings(exposure(1), for: "A")
        model.beginTermination()
        #expect(model.isClosing)
        #expect(!model.canEdit)
        #expect(!model.canBackUp)
        model.setSettings(exposure(3), for: "A")
        model.reset(assetID: "A")
        model.undo(assetID: "A")
        #expect(await model.flush())
        #expect(await store.savedSettings()["A"]?.exposure == 1)
        model.cancelTermination()
        #expect(model.canEdit)
        model.setSettings(exposure(2), for: "A")
        #expect(await model.flush())
        #expect(await store.savedSettings()["A"]?.exposure == 2)
    }

    @Test
    func terminationFlushWaitsForRestoreToFinishBeforeAllowingQuit() async throws {
        let store = ControlledEditStore(restored: ["A": exposure(2)])
        let model = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitLoaded(model)
        await store.blockNextRestore()
        let restore = Task { await model.restoreBackup(from: directory.appendingPathComponent("backup.sqlite")) }
        try await waitUntil { await store.isRestoreBlocked() }
        model.beginTermination()
        var flushFinished = false
        let flush = Task {
            let result = await model.flush()
            flushFinished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!flushFinished)
        await store.releaseRestore()
        #expect(await restore.value)
        #expect(await flush.value)
        #expect(model.settings(for: "A").exposure == 2)
        #expect(!model.isRestoring)
        #expect(model.isClosing)
    }

    private func loadStoredState(in target: URL? = nil) async throws -> EditingStoreState {
        // Read the actual V2 repository through its production bootstrap rather
        // than reopening the migrated file with the deliberately V1-only API.
        let bootstrap = ArtifactAppBootstrap(directory: target ?? directory)
        let dependencies = try await bootstrap.editingDependencies()
        return try await dependencies.database.loadState()
    }

    private func exposure(_ value: Double) -> EditSettings {
        var settings = EditSettings.neutral
        settings.exposure = value
        return settings
    }

    private func waitLoaded(_ model: EditingModel) async throws {
        try await waitUntil { !model.isLoading }
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw EditingTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// Keep the real legacy actor outside the MainActor test instance and return
// no retained handle, matching the Core migration fixture's orderly shutdown.
private func seedClosedLegacyDatabase(in directory: URL) async throws -> @Sendable () -> Bool {
    let database = try EditDatabase(directory: directory)
    try await database.save(EditSettings(exposure: 0.5), for: "A", revision: 40)
    try #require(try await database.loadAll()["A"]?.exposure == 0.5)
    try #require(try await database.revisions()["A"] == 40)
    // This Sendable token observes ARC only and never retains or calls the
    // actor. The production migration below proves the complete SQL handoff.
    return { [weak database] in database == nil }
}

private enum EditingTestError: Error { case injected, timeout }

private actor ControlledEditStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings]
    private var revisionsByAsset: [String: Int64] = [:]
    private let failLoad: Bool
    private var failSaveCount: Int
    private let failAutomaticBackup: Bool
    private let failRestore: Bool
    private let restored: [String: EditSettings]
    private var blockSave = false
    private var saveGate: CheckedContinuation<Void, Never>?
    private var blockRestore = false
    private var restoreGate: CheckedContinuation<Void, Never>?
    private var activeSaves = 0
    private var maximumSaves = 0
    private var saveCalls = 0
    private var restoreCalls = 0
    private var sawCancellation = false
    private var manualBackup: [String: EditSettings] = [:]
    private var beforeRestore: [String: EditSettings] = [:]

    init(initial: [String: EditSettings] = [:], failLoad: Bool = false, failSaveCount: Int = 0,
         failAutomaticBackup: Bool = false, failRestore: Bool = false, restored: [String: EditSettings] = [:]) {
        values = initial
        self.failLoad = failLoad
        self.failSaveCount = failSaveCount
        self.failAutomaticBackup = failAutomaticBackup
        self.failRestore = failRestore
        self.restored = restored
    }

    func loadAll() throws -> [String: EditSettings] {
        if failLoad { throw EditingTestError.injected }
        return values
    }

    func revisions() -> [String: Int64] { revisionsByAsset }

    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async throws {
        saveCalls += 1
        activeSaves += 1
        maximumSaves = max(maximumSaves, activeSaves)
        defer { activeSaves -= 1 }
        if blockSave {
            blockSave = false
            await withCheckedContinuation { saveGate = $0 }
        }
        sawCancellation = sawCancellation || Task.isCancelled
        if failSaveCount > 0 {
            failSaveCount -= 1
            throw EditingTestError.injected
        }
        if revision > revisionsByAsset[assetID, default: 0] {
            values[assetID] = settings
            revisionsByAsset[assetID] = revision
        }
    }

    func createBackup(automatic: Bool) throws -> URL {
        if automatic && failAutomaticBackup { throw EditingTestError.injected }
        if !automatic { manualBackup = values }
        return URL(fileURLWithPath: "/tmp/controlled-backup.sqlite")
    }

    func restoreBackup(from url: URL) async throws -> [String: EditSettings] {
        restoreCalls += 1
        if failRestore { throw EditingTestError.injected }
        if blockRestore {
            blockRestore = false
            await withCheckedContinuation { restoreGate = $0 }
        }
        beforeRestore = values
        values = restored
        for id in Set(revisionsByAsset.keys).union(restored.keys) {
            revisionsByAsset[id] = revisionsByAsset[id, default: 0] + 100
        }
        return restored
    }

    func blockNextSave() { blockSave = true }
    func isSaveBlocked() -> Bool { saveGate != nil }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func blockNextRestore() { blockRestore = true }
    func isRestoreBlocked() -> Bool { restoreGate != nil }
    func releaseRestore() { restoreGate?.resume(); restoreGate = nil }
    func savedSettings() -> [String: EditSettings] { values }
    func savedRevisions() -> [String: Int64] { revisionsByAsset }
    func maximumConcurrentSaves() -> Int { maximumSaves }
    func observedCancellation() -> Bool { sawCancellation }
    func totalSaveCalls() -> Int { saveCalls }
    func totalRestoreCalls() -> Int { restoreCalls }
    func latestManualBackup() -> [String: EditSettings] { manualBackup }
    func settingsBeforeRestore() -> [String: EditSettings] { beforeRestore }
}
