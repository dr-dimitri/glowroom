import AppKit
import Foundation
import GlowroomCore

/// Finishing an already accepted save is allowed; an edit from outside this
/// workspace, a selection round trip or a store epoch change invalidates it.
struct LocalMaskEditingAnchor {
    let snapshot: AIEditingSnapshot
    let localRevision: Int64
    @MainActor init?(editor: EditingModel, library: LibraryModel) {
        guard let snapshot = editor.aiSnapshot(in: library) else { return nil }
        self.snapshot = snapshot; localRevision = editor.localRevision(for: snapshot.assetID)
    }
    @MainActor func isCurrent(editor: EditingModel, library: LibraryModel) -> Bool {
        guard let current = editor.aiSnapshot(in: library) else { return false }
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
        }
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
    private var history = BoundedEditingHistory<[LocalAdjustment]>(footprint: EditingHistoryFootprint.layers)
    private var groupStart: [LocalAdjustment]? { history.group() }
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
    }

    var selected: LocalAdjustment? { settings.localAdjustments.first { $0.id == selectedID } }
    var hasActiveChange: Bool { groupStart != nil }

    /// Reopening the inline inspector starts from the current accepted edit.
    func reset(settings: EditSettings) {
        close()
        self.settings = settings
        selectedID = settings.localAdjustments.first?.id
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
        catch { if token == session { errorMessage = error.localizedDescription; isLoading = false } }
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
        } catch { errorMessage = error.localizedDescription }
    }

    private func append(_ name: String, shape: LocalMaskShape, feather: Double = 0.5) throws {
        endChange()
        let layer = try LocalAdjustment(name: name, mask: LocalAdjustmentMask(shape: shape, feather: feather))
        guard try install(settings.localAdjustments + [layer]) else { return }
        selectedID = layer.id
    }

    func updateSelected(_ update: (inout LocalAdjustment) -> Void) {
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }) else { return }
        var layers = settings.localAdjustments
        update(&layers[index])
        layers[index].settings = layers[index].settings.normalized
        do { try install(layers) } catch { errorMessage = error.localizedDescription }
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
        catch { errorMessage = error.localizedDescription }
    }

    func moveSelected(by offset: Int) {
        endChange()
        guard let index = settings.localAdjustments.firstIndex(where: { $0.id == selectedID }) else { return }
        let destination = index + offset
        guard settings.localAdjustments.indices.contains(destination), destination != index else { return }
        var layers = settings.localAdjustments
        layers.swapAt(index, destination)
        do { try install(layers) } catch { errorMessage = error.localizedDescription }
    }

    func duplicateSelected() {
        guard let selected else { return }
        endChange()
        do {
            let duplicate = try LocalAdjustment(name: String((selected.name + " Kopie").prefix(64)),
                mask: selected.mask, settings: selected.settings, isEnabled: selected.isEnabled)
            guard try install(settings.localAdjustments + [duplicate]) else { return }
            selectedID = duplicate.id
        } catch { errorMessage = error.localizedDescription }
    }

    func beginChange() { history.beginGroup(settings.localAdjustments) }
    func endChange() {
        guard let previous = history.endGroup() else { return }
        if previous != settings.localAdjustments { remember(previous) }
    }
    func undo() {
        cancelInference()
        endChange()
        guard let previous = history.lastUndo() else { return }
        var candidate = settings; candidate.localAdjustments = previous
        guard acceptSettings?(candidate) != false else { return }
        history.popUndo()
        inputContextID = UUID()
        history.appendRedo(settings.localAdjustments); settings = candidate; reconcileSelection(); updateHistory()
    }
    func redo() {
        cancelInference()
        endChange()
        guard let next = history.lastRedo() else { return }
        var candidate = settings; candidate.localAdjustments = next
        guard acceptSettings?(candidate) != false else { return }
        history.popRedo()
        inputContextID = UUID()
        history.appendUndo(settings.localAdjustments); settings = candidate; reconcileSelection(); updateHistory()
    }
    private func reconcileSelection() {
        if selected == nil { selectedID = settings.localAdjustments.first?.id }
    }
    @discardableResult private func install(_ layers: [LocalAdjustment]) throws -> Bool {
        guard settings.localAdjustments != layers else { return true }
        var candidate = settings; candidate.localAdjustments = layers
        _ = try EditingSnapshot(settings: candidate)
        guard acceptSettings?(candidate) != false else { return false }
        if groupStart == nil { remember(settings.localAdjustments) }
        else { history.clearRedo() }
        settings = candidate; errorMessage = nil; updateHistory()
        return true
    }
    private func remember(_ previous: [LocalAdjustment]) {
        history.clearRedo()
        history.appendUndo(previous)
        updateHistory()
    }
    private func updateHistory() {
        canUndo = history.canUndo() || groupStart.map { $0 != settings.localAdjustments } == true
        canRedo = history.canRedo()
    }

    private func generate(_ kind: AutomaticMaskKind, isBackground: Bool = false) {
        guard !isGenerating, let bitmap, let source else { return }
        let token = UUID(), currentSession = session
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
                try self.append(name, shape: kind == .subject ? .subject(raster) : .sky(raster), feather: 0)
            } catch is CancellationError { }
            catch {
                if let self, self.session == currentSession, self.operation == token { self.errorMessage = error.localizedDescription }
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
}
