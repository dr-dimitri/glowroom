import Foundation
import GlowroomCore

/// The dispatcher owns no database/render pool. Final acceptance is a short
/// ordered MainActor transaction through EditingModel's existing admission,
/// history, pending-save and bounded worker ownership.
@MainActor
final class DevelopCommandDispatcher {
    typealias ValidateSource = @Sendable (AIEditingSnapshot) async throws -> Void
    private unowned let editor: EditingModel
    private weak var workspace: DevelopWorkspace?
    private weak var masks: InlineMaskWorkspace?
    private var ledger: DevelopCommandLedger
    private let validateSource: ValidateSource
    private var previewInFlight = false
    var sessionID: UUID { ledger.sessionID }
    var retainedResultCount: Int { ledger.count }

    init(editor: EditingModel, sessionID: UUID = UUID(), validateSource: @escaping ValidateSource = { snapshot in
        let request = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID())
        _ = try await ImageAnalysisPreparer().sourceStamp(for: request)
    }) {
        self.editor = editor; ledger = DevelopCommandLedger(sessionID: sessionID); self.validateSource = validateSource
    }

    func bind(workspace: DevelopWorkspace, masks: InlineMaskWorkspace) {
        self.workspace = workspace; self.masks = masks
    }

    func target(in library: LibraryModel) -> DevelopCommandTarget? {
        guard let snapshot = editor.localEditingAnchorSnapshot(in: library) else { return nil }
        return DevelopCommandTarget(snapshot: snapshot, localRevision: editor.localRevision(for: snapshot.assetID))
    }

    func availability(in library: LibraryModel, mutation: Bool = true,
                      permitsActiveInput: Bool = false, permitsToolHistory: Bool = false) -> DevelopCommandAvailability {
        if library.selectedAsset == nil { return .init(.noPhoto) }
        if editor.isLoading || library.isLoading || library.isProjecting { return .init(.loading) }
        if editor.isReadOnly || library.isReadOnly { return .init(.readOnly) }
        if !mutation { return .init() }
        if !editor.canEdit || !library.canModify || library.isImporting { return .init(.maintenance) }
        if library.comparesOriginal || library.comparesCurrentSourceWithoutSettings { return .init(.comparison) }
        if !permitsToolHistory {
            let unboundTool: Bool
            if workspace == nil, let assetID = library.selectedID {
                switch editor.editingFunction(assetID: assetID) {
                case .masks, .crop, .repair: unboundTool = true
                default: unboundTool = false
                }
            } else { unboundTool = false }
            if masks?.isPresented == true || workspace.map({ $0.tool != .basic }) == true || unboundTool {
                return .init(.activeTool)
            }
        }
        if !permitsActiveInput, let id = library.selectedID,
           editor.hasActiveEditing(assetID: id) || editor.sliderPersistenceSession.hasActiveInput { return .init(.activeInput) }
        return .init()
    }

    func catalog(in library: LibraryModel) -> [DevelopCommandDescriptor] {
        DevelopCommandID.allCases.map { id in
            var state = availability(in: library, mutation: id.isMutation)
            if state.isAvailable, let assetID = library.selectedID {
                if id == .undo, !editor.canUndo(assetID: assetID) { state = .init(.noHistory) }
                if id == .redo, !editor.canRedo(assetID: assetID) { state = .init(.noHistory) }
            }
            return DevelopCommandDescriptor(id, availability: state)
        }
    }

    func nextRequestID() throws -> DevelopCommandRequestID {
        guard ledger.highWater < .max else { throw DevelopCommandError.outcomeUnknown }
        return .init(sessionID: sessionID, sequence: ledger.highWater + 1)
    }

    /// Validation/preview has no history or persistence effect. Source stat IO
    /// runs off MainActor and a late/cancelled result cannot become a commit.
    func preview(_ request: DevelopCommandRequest, in library: LibraryModel) async throws -> EditSettings {
        guard !previewInFlight else { throw DevelopCommandError.unavailable(.maintenance) }
        let command = try request.validate()
        try requireCurrent(request.target, in: library)
        let state = availability(in: library, mutation: command.isMutation)
        guard state.isAvailable else { throw DevelopCommandError.unavailable(state.reason) }
        previewInFlight = true
        defer { previewInFlight = false }
        let expected = request.target.snapshot
        let worker = Task.detached(priority: .userInitiated) { [validateSource] in try await validateSource(expected) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        try requireCurrent(request.target, in: library)
        return try request.patch?.applying(to: expected.settings) ?? expected.settings
    }

    /// Final acceptance is deliberately synchronous; cancellation after this
    /// boundary never cancels an accepted pending save. Call preview separately
    /// when a caller needs filesystem validation or a rendered proposal.
    @discardableResult
    func execute(_ request: DevelopCommandRequest, in library: LibraryModel,
                 permitsActiveInput: Bool = false) throws -> DevelopCommandResult {
        if let cached = try ledger.cached(request) { return try cached.get() }
        let result: Result<DevelopCommandResult, DevelopCommandError>
        do { result = .success(try executeNew(request, in: library, permitsActiveInput: permitsActiveInput)) }
        catch let error as DevelopCommandError { result = .failure(error) }
        catch { result = .failure(.invalidPatch) }
        var bytes = Self.retentionCost(request.target.snapshot.settings)
        if case .success(let value) = result { bytes += Self.retentionCost(value.target.snapshot.settings) }
        ledger.complete(request, result: result, retainedBytes: bytes)
        return try result.get()
    }

    private func executeNew(_ request: DevelopCommandRequest, in library: LibraryModel,
                            permitsActiveInput: Bool) throws -> DevelopCommandResult {
        let command = try request.validate()
        try requireCurrent(request.target, in: library)
        let state = availability(in: library, mutation: command.isMutation, permitsActiveInput: permitsActiveInput)
        guard state.isAvailable else { throw DevelopCommandError.unavailable(state.reason) }
        let assetID = request.target.assetID, revision = editor.localRevision(for: assetID)
        switch command {
        case .get, .controls: break
        case .patch:
            let settings = try request.patch!.applying(to: request.target.snapshot.settings)
            try applySettings(settings, target: request.target, in: library, permitsActiveInput: permitsActiveInput)
        case .undo:
            guard editor.canUndo(assetID: assetID) else { throw DevelopCommandError.unavailable(.noHistory) }
            editor.undo(assetID: assetID)
            guard editor.localRevision(for: assetID) != revision else { throw DevelopCommandError.unavailable(.maintenance) }
        case .redo:
            guard editor.canRedo(assetID: assetID) else { throw DevelopCommandError.unavailable(.noHistory) }
            editor.redo(assetID: assetID)
            guard editor.localRevision(for: assetID) != revision else { throw DevelopCommandError.unavailable(.maintenance) }
        case .reset:
            let requiresChange = request.target.snapshot.settings != request.target.snapshot.settings.resettingAdjustments
            editor.reset(assetID: assetID)
            if requiresChange, editor.localRevision(for: assetID) == revision { throw DevelopCommandError.unavailable(.maintenance) }
        }
        guard let next = target(in: library) else { throw DevelopCommandError.staleTarget }
        return DevelopCommandResult(target: next, didChange: editor.localRevision(for: assetID) != revision,
            controls: command == .controls ? EditParameter.allCases.map(DevelopControlDescriptor.init) : [])
    }

    /// Shared admission for separately typed adapters (portable presets and
    /// existing color/local AI actions). It does not advertise extra controls in
    /// the numeric product catalog and never changes a source.
    func applySettings(_ settings: EditSettings, target expected: DevelopCommandTarget, in library: LibraryModel,
                       permitsActiveInput: Bool = false) throws {
        try requireCurrent(expected, in: library)
        let state = availability(in: library, permitsActiveInput: permitsActiveInput)
        guard state.isAvailable else { throw DevelopCommandError.unavailable(state.reason) }
        for parameter in EditParameter.allCases {
            let value = parameter.value(in: settings)
            guard value.isFinite, parameter.range.contains(value) else { throw DevelopCommandError.invalidPatch }
        }
        try settings.validateLocalAdjustments(); try settings.levels.validate(); try settings.toneCurves.validate()
        try settings.developGeometry.validate()
        guard settings == settings.normalized else { throw DevelopCommandError.invalidPatch }
        if settings == editor.settings(for: expected.assetID) { return }
        editor.selectEditingFunction(.adjustments, assetID: expected.assetID, cancelsActiveInput: false)
        let revision = editor.localRevision(for: expected.assetID)
        editor.setSettings(settings, for: expected.assetID)
        guard editor.localRevision(for: expected.assetID) != revision,
              editor.settings(for: expected.assetID) == settings else { throw DevelopCommandError.unavailable(.maintenance) }
    }

    @discardableResult
    func applyNumericSettings(_ settings: EditSettings, assetID: String, in library: LibraryModel) -> Bool {
        do {
            guard let expected = target(in: library), expected.assetID == assetID else { throw DevelopCommandError.staleTarget }
            let patch = DevelopNumericPatch.difference(from: expected.snapshot.settings, to: settings)
            if try patch.applying(to: expected.snapshot.settings) == settings {
                let request = DevelopCommandRequest(.patch, id: try nextRequestID(), target: expected, patch: patch)
                _ = try execute(request, in: library, permitsActiveInput: true)
            } else { try applySettings(settings, target: expected, in: library, permitsActiveInput: true) }
            return true
        } catch { editor.errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func performHistory(_ command: DevelopCommandID, in library: LibraryModel) -> Bool {
        do {
            guard let expected = target(in: library) else { throw DevelopCommandError.staleTarget }
            _ = try execute(.init(command, id: try nextRequestID(), target: expected), in: library, permitsActiveInput: true)
            return true
        } catch { editor.errorMessage = error.localizedDescription; return false }
    }

    private func requireCurrent(_ expected: DevelopCommandTarget, in library: LibraryModel) throws {
        guard let current = target(in: library), current.assetID == expected.assetID,
              current.localRevision == expected.localRevision,
              current.snapshot.source == expected.snapshot.source,
              current.snapshot.settings == expected.snapshot.settings,
              current.snapshot.token == expected.snapshot.token,
              current.snapshot.persistedVersion?.storeEpoch == expected.snapshot.persistedVersion?.storeEpoch
        else { throw DevelopCommandError.staleTarget }
    }

    static func retentionCost(_ settings: EditSettings) -> Int {
        // Count ownership without encoding, hashing, copying or reading pixels.
        var bytes = 4_096
        for layer in settings.localAdjustments {
            let usage = layer.mask.resourceUsage
            bytes += usage.rasterBytes + usage.brushPoints * MemoryLayout<MaskPoint>.stride
                + usage.brushStrokes * 128 + layer.mask.componentCount * 512
        }
        for stroke in settings.developGeometry.retouchStrokes {
            bytes += stroke.path.count * MemoryLayout<LocalMaskPoint>.stride + (stroke.mask?.bytes.count ?? 0)
                + (stroke.replacement?.rgba.count ?? 0) + 512
        }
        return bytes
    }
}
