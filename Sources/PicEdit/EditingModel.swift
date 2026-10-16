import Combine
import Darwin
import Foundation
import PicEditCore

// The actor boundary also lets the controller's save ordering be exercised with
// a deliberately slow store, without involving a real user's database.
protocol EditingPersistence: Actor {
    func loadAll() async throws -> [String: EditSettings]
    func revisions() async throws -> [String: Int64]
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async throws
    func createBackup(automatic: Bool) async throws -> URL
    func restoreBackup(from url: URL) async throws -> [String: EditSettings]
}

extension EditDatabase: EditingPersistence {}

@MainActor
final class EditingModel: ObservableObject {
    @Published private(set) var settingsByAsset: [String: EditSettings] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isRestoring = false
    @Published private(set) var isBackingUp = false {
        didSet { if oldValue != isBackingUp { advanceAIEditGeneration() } }
    }
    @Published private(set) var isReadOnly = false {
        didSet { if oldValue != isReadOnly { advanceAIEditGeneration() } }
    }
    @Published private(set) var isClosing = false {
        didSet { if oldValue != isClosing { advanceAIEditGeneration() } }
    }
    @Published private(set) var hasPendingChanges = false
    @Published var errorMessage: String?
    @Published var notice: String?

    private struct PendingEdit {
        let settings: EditSettings
        let revision: Int64
    }
    private struct History {
        var undo: [EditSettings] = []
        var redo: [EditSettings] = []
    }

    private var database: (any EditingPersistence)?
    private let directory: URL?
    private var revisionsByAsset: [String: Int64] = [:]
    private var pending: [String: PendingEdit] = [:]
    private var histories: [String: History] = [:]
    private var gestureStarts: [String: EditSettings] = [:]
    private var loadingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private let historyLimit = 100

    // These are deliberately independent of SQLite revisions. Restore can
    // replace revision values; changing a value back must never revive a reply.
    private(set) var aiEditSessionID = UUID()
    private(set) var aiEditGeneration: UInt64 = 0

    var semanticProtectedURLs: [URL] {
        guard let directory else { return [] }
        return ["semantic-index.sqlite", "semantic-index.sqlite-journal", "semantic-index.sqlite-wal", "semantic-index.sqlite-shm"]
            .map { directory.appendingPathComponent($0) }
            + [directory.appendingPathComponent("SemanticModels", isDirectory: true)]
    }

    var semanticProtectedDirectoryFamilies: [ManagedDirectoryFamily] {
        guard let directory else { return [] }
        return [ManagedDirectoryFamily(parent: directory, childNamePrefix: "semantic-index-quarantine-")]
    }

    var cloudProtectedURLs: [URL] {
        guard let directory else { return [] }
        return ["cloud-usage.sqlite", "cloud-usage.sqlite-journal", "cloud-usage.sqlite-wal", "cloud-usage.sqlite-shm"].map { directory.appendingPathComponent($0) }
    }

    var canEdit: Bool { !isLoading && !isReadOnly && !isRestoring && !isBackingUp && !isClosing }
    var canBackUp: Bool { !isLoading && !isRestoring && !isBackingUp && !isClosing && database != nil }
    var canRestore: Bool { !isLoading && !isRestoring && !isBackingUp && !isClosing && (database != nil || directory != nil) }

    func beginTermination() { isClosing = true }
    func cancelTermination() { isClosing = false }

    init(directory: URL) {
        self.directory = directory
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let database = try await Task.detached { try EditDatabase(directory: directory) }.value
                await load(database)
            } catch {
                finishLoadingWithError(error)
            }
        }
    }

    // Internal dependency injection keeps concurrency/failure tests deterministic.
    init(database: any EditingPersistence) {
        directory = nil
        loadingTask = Task { [weak self] in await self?.load(database) }
    }

    deinit { debounceTask?.cancel() }

    func settings(for assetID: String) -> EditSettings {
        settingsByAsset[assetID] ?? .neutral
    }

    func setSettings(_ settings: EditSettings, for assetID: String) {
        guard canEdit, !assetID.isEmpty else { return }
        let normalized = settings.normalized
        let old = self.settings(for: assetID)
        guard old != normalized, nextRevisionAvailable(for: assetID) else { return }
        if gestureStarts[assetID] == nil { appendUndo(old, for: assetID) }
        histories[assetID, default: History()].redo.removeAll()
        apply(normalized, for: assetID)
    }

    /// Call from Slider.onEditingChanged. A drag becomes one undo operation.
    func beginEditing(assetID: String) {
        guard canEdit, !assetID.isEmpty, gestureStarts[assetID] == nil else { return }
        advanceAIEditGeneration()
        gestureStarts[assetID] = settings(for: assetID)
    }

    func endEditing(assetID: String) {
        guard let start = gestureStarts.removeValue(forKey: assetID), start != settings(for: assetID) else { return }
        appendUndo(start, for: assetID)
    }

    func reset(assetID: String) {
        guard canEdit, !assetID.isEmpty else { return }
        // Reset is an explicit editing intent, including on an already neutral
        // image; a reply requested before it must stay obsolete.
        advanceAIEditGeneration()
        endEditing(assetID: assetID)
        setSettings(.neutral, for: assetID)
    }

    func canUndo(assetID: String) -> Bool {
        guard canEdit else { return false }
        return !(histories[assetID]?.undo.isEmpty ?? true) ||
            gestureStarts[assetID].map { $0 != settings(for: assetID) } == true
    }

    func canRedo(assetID: String) -> Bool {
        canEdit && !(histories[assetID]?.redo.isEmpty ?? true)
    }

    func undo(assetID: String) {
        guard canUndo(assetID: assetID), nextRevisionAvailable(for: assetID) else { return }
        endEditing(assetID: assetID)
        guard let previous = histories[assetID]?.undo.popLast() else { return }
        histories[assetID, default: History()].redo.append(settings(for: assetID))
        apply(previous, for: assetID)
    }

    func redo(assetID: String) {
        guard canRedo(assetID: assetID), nextRevisionAvailable(for: assetID) else { return }
        endEditing(assetID: assetID)
        guard let next = histories[assetID]?.redo.popLast() else { return }
        appendUndo(settings(for: assetID), for: assetID)
        apply(next, for: assetID)
    }

    /// Await this before quitting. A canceled caller cannot cancel the shared
    /// save operation, and changes arriving during a save are drained as well.
    func flush() async -> Bool {
        // In particular, quitting must not interrupt a recovery between moving
        // the damaged files aside and installing the validated replacement.
        while isRestoring || isBackingUp {
            await withCheckedContinuation { maintenanceWaiters.append($0) }
        }
        return await flushPending()
    }

    private func flushPending() async -> Bool {
        if let loadingTask { await loadingTask.value }
        debounceTask?.cancel()
        debounceTask = nil
        if let saveTask { return await saveTask.value }
        guard let database else { return false }
        guard !pending.isEmpty else { return !isReadOnly }
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.savePending(using: database)
        }
        saveTask = task
        return await task.value
    }

    func createBackup(exportTo target: URL? = nil) async -> URL? {
        guard canBackUp, let database else { return nil }
        isBackingUp = true
        defer { isBackingUp = false; finishMaintenance() }
        if let target {
            let directory = self.directory
            // Path resolution may access a network volume. Hold the backup
            // lifecycle open while validating on a worker, so termination also
            // waits for this accepted operation.
            let validTarget = await Task.detached(priority: .userInitiated) {
                Self.isValidExportTarget(target, directory: directory)
            }.value
            guard validTarget else {
                errorMessage = "Wähle eine separate Datei mit der Endung .sqlite als Backup-Ziel. Die aktive Datenbank darf nicht überschrieben werden."
                return nil
            }
        }
        guard await flushPending() else { return nil }
        do {
            let url = try await database.createBackup(automatic: false)
            if let target {
                do {
                    let exported = try await Task.detached {
                        try Self.exportBackup(url, to: target)
                    }.value
                    notice = "Backup exportiert: \(exported.lastPathComponent)"
                    return exported
                } catch {
                    notice = "Lokales Backup erstellt: \(url.lastPathComponent)"
                    errorMessage = "Das lokale Backup wurde erstellt, konnte aber nicht an den gewählten Speicherort exportiert werden. Es bleibt unter \(url.path) erhalten.\n\n\(error.localizedDescription)"
                    return nil
                }
            }
            notice = "Backup erstellt: \(url.lastPathComponent)"
            return url
        } catch {
            errorMessage = "Das Backup konnte nicht erstellt werden.\n\n\(error.localizedDescription)"
            return nil
        }
    }

    func restoreBackup(from url: URL) async -> Bool {
        guard canRestore else { return false }
        aiEditSessionID = UUID()
        aiEditGeneration = 0
        isRestoring = true
        defer { isRestoring = false; finishMaintenance() }
        // Failed writes must not be discarded by a restore. A read-only store
        // with no pending edits can still be recovered from a valid backup.
        let saved = await flushPending()
        guard saved || pending.isEmpty else { return false }
        let previouslyReadOnly = isReadOnly
        let recoveringDamagedDatabase = database == nil
        var restoredDatabase = false
        do {
            let restored: [String: EditSettings]
            let store: any EditingPersistence
            if let database {
                store = database
                restored = try await database.restoreBackup(from: url)
            } else if let directory {
                // A failed initial open has no live connection. The recovery
                // API validates first and archives damaged files before replacement.
                let recovered = try await Task.detached {
                    try EditDatabase.recoverDatabase(in: directory, from: url)
                }.value
                database = recovered
                store = recovered
                restoredDatabase = true
                restored = try await recovered.loadAll()
            } else { return false }
            restoredDatabase = true
            let restoredRevisions = try await store.revisions()
            settingsByAsset = restored
            revisionsByAsset = restoredRevisions
            pending.removeAll()
            hasPendingChanges = false
            histories.removeAll()
            gestureStarts.removeAll()
            isReadOnly = false
            errorMessage = nil
            notice = recoveringDamagedDatabase
                ? "Backup wiederhergestellt. Die vorherigen Datenbankdateien wurden im Ordner „Recovery“ archiviert."
                : "Backup wiederhergestellt. Der vorherige Stand wurde als Sicherheitsbackup gesichert."
            return true
        } catch {
            // Invalid candidates are rejected by the database before mutation.
            // Verify the active store still matches our snapshot after other
            // failures (for example I/O errors during a SQLite transaction).
            var unchanged = false
            if !restoredDatabase, let database,
               let storedSettings = try? await database.loadAll(),
               let storedRevisions = try? await database.revisions() {
                unchanged = storedSettings == settingsByAsset && storedRevisions == revisionsByAsset
            }
            isReadOnly = previouslyReadOnly || restoredDatabase || !unchanged
            errorMessage = "Das Backup konnte nicht wiederhergestellt werden.\n\n\(error.localizedDescription)"
            return false
        }
    }

    private func load(_ database: any EditingPersistence) async {
        self.database = database
        do {
            let settings = try await database.loadAll()
            let revisions = try await database.revisions()
            settingsByAsset = settings
            revisionsByAsset = revisions
            isLoading = false
            loadingTask = nil
        } catch {
            finishLoadingWithError(error)
        }
    }

    private func finishLoadingWithError(_ error: Error) {
        isLoading = false
        loadingTask = nil
        isReadOnly = true
        errorMessage = "Die Bearbeitungsdatenbank konnte nicht geöffnet werden. Vorhandene Daten bleiben erhalten.\n\n\(error.localizedDescription)"
    }

    private func finishMaintenance() {
        let waiters = maintenanceWaiters
        maintenanceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private nonisolated static func exportBackup(_ source: URL, to target: URL) throws -> URL {
        guard target.isFileURL else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        // Copy only the completed standalone snapshot. Staging beside the
        // destination makes the final rename atomic even across volumes.
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".picedit-backup-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        guard Darwin.rename(staging.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: target.path])
        }
        return target
    }

    private nonisolated static func isValidExportTarget(_ target: URL, directory: URL?) -> Bool {
        guard target.isFileURL, target.pathExtension.lowercased() == "sqlite" else { return false }
        guard let directory else { return true }
        // A handful of paths does not justify nested worker tasks. All
        // filesystem lookups already run outside MainActor in the caller.
        return !ManagedFileProtection.protects(target, directory: directory)
    }

    private func nextRevisionAvailable(for assetID: String) -> Bool {
        guard revisionsByAsset[assetID, default: 0] < Int64.max else {
            isReadOnly = true
            errorMessage = "Diese Bearbeitung kann nicht weiter gespeichert werden: Die maximale Versionsnummer wurde erreicht."
            return false
        }
        return true
    }

    private func apply(_ settings: EditSettings, for assetID: String) {
        advanceAIEditGeneration()
        let revision = revisionsByAsset[assetID, default: 0] + 1
        revisionsByAsset[assetID] = revision
        settingsByAsset[assetID] = settings
        pending[assetID] = PendingEdit(settings: settings, revision: revision)
        hasPendingChanges = true
        scheduleSave()
    }

    private func advanceAIEditGeneration() {
        // Resetting an already neutral edit and beginning a gesture still
        // invalidate ephemeral AI results, even without a settings publication.
        objectWillChange.send()
        if aiEditGeneration == .max {
            aiEditSessionID = UUID()
            aiEditGeneration = 0
        } else {
            aiEditGeneration += 1
        }
    }

    /// The final synchronous gate also preflights revision exhaustion, before
    /// ending a gesture or touching undo. Accepted edits use the ordinary path.
    func acceptAIProposal(_ result: AIProposalResult, in library: LibraryModel) -> Bool {
        do { try result.request.snapshot.validate() }
        catch { return false }
        guard isCurrentAISnapshot(result.request.snapshot, in: library),
              case .changes(let proposal, let settings) = result.validation,
              let checked = try? EditProposalValidator().validate(proposal, against: result.request.snapshot.settings),
              case .changes(_, let validatedSettings) = checked,
              settings == validatedSettings,
              settings != self.settings(for: result.request.snapshot.assetID),
              nextRevisionAvailable(for: result.request.snapshot.assetID) else { return false }

        // No suspension is permitted between the snapshot check and setSettings.
        // MainActor keeps selection, histories and the pending save atomic here.
        let assetID = result.request.snapshot.assetID
        endEditing(assetID: assetID)
        setSettings(validatedSettings, for: assetID)
        return true
    }

    private func appendUndo(_ settings: EditSettings, for assetID: String) {
        histories[assetID, default: History()].undo.append(settings)
        if histories[assetID, default: History()].undo.count > historyLimit {
            histories[assetID]?.undo.removeFirst()
        }
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil
            _ = await self.flush()
        }
    }

    private func savePending(using database: any EditingPersistence) async -> Bool {
        isSaving = true
        defer {
            isSaving = false
            saveTask = nil
        }
        repeat {
            // Each batch is a snapshot. Remove a pending value only if it is
            // still the exact revision that was successfully written.
            let batch = pending
            for assetID in batch.keys.sorted() {
                guard let edit = batch[assetID] else { continue }
                do {
                    try await database.save(edit.settings, for: assetID, revision: edit.revision)
                } catch {
                    isReadOnly = true
                    errorMessage = "Bearbeitungen konnten nicht gespeichert werden. Die letzten Werte bleiben für einen erneuten Speicherversuch im Speicher erhalten.\n\n\(error.localizedDescription)"
                    return false
                }
                if pending[assetID]?.revision == edit.revision { pending.removeValue(forKey: assetID) }
                hasPendingChanges = !pending.isEmpty
            }
            isReadOnly = false
            errorMessage = nil
            do {
                _ = try await database.createBackup(automatic: true)
            } catch {
                errorMessage = "Die Bearbeitungen sind gespeichert, aber das automatische Backup konnte nicht erstellt werden.\n\n\(error.localizedDescription)"
            }
        } while !pending.isEmpty
        return true
    }
}
