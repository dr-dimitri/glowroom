import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Three look assistant", .serialized, .timeLimit(.minutes(2)))
@MainActor
final class AILookAssistantTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-LookAssistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func tenSelectionsShareBaselineNeverInferOrSaveAndAcceptOneUndoStep() async throws {
        let (library, editor, store, provider, _, model) = try await fixture()
        let baseline = try #require(editor.aiSnapshot(in: library))
        #expect(model.prompt.isEmpty)
        #expect(!model.canGenerate)
        #expect(model.canGenerateLooks)
        model.generateLooks()
        try await wait { await provider.isWaiting }
        let providerRequest = try #require(await provider.requests.first)
        #expect(providerRequest.mode == .lookGroup)
        #expect(providerRequest.snapshot == baseline)
        await provider.complete()
        try await wait { model.state == .previewing }
        let group = try #require(model.lookGroup)
        #expect(group.validation.variants.map(\.proposal.id) == AILookID.allCases)
        #expect(model.result == nil)
        #expect(model.selectedLookID == .natural)
        #expect(model.changes(for: .natural).map(\.delta) == [0.6])
        #expect(model.changes(for: .contrasty).map(\.delta) == [35])
        #expect(model.changes(for: .desaturated).map(\.delta) == [-45])
        for index in 0..<12 {
            let id = AILookID.allCases[index % 3]
            model.selectLook(id)
            let selected = try #require(group.validation.variants.first { $0.proposal.id == id })
            let active = try #require(model.activeProposalResult)
            #expect(active.request.snapshot == baseline)
            #expect(model.displaySettings(assetID: baseline.assetID, committed: baseline.settings,
                                            developing: true, comparesOriginal: false) == selected.target)
            #expect(editor.settings(for: baseline.assetID) == baseline.settings)
        }
        #expect(await provider.requests.count == 1)
        #expect(await store.saveCount == 0)
        #expect(!editor.canUndo(assetID: baseline.assetID))
        #expect(!editor.hasPendingChanges)
        model.comparison = .current
        #expect(model.displaySettings(assetID: baseline.assetID, committed: baseline.settings,
                                        developing: true, comparesOriginal: false) == baseline.settings)
        #expect(model.displaySettings(assetID: baseline.assetID, committed: baseline.settings,
                                        developing: true, comparesOriginal: true).isNeutral)
        // The existing export controller receives only accepted editor values.
        let exports = LookExportProbe()
        let exporter = JPEGExportModel(preferences: nil, export: { await exports.export($0) })
        exporter.destinationDirectory = directory
        exporter.present(asset: try #require(library.selectedAsset), settings: editor.settings(for: baseline.assetID))
        exporter.startExport()
        try await wait { !exporter.isExporting }
        #expect(await exports.settings == [baseline.settings])
        exporter.cancel()
        model.selectLook(.contrasty)
        let target = try #require(group.validation.variants.first { $0.proposal.id == .contrasty }).target
        #expect(model.acceptProposal())
        #expect(!model.acceptProposal())
        #expect(model.lookGroup == nil)
        #expect(model.selectedLookID == nil)
        for id in AILookID.allCases { #expect(model.cards.bitmap(for: id) == nil) }
        #expect(editor.settings(for: baseline.assetID) == target)
        #expect(await editor.flush())
        #expect(await store.saveCount == 1)
        #expect(await store.revision(for: baseline.assetID) == 1)
        exporter.present(asset: try #require(library.selectedAsset), settings: editor.settings(for: baseline.assetID))
        exporter.startExport()
        try await wait { !exporter.isExporting }
        #expect(await exports.settings == [baseline.settings, target])
        exporter.cancel()
        editor.undo(assetID: baseline.assetID)
        #expect(editor.settings(for: baseline.assetID) == baseline.settings)
        #expect(!editor.canUndo(assetID: baseline.assetID))
        editor.redo(assetID: baseline.assetID)
        #expect(editor.settings(for: baseline.assetID) == target)
        #expect(await provider.requests.count == 1)
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func everyContextChangeInvalidatesWholeGroupAndAllCardReferences() async throws {
        let (library, editor, _, provider, _, model) = try await fixture()
        let assetID = try #require(library.selectedID)
        for event in 0..<7 {
            model.generateLooks()
            try await wait { await provider.isWaiting }
            await provider.complete()
            try await wait { model.state == .previewing }
            let oldGroup = try #require(model.lookGroup)
            switch event {
            case 0:
                library.selectedID = library.assets[1].id
                library.selectedID = assetID
            case 1: editor.setSettings(EditSettings(exposure: 0.5), for: assetID)
            case 2: editor.undo(assetID: assetID)
            case 3: editor.reset(assetID: assetID)
            case 4: #expect(await editor.restoreBackup(from: directory.appendingPathComponent("restore.sqlite")))
            case 5: editor.beginTermination()
            default: library.beginTermination()
            }
            #expect(!model.acceptProposal())
            try await wait { model.lookGroup == nil }
            for id in AILookID.allCases { #expect(model.cards.bitmap(for: id) == nil) }
            #expect(model.activeProposalResult == nil)
            #expect(model.selectedLookID == nil)
            #expect(model.displaySettings(assetID: assetID, committed: editor.settings(for: assetID),
                                            developing: true, comparesOriginal: false) == editor.settings(for: assetID))
            #expect(!editor.isCurrentAISnapshot(oldGroup.request.snapshot, in: library))
            editor.cancelTermination()
            library.cancelTermination()
        }
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func twentyRapidGroupsKeepOneInferenceAndPublishOnlyLatestGroup() async throws {
        let (library, editor, store, provider, coordinator, model) = try await fixture()
        model.generateLooks()
        try await wait { await provider.isWaiting }
        for index in 0..<20 {
            model.discard()
            model.prompt = "Gruppe \(index)"
            model.generateLooks()
            let expectedID = try #require(model.requestID)
            let states = await coordinator.stateUpdates()
            for await state in states {
                #expect(state.runningCount <= 1)
                #expect(state.queuedCount <= 1)
                if state.queuedRequestID == expectedID { break }
            }
            #expect(model.lookGroup == nil)
        }
        #expect(await provider.requests.count == 1)
        await provider.complete() // Non-cooperative first call really releases its slot now.
        try await wait { await provider.requests.count == 2 }
        let latest = try #require(await provider.requests.last)
        #expect(latest.prompt == "Gruppe 19")
        #expect(model.lookGroup == nil)
        await provider.complete()
        try await wait { model.state == .previewing }
        #expect(model.lookGroup?.request.id == latest.id)
        #expect(model.lookGroup?.request.prompt == "Gruppe 19")
        #expect(await provider.maximumConcurrentCalls == 1)
        model.discard()
        for id in AILookID.allCases { #expect(model.cards.bitmap(for: id) == nil) }
        #expect(!editor.hasPendingChanges)
        #expect(await store.saveCount == 0)
        #expect(await library.finishSaving())
    }

    @Test
    func lateGroupsAfterSelectionResetAndRestoreCannotPublishCardsOrSettings() async throws {
        let (library, editor, _, provider, coordinator, model) = try await fixture()
        let assetID = try #require(library.selectedID)
        for event in 0..<3 {
            model.generateLooks()
            try await wait { await provider.isWaiting }
            switch event {
            case 0:
                library.selectedID = library.assets[1].id
                library.selectedID = assetID
            case 1: editor.reset(assetID: assetID)
            default: #expect(await editor.restoreBackup(from: directory.appendingPathComponent("restore.sqlite")))
            }
            let expectedSettings = editor.settings(for: assetID)
            try await wait { model.state != .generating }
            await provider.complete()
            let states = await coordinator.stateUpdates()
            for await state in states { if state.runningCount == 0 { break } }
            #expect(model.lookGroup == nil)
            #expect(model.activeProposalResult == nil)
            #expect(!model.acceptProposal())
            for id in AILookID.allCases { #expect(model.cards.bitmap(for: id) == nil) }
            #expect(editor.settings(for: assetID) == expectedSettings)
        }
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func malformedGroupNeverPublishesPartialCardsAndOptionalTextLimitIsEnforced() async throws {
        let (library, editor, store, provider, _, model) = try await fixture()
        model.prompt = String(repeating: "x", count: model.maximumPromptBytes + 1)
        #expect(!model.canGenerateLooks)
        model.generateLooks()
        #expect(await provider.requests.isEmpty)
        model.prompt = ""
        model.generateLooks()
        try await wait { await provider.isWaiting }
        await provider.complete(data: Data("{\"schemaVersion\":1,\"variants\":[]}".utf8))
        try await wait { if case .failed = model.state { return true }; return false }
        #expect(model.lookGroup == nil)
        #expect(model.selectedLookID == nil)
        #expect(!model.canAccept)
        #expect(model.canGenerateLooks)
        for id in AILookID.allCases { #expect(model.cards.bitmap(for: id) == nil) }
        #expect(await store.saveCount == 0)
        #expect(!editor.hasPendingChanges)
        #expect(await library.finishSaving())
    }

    private func fixture() async throws -> (LibraryModel, EditingModel, LookEditStore, LookProvider, AIRequestCoordinator, AIAssistantModel) {
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let folder = LibraryFolder(url: photos)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let assets = try ["A.png", "B.png"].map { name in
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: Int64(png.count),
                              pixelWidth: 1, pixelHeight: 1,
                              createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let store = LookEditStore(initial: [assets[0].id: EditSettings(exposure: 0.4, saturation: 10)])
        let editor = EditingModel(database: store)
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id
        library.isDeveloping = true
        let provider = LookProvider()
        let coordinator = AIRequestCoordinator(provider: provider, budget: AIResourceBudget())
        let model = AIAssistantModel(provider: provider, coordinator: coordinator, editor: editor, library: library,
                                     maximumPromptBytes: LocalAIEditingPrompt.maximumUserTextBytes)
        await model.refreshAvailability()
        return (library, editor, store, provider, coordinator, model)
    }

    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw LookAssistantTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum LookAssistantTestError: Error { case timeout }

private actor LookProvider: AIEditingProvider {
    nonisolated let id = "look-ui-test"
    nonisolated let capabilities: AIProviderCapabilities = [.textEditing, .lookSuggestions]
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var requests: [AIEditingRequest] = []
    private var concurrentCalls = 0
    private(set) var maximumConcurrentCalls = 0
    var isWaiting: Bool { continuation != nil }
    func availability() -> AIAvailability { .available }
    func proposal(for request: AIEditingRequest) async -> Data {
        requests.append(request)
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        defer { concurrentCalls -= 1 }
        return await withCheckedContinuation { continuation = $0 } // Ignores cancellation.
    }
    func complete(data: Data? = nil) {
        let group = AILookProposalGroup(variants: [
            AILookProposal(id: .natural, name: "Natürlich", proposal: EditProposal(changes: [.init(parameter: .exposure, value: 1)])),
            AILookProposal(id: .contrasty, name: "Kontrastreich", proposal: EditProposal(changes: [.init(parameter: .contrast, value: 35)])),
            AILookProposal(id: .desaturated, name: "Entsättigt", proposal: EditProposal(changes: [.init(parameter: .saturation, value: -35)]))
        ])
        let bytes = data ?? (try! JSONEncoder().encode(group))
        let waiter = continuation
        continuation = nil
        waiter?.resume(returning: bytes)
    }
}

private actor LookEditStore: EditingPersistence {
    private let initial: [String: EditSettings]
    private var values: [String: EditSettings]
    private var revisionsByAsset: [String: Int64] = [:]
    private(set) var saveCount = 0
    init(initial: [String: EditSettings]) { self.initial = initial; values = initial }
    func loadAll() -> [String: EditSettings] { values }
    func revisions() -> [String: Int64] { revisionsByAsset }
    func save(_ settings: EditSettings, for assetID: String, revision: Int64) {
        values[assetID] = settings
        revisionsByAsset[assetID] = revision
        saveCount += 1
    }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/look-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values = initial; return values }
    func revision(for id: String) -> Int64 { revisionsByAsset[id, default: 0] }
}

private actor LookExportProbe {
    private(set) var settings: [EditSettings] = []
    func export(_ request: JPEGExportRequest) -> JPEGExportResult {
        settings.append(request.settings)
        return JPEGExportResult(url: request.destinationURL, width: 1, height: 1)
    }
}
