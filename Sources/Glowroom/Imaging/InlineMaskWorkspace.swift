import AppKit
import Combine
import GlowroomCore

/// Owns one source-bound mask editing session in the main workspace. Canvas and
/// inspector share live accepted settings and the same gesture undo history.
@MainActor
final class InlineMaskWorkspace: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var model: LocalAdjustmentEditorModel?
    @Published private(set) var asset: PhotoAsset?
    @Published private(set) var source: AISourceIdentity?
    @Published var showsOverlay = true
    @Published var comparesBefore = false
    @Published var showsObjectCreator = false
    @Published var erases = false {
        didSet {
            brush.cancelStroke()
            brush.mode = brushMode(isInverted: selected?.mask.isInverted ?? false)
        }
    }
    @Published var refines = false { didSet { finishGesture() } }
    @Published var errorMessage: String?
    let brush = MaskEditingModel(rendersOverlay: false)
    let objectMask: InlineObjectMaskModel
    private var openingSettings = EditSettings.neutral
    private var acceptedSettings = EditSettings.neutral
    private var anchor: LocalMaskEditingAnchor?
    private weak var editor: EditingModel?
    private weak var library: LibraryModel?
    private weak var developWorkspace: DevelopWorkspace?
    private var subscriptions: Set<AnyCancellable> = []
    private var brushSubscriptions: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var reconciliation: Task<Void, Never>?
    private var session = UUID()
    private var syncingBrush = false

    init(objectMask: InlineObjectMaskModel? = nil) {
        let objectMask = objectMask ?? InlineObjectMaskModel()
        self.objectMask = objectMask
        objectMask.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &brushSubscriptions)
        brush.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &brushSubscriptions)
        brush.$document.dropFirst().sink { [weak self] document in
            guard let self, !self.syncingBrush, let document else { return }
            self.installBrush(document)
        }.store(in: &brushSubscriptions)
        brush.$previewDocument.dropFirst().sink { [weak self] document in
            guard let self, !self.syncingBrush, self.isPresented, self.usesBrush,
                  let document, document != self.brush.document else { return }
            self.showsOverlay = true
        }.store(in: &brushSubscriptions)
    }

    var selected: LocalAdjustment? { model?.selected }
    var showsMaskList: Bool { isPresented && model?.settings.localAdjustments.isEmpty == false }
    /// Follows the visible request, not a canceled native operation's lifetime.
    /// Source changes hide its status before asynchronous reconciliation closes it.
    var showsCalculationStatus: Bool { isCurrent && (model?.isGenerating == true || objectMask.isRunning) }
    var canvasSize: ArtifactPixelSize? { model?.canvasSize }
    var blocksMaskInput: Bool { model?.isGenerating == true || objectMask.blocksMaskInput }
    var canCreateMask: Bool {
        isCurrent && canvasSize != nil && model?.isLoading == false
            && model?.isGenerating == false && !blocksMaskInput
            && (model?.settings.localAdjustments.count ?? 0) < LocalAdjustment.maximumCount
    }
    var canRequestObjectMask: Bool {
        guard canCreateMask else { return false }
        guard let developWorkspace else { return true }
        return developWorkspace.tool == .masks && developWorkspace.sourceIdentity == source
            && developWorkspace.originalBitmap != nil && developWorkspace.isFinalPreviewReady
    }
    var displayMaskID: UUID? { objectMask.proposal?.layer.id ?? selected?.id }
    var previewSettings: EditSettings? {
        guard isPresented else { return nil }
        return comparesBefore ? openingSettings : model?.settings
    }
    var isCurrent: Bool {
        guard isPresented, let asset, let source, let editor, let library, let anchor else { return false }
        return library.selectedID == asset.id && editor.canEdit && editor.settings(for: asset.id) == acceptedSettings
            && (try? editor.resolvedSource(for: asset).identity) == source
            && anchor.isCurrent(editor: editor, library: library)
    }
    var canApply: Bool { isCurrent && model?.isLoading == false && model?.isGenerating == false }
    func acceptsCanvasInput(source: AISourceIdentity, layerID: UUID) -> Bool {
        isCurrent && self.source == source && selected?.id == layerID && model?.isGenerating == false && !blocksMaskInput
    }
    var usesBrush: Bool {
        guard let selected else { return false }
        switch selected.mask.shape {
        case .brush, .subject, .sky: return true
        case .linear, .radial: return refines
        }
    }
    var displayMask: LocalAdjustmentMask? {
        if let proposal = objectMask.proposal { return proposal.layer.mask }
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
              editor: EditingModel, library: LibraryModel, model suppliedModel: LocalAdjustmentEditorModel? = nil,
              developWorkspace: DevelopWorkspace? = nil) -> Bool {
        cancel()
        guard library.selectedID == asset.id, editor.canEdit,
              editor.settings(for: asset.id) == settings,
              (try? editor.resolvedSource(for: asset).identity) == source,
              let anchor = LocalMaskEditingAnchor(editor: editor, library: library) else { return false }
        let model = suppliedModel ?? LocalAdjustmentEditorModel(settings: settings)
        model.reset(settings: settings)
        self.model = model; self.asset = asset; self.source = source
        self.editor = editor; self.library = library; self.anchor = anchor
        self.developWorkspace = developWorkspace
        openingSettings = settings; acceptedSettings = settings; errorMessage = nil
        showsOverlay = true; comparesBefore = false; erases = false; refines = false; showsObjectCreator = false
        isPresented = true
        model.acceptSettings = { [weak self] settings in self?.accept(settings) == true }
        model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        model.$settings.dropFirst().sink { [weak self] settings in
            guard let self else { return }
            if settings != self.model?.settings { self.objectMask.invalidate() }
            self.updateOverlayVisibility(settings: settings)
            self.syncBrush(settings: settings)
        }.store(in: &subscriptions)
        model.$selectedID.dropFirst().sink { [weak self] selectedID in
            guard let self else { return }
            if selectedID != self.model?.selectedID { self.objectMask.invalidate() }
            self.brush.cancelStroke(); self.model?.endChange(); self.refines = false
            self.showsOverlay = true
            self.syncBrush(selectedID: selectedID)
        }.store(in: &subscriptions)
        // These publishers announce before mutation. Reconcile on the next actor
        // turn, coalescing rapid edits and allowing an accepted opening save.
        editor.objectWillChange.sink { [weak self] _ in self?.scheduleReconciliation() }.store(in: &subscriptions)
        library.objectWillChange.sink { [weak self] _ in self?.scheduleReconciliation() }.store(in: &subscriptions)
        if let developWorkspace {
            developWorkspace.$tool.dropFirst().sink { [weak self] tool in
                if tool != .masks { self?.objectMask.discard() }
            }.store(in: &subscriptions)
            developWorkspace.objectWillChange.sink { [weak self] _ in self?.scheduleReconciliation() }.store(in: &subscriptions)
        }
        let token = session
        loadTask = Task { [weak self, weak model] in
            guard let model else { return }
            await model.load(source: source)
            guard let self, self.session == token, self.isPresented, !Task.isCancelled else { return }
            self.syncBrush()
        }
        return true
    }

    /// Closing preserves all accepted edits. Finish an active gesture only while
    /// its original source is current; stale work must never overwrite a winner.
    func cancel() {
        objectMask.discard()
        showsObjectCreator = false
        if isCurrent { finishGesture() }
        session = UUID(); loadTask?.cancel(); loadTask = nil
        reconciliation?.cancel(); reconciliation = nil
        subscriptions.removeAll(); syncingBrush = true; brush.discard(); syncingBrush = false
        model?.close(); model = nil; asset = nil; source = nil; anchor = nil
        editor = nil; library = nil; developWorkspace = nil; isPresented = false; errorMessage = nil
    }
    func close() { cancel() }
    func reconcile() {
        guard isPresented, let asset, let source, let editor, let library, let anchor else { return }
        objectMask.invalidateIfNeeded()
        if library.selectedID != asset.id || editor.settings(for: asset.id) != acceptedSettings
            || (try? editor.resolvedSource(for: asset).identity) != source
            || !anchor.isCurrent(editor: editor, library: library) { cancel() }
    }
    @discardableResult func apply() -> Bool {
        finishGesture()
        guard canApply else { return false }
        close()
        return true
    }
    private func accept(_ settings: EditSettings) -> Bool {
        guard isCurrent, let asset, let editor, let library else {
            scheduleReconciliation()
            return false
        }
        // Editor mutations and their source/revision anchor stay ordered on the
        // main actor. Database persistence remains the editor's debounced task.
        editor.endEditing(assetID: asset.id)
        editor.setSettings(settings, for: asset.id)
        guard editor.settings(for: asset.id) == settings,
              let refreshedAnchor = LocalMaskEditingAnchor(editor: editor, library: library) else {
            errorMessage = editor.errorMessage ?? "Die Maskenänderung konnte nicht übernommen werden."
            return false
        }
        acceptedSettings = settings
        anchor = refreshedAnchor
        return true
    }
    func finishGesture() { brush.endStroke(); model?.endChange() }
    func beginSliderAdjustment(contextID: UUID, target: LocalMaskSliderTarget) {
        guard isCurrent, model?.inputContextID == contextID else { return }
        // Mask controls inspect the selected area; correction controls inspect
        // the resulting photo. Apply this before the first native slider value.
        showsOverlay = target == .mask
    }
    func undo() { objectMask.discard(); brush.cancelStroke(); model?.undo(); syncBrush() }
    func redo() { objectMask.discard(); brush.cancelStroke(); model?.redo(); syncBrush() }
    func select(_ id: UUID) {
        guard model?.settings.localAdjustments.contains(where: { $0.id == id }) == true else { return }
        finishGesture(); model?.selectedID = id; showsOverlay = true
    }
    func delete(_ id: UUID) { finishGesture(); model?.delete(id) }

    @discardableResult
    func requestObjectMask() -> Task<Void, Never>? {
        guard canRequestObjectMask, let model, let editor, let library else { return nil }
        finishGesture()
        guard isCurrent, let expected = LocalMaskEditingAnchor(editor: editor, library: library) else { return nil }
        let token = session, inputContext = model.inputContextID
        let developWorkspace = developWorkspace
        if let developWorkspace {
            guard developWorkspace.tool == .masks, developWorkspace.sourceIdentity == source,
                  developWorkspace.originalBitmap != nil, developWorkspace.isFinalPreviewReady else { return nil }
        }
        let bitmapID = developWorkspace?.originalBitmap.map { ObjectIdentifier($0.image) }
        let bitmapStamp = developWorkspace?.originalSourceStamp
        showsOverlay = true; comparesBefore = false
        return objectMask.start(snapshot: expected.snapshot, expectedSourceStamp: bitmapStamp) { [weak self, weak model, weak editor, weak library, weak developWorkspace] in
            guard let self, let model, let editor, let library else { return false }
            if let developWorkspace {
                guard developWorkspace.tool == .masks, developWorkspace.sourceIdentity == self.source,
                      developWorkspace.originalBitmap.map({ ObjectIdentifier($0.image) }) == bitmapID,
                      developWorkspace.originalSourceStamp == bitmapStamp else { return false }
            }
            return self.session == token && self.isCurrent && self.model === model
                && model.inputContextID == inputContext && !model.isGenerating
                && expected.isCurrent(editor: editor, library: library)
        }
    }

    @discardableResult
    func applyObjectMask() -> Task<Void, Never>? {
        objectMask.apply { [weak self] layer in
            guard let self, self.isCurrent, let model = self.model,
                  model.settings.localAdjustments.count < LocalAdjustment.maximumCount else { return false }
            guard model.appendProposedMask(layer) else { return false }
            self.showsObjectCreator = false
            self.comparesBefore = false; self.showsOverlay = true; self.refines = true; self.erases = false
            self.syncBrush()
            return true
        }
    }

    func discardObjectMask() { objectMask.discard(); showsOverlay = true }
    func reloadObjectMaskSource() {
        finishGesture()
        discardObjectMask()
        developWorkspace?.previewReloadID = UUID()
        guard isCurrent, let source, let model else { return }
        loadTask?.cancel()
        let token = session
        loadTask = Task { [weak self, weak model] in
            guard let model else { return }
            // The preview pipeline checks the native source stamp again, so a
            // replaced file refreshes both the photo and mask-canvas geometry.
            await model.load(source: source)
            guard let self, self.session == token, !Task.isCancelled else { return }
            self.syncBrush()
        }
    }
    func refreshObjectMaskFolder() {
        discardObjectMask()
        library?.refreshCurrentFolder()
    }
    private func updateOverlayVisibility(settings: EditSettings) {
        // The comparison toggle lives in the floating list. Once that list
        // disappears, show current edits rather than an unreachable before state.
        if settings.localAdjustments.isEmpty { comparesBefore = false }
        // Published settings arrive before mutation. Compare the same selected
        // layer so names, ordering and edits to other masks do not hide its area.
        guard let selected = model?.selected,
              let updated = settings.localAdjustments.first(where: { $0.id == selected.id }) else { return }
        if selected.settings != updated.settings {
            showsOverlay = false
        } else if selected.mask != updated.mask {
            showsOverlay = true
        }
    }
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
        let mode = brushMode(isInverted: selected.mask.isInverted)
        if brush.mode != mode { brush.cancelStroke(); brush.mode = mode }
        guard brush.document != document || brush.source != source else { return }
        syncingBrush = true
        do { try brush.load(source: source, document: document) }
        catch { errorMessage = error.localizedDescription }
        syncingBrush = false
        brush.mode = mode
    }
    private func brushMode(isInverted: Bool) -> MaskStrokeMode {
        // The renderer inverts the whole composed selection, including historic
        // strokes. Reverse only newly captured operations so their visible
        // paint/erase effect stays unchanged; no persisted mask is rewritten.
        // MaskDocument.isInverted sets its initial coverage, not stroke meaning.
        erases != isInverted ? .erase : .brush
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
