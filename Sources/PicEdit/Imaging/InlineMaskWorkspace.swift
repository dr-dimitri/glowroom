import AppKit
import Combine
import PicEditCore

/// Owns one source-bound mask draft in the main workspace. Canvas and inspector
/// share this object, so hiding or moving a panel does not recreate the draft.
@MainActor
final class InlineMaskWorkspace: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var model: LocalAdjustmentEditorModel?
    @Published private(set) var asset: PhotoAsset?
    @Published private(set) var source: AISourceIdentity?
    @Published var showsOverlay = true
    @Published var comparesBefore = false
    @Published var erases = false { didSet { brush.cancelStroke(); brush.mode = erases ? .erase : .brush } }
    @Published var refines = false { didSet { finishGesture() } }
    @Published var errorMessage: String?
    let brush = MaskEditingModel(rendersOverlay: false)
    private var openingSettings = EditSettings.neutral
    private var anchor: LocalMaskEditingAnchor?
    private weak var editor: EditingModel?
    private weak var library: LibraryModel?
    private var subscriptions: Set<AnyCancellable> = []
    private var brushSubscriptions: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var reconciliation: Task<Void, Never>?
    private var session = UUID()
    private var syncingBrush = false

    init() {
        brush.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &brushSubscriptions)
        brush.$document.dropFirst().sink { [weak self] document in
            guard let self, !self.syncingBrush, let document else { return }
            self.installBrush(document)
        }.store(in: &brushSubscriptions)
    }

    var selected: LocalAdjustment? { model?.selected }
    var canvasSize: ArtifactPixelSize? { model?.canvasSize }
    var previewSettings: EditSettings? {
        guard isPresented else { return nil }
        return comparesBefore ? openingSettings : model?.settings
    }
    var isCurrent: Bool {
        guard isPresented, let asset, let source, let editor, let library, let anchor else { return false }
        return library.selectedID == asset.id && editor.canEdit && editor.settings(for: asset.id) == openingSettings
            && (try? editor.resolvedSource(for: asset).identity) == source
            && anchor.isCurrent(editor: editor, library: library)
    }
    var canApply: Bool { isCurrent && model?.isLoading == false && model?.isGenerating == false }
    func acceptsCanvasInput(source: AISourceIdentity, layerID: UUID) -> Bool {
        isCurrent && self.source == source && selected?.id == layerID && model?.isGenerating == false
    }
    var usesBrush: Bool {
        guard let selected else { return false }
        switch selected.mask.shape {
        case .brush, .subject, .sky: return true
        case .linear, .radial: return refines
        }
    }
    var displayMask: LocalAdjustmentMask? {
        guard var mask = selected?.mask else { return nil }
        if let document = brush.previewDocument, brush.source == source {
            if case .brush = mask.shape { mask.shape = .brush(document) }
            else if !document.strokes.isEmpty { mask.refinement = document }
        }
        return mask
    }
    var instruction: String {
        guard !comparesBefore else { return "Stand vor den Maskenänderungen." }
        guard let selected else { return "Neue Maske hinzufügen, anschließend den Bereich wählen." }
        switch selected.mask.shape {
        case .brush: return erases ? "Ziehen entfernt Bereiche aus der Pinselmaske." : "Ziehen malt die Pinselmaske."
        case .linear: return refines ? "Mit Pinsel ergänzen oder mit Radierer abziehen." : "Endpunkte verschieben oder einen neuen Verlauf ziehen."
        case .radial: return refines ? "Mit Pinsel ergänzen oder mit Radierer abziehen." : "Mitte oder Griffe verschieben; außerhalb eine neue Ellipse ziehen."
        case .subject, .sky: return "Auswahl mit Pinsel ergänzen oder mit Radierer abziehen."
        }
    }

    @discardableResult
    func open(asset: PhotoAsset, source: AISourceIdentity, settings: EditSettings,
              editor: EditingModel, library: LibraryModel, model suppliedModel: LocalAdjustmentEditorModel? = nil) -> Bool {
        cancel()
        guard library.selectedID == asset.id, editor.canEdit,
              editor.settings(for: asset.id) == settings,
              (try? editor.resolvedSource(for: asset).identity) == source,
              let anchor = LocalMaskEditingAnchor(editor: editor, library: library) else { return false }
        let model = suppliedModel ?? LocalAdjustmentEditorModel(settings: settings)
        model.reset(settings: settings)
        self.model = model; self.asset = asset; self.source = source
        self.editor = editor; self.library = library; self.anchor = anchor
        openingSettings = settings; errorMessage = nil
        showsOverlay = true; comparesBefore = false; erases = false; refines = false
        isPresented = true
        model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        model.$settings.dropFirst().sink { [weak self] settings in self?.syncBrush(settings: settings) }.store(in: &subscriptions)
        model.$selectedID.dropFirst().sink { [weak self] selectedID in
            guard let self else { return }
            self.brush.cancelStroke(); self.model?.endChange(); self.refines = false
            self.syncBrush(selectedID: selectedID)
        }.store(in: &subscriptions)
        // These publishers announce before mutation. Reconcile on the next actor
        // turn, coalescing rapid edits and allowing an accepted opening save.
        editor.objectWillChange.sink { [weak self] _ in self?.scheduleReconciliation() }.store(in: &subscriptions)
        library.objectWillChange.sink { [weak self] _ in self?.scheduleReconciliation() }.store(in: &subscriptions)
        let token = session
        loadTask = Task { [weak self, weak model] in
            guard let model else { return }
            await model.load(source: source)
            guard let self, self.session == token, self.isPresented, !Task.isCancelled else { return }
            self.syncBrush()
        }
        return true
    }

    /// Unaccepted work is disposable. Stored editor transactions are never
    /// canceled here, including when selection, undo or source replacement wins.
    func cancel() {
        session = UUID(); loadTask?.cancel(); loadTask = nil
        reconciliation?.cancel(); reconciliation = nil
        subscriptions.removeAll(); syncingBrush = true; brush.discard(); syncingBrush = false
        model?.close(); model = nil; asset = nil; source = nil; anchor = nil
        editor = nil; library = nil; isPresented = false; errorMessage = nil
    }
    func close() { cancel() }
    func reconcile() {
        guard isPresented, let asset, let source, let editor, let library, let anchor else { return }
        if library.selectedID != asset.id || editor.settings(for: asset.id) != openingSettings
            || (try? editor.resolvedSource(for: asset).identity) != source
            || !anchor.isCurrent(editor: editor, library: library) { cancel() }
    }
    @discardableResult func apply() -> Bool {
        finishGesture()
        guard canApply, let model, let asset, let editor else { return false }
        editor.endEditing(assetID: asset.id)
        editor.setSettings(model.settings, for: asset.id)
        guard editor.settings(for: asset.id) == model.settings else { return false }
        cancel()
        return true
    }
    func finishGesture() { brush.endStroke(); model?.endChange() }
    func undo() { brush.cancelStroke(); model?.undo(); syncBrush() }
    func redo() { brush.cancelStroke(); model?.redo(); syncBrush() }
    func select(_ id: UUID) { finishGesture(); model?.selectedID = id }
    func syncBrush(settings suppliedSettings: EditSettings? = nil, selectedID suppliedID: UUID?? = nil) {
        guard !syncingBrush, let model, let source, let canvas = model.canvasSize else { return }
        let settings = suppliedSettings ?? model.settings
        let selectedID = suppliedID ?? model.selectedID
        guard let selected = settings.localAdjustments.first(where: { $0.id == selectedID }) else {
            syncingBrush = true; brush.discard(); syncingBrush = false; return
        }
        let document: MaskDocument
        if case .brush(let saved) = selected.mask.shape { document = saved }
        else if let saved = selected.mask.refinement { document = saved }
        else { guard let empty = try? MaskDocument(canvasSize: canvas) else { return }; document = empty }
        guard brush.document != document || brush.source != source else { return }
        syncingBrush = true
        do { try brush.load(source: source, document: document) }
        catch { errorMessage = error.localizedDescription }
        syncingBrush = false
        brush.mode = erases ? .erase : .brush
    }
    private func installBrush(_ document: MaskDocument) {
        guard let model, let selected else { return }
        syncingBrush = true
        if case .brush = selected.mask.shape { model.updateSelected { $0.mask.shape = .brush(document) } }
        else if !document.strokes.isEmpty || selected.mask.refinement != nil { model.updateSelected { $0.mask.refinement = document } }
        syncingBrush = false
        let accepted: MaskDocument?
        if case .brush(let saved)? = model.selected?.mask.shape { accepted = saved }
        else { accepted = model.selected?.mask.refinement }
        if !document.strokes.isEmpty, accepted != document {
            errorMessage = model.errorMessage
            // MaskEditingModel is still publishing this value. Correct its
            // rejected document after its own commit has finished.
            let token = session
            Task { [weak self] in guard let self, self.session == token else { return }; self.syncBrush() }
        }
    }
    private func scheduleReconciliation() {
        guard isPresented, reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.reconciliation = nil; self.reconcile()
        }
    }
}
