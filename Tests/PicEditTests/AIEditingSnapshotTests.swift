import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Editing snapshot and local mask boundaries", .serialized)
@MainActor
final class AIEditingSnapshotTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-AISnapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func selectedPhotoRoundTripNeverRevivesSnapshotOrMutatesUndoAndStore() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        library.selectedID = library.assets[1].id
        library.selectedID = snapshot.assetID
        #expect(!editing.isCurrentAISnapshot(snapshot, in: library))
        #expect(editing.settings(for: snapshot.assetID).isNeutral)
        #expect(!editing.canUndo(assetID: snapshot.assetID))
        #expect(!editing.hasPendingChanges)
        #expect(await editing.flush())
        #expect(await store.saveCount() == 0)
    }

    @Test
    func manualUndoRedoAndNeutralResetInvalidateEqualSettings() async throws {
        let (library, editing, store) = try await fixture()
        let initial = try #require(editing.aiSnapshot(in: library))
        editing.setSettings(EditSettings(exposure: 1), for: initial.assetID)
        editing.undo(assetID: initial.assetID)
        #expect(editing.settings(for: initial.assetID) == initial.settings)
        #expect(!editing.isCurrentAISnapshot(initial, in: library))

        let undone = try #require(editing.aiSnapshot(in: library))
        editing.redo(assetID: initial.assetID)
        editing.undo(assetID: initial.assetID)
        #expect(editing.settings(for: initial.assetID) == undone.settings)
        #expect(!editing.isCurrentAISnapshot(undone, in: library))

        let neutral = try #require(editing.aiSnapshot(in: library))
        editing.reset(assetID: initial.assetID)
        #expect(editing.settings(for: initial.assetID) == neutral.settings)
        #expect(!editing.isCurrentAISnapshot(neutral, in: library))
        #expect(await editing.flush())
        #expect(await store.revision(for: initial.assetID) == 4)
    }

    @Test
    func localMaskChangesAndUndoInvalidateSuggestionsWithEqualGlobalControls() async throws {
        let (library, editing, _) = try await fixture()
        let before = try #require(editing.aiSnapshot(in: library))
        var settings = before.settings
        settings.localAdjustments = [try LocalAdjustment(name: "Bereich", mask: LocalAdjustmentMask(
            shape: .linear(start: LocalMaskPoint(x: 0, y: 0.5), end: LocalMaskPoint(x: 1, y: 0.5))),
            settings: LocalAdjustmentSettings(exposure: 1))]
        editing.setSettings(settings, for: before.assetID)
        #expect(!editing.isCurrentAISnapshot(before, in: library))
        let masked = try #require(editing.aiSnapshot(in: library))
        editing.undo(assetID: before.assetID)
        #expect(editing.settings(for: before.assetID) == before.settings)
        #expect(!editing.isCurrentAISnapshot(before, in: library))
        #expect(!editing.isCurrentAISnapshot(masked, in: library))
        #expect(await editing.flush())
    }

    @Test
    func maskDraftAllowsOpeningSaveToFinishButRejectsUndoAndSelectionRoundTrips() async throws {
        let (library, editing, _) = try await fixture()
        let assetID = try #require(library.selectedID)
        editing.setSettings(EditSettings(exposure: 1), for: assetID)
        let anchor = try #require(LocalMaskEditingAnchor(editor: editing, library: library))
        #expect(await editing.flush())
        #expect(anchor.isCurrent(editor: editing, library: library))
        editing.undo(assetID: assetID); editing.redo(assetID: assetID)
        #expect(editing.settings(for: assetID) == anchor.snapshot.settings)
        #expect(!anchor.isCurrent(editor: editing, library: library))
        let next = try #require(LocalMaskEditingAnchor(editor: editing, library: library))
        library.selectedID = library.assets[1].id; library.selectedID = assetID
        #expect(!next.isCurrent(editor: editing, library: library))
        #expect(await editing.flush())
    }

    @Test
    func refreshInvalidatesImmediatelyAndCapturesUpdatedSourceMetadata() async throws {
        let (library, editing, store) = try await fixture(realFiles: true)
        let beforeRefresh = try #require(editing.aiSnapshot(in: library))
        library.refreshCurrentFolder()
        #expect(editing.aiSnapshot(in: library) == nil)
        try await waitUntil { !library.isImporting }
        await library.waitForProjection()
        let afterRefresh = try #require(editing.aiSnapshot(in: library))
        #expect(afterRefresh.assetID == beforeRefresh.assetID)
        #expect(afterRefresh.source != beforeRefresh.source)
        #expect(await editing.flush())
        #expect(await store.saveCount() == 0)
        #expect(await library.finishSaving())
    }

    @Test
    func newLibrarySessionAndTerminationCancellationInvalidateSnapshots() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        library.beginTermination()
        #expect(editing.aiSnapshot(in: library) == nil)
        library.cancelTermination()
        #expect(!editing.isCurrentAISnapshot(snapshot, in: library))

        let current = try #require(editing.aiSnapshot(in: library))
        editing.beginTermination()
        editing.cancelTermination()
        #expect(!editing.isCurrentAISnapshot(current, in: library))

        let replacement = LibraryModel(repository: CatalogRepository(directory: directory.appendingPathComponent("Catalog")))
        try await waitUntil { !replacement.isLoading && !replacement.isProjecting }
        replacement.selectedID = snapshot.assetID
        #expect(!editing.isCurrentAISnapshot(snapshot, in: replacement))
        #expect(await editing.flush())
        #expect(await store.saveCount() == 0)
    }

    @Test
    func restoreRotatesSessionEvenWhenSettingsStayIdenticalAndRejectsDuringLock() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        await store.blockNextRestore()
        let restore = Task { await editing.restoreBackup(from: directory.appendingPathComponent("backup.sqlite")) }
        try await waitUntil { await store.isRestoreBlocked() }
        #expect(editing.aiSnapshot(in: library) == nil)
        await store.releaseRestore()
        #expect(await restore.value)
        let restored = try #require(editing.aiSnapshot(in: library))
        #expect(restored.settings == snapshot.settings)
        #expect(restored.token.editSessionID != snapshot.token.editSessionID)
        #expect(!editing.canUndo(assetID: snapshot.assetID))
        #expect(await store.saveCount() == 0)
    }

    @Test
    func failedRestoreAndCompletedBackupInvalidateSnapshots() async throws {
        let (library, _, _) = try await fixture()
        let store = AISnapshotEditStore(failRestore: true)
        let editing = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitUntil { !editing.isLoading }
        let initial = try #require(editing.aiSnapshot(in: library))
        #expect(!(await editing.restoreBackup(from: directory.appendingPathComponent("bad.sqlite"))))
        #expect(editing.canEdit)
        #expect(!editing.isCurrentAISnapshot(initial, in: library))

        let afterFailure = try #require(editing.aiSnapshot(in: library))
        #expect(await editing.createBackup() != nil)
        #expect(editing.canEdit)
        #expect(!editing.isCurrentAISnapshot(afterFailure, in: library))
        #expect(!editing.canUndo(assetID: initial.assetID))
        #expect(await store.saveCount() == 0)
    }

    private func fixture(realFiles: Bool = false) async throws -> (LibraryModel, EditingModel, AISnapshotEditStore) {
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos, subdirectoryPaths: ["Existing"])
        let assets = ["A.png", "B.png"].map {
            PhotoAsset(folderID: folder.id, fileURL: photos.appendingPathComponent($0), fileSize: 1,
                       createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        }
        if realFiles {
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            for asset in assets { try png.write(to: asset.fileURL) }
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let store = AISnapshotEditStore()
        let editing = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitUntil { !library.isLoading && !library.isProjecting && !editing.isLoading }
        library.selectedID = assets[0].id
        return (library, editing, store)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AISnapshotTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum AISnapshotTestError: Error { case injected, timeout }

private actor AISnapshotEditStore: LegacySnapshotTestStore {
    private var settings: [String: EditSettings] = [:]
    private var revisionsByAsset: [String: Int64]
    private let failRestore: Bool
    private var saves = 0
    private var restoreBlocked = false
    private var restoreGate: CheckedContinuation<Void, Never>?

    init(failRestore: Bool = false, revisions: [String: Int64] = [:]) {
        self.failRestore = failRestore
        revisionsByAsset = revisions
    }

    func loadAll() -> [String: EditSettings] { settings }

    func revisions() -> [String: Int64] { revisionsByAsset }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) async {
        saves += 1
        settings[assetID] = value
        revisionsByAsset[assetID] = revision
    }

    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/ai-snapshot-backup.sqlite") }
    func restoreBackup(from url: URL) async throws -> [String: EditSettings] {
        if failRestore { throw AISnapshotTestError.injected }
        if restoreBlocked {
            restoreBlocked = false
            await withCheckedContinuation { restoreGate = $0 }
        }
        return settings
    }

    func saveCount() -> Int { saves }
    func revision(for id: String) -> Int64 { revisionsByAsset[id, default: 0] }
    func blockNextRestore() { restoreBlocked = true }
    func isRestoreBlocked() -> Bool { restoreGate != nil }
    func releaseRestore() { restoreGate?.resume(); restoreGate = nil }
}
