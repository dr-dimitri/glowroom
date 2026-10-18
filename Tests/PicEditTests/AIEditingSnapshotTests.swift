import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("AI editing snapshot boundary", .serialized)
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
        let result = try proposal(snapshot)
        library.selectedID = library.assets[1].id
        library.selectedID = snapshot.assetID
        #expect(!editing.isCurrentAISnapshot(snapshot, in: library))
        #expect(!editing.acceptAIProposal(result, in: library))
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
        #expect(!editing.acceptAIProposal(try proposal(initial), in: library))

        let undone = try #require(editing.aiSnapshot(in: library))
        editing.redo(assetID: initial.assetID)
        editing.undo(assetID: initial.assetID)
        #expect(editing.settings(for: initial.assetID) == undone.settings)
        #expect(!editing.acceptAIProposal(try proposal(undone), in: library))

        let neutral = try #require(editing.aiSnapshot(in: library))
        editing.reset(assetID: initial.assetID)
        #expect(editing.settings(for: initial.assetID) == neutral.settings)
        #expect(!editing.acceptAIProposal(try proposal(neutral), in: library))
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
        #expect(!editing.acceptAIProposal(try proposal(before), in: library))
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
        #expect(!editing.acceptAIProposal(try proposal(beforeRefresh), in: library))
        try await waitUntil { !library.isImporting }
        await library.waitForProjection()
        let afterRefresh = try #require(editing.aiSnapshot(in: library))
        #expect(afterRefresh.assetID == beforeRefresh.assetID)
        #expect(afterRefresh.source != beforeRefresh.source)
        #expect(!editing.acceptAIProposal(try proposal(beforeRefresh), in: library))
        #expect(await editing.flush())
        #expect(await store.saveCount() == 0)
        #expect(await library.finishSaving())
    }

    @Test
    func newLibrarySessionAndTerminationCancellationKeepOldRepliesObsolete() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        library.beginTermination()
        #expect(editing.aiSnapshot(in: library) == nil)
        #expect(!editing.acceptAIProposal(try proposal(snapshot), in: library))
        library.cancelTermination()
        #expect(!editing.isCurrentAISnapshot(snapshot, in: library))

        let current = try #require(editing.aiSnapshot(in: library))
        editing.beginTermination()
        #expect(!editing.acceptAIProposal(try proposal(current), in: library))
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
        #expect(!editing.acceptAIProposal(try proposal(snapshot), in: library))
        await store.releaseRestore()
        #expect(await restore.value)
        let restored = try #require(editing.aiSnapshot(in: library))
        #expect(restored.settings == snapshot.settings)
        #expect(restored.token.editSessionID != snapshot.token.editSessionID)
        #expect(!editing.acceptAIProposal(try proposal(snapshot), in: library))
        #expect(!editing.canUndo(assetID: snapshot.assetID))
        #expect(await store.saveCount() == 0)
    }

    @Test
    func failedRestoreAndCompletedBackupDoNotRevivePreMaintenanceProposals() async throws {
        let (library, _, _) = try await fixture()
        let store = AISnapshotEditStore(failRestore: true)
        let editing = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await waitUntil { !editing.isLoading }
        let initial = try #require(editing.aiSnapshot(in: library))
        #expect(!(await editing.restoreBackup(from: directory.appendingPathComponent("bad.sqlite"))))
        #expect(editing.canEdit)
        #expect(!editing.isCurrentAISnapshot(initial, in: library))
        #expect(!editing.acceptAIProposal(try proposal(initial), in: library))

        let afterFailure = try #require(editing.aiSnapshot(in: library))
        #expect(await editing.createBackup() != nil)
        #expect(editing.canEdit)
        #expect(!editing.isCurrentAISnapshot(afterFailure, in: library))
        #expect(!editing.acceptAIProposal(try proposal(afterFailure), in: library))
        #expect(!editing.canUndo(assetID: initial.assetID))
        #expect(await store.saveCount() == 0)
    }

    @Test
    func forgedAndMalformedValidatedResultsCannotReachEditingOrPersistence() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        let request = AIEditingRequest(prompt: "Aufhellen", snapshot: snapshot)
        let invalid = [
            EditProposal(changes: [.init(parameter: .exposure, value: .nan)]),
            EditProposal(changes: [.init(parameter: .exposure, value: 50)]),
            EditProposal(changes: [.init(parameter: .exposure, value: 1), .init(parameter: .exposure, value: 2)]),
            EditProposal(schemaVersion: 2, changes: [.init(parameter: .exposure, value: 1)])
        ]
        for patch in invalid {
            let result = AIProposalResult(request: request, validation: .changes(proposal: patch, settings: EditSettings(exposure: 1)))
            #expect(!editing.acceptAIProposal(result, in: library))
        }
        let validPatch = EditProposal(changes: [.init(parameter: .exposure, value: 1)])
        let mismatched = AIProposalResult(request: request, validation: .changes(proposal: validPatch, settings: EditSettings(exposure: 2)))
        #expect(!editing.acceptAIProposal(mismatched, in: library))
        #expect(!editing.acceptAIProposal(AIProposalResult(request: request, validation: .noChange()), in: library))
        #expect(editing.isCurrentAISnapshot(snapshot, in: library))
        #expect(editing.settings(for: snapshot.assetID).isNeutral)
        #expect(!editing.canUndo(assetID: snapshot.assetID))
        #expect(!editing.canRedo(assetID: snapshot.assetID))
        #expect(!editing.hasPendingChanges)
        #expect(await editing.flush())
        #expect(await store.saveCount() == 0)
    }

    @Test
    func confirmedProposalUsesOneUndoOneRevisionAndCanOnlyBeAcceptedOnce() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        let result = try proposal(snapshot)
        #expect(editing.acceptAIProposal(result, in: library))
        #expect(!editing.acceptAIProposal(result, in: library))
        #expect(editing.settings(for: snapshot.assetID).exposure == 1)
        #expect(await editing.flush())
        #expect(await store.saveCount() == 1)
        #expect(await store.revision(for: snapshot.assetID) == 1)
        editing.undo(assetID: snapshot.assetID)
        #expect(editing.settings(for: snapshot.assetID).isNeutral)
        #expect(!editing.canUndo(assetID: snapshot.assetID))
        #expect(editing.canRedo(assetID: snapshot.assetID))
        #expect(await editing.flush())
    }

    @Test
    func acceptingCurrentResultPreservesTheCoordinatorsLargerPromptBudget() async throws {
        let (library, editing, store) = try await fixture()
        let snapshot = try #require(editing.aiSnapshot(in: library))
        let request = AIEditingRequest(prompt: String(repeating: "x", count: 17_000), snapshot: snapshot)
        // A coordinator may explicitly admit this prompt with its own budget.
        // Acceptance checks context and the typed patch, without parsing it again.
        try request.validate(maximumPromptBytes: 32_768)
        let patch = EditProposal(changes: [.init(parameter: .exposure, value: 1)])
        let result = AIProposalResult(request: request,
                                      validation: try EditProposalValidator().validate(patch, against: snapshot.settings))
        #expect(editing.acceptAIProposal(result, in: library))
        #expect(editing.settings(for: snapshot.assetID).exposure == 1)
        #expect(await editing.flush())
        #expect(await store.saveCount() == 1)
        #expect(await store.revision(for: snapshot.assetID) == 1)
    }

    @Test
    func acceptedProposalFinishesGestureAndKeepsAcceptedSaveDespiteCallerCancellation() async throws {
        let (library, editing, store) = try await fixture()
        let assetID = try #require(library.selectedID)
        editing.beginEditing(assetID: assetID)
        editing.setSettings(EditSettings(exposure: 0.5), for: assetID)
        let snapshot = try #require(editing.aiSnapshot(in: library))
        #expect(editing.acceptAIProposal(try proposal(snapshot), in: library))
        await store.blockNextSave()
        let flush = Task { await editing.flush() }
        try await waitUntil { await store.isSaveBlocked() }
        flush.cancel()
        await store.releaseSave()
        #expect(await flush.value)
        #expect(await store.savedSettings(for: assetID).exposure == 1)
        #expect(!(await store.observedCancellation()))
        #expect(!editing.hasPendingChanges)
        editing.undo(assetID: assetID)
        #expect(editing.settings(for: assetID).exposure == 0.5)
        editing.undo(assetID: assetID)
        #expect(editing.settings(for: assetID).isNeutral)
        #expect(!editing.canUndo(assetID: assetID))
        #expect(await editing.flush())
    }

    @Test
    func loadingReadOnlyAndRevisionExhaustionCannotApplyAProposal() async throws {
        let (library, _, _) = try await fixture()
        let failed = EditingModel(database: LegacySnapshotTestAdapter(AISnapshotEditStore(failLoad: true)))
        #expect(failed.aiSnapshot(in: library) == nil)
        try await waitUntil { !failed.isLoading }
        #expect(failed.aiSnapshot(in: library) == nil)
        let id = try #require(library.selectedID)
        let exhaustedStore = AISnapshotEditStore(revisions: [id: .max])
        let exhausted = EditingModel(database: LegacySnapshotTestAdapter(exhaustedStore))
        try await waitUntil { !exhausted.isLoading }
        let snapshot = try #require(exhausted.aiSnapshot(in: library))
        #expect(!exhausted.acceptAIProposal(try proposal(snapshot), in: library))
        #expect(exhausted.isReadOnly)
        #expect(!exhausted.canUndo(assetID: id))
        #expect(exhausted.settings(for: id).isNeutral)
        #expect(!exhausted.hasPendingChanges)
        #expect(await exhaustedStore.saveCount() == 0)
    }

    private func proposal(_ snapshot: AIEditingSnapshot) throws -> AIProposalResult {
        let patch = EditProposal(changes: [.init(parameter: .exposure, value: 1)])
        return AIProposalResult(request: AIEditingRequest(prompt: "Aufhellen", snapshot: snapshot),
                                validation: try EditProposalValidator().validate(patch, against: snapshot.settings))
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
    private let failLoad: Bool
    private let failRestore: Bool
    private var saves = 0
    private var saveBlocked = false
    private var restoreBlocked = false
    private var saveGate: CheckedContinuation<Void, Never>?
    private var restoreGate: CheckedContinuation<Void, Never>?
    private var cancelled = false

    init(failLoad: Bool = false, failRestore: Bool = false, revisions: [String: Int64] = [:]) {
        self.failLoad = failLoad
        self.failRestore = failRestore
        revisionsByAsset = revisions
    }

    func loadAll() throws -> [String: EditSettings] {
        if failLoad { throw AISnapshotTestError.injected }
        return settings
    }

    func revisions() -> [String: Int64] { revisionsByAsset }
    func save(_ value: EditSettings, for assetID: String, revision: Int64) async {
        saves += 1
        if saveBlocked {
            saveBlocked = false
            await withCheckedContinuation { saveGate = $0 }
        }
        cancelled = cancelled || Task.isCancelled
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
    func savedSettings(for id: String) -> EditSettings { settings[id] ?? .neutral }
    func observedCancellation() -> Bool { cancelled }
    func blockNextSave() { saveBlocked = true }
    func blockNextRestore() { restoreBlocked = true }
    func isSaveBlocked() -> Bool { saveGate != nil }
    func isRestoreBlocked() -> Bool { restoreGate != nil }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func releaseRestore() { restoreGate?.resume(); restoreGate = nil }
}
