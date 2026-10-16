import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Image analysis observer and lifecycle", .serialized, .timeLimit(.minutes(2)))
@MainActor
final class ImageAnalysisModelTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit-AnalysisUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test
    func originalIsExplicitReadOnlyAndSurvivesManualSliderChanges() async throws {
        let (library, editor, store, service, model) = try await fixture()
        let id = try #require(library.selectedID)
        let baseline = editor.settings(for: id)
        #expect(model.inputKind == .originalPreview)
        #expect(await service.requestCount == 0)
        #expect(model.canAnalyze)
        #expect(!editor.canUndo(assetID: id))
        model.analyze()
        try await wait { await service.requestCount == 1 }
        let request = try #require(await service.lastRequest)
        #expect(request.inputKind == .originalPreview)
        editor.setSettings(EditSettings(exposure: 2, saturation: -30), for: id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.state == .analyzing)
        await service.complete(request.id)
        try await wait { model.state == .ready }
        let result = try #require(model.result)
        #expect(result.request == request)
        #expect(result.provenance.inputKind == .originalPreview)
        #expect(result.provenance.editToken == nil)
        #expect(editor.settings(for: id).exposure == 2)
        editor.undo(assetID: id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(editor.settings(for: id) == baseline)
        #expect(model.result == result)
        #expect(!editor.canUndo(assetID: id))
        model.discard()
        #expect(model.result == nil)
        #expect(editor.settings(for: id) == baseline)
        #expect(await service.invalidateCount == 0)
        #expect(await editor.flush())
        #expect(await store.revision(for: id) == 2) // Only the manual edit and Undo.
        #expect(await library.finishSaving())
    }

    @Test
    func requestDisplayDiscardAndModeSwitchDoNotWriteOrCreateUndo() async throws {
        let (library, editor, store, service, model) = try await fixture()
        let snapshot = try #require(editor.aiSnapshot(in: library))
        model.analyze()
        try await wait { await service.requestCount == 1 }
        await service.complete(try #require(await service.lastRequest).id)
        try await wait { model.state == .ready }
        #expect(model.result?.suggestions.description == "Ein roter Kreis neben einer blauen Fläche.")
        model.inputKind = .editedPreview
        #expect(model.result == nil)
        #expect(await service.requestCount == 1) // Changing input never starts inference.
        model.analyze()
        try await wait { await service.requestCount == 2 }
        let edited = try #require(await service.lastRequest)
        #expect(edited.snapshot.settings == snapshot.settings)
        await service.complete(edited.id)
        try await wait { model.state == .ready }
        #expect(model.result?.provenance.editToken == snapshot.token)
        model.discard()
        #expect(editor.aiSnapshot(in: library) == snapshot)
        #expect(!editor.canUndo(assetID: snapshot.assetID))
        #expect(!editor.canRedo(assetID: snapshot.assetID))
        #expect(!editor.hasPendingChanges)
        #expect(await editor.flush())
        #expect(await store.saveCount == 0)
        #expect(await library.finishSaving())
    }

    @Test
    func editedInputRejectsEqualSettingsAfterUndoAndOriginalDoesNot() async throws {
        let (library, editor, _, service, model) = try await fixture()
        let id = try #require(library.selectedID)
        model.inputKind = .editedPreview
        model.analyze()
        try await wait { await service.requestCount == 1 }
        let request = try #require(await service.lastRequest)
        editor.setSettings(EditSettings(exposure: 1), for: id)
        editor.undo(assetID: id)
        #expect(editor.settings(for: id) == request.snapshot.settings)
        try await wait { model.state != .analyzing }
        await service.complete(request.id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.result == nil)
        model.inputKind = .originalPreview
        model.analyze()
        try await wait { await service.requestCount == 2 }
        let original = try #require(await service.lastRequest)
        editor.reset(assetID: id)
        await service.complete(original.id)
        try await wait { model.state == .ready }
        #expect(model.result?.request.id == original.id)
        model.discard()
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func selectionRoundTripAndSourceRefreshRejectDelayedAnalysis() async throws {
        let (library, editor, store, service, model) = try await fixture()
        let id = try #require(library.selectedID)
        model.analyze()
        try await wait { await service.requestCount == 1 }
        let first = try #require(await service.lastRequest)
        library.selectedID = library.assets[1].id
        library.selectedID = id
        try await wait { model.state != .analyzing }
        await service.complete(first.id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.result == nil)
        model.analyze()
        try await wait { await service.requestCount == 2 }
        let second = try #require(await service.lastRequest)
        let sourceURL = try #require(library.selectedAsset).fileURL
        let bytes = try Data(contentsOf: sourceURL)
        try (bytes + Data([0])).write(to: sourceURL)
        library.refreshCurrentFolder()
        try await wait { !library.isImporting && !library.isProjecting }
        await service.complete(second.id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.result == nil)
        #expect(editor.aiSnapshot(in: library)?.source != second.snapshot.source)
        #expect(await store.saveCount == 0)
        #expect(await library.finishSaving())
    }

    @Test
    func restoreAndBriefTerminationSynchronouslyInvalidateOriginalResults() async throws {
        let (library, editor, store, service, model) = try await fixture()
        for event in 0..<4 {
            model.analyze()
            try await wait { await service.requestCount == event + 1 }
            let request = try #require(await service.lastRequest)
            await service.complete(request.id)
            try await wait { model.state == .ready }
            switch event {
            case 0: #expect(await editor.restoreBackup(from: directory.appendingPathComponent("restore.sqlite")))
            case 1: editor.beginTermination(); editor.cancelTermination()
            case 2: library.beginTermination(); library.cancelTermination()
            default: #expect(await editor.createBackup() != nil)
            }
            // Also covers maintenance that completes before deferred observation.
            #expect(model.result == nil)
            #expect(model.state != .ready)
        }
        #expect(await store.saveCount == 0)
        #expect(await editor.flush())
        #expect(await library.finishSaving())
    }

    @Test
    func cancelAndNewInputCannotPublishNonCooperativeOldResults() async throws {
        let (library, editor, store, service, model) = try await fixture()
        model.analyze()
        try await wait { await service.requestCount == 1 }
        let first = try #require(await service.lastRequest)
        model.discard()
        model.inputKind = .editedPreview
        model.analyze()
        try await wait { await service.requestCount == 2 }
        let second = try #require(await service.lastRequest)
        await service.complete(first.id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.result == nil)
        #expect(model.state == .analyzing)
        await service.complete(second.id)
        try await wait { model.state == .ready }
        #expect(model.result?.request.id == second.id)
        #expect(model.result?.request.inputKind == .editedPreview)
        model.discard()
        #expect(await service.invalidateCount == 0)
        #expect(await store.saveCount == 0)
        #expect(!editor.hasPendingChanges)
        #expect(await library.finishSaving())
    }

    @Test
    func everyUnavailableReasonIsDistinctAndErrorsAllowExplicitRetry() async throws {
        let (library, editor, store, service, model) = try await fixture()
        let reasons: [ImageAnalysisUnavailableReason] = [.unsupportedSystem, .sdkUnavailable, .unsupportedHardware,
            .disabled, .modelUnavailable, .unsupportedLanguage, .unsupportedCapability, .temporaryFailure, .unknown]
        #expect(Set(reasons.map(\.localizedDescription)).count == reasons.count)
        #expect(ImageAnalysisUnavailableReason.unsupportedSystem.localizedDescription.contains("27"))
        for reason in reasons {
            await service.setAvailability(.unavailable(reason))
            await model.refreshAvailability()
            #expect(model.state == .unavailable(reason))
            #expect(!model.canAnalyze)
            model.analyze()
            #expect(await service.requestCount == 0)
        }
        await service.setAvailability(.available)
        await model.refreshAvailability()
        let errors: [ImageAnalysisError] = [.safetyRefusal, .invalidResponse, .staleSource, .temporaryModelFailure]
        for (index, error) in errors.enumerated() {
            model.analyze()
            try await wait { await service.requestCount == index + 1 }
            await service.fail(try #require(await service.lastRequest).id, error: error)
            try await wait { if case .failed = model.state { return true }; return false }
            #expect(model.state == .failed(error.localizedDescription))
            #expect(model.result == nil)
            #expect(model.canAnalyze)
        }
        model.analyze()
        try await wait { await service.requestCount == errors.count + 1 }
        await service.fail(try #require(await service.lastRequest).id, error: ImageAnalysisUITestError.injected)
        try await wait { if case .failed = model.state { return true }; return false }
        #expect(model.state == .failed(ImageAnalysisError.providerFailure.localizedDescription))
        #expect(await store.saveCount == 0)
        #expect(!editor.hasPendingChanges)
        #expect(await library.finishSaving())
    }

    private func fixture() async throws -> (LibraryModel, EditingModel, AnalysisUIEditStore, AnalysisUIService, ImageAnalysisModel) {
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let folder = LibraryFolder(url: photos)
        let assets = try ["A.png", "B.png"].map { name in
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
            return PhotoAsset(folderID: folder.id, fileURL: url, fileSize: Int64(png.count),
                              createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
        }
        let repository = CatalogRepository(directory: directory.appendingPathComponent("Catalog"))
        try repository.save(LibraryCatalog(folders: [folder], assets: assets))
        let library = LibraryModel(repository: repository)
        let store = AnalysisUIEditStore(initial: [assets[0].id: EditSettings(exposure: 0.4, saturation: 10)])
        let editor = EditingModel(database: store)
        try await wait { !library.isLoading && !library.isProjecting && !editor.isLoading }
        library.selectedID = assets[0].id
        library.isDeveloping = true
        let service = AnalysisUIService()
        let model = ImageAnalysisModel(service: service, editor: editor, library: library)
        await model.refreshAvailability()
        return (library, editor, store, service, model)
    }

    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ImageAnalysisUITestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ImageAnalysisUITestError: Error { case timeout, injected }

private actor AnalysisUIService: ImageAnalysisServing {
    nonisolated let descriptor = ImageAnalysisProviderDescriptor(providerID: "analysis-ui-fake", modelID: "synthetic-v1")
    private var status: ImageAnalysisAvailability = .available
    private var pending: [UUID: (ImageAnalysisRequest, CheckedContinuation<ImageAnalysisResult, Error>)] = [:]
    private(set) var requestCount = 0
    private(set) var lastRequest: ImageAnalysisRequest?
    private(set) var invalidateCount = 0
    func availability() -> ImageAnalysisAvailability { status }
    func setAvailability(_ value: ImageAnalysisAvailability) { status = value }
    func analyze(_ request: ImageAnalysisRequest) async throws -> ImageAnalysisResult {
        requestCount += 1
        lastRequest = request
        return try await withCheckedThrowingContinuation { pending[request.id] = (request, $0) }
    }
    func invalidate() { invalidateCount += 1 }
    func complete(_ id: UUID) {
        guard let (request, continuation) = pending.removeValue(forKey: id),
              case .original(let source) = request.snapshot.source else { return }
        let provenance = ImageAnalysisProvenance(descriptor: descriptor, analyzedAt: Date(timeIntervalSince1970: 100),
            rasterSHA256: String(repeating: "a", count: 64), pixelWidth: 512, pixelHeight: 320,
            byteCount: 512 * 320 * 4, colorProfile: "sRGB", colorProfileSHA256: nil,
            source: source, inputKind: request.inputKind,
            editToken: request.inputKind == .editedPreview ? request.snapshot.token : nil)
        let suggestions = ImageAnalysisSuggestions(description: "Ein roter Kreis neben einer blauen Fläche.",
            attributes: [.init(category: .color, value: "Rot und Blau")])
        continuation.resume(returning: ImageAnalysisResult(request: request, suggestions: suggestions, provenance: provenance))
    }
    func fail(_ id: UUID, error: Error) { pending.removeValue(forKey: id)?.1.resume(throwing: error) }
}

private actor AnalysisUIEditStore: EditingPersistence {
    private var values: [String: EditSettings]
    private let initial: [String: EditSettings]
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
    func revision(for id: String) -> Int64 { revisionsByAsset[id, default: 0] }
    func createBackup(automatic: Bool) -> URL { URL(fileURLWithPath: "/tmp/image-analysis-ui-backup.sqlite") }
    func restoreBackup(from url: URL) -> [String: EditSettings] { values = initial; return values }
}
