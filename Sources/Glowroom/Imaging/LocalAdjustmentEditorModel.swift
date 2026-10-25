import AppKit
import Foundation
import GlowroomCore

/// Finishing an already accepted save is allowed; an edit from outside this
/// workspace, a selection round trip or a store epoch change invalidates it.
struct LocalMaskEditingAnchor {
    let snapshot: AIEditingSnapshot
    let localRevision: Int64
    @MainActor init?(editor: EditingModel, library: LibraryModel) {
        guard let snapshot = editor.localEditingAnchorSnapshot(in: library) else { return nil }
        self.snapshot = snapshot; localRevision = editor.localRevision(for: snapshot.assetID)
    }
    @MainActor func isCurrent(editor: EditingModel, library: LibraryModel) -> Bool {
        guard let current = editor.localEditingAnchorSnapshot(in: library) else { return false }
        return current.assetID == snapshot.assetID && current.source == snapshot.source && current.settings == snapshot.settings
            && current.token == snapshot.token && editor.localRevision(for: snapshot.assetID) == localRevision
            && current.persistedVersion?.storeEpoch == snapshot.persistedVersion?.storeEpoch
    }
}

enum LocalMaskCreation: String, CaseIterable, Identifiable {
    case brush, linear, radial, subject, sky, background
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brush: "Pinsel"
        case .linear: "Linearer Verlauf"
        case .radial: "Radialer Verlauf"
        case .subject: "Motiv auswählen"
        case .sky: "Himmel auswählen"
        case .background: "Hintergrund auswählen"
        }
    }
    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .linear: "rectangle.lefthalf.filled"
        case .radial: "circle.lefthalf.filled"
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        case .background: "rectangle.inset.filled.and.person.filled"
        }
    }
}

/// Source-bound mask controls with one undo entry per gesture. The workspace
/// accepts each valid state immediately; ending preview or inference work never
/// cancels an already accepted store write.
@MainActor
final class LocalAdjustmentEditorModel: ObservableObject {
    typealias Loader = @Sendable (PreviewRequest) async throws -> PreviewBitmap
    typealias Generator = @Sendable (PreviewBitmap, AutomaticMaskKind, URL?) async throws -> LocalMaskRaster
    @Published private(set) var settings: EditSettings
    @Published var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            endChange(); inputContextID = UUID()
            selectedComponentID = settings.localAdjustments.first(where: { $0.id == selectedID })?.mask.composition?.components.first?.id
        }
    }
    @Published var selectedComponentID: UUID? {
        didSet { if oldValue != selectedComponentID { endChange(); inputContextID = UUID() } }
    }
    @Published private(set) var bitmap: PreviewBitmap?
    @Published private(set) var canvasSize: ArtifactPixelSize?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private let loader: Loader
    private let generator: Generator
    private struct HistoryState {
        let layers: [LocalAdjustment]
        let selectedID: UUID?
        let selectedComponentID: UUID?
    }
    private var history = BoundedEditingHistory<HistoryState> { state in
        var footprint = EditingHistoryFootprint.layers(state.layers)
        footprint.metadataBytes += 2 * MemoryLayout<UUID?>.stride
        return footprint
    }
    private var historyState: HistoryState { .init(layers: settings.localAdjustments, selectedID: selectedID, selectedComponentID: selectedComponentID) }
    private var groupStart: HistoryState? { history.group() }
    var historyStateCount: Int { history.count }
    var historyByteCount: Int { history.byteCount }
    private var session = UUID()
    private var operation: UUID?
    private var inference: Task<Void, Never>?
    private(set) var source: AISourceIdentity?
    /// Accept before changing local state, so stale controls and late inference
    /// cannot replace a newer editor state. Standalone models need no receiver.
    var acceptSettings: ((EditSettings) -> Bool)?
    /// Native controls can finish after SwiftUI replaces a selected mask view.
    /// A context remains invalid even when selection returns to the same UUID.
    private(set) var inputContextID = UUID()

    init(settings: EditSettings, loader: @escaping Loader = {
        try await ImagePreviewPipeline.shared.image(for: $0, priority: .selected)
    }, generator: @escaping Generator = {
        try await AutomaticMaskService.shared.generate($0, kind: $1, sourceURL: $2)
    }) {
        self.settings = settings
        self.loader = loader
        self.generator = generator
        selectedID = settings.localAdjustments.first?.id
        selectedComponentID = settings.localAdjustments.first?.mask.composition?.components.first?.id
    }

    var selected: LocalAdjustment? { settings.localAdjustments.first { $0.id == selectedID } }
    var selectedComponent: LocalMaskComponent? {
        selected?.mask.composition?.components.first { $0.id == selectedComponentID }
    }
    var selectedMask: LocalAdjustmentMask? {
        if let component = selectedComponent { return try? component.selectionMask() }
        guard selected?.mask.composition == nil else { return nil }
        return selected?.mask
    }
    var canAddComponent: Bool {
        guard let selected, canvasSize != nil, !isLoading, !isGenerating else { return false }
        let count = selected.mask.composition?.components.count ?? 1
        let total = settings.localAdjustments.reduce(0) { $0 + $1.mask.componentCount }
        return count < LocalMaskComposition.maximumComponents && total + 1 <= LocalAdjustment.maximumTotalComponents
    }
    var hasActiveChange: Bool { groupStart != nil }

    /// Edits the selected component, or the unchanged legacy single selection.
    func updateSelectedMask(_ update: (inout LocalAdjustmentMask) -> Void) {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }),
              var selection = selectedMask else { return }
        update(&selection)
        var layers = settings.localAdjustments
        do {
            try selection.validate()
            if var composition = layers[index].mask.composition,
               let componentIndex = composition.components.firstIndex(where: { $0.id == selectedComponentID }) {
                composition.components[componentIndex].shape = selection.shape
                composition.components[componentIndex].refinement = selection.refinement
                composition.components[componentIndex].feather = selection.feather
                composition.components[componentIndex].isInverted = selection.isInverted
                try layers[index].mask.setComposition(composition)
            } else { layers[index].mask = selection }
            try install(layers)
        } catch { errorMessage = Self.message(for: error) }
    }
    func updateComponent(_ id: UUID, _ update: (inout LocalMaskComponent) -> Void) {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }),
              var composition = settings.localAdjustments[index].mask.composition,
              let componentIndex = composition.components.firstIndex(where: { $0.id == id }) else { return }
        update(&composition.components[componentIndex])
        var layers = settings.localAdjustments
        do { try layers[index].mask.setComposition(composition); try install(layers) }
        catch { errorMessage = Self.message(for: error) }
    }
    func deleteComponent(_ id: UUID) {
        endChange(); cancelInference()
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }),
              var composition = settings.localAdjustments[index].mask.composition,
              let removed = composition.components.firstIndex(where: { $0.id == id }) else { return }
        composition.components.remove(at: removed)
        var layers = settings.localAdjustments
        do {
            try layers[index].mask.setComposition(composition)
            guard try install(layers) else { return }
            if selectedComponentID == id { selectedComponentID = composition.components.first?.id }
        } catch { errorMessage = Self.message(for: error) }
    }
    func addComponent(_ kind: LocalMaskCreation, operation: LocalMaskOperation) {
        endChange()
        guard canAddComponent, let canvasSize else { return }
        do {
            switch kind {
            case .brush: try appendComponent(kind.title, shape: .brush(MaskDocument(canvasSize: canvasSize)), operation: operation)
            case .linear: try appendComponent(kind.title, shape: .linear(start: .init(x: 0.5, y: 0.2), end: .init(x: 0.5, y: 0.8)), operation: operation)
            case .radial: try appendComponent(kind.title, shape: .radial(center: .init(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, rotation: 0), operation: operation)
            case .subject, .sky: generate(kind == .subject ? .subject : .sky, componentOperation: operation)
            case .background: generate(.subject, isBackground: true, componentOperation: operation)
            }
        } catch { errorMessage = Self.message(for: error) }
    }
    private func appendComponent(_ name: String, shape: LocalMaskShape, feather: Double = 0.5, operation: LocalMaskOperation) throws {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }) else { return }
        var layers = settings.localAdjustments
        var composition = try layers[index].mask.convertedToComposition(name: layers[index].name)
        let component = try LocalMaskComponent(name: name, operation: operation, shape: shape, feather: feather)
        composition.components.append(component)
        try layers[index].mask.setComposition(composition)
        guard try install(layers) else { return }
        selectedComponentID = component.id
    }

    /// Reopening the inline inspector starts from the current accepted edit.
    func reset(settings: EditSettings) {
        close()
        self.settings = settings
        selectedID = settings.localAdjustments.first?.id
        restoreComponentSelection(nil)
    }

    func load(source: AISourceIdentity) async {
        guard !Task.isCancelled else { return }
        cancelInference()
        inputContextID = UUID()
        let token = UUID(); session = token; self.source = source
        bitmap = nil; canvasSize = nil; isLoading = true; errorMessage = nil
        do {
            let value = try await loader(PreviewRequest(source: source, pixelSize: 2_400, allowsEmbeddedPreview: false))
            try Task.checkCancellation()
            guard token == session else { return }
            let scale = min(1, 1_024 / Double(max(value.image.width, value.image.height)))
            canvasSize = try ArtifactPixelSize(width: max(1, Int((Double(value.image.width) * scale).rounded())),
                height: max(1, Int((Double(value.image.height) * scale).rounded())))
            bitmap = value; isLoading = false
        } catch is CancellationError {
            if token == session { isLoading = false; self.source = nil; bitmap = nil; canvasSize = nil }
        }
        catch { if token == session { errorMessage = Self.message(for: error); isLoading = false } }
    }

    func add(_ kind: LocalMaskCreation) {
        endChange()
        guard let canvasSize else { return }
        do {
            switch kind {
            case .brush:
                try append(kind.title, shape: .brush(MaskDocument(canvasSize: canvasSize)))
            case .linear:
                try append(kind.title, shape: .linear(start: LocalMaskPoint(x: 0.5, y: 0.2),
                    end: LocalMaskPoint(x: 0.5, y: 0.8)))
            case .radial:
                try append(kind.title, shape: .radial(center: LocalMaskPoint(x: 0.5, y: 0.5),
                    radiusX: 0.3, radiusY: 0.3, rotation: 0))
            case .subject, .sky:
                generate(kind == .subject ? .subject : .sky)
            case .background:
                generate(.subject, isBackground: true)
            }
        } catch { errorMessage = Self.message(for: error) }
    }

    private func append(_ name: String, shape: LocalMaskShape, feather: Double = 0.5) throws {
        endChange()
        let layer = try LocalAdjustment(name: name, mask: LocalAdjustmentMask(shape: shape, feather: feather))
        guard try install(settings.localAdjustments + [layer]) else { return }
        selectedID = layer.id
    }

    /// Preserve the reviewed raster, name and UUID, using the same validation,
    /// accepted write and single undo entry as the other creation tools.
    @discardableResult
    func appendProposedMask(_ layer: LocalAdjustment) -> Bool {
        endChange()
        guard canvasSize != nil, !isLoading, !isGenerating,
              !settings.localAdjustments.contains(where: { $0.id == layer.id }) else { return false }
        do {
            guard try install(settings.localAdjustments + [layer]) else { return false }
            selectedID = layer.id
            return true
        } catch { errorMessage = Self.message(for: error); return false }
    }

    func updateSelected(_ update: (inout LocalAdjustment) -> Void) {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }) else { return }
        var layers = settings.localAdjustments
        update(&layers[index])
        layers[index].settings = layers[index].settings.normalized
        do { try install(layers) } catch { errorMessage = Self.message(for: error) }
    }

    func deleteSelected() {
        guard let selectedID else { return }
        delete(selectedID)
    }

    func delete(_ id: UUID) {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
        endChange()
        var layers = settings.localAdjustments
        layers.remove(at: index)
        do {
            guard try install(layers) else { return }
            if selectedID == id { selectedID = layers.isEmpty ? nil : layers[min(index, layers.count - 1)].id }
        }
        catch { errorMessage = Self.message(for: error) }
    }

    func moveSelected(by offset: Int) {
        endChange()
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }) else { return }
        let destination = index + offset
        guard settings.localAdjustments.indices.contains(destination), destination != index else { return }
        var layers = settings.localAdjustments
        layers.swapAt(index, destination)
        do { try install(layers) } catch { errorMessage = Self.message(for: error) }
    }

    func duplicateSelected() {
        guard let selected else { return }
        endChange()
        do {
            let duplicate = try LocalAdjustment(name: String((selected.name + " Kopie").prefix(64)),
                mask: selected.mask, settings: selected.settings, isEnabled: selected.isEnabled)
            guard try install(settings.localAdjustments + [duplicate]) else { return }
            selectedID = duplicate.id
        } catch { errorMessage = Self.message(for: error) }
    }

    func beginChange() { history.beginGroup(historyState) }
    func endChange() {
        guard let previous = history.endGroup() else { return }
        if previous.layers != settings.localAdjustments { remember(previous) }
    }
    func undo() {
        cancelInference()
        endChange()
        guard let previous = history.lastUndo() else { return }
        var candidate = settings; candidate.localAdjustments = previous.layers
        guard acceptSettings?(candidate) != false else { return }
        history.popUndo()
        inputContextID = UUID()
        history.appendRedo(historyState); settings = candidate
        restoreSelection(previous.selectedID); restoreComponentSelection(previous.selectedComponentID); updateHistory()
    }
    func redo() {
        cancelInference()
        endChange()
        guard let next = history.lastRedo() else { return }
        var candidate = settings; candidate.localAdjustments = next.layers
        guard acceptSettings?(candidate) != false else { return }
        history.popRedo()
        inputContextID = UUID()
        history.appendUndo(historyState); settings = candidate
        restoreSelection(next.selectedID); restoreComponentSelection(next.selectedComponentID); updateHistory()
    }
    private func restoreSelection(_ preferredID: UUID?) {
        // A restored creation must select that mask again, even when another
        // accepted mask remains after undo. Refinement then targets the same
        // layer the user had selected before undoing the operation.
        let restoredID = settings.localAdjustments.contains { $0.id == preferredID }
            ? preferredID : settings.localAdjustments.first?.id
        // Reassigning the same @Published value would look like selection to
        // the workspace and reveal the overlay after a correction-only undo.
        if selectedID != restoredID { selectedID = restoredID }
    }
    private func restoreComponentSelection(_ preferredID: UUID?) {
        let restoredID = selected?.mask.composition?.components.contains(where: { $0.id == preferredID }) == true
            ? preferredID : selected?.mask.composition?.components.first?.id
        // Avoid publishing an unchanged selection during correction-only undo:
        // the workspace would otherwise reveal the selection overlay again.
        if selectedComponentID != restoredID { selectedComponentID = restoredID }
    }
    @discardableResult private func install(_ layers: [LocalAdjustment]) throws -> Bool {
        guard settings.localAdjustments != layers else { return true }
        var candidate = settings; candidate.localAdjustments = layers
        _ = try EditingSnapshot(settings: candidate)
        guard acceptSettings?(candidate) != false else { return false }
        if groupStart == nil { remember(historyState) }
        else { history.clearRedo() }
        settings = candidate; errorMessage = nil; updateHistory()
        return true
    }
    private func remember(_ previous: HistoryState) {
        history.clearRedo()
        history.appendUndo(previous)
        updateHistory()
    }
    private func updateHistory() {
        canUndo = history.canUndo() || groupStart.map { $0.layers != settings.localAdjustments } == true
        canRedo = history.canRedo()
    }

    private func generate(_ kind: AutomaticMaskKind, isBackground: Bool = false, componentOperation: LocalMaskOperation? = nil) {
        guard !isGenerating, let bitmap, let source else { return }
        let token = UUID(), currentSession = session
        let componentTarget = componentOperation == nil ? nil : selectedID
        let componentBaseline = componentOperation == nil ? nil : selected?.mask
        let componentContext = inputContextID
        operation = token; isGenerating = true; errorMessage = nil
        let sourceURL: URL?
        if case .original(let original) = source { sourceURL = URL(fileURLWithPath: original.standardizedPath) }
        else { sourceURL = nil }
        inference = Task { [weak self, generator] in
            do {
                var raster = try await generator(bitmap, kind, sourceURL)
                if isBackground { raster = try await Self.backgroundRaster(from: raster) }
                try Task.checkCancellation()
                guard let self, self.session == currentSession, self.operation == token else { return }
                let name = isBackground ? "Hintergrund" : kind == .subject ? "Motiv" : "Himmel"
                // The inferred matte already carries edge coverage. A broad
                // default blur would close small background gaps and produce
                // halos; explicit feather edits and saved masks stay unchanged.
                let shape: LocalMaskShape = kind == .subject ? .subject(raster) : .sky(raster)
                if let componentOperation {
                    guard self.selectedID == componentTarget, self.selected?.mask == componentBaseline,
                          self.inputContextID == componentContext else { throw CancellationError() }
                    try self.appendComponent(name, shape: shape, feather: 0, operation: componentOperation)
                } else { try self.append(name, shape: shape, feather: 0) }
            } catch is CancellationError { }
            catch {
                if let self, self.session == currentSession, self.operation == token { self.errorMessage = Self.message(for: error) }
            }
            if let self, self.operation == token { self.operation = nil; self.isGenerating = false; self.inference = nil }
        }
    }
    /// Complement the bounded Gray8 raster off MainActor so later brush/erase
    /// refinements operate directly on the visible background selection. At
    /// most LocalMaskRaster.maximumDimension² bytes need one pass; an
    /// additional worker pool would compete with the admitted inference worker.
    nonisolated private static func backgroundRaster(from raster: LocalMaskRaster) async throws -> LocalMaskRaster {
        try Task.checkCancellation()
        let bytes = Data(raster.bytes.map { 255 - $0 })
        try Task.checkCancellation()
        return try LocalMaskRaster(width: raster.width, height: raster.height, bytes: bytes)
    }
    func cancelInference() {
        operation = nil; inference?.cancel(); inference = nil; isGenerating = false
    }
    func close() {
        acceptSettings = nil
        inputContextID = UUID()
        session = UUID(); cancelInference(); source = nil; bitmap = nil; canvasSize = nil
        selectedID = settings.localAdjustments.first?.id
        history.removeAll(); errorMessage = nil; updateHistory()
    }
    func waitForInference() async { if let inference { await inference.value } }
    nonisolated private static func message(for error: any Error) -> String {
        if case ArtifactContractError.invalidValue(let detail) = error, detail.hasPrefix("Erster aktiver Bestandteil") { return detail }
        return error.localizedDescription
    }
}
