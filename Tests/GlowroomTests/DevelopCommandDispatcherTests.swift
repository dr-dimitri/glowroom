import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Development command dispatch and shared admissions", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct DevelopCommandDispatcherTests {
    @Test func uiAndDirectPatchesUseOneRevisionAndGroupedUndo() async throws {
        let f = try await CommandFixture.make(); defer { f.remove() }
        let target = try #require(f.dispatcher.target(in: f.library))
        let request = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: target,
            patch: .init([.init(.exposure, 1)]))
        let result = try f.dispatcher.execute(request, in: f.library)
        #expect(result.didChange && f.editor.localRevision(for: f.id) == 1)
        #expect(try f.dispatcher.execute(request, in: f.library) == result)
        #expect(f.editor.localRevision(for: f.id) == 1)
        #expect(f.editor.historyStateCount == 1)
        f.editor.undo(assetID: f.id)
        f.editor.beginEditing(assetID: f.id)
        var settings = f.editor.settings(for: f.id); settings.exposure = 0.5
        #expect(f.dispatcher.applyNumericSettings(settings, assetID: f.id, in: f.library))
        settings.exposure = 1
        #expect(f.dispatcher.applyNumericSettings(settings, assetID: f.id, in: f.library))
        f.editor.endEditing(assetID: f.id)
        #expect(f.editor.settings(for: f.id) == result.target.snapshot.settings)
        f.editor.undo(assetID: f.id)
        #expect(f.editor.settings(for: f.id).exposure == 0)
        #expect(!f.editor.canUndo(assetID: f.id))
        #expect(await f.editor.flush())
    }

    @Test func invalidAndNoopPatchesNeverCreateHistory() async throws {
        let f = try await CommandFixture.make(); defer { f.remove() }
        let target = try #require(f.dispatcher.target(in: f.library))
        let invalid = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: target,
            patch: .init([.init(.contrast, 20), .init(.exposure, .infinity)]))
        #expect(throws: DevelopCommandError.invalidPatch) { try f.dispatcher.execute(invalid, in: f.library) }
        let empty = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: target, patch: .init([]))
        #expect(try !f.dispatcher.execute(empty, in: f.library).didChange)
        #expect(f.editor.localRevision(for: f.id) == 0 && !f.editor.canUndo(assetID: f.id))
        #expect(f.dispatcher.catalog(in: f.library).count == 6)
        #expect(await f.editor.flush())
    }

    @Test func equalSettingsAfterSelectionAndUndoStillConflict() async throws {
        let f = try await CommandFixture.make(); defer { f.remove() }
        let target = try #require(f.dispatcher.target(in: f.library))
        f.library.selectedID = nil; f.library.selectedID = f.id
        let stale = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: target,
            patch: .init([.init(.exposure, 1)]))
        #expect(throws: DevelopCommandError.staleTarget) { try f.dispatcher.execute(stale, in: f.library) }
        let next = try #require(f.dispatcher.target(in: f.library))
        f.editor.setSettings(EditSettings(exposure: 2, toneProcessingVersion: .consistentV2), for: f.id)
        f.editor.undo(assetID: f.id)
        #expect(f.editor.settings(for: f.id) == next.snapshot.settings)
        let staleUndo = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: next,
            patch: .init([.init(.exposure, 1)]))
        #expect(throws: DevelopCommandError.staleTarget) { try f.dispatcher.execute(staleUndo, in: f.library) }
        #expect(await f.editor.flush())
    }

    @Test func toolDraftComparisonAndInputGatesAreShared() async throws {
        let f = try await CommandFixture.make(); defer { f.remove() }
        f.workspace.tool = .crop
        #expect(f.dispatcher.availability(in: f.library).reason == .activeTool)
        f.workspace.tool = .basic
        f.library.comparesOriginal = true
        #expect(f.dispatcher.availability(in: f.library).reason == .comparison)
        f.library.comparesOriginal = false
        f.editor.beginEditing(assetID: f.id)
        #expect(f.dispatcher.availability(in: f.library).reason == .activeInput)
        #expect(f.dispatcher.availability(in: f.library, permitsActiveInput: true).isAvailable)
        f.editor.endEditing(assetID: f.id)
        f.editor.beginTermination()
        #expect(f.dispatcher.availability(in: f.library).reason == .maintenance)
        f.editor.cancelTermination()
        #expect(await f.editor.flush())
    }

    @Test func delayedAndCancelledPreviewCannotCommit() async throws {
        let entered = TestAsyncLatch(), release = TestAsyncLatch()
        let f = try await CommandFixture.make(validate: { _ in entered.releaseAll(); await release.wait() })
        defer { release.releaseAll(); f.remove() }
        let request = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(),
            target: try #require(f.dispatcher.target(in: f.library)), patch: .init([.init(.exposure, 1)]))
        let task = Task { try await f.dispatcher.preview(request, in: f.library) }
        await entered.wait()
        do { _ = try await f.dispatcher.preview(request, in: f.library); Issue.record("unbounded metadata admission") }
        catch { #expect(error as? DevelopCommandError == .unavailable(.maintenance)) }
        f.library.selectedID = nil; f.library.selectedID = f.id
        release.releaseAll()
        do { _ = try await task.value; Issue.record("stale preview accepted") }
        catch { #expect(error as? DevelopCommandError == .staleTarget) }
        #expect(f.editor.localRevision(for: f.id) == 0)
        let request2 = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(),
            target: try #require(f.dispatcher.target(in: f.library)), patch: .init([.init(.exposure, 1)]))
        let cancelled = Task { try await f.dispatcher.preview(request2, in: f.library) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("cancelled preview accepted") } catch { #expect(error is CancellationError) }
        #expect(f.editor.localRevision(for: f.id) == 0)
        #expect(await f.editor.flush())
    }

    @Test func restoreEpochAndSourceAddressCannotBeReused() async throws {
        let f = try await CommandFixture.make(); defer { f.remove() }
        let initial = try #require(f.dispatcher.target(in: f.library))
        let backup = try #require(await f.editor.createBackup())
        #expect(await f.editor.restoreBackup(from: backup))
        let stale = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: initial,
            patch: .init([.init(.exposure, 1)]))
        #expect(throws: DevelopCommandError.staleTarget) { try f.dispatcher.execute(stale, in: f.library) }
        let current = try #require(f.dispatcher.target(in: f.library))
        let snapshot = current.snapshot
        let wrongSource = AIEditingSnapshot(assetID: snapshot.assetID,
            source: .original(.init(fileURL: URL(fileURLWithPath: "/tmp/other-command-source.png"), modifiedAt: .distantPast, fileSize: 0)),
            settings: snapshot.settings, token: snapshot.token, persistedVersion: snapshot.persistedVersion)
        let request = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(),
            target: .init(snapshot: wrongSource, localRevision: current.localRevision), patch: .init([.init(.exposure, 1)]))
        #expect(throws: DevelopCommandError.staleTarget) { try f.dispatcher.execute(request, in: f.library) }
        #expect(f.editor.localRevision(for: f.id) == 0)
        #expect(await f.editor.flush())
    }

    @Test func unavailableStoreAndBackupHaveMachineReadableGates() async throws {
        let store = CommandBackupStore()
        let f = try await CommandFixture.make(store: store); defer { f.remove() }
        let unavailable = EditingModel(loader: { throw DevelopCommandError.unavailable(.readOnly) })
        try await waitForTestState("unavailable command store", state: { @MainActor in !unavailable.isLoading }, until: { $0 })
        #expect(DevelopCommandDispatcher(editor: unavailable).availability(in: f.library).reason == .readOnly)
        let before = try #require(f.dispatcher.target(in: f.library))
        let backup = Task { await f.editor.createBackup() }
        await store.backupEntered.wait()
        #expect(f.dispatcher.availability(in: f.library).reason == .maintenance)
        #expect(f.dispatcher.catalog(in: f.library).filter(\.isMutation).allSatisfy { $0.availability.reason == .maintenance })
        store.backupRelease.releaseAll()
        #expect(await backup.value != nil)
        let request = DevelopCommandRequest(.patch, id: try f.dispatcher.nextRequestID(), target: before,
            patch: .init([.init(.exposure, 1)]))
        #expect(throws: DevelopCommandError.staleTarget) { try f.dispatcher.execute(request, in: f.library) }
        #expect(await f.editor.flush())
    }

    @Test func failedHistoryAdmissionCannotReturnSuccessfulMutation() async throws {
        let f = try await CommandFixture.make(initialRevision: .max - 1); defer { f.remove() }
        var settings = f.editor.settings(for: f.id); settings.exposure = 1
        f.editor.setSettings(settings, for: f.id)
        #expect(f.editor.localRevision(for: f.id) == .max && f.editor.canUndo(assetID: f.id))
        let request = DevelopCommandRequest(.undo, id: try f.dispatcher.nextRequestID(),
            target: try #require(f.dispatcher.target(in: f.library)))
        #expect(throws: DevelopCommandError.unavailable(.maintenance)) { try f.dispatcher.execute(request, in: f.library) }
        #expect(f.editor.settings(for: f.id).exposure == 1 && f.editor.isReadOnly)
        _ = await f.editor.flush()
    }
}

@MainActor private struct CommandFixture {
    let directory: URL
    let library: LibraryModel
    let editor: EditingModel
    let workspace: DevelopWorkspace
    let masks: InlineMaskWorkspace
    let dispatcher: DevelopCommandDispatcher
    let id: String
    func remove() { workspace.clear(); try? FileManager.default.removeItem(at: directory) }
    static func make(store: CommandBackupStore? = nil, initialRevision: Int64? = nil,
                     validate: @escaping DevelopCommandDispatcher.ValidateSource = { _ in }) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Commands-\(UUID())")
        let folder = LibraryFolder(url: directory)
        let asset = PhotoAsset(folderID: folder.id, fileURL: directory.appendingPathComponent("photo.png"))
        let repository = CatalogRepository(directory: directory.appendingPathComponent("catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: [asset]))
        let library = LibraryModel(repository: repository)
        let editor: EditingModel
        let seededStore = store ?? initialRevision.map { CommandBackupStore(assetID: asset.id, revision: $0) }
        if let store = seededStore { editor = EditingModel(loader: { .init(database: LegacySnapshotTestAdapter(store)) }) }
        else { editor = EditingModel(directory: directory.appendingPathComponent("edits")) }
        try await waitForTestState("command fixture", state: { @MainActor in
            !library.isLoading && !library.isProjecting && !editor.isLoading
        }, until: { $0 })
        library.selectedID = asset.id; library.workspaceMode = .develop
        let workspace = DevelopWorkspace(), masks = InlineMaskWorkspace()
        let dispatcher = DevelopCommandDispatcher(editor: editor, validateSource: validate)
        dispatcher.bind(workspace: workspace, masks: masks)
        return Self(directory: directory, library: library, editor: editor, workspace: workspace,
            masks: masks, dispatcher: dispatcher, id: asset.id)
    }
}

private actor CommandBackupStore: LegacySnapshotTestStore {
    nonisolated let backupEntered = TestAsyncLatch(), backupRelease = TestAsyncLatch()
    private var values: [String: EditSettings] = [:]
    private var versions: [String: Int64] = [:]
    init(assetID: String? = nil, revision: Int64 = 0) {
        if let assetID { values[assetID] = .newEditingSettings; versions[assetID] = revision }
    }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { versions }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {
        values[assetID] = settings; versions[assetID] = revision
    }
    func createBackup(automatic: Bool) async -> URL {
        if !automatic { backupEntered.releaseAll(); await backupRelease.wait() }
        return URL(fileURLWithPath: "/tmp/command-backup.glowroombackup")
    }
    func restoreBackup(from url: URL) -> [String: EditSettings] { [:] }
}
