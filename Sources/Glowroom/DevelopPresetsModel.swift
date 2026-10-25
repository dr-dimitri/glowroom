import AppKit
import Combine
import Foundation
import GlowroomCore

/// Personal presets use the same decoded source and display-only preview as
/// explicit AI proposals. No preview enters persistence, export or undo.
@MainActor
final class DevelopPresetsModel: ObservableObject {
    typealias Render = AIDevelopmentModel.RenderCorrection
    typealias ValidateSource = AIDevelopmentModel.ValidateSource
    @Published private(set) var presets: [DevelopPreset] = []
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { discard() } } }
    @Published var groups: Set<DevelopPresetGroup> = Set(DevelopPresetGroup.allCases) {
        didSet { if oldValue != groups { discard() } }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var status: String?
    @Published private(set) var hasPreview = false
    private let store: DevelopPresetStore
    private let render: Render
    private let validateSource: ValidateSource
    private var task: Task<Void, Never>?
    private var request = UUID()
    private weak var workspace: DevelopWorkspace?
    private var preview: AICorrectionPreview?
    private var target: DevelopCommandTarget?
    private var sourceStamp: ImageAnalysisSourceStamp?

    var selected: DevelopPreset? { presets.first { $0.id == selectedID } }
    init(store: DevelopPresetStore = DevelopPresetStore(),
         render: Render? = nil, validateSource: ValidateSource? = nil) {
        self.store = store
        self.render = render ?? { bitmap, snapshot, settings, stamp in
            let request = PreviewRequest(source: snapshot.source,
                pixelSize: min(2_400, max(bitmap.image.width, bitmap.image.height)),
                allowsEmbeddedPreview: false, sourceRevision: stamp?.cacheRevision,
                allowsHDR: snapshot.settings.developColor.hdrEnabled)
            return try await AdjustedPreviewPipeline.shared.image(bitmap, request: request,
                settings: settings, priority: .selected, maximumOutputPixelSize: request.pixelSize)
        }
        self.validateSource = validateSource ?? { snapshot, stamp in
            let request = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID())
            guard try await ImageAnalysisPreparer().sourceStamp(for: request) == stamp else {
                throw AIDevelopmentError.staleContext
            }
        }
    }

    func load() async {
        do { presets = try await store.load() }
        catch { status = error.localizedDescription }
    }

    func choose(_ id: UUID?) {
        selectedID = id
        if let selected { groups = selected.patch.groups }
    }

    func save(name: String, library: LibraryModel, editor: EditingModel) async {
        guard let assetID = library.selectedID else { return }
        finishInput(editor: editor, assetID: assetID)
        do {
            let patch = try DevelopSettingsPatch(settings: editor.settings(for: assetID), groups: groups)
            let preset = try DevelopPreset(name: name, patch: patch)
            try await store.save(preset)
            await load(); choose(preset.id); status = "Vorgabe gespeichert."
        } catch { status = error.localizedDescription }
    }

    func rename(_ name: String) async {
        guard let selected else { return }
        do {
            try await store.save(selected.replacingName(name))
            await load(); status = "Vorgabe umbenannt."
        } catch { status = error.localizedDescription }
    }

    func delete() async {
        guard let selectedID else { return }
        do {
            try await store.delete(id: selectedID)
            discard(); self.selectedID = nil; await load(); status = "Vorgabe gelöscht."
        } catch { status = error.localizedDescription }
    }

    func importFile(_ url: URL) async {
        do {
            let preset = try await store.importFile(url)
            await load(); choose(preset.id); status = "Vorgabe importiert."
        } catch { status = error.localizedDescription }
    }

    func export(_ preset: DevelopPreset, to url: URL) async {
        do { try await store.export(preset, to: url); status = "Vorgabe exportiert." }
        catch { status = error.localizedDescription }
    }

    @discardableResult
    func showPreview(library: LibraryModel, editor: EditingModel, workspace: DevelopWorkspace) -> Task<Void, Never>? {
        discard()
        guard let selected, let assetID = library.selectedID, workspace.tool == .basic,
              library.isDeveloping, !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings else { return nil }
        finishInput(editor: editor, assetID: assetID)
        guard let snapshot = editor.aiSnapshot(in: library), let bitmap = workspace.originalBitmap,
              workspace.isFinalPreviewReady, workspace.sourceIdentity == snapshot.source,
              let stamp = workspace.originalSourceStamp else {
            status = "Warte auf die vollständige Bildvorschau."; return nil
        }
        let target = DevelopCommandTarget(snapshot: snapshot, localRevision: editor.localRevision(for: assetID))
        let availability = editor.developCommands.availability(in: library)
        guard availability.isAvailable else {
            status = DevelopCommandError.unavailable(availability.reason).localizedDescription; return nil
        }
        let settings: EditSettings
        do { settings = try selected.patch.selecting(groups).applying(to: snapshot.settings) }
        catch { status = error.localizedDescription; return nil }
        self.workspace = workspace
        let previewRequest = workspace.beginCorrectionPreview()
        let token = UUID(); request = token; isWorking = true; status = "Vorschau wird erstellt …"
        let worker = Task.detached(priority: .userInitiated) { [render, validateSource] in
            try await validateSource(snapshot, stamp)
            return try await render(bitmap, snapshot, settings, stamp)
        }
        let operation = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, request == token else { return }
                let preview = AICorrectionPreview(snapshot: snapshot, settings: settings, bitmap: result)
                guard workspace.correctionPreviewRequestID == previewRequest,
                      preview.matches(editor.localEditingAnchorSnapshot(in: library)), library.isDeveloping,
                      !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings,
                      workspace.tool == .basic, workspace.originalSourceStamp == stamp,
                      workspace.originalBitmap.map({ ObjectIdentifier($0.image) }) == ObjectIdentifier(bitmap.image) else {
                    discard(); status = "Das Foto wurde geändert. Erstelle die Vorschau erneut."; return
                }
                self.preview = preview; self.target = target; sourceStamp = stamp; workspace.presetPreview = preview
                workspace.showsAICorrectionProposal = true
                hasPreview = true; isWorking = false; task = nil; status = "Vorgabe zur Übernahme bereit."
            } catch {
                guard let self, request == token else { return }
                isWorking = false; task = nil
                if !(error is CancellationError) { status = error.localizedDescription }
            }
        }
        task = operation
        return operation
    }

    @discardableResult
    func apply(library: LibraryModel, editor: EditingModel) -> Task<Void, Never>? {
        guard editor.canEdit, library.isDeveloping, !library.comparesOriginal,
              !library.comparesCurrentSourceWithoutSettings else { return nil }
        guard let preview, let target, let sourceStamp, !isWorking,
              preview.matches(editor.aiSnapshot(in: library)), let workspace,
              workspace.presetPreview?.snapshot == preview.snapshot,
              workspace.tool == .basic else { discard(); return nil }
        let token = request; isWorking = true
        let worker = Task.detached(priority: .userInitiated) { [validateSource] in
            try await validateSource(preview.snapshot, sourceStamp)
        }
        let operation = Task { [weak self] in
            defer {
                if let self, request == token { isWorking = false; task = nil }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, request == token else { return }
                guard workspace.tool == .basic, library.isDeveloping, !library.comparesOriginal,
                      !library.comparesCurrentSourceWithoutSettings,
                      workspace.presetPreview?.snapshot == preview.snapshot,
                      workspace.presetPreview?.settings == preview.settings,
                      preview.matches(editor.localEditingAnchorSnapshot(in: library)) else {
                    discard(); status = "Das Foto wurde geändert. Erstelle die Vorschau erneut."; return
                }
                try editor.developCommands.applySettings(preview.settings,
                    target: target, in: library)
                discard(); status = "Vorgabe übernommen."
            } catch {
                guard let self, request == token else { return }
                discard(); status = error.localizedDescription
            }
        }
        task = operation
        return operation
    }

    func invalidate(library: LibraryModel, editor: EditingModel) {
        guard let preview else { return }
        if !preview.matches(editor.localEditingAnchorSnapshot(in: library)) || workspace?.tool != .basic
            || workspace?.presetPreview == nil || !library.isDeveloping {
            discard()
        }
    }

    func discard() {
        request = UUID(); task?.cancel(); task = nil
        if let preview, workspace?.presetPreview?.snapshot == preview.snapshot,
           workspace?.presetPreview?.settings == preview.settings,
           workspace?.presetPreview?.bitmap.image === preview.bitmap.image {
            workspace?.presetPreview = nil
        }
        preview = nil; sourceStamp = nil; target = nil; status = nil
        hasPreview = false; isWorking = false
    }

    private func finishInput(editor: EditingModel, assetID: String) {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        ResettableNativeSlider.cancelInputs(in: NSApp?.keyWindow?.contentView)
        editor.endEditing(assetID: assetID)
    }
}
