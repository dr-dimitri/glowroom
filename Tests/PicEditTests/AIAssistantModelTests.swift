import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("AI assistant preview and acceptance", .serialized, .timeLimit(.minutes(2)))
@MainActor
final class AIAssistantModelTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-Assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func previewComparisonsAndDiscardNeverEditOrSave() async throws {
        let (library, editor, store, provider, assistant) = try await fixture()
        let initial = try #require(editor.aiSnapshot(in: library))
        await completeProposal(assistant, provider)
        try await wait { assistant.state == .previewing }
        #expect(assistant.canAccept)
        #expect(assistant.changes.map(\.parameter) == [.exposure, .shadows])
        #expect(assistant.changes.map(\.delta) == [1, 30])
        #expect(assistant.displaySettings(assetID: initial.assetID, committed: initial.settings,
                                          developing: true, comparesOriginal: false).exposure == 1)
        assistant.comparison = .current
        #expect(assistant.displaySettings(assetID: initial.assetID, committed: initial.settings,
                                          developing: true, comparesOriginal: false) == initial.settings)
        assistant.comparison = .proposal
        library.comparesOriginal = true
        #expect(assistant.displaySettings(assetID: initial.assetID, committed: initial.settings,
                                          developing: true, comparesOriginal: true).isNeutral)
        #expect(assistant.canAccept)
        assistant.discard()
        #expect(editor.aiSnapshot(in: library) == initial)
        #expect(!editor.canUndo(assetID: initial.assetID))
        #expect(!editor.canRedo(assetID: initial.assetID))
        #expect(!editor.hasPendingChanges)
        #expect(await editor.flush())
        #expect(await store.saveCount == 0)
        #expect(await store.revision(for: initial.assetID) == 0)
        #expect(await library.finishSaving())
    }

    @Test
    func acceptanceFinishesGestureCreatesExactlyOneStepAndSurvivesUICancellation() async throws {
        let (library, editor, store, provider, assistant) = try await fixture()
        let assetID = try #require(library.selectedID)
        editor.beginEditing(assetID: assetID)
        editor.setSettings(EditSettings(exposure: 0.25, saturation: 12), for: assetID)
        await completeProposal(assistant, provider)
        try await wait { assistant.state == .previewing }
        #expect(assistant.result?.request.snapshot.settings.exposure == 0.25)
        #expect(editor.settings(for: assetID).exposure == 0.25)
        library.comparesOriginal = true
        #expect(assistant.acceptProposal())
        #expect(!assistant.acceptProposal())
        #expect(!library.comparesOriginal)
        #expect(editor.settings(for: assetID) == EditSettings(exposure: 1, shadows: 30, saturation: 12))
        assistant.discard()
        // Accepted saving belongs to EditingModel, never to the UI request task.
        await store.blockNextSave()
        let flush = Task { await editor.flush() }
        try await wait { await store.saveBlocked }
        flush.cancel()
        assistant.discard()
        await store.releaseSave()
        #expect(await flush.value)
        #expect(await store.revision(for: assetID) == 2)
        #expect(await store.saved(for: assetID) == editor.settings(for: assetID))
        #expect(!(await store.observedCancellation))
        editor.undo(assetID: assetID)
        #expect(editor.settings(for: assetID) == EditSettings(exposure: 0.25, saturation: 12))
        editor.undo(assetID: assetID)
        #expect(editor.settings(for: assetID).isNeutral)
        #expect(!editor.canUndo(assetID: assetID))
        editor.redo(assetID: assetID)
        editor.redo(assetID: assetID)
        #expect(editor.settings(for: assetID) == EditSettings(exposure: 1, shadows: 30, saturation: 12))
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func delayedResultsCannotSurviveSelectionRoundtripManualChangeUndoResetOrRestore() async throws {
        let (library, editor, store, provider, assistant) = try await fixture()
        let assetID = try #require(library.selectedID)
        for event in 0..<5 {
            assistant.prompt = "Anfrage \(event)"
            assistant.generate()
            try await wait { await provider.hasWaitingCall }
            switch event {
            case 0:
                library.selectedID = library.assets[1].id
                library.selectedID = assetID
            case 1: editor.setSettings(EditSettings(exposure: 0.5), for: assetID)
            case 2: editor.undo(assetID: assetID)
            case 3: editor.reset(assetID: assetID) // Already neutral still invalidates.
            default: #expect(await editor.restoreBackup(from: directory.appendingPathComponent("backup.sqlite")))
            }
            try await wait { assistant.state != .generating }
            await provider.complete()
            try await wait { await provider.finishedCalls == event + 1 }
            #expect(assistant.result == nil)
            #expect(!assistant.acceptProposal())
        }
        #expect(editor.settings(for: assetID).isNeutral)
        #expect(!editor.hasPendingChanges)
        #expect(await store.saveCount == 1) // Debounce coalesces the two manual revisions.
        #expect(await store.revision(for: assetID) == 2)
        #expect(await library.finishSaving())
    }

    @Test
    func locksAndLeavingDevelopInvalidatePreviewAndBlockAcceptance() async throws {
        let (library, editor, _, provider, assistant) = try await fixture()
        await completeProposal(assistant, provider)
        try await wait { assistant.state == .previewing }
        editor.beginTermination()
        // Recheck the gate immediately, before deferred observation can run.
        #expect(!assistant.acceptProposal())
        #expect(editor.settings(for: try #require(library.selectedID)).isNeutral)
        try await wait { assistant.result == nil }
        editor.cancelTermination()
        await completeProposal(assistant, provider)
        try await wait { assistant.state == .previewing }
        library.beginTermination()
        #expect(!assistant.acceptProposal())
        library.cancelTermination()
        await completeProposal(assistant, provider)
        try await wait { assistant.state == .previewing }
        library.isDeveloping = false
        try await wait { assistant.result == nil }
        #expect(!editor.hasPendingChanges)
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func cancelThenNewRequestRejectsNonCooperativeOldResponse() async throws {
        let (library, editor, _, provider, assistant) = try await fixture()
        assistant.generate()
        try await wait { await provider.hasWaitingCall }
        assistant.discard()
        #expect(assistant.state == .idle)
        assistant.prompt = "Neue Anfrage"
        assistant.generate()
        await provider.complete()
        try await wait {
            let count = await provider.startedCalls
            let waiting = await provider.hasWaitingCall
            return count == 2 && waiting
        }
        #expect(assistant.result == nil)
        await provider.complete()
        try await wait { assistant.state == .previewing }
        #expect(assistant.result?.request.prompt == "Neue Anfrage")
        assistant.discard()
        #expect(!editor.hasPendingChanges)
        #expect(await library.finishSaving())
    }

    @Test
    func unavailableReadOnlyUnreadableInvalidAndNoChangeAreSafeAndRetryable() async throws {
        let (library, editor, store, provider, assistant) = try await fixture()
        await provider.setAvailability(.unavailable(.disabled))
        await assistant.refreshAvailability()
        #expect(assistant.state == .unavailable(.disabled))
        #expect(!assistant.canGenerate)
        assistant.generate()
        #expect(await provider.startedCalls == 0)
        await provider.setAvailability(.available)
        await assistant.refreshAvailability()
        assistant.prompt = " "
        #expect(!assistant.canGenerate)
        assistant.prompt = String(repeating: "x", count: assistant.maximumPromptBytes + 1)
        #expect(!assistant.canGenerate)
        assistant.generate()
        #expect(await provider.startedCalls == 0)
        assistant.prompt = "Aufhellen"
        assistant.generate()
        try await wait { await provider.hasWaitingCall }
        await provider.complete(data: Data("{\"schemaVersion\":1,\"changes\":[{\"parameter\":\"exposure\",\"value\":500}]}".utf8))
        try await wait { if case .failed = assistant.state { return true }; return false }
        #expect(!assistant.canAccept)
        assistant.generate()
        try await wait { await provider.hasWaitingCall }
        await provider.complete(data: Data("{\"schemaVersion\":1,\"changes\":[],\"explanation\":\"Weißabgleich ist nicht verfügbar.\"}".utf8))
        try await wait { assistant.state == .previewing }
        #expect(assistant.changes.isEmpty)
        #expect(assistant.explanation == "Weißabgleich ist nicht verfügbar.")
        #expect(!assistant.canAccept)
        #expect(!assistant.acceptProposal())
        #expect(!editor.canUndo(assetID: try #require(library.selectedID)))
        #expect(!editor.hasPendingChanges)
        assistant.discard()
        // A missing original is rejected by the worker before provider inference.
        try FileManager.default.removeItem(at: try #require(library.selectedAsset).fileURL)
        assistant.generate()
        try await wait { if case .failed = assistant.state { return true }; return false }
        #expect(await provider.startedCalls == 2)
        let readOnly = EditingModel(database: LegacySnapshotTestAdapter(AssistantEditStore(failLoad: true)))
        try await wait { !readOnly.isLoading }
        let locked = AIAssistantModel(provider: provider, coordinator: AIRequestCoordinator(provider: provider),
                                      editor: readOnly, library: library)
        locked.prompt = "Aufhellen"
        await locked.refreshAvailability()
        #expect(!locked.canGenerate)
        locked.generate()
        #expect(!locked.canAccept)
        #expect(await store.saveCount == 0)
        #expect(!editor.hasPendingChanges)
        #expect(await library.finishSaving())
    }

    @Test
    func damagedPhotoIsRejectedBeforeProviderAndRefusalsRemainRetryable() async throws {
        let (library, editor, store, provider, assistant) = try await fixture()
        let original = try #require(library.selectedAsset).fileURL
        let bytes = try Data(contentsOf: original)
        try Data("not an image".utf8).write(to: original)
        assistant.generate()
        try await wait { if case .failed = assistant.state { return true }; return false }
        #expect(await provider.startedCalls == 0)
        try bytes.write(to: original)
        for error in [AIEditingError.safetyRefusal, .unsupportedTask(.imageAnalysis), .temporaryModelFailure] {
            assistant.generate()
            try await wait { await provider.hasWaitingCall }
            await provider.fail(error)
            try await wait { if case .failed = assistant.state { return true }; return false }
            #expect(assistant.state == .failed(error.localizedDescription))
            #expect(assistant.canGenerate)
            #expect(!assistant.canAccept)
        }
        #expect(!editor.hasPendingChanges)
        #expect(!editor.canUndo(assetID: try #require(library.selectedID)))
        #expect(await store.saveCount == 0)
        #expect(await library.finishSaving())
    }

    private func completeProposal(_ assistant: AIAssistantModel, _ provider: AssistantProvider) async {
        assistant.generate()
        do { try await wait { await provider.hasWaitingCall } }
        catch { Issue.record("Provider did not start"); return }
        await provider.complete()
    }

    private func fixture() async throws -> (LibraryModel, EditingModel, AssistantEditStore, AssistantProvider, AIAssistantModel) {
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let assets = try ["A.png", "B.png"].map { name in
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: Int64(png.count),
                              createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let store = AssistantEditStore()
        let editor = EditingModel(database: LegacySnapshotTestAdapter(store))
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id
        library.isDeveloping = true
        let provider = AssistantProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let assistant = AIAssistantModel(provider: provider, coordinator: coordinator, editor: editor, library: library,
                                         maximumPromptBytes: LocalAIEditingPrompt.maximumUserTextBytes)
        assistant.prompt = "Aufhellen und Tiefen öffnen"
        await assistant.refreshAvailability()
        return (library, editor, store, provider, assistant)
    }

    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AssistantTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum AssistantTestError: Error { case timeout, injected }

private actor AssistantProvider: AIEditingProvider {
    nonisolated let id = "assistant-test"
    nonisolated let capabilities: AIProviderCapabilities = [.textEditing]
    private var status: AIAvailability = .available
    private var continuation: CheckedContinuation<Data, Error>?
    private(set) var startedCalls = 0
    private(set) var finishedCalls = 0
    var hasWaitingCall: Bool { continuation != nil }
    func availability() -> AIAvailability { status }
    func setAvailability(_ status: AIAvailability) { self.status = status }
    func proposal(for request: AIEditingRequest) async throws -> Data {
        startedCalls += 1
        defer { finishedCalls += 1 }
        let data = try await withCheckedThrowingContinuation { continuation = $0 }
        return data // Deliberately ignores cancellation.
    }
    func complete(data: Data = Data("{\"schemaVersion\":1,\"changes\":[{\"parameter\":\"exposure\",\"value\":1},{\"parameter\":\"shadows\",\"value\":30}],\"explanation\":\"Vorschlag aus der Textanweisung.\"}".utf8)) {
        let current = continuation
        continuation = nil
        current?.resume(returning: data)
    }
    func fail(_ error: AIEditingError) {
        let current = continuation
        continuation = nil
        current?.resume(throwing: error)
    }
}

private actor AssistantEditStore: LegacySnapshotTestStore {
    private var values: [String: EditSettings] = [:]
    private var revisionsByAsset: [String: Int64] = [:]
    private let failLoad: Bool
    private var blockSave = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var saveCount = 0
    private(set) var observedCancellation = false
    var saveBlocked: Bool { gate != nil }
    init(failLoad: Bool = false) { self.failLoad = failLoad }
    func loadAll() throws -> [String: EditSettings] {
        if failLoad { throw AssistantTestError.injected }
        return values
    }
    func revisions() -> [String: Int64] { revisionsByAsset }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) async {
        saveCount += 1
        if blockSave { blockSave = false; await withCheckedContinuation { gate = $0 } }
        observedCancellation = observedCancellation || Task.isCancelled
        values[assetID] = settings
        revisionsByAsset[assetID] = revision
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/assistant-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values = [:]; return values }
    func revision(for assetID: String) -> Int64 { revisionsByAsset[assetID, default: 0] }
    func saved(for assetID: String) -> EditSettings { values[assetID] ?? .neutral }
    func blockNextSave() { blockSave = true }
    func releaseSave() { gate?.resume(); gate = nil }
}
