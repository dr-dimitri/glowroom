import AppKit
import Combine
import Foundation
import GlowroomCore

struct AIDevelopmentReview: Equatable, Sendable {
    let summary: String
    let changes: [String]
    let settings: EditSettings
    let targetName: String?
    let createdMaskID: UUID?

    init(proposal: AIDevelopmentProposal, baseline: EditSettings, strength: Double, targetMaskID: UUID? = nil) throws {
        var intent = AIDevelopmentIntent(); intent.strength = strength; intent.targetMaskID = targetMaskID
        let target = try intent.targetMask(in: baseline)
        summary = proposal.summary
        targetName = target?.name; createdMaskID = nil
        let result = try proposal.adjustments.applying(to: baseline, intent: intent)
        settings = result
        let before = target?.settings.editSettings ?? baseline
        let after = targetMaskID.flatMap { id in result.localAdjustments.first { $0.id == id } }?.settings.editSettings ?? result
        let controls: [(String, Double, Double)] = [
            ("Belichtung", before.exposure, after.exposure), ("Kontrast", before.contrast, after.contrast),
            ("Lichter", before.highlights, after.highlights), ("Tiefen", before.shadows, after.shadows),
            ("Weiß", before.whites, after.whites), ("Schwarz", before.blacks, after.blacks),
            ("Dynamik", before.vibrance, after.vibrance), ("Sättigung", before.saturation, after.saturation),
            ("Temperatur", before.developColor.temperature, after.developColor.temperature),
            ("Tönung", before.developColor.tint, after.developColor.tint)]
        changes = controls.compactMap { label, before, after in
            guard before != after else { return nil }
            return "\(label): \(before.formatted(.number.precision(.fractionLength(0...2)))) → \(after.formatted(.number.precision(.fractionLength(0...2))))"
        }
    }

    init(mask response: AIObjectMaskResponse, baseline: EditSettings) throws {
        var result = baseline
        result.localAdjustments.append(response.layer)
        try result.validateLocalAdjustments()
        summary = response.summary
        changes = ["Neue Maske: \(response.layer.name)"]
        settings = result; targetName = response.layer.name; createdMaskID = response.layer.id
    }

}

@MainActor
final class AIDevelopmentModel: ObservableObject {
    typealias Propose = @Sendable (AIEditingSnapshot, PreviewBitmap, AIDevelopmentIntent) async throws -> AIDevelopmentResponse
    typealias ProposeMask = @Sendable (AIEditingSnapshot, String) async throws -> AIObjectMaskResponse
    typealias ValidateSource = @Sendable (AIEditingSnapshot, ImageAnalysisSourceStamp) async throws -> Void
    typealias RenderCorrection = @Sendable (PreviewBitmap, AIEditingSnapshot, EditSettings, ImageAnalysisSourceStamp?) async throws -> PreviewBitmap
    @Published var intent = AIDevelopmentIntent() {
        didSet { if intent != oldValue { discard() } }
    }
    @Published var createsMask = false {
        didSet { if createsMask != oldValue { discard() } }
    }
    @Published private(set) var maskPreview: PreviewBitmap?
    @Published private(set) var proposal: AIDevelopmentReview?
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false
    var canApplyProposal: Bool {
        guard let proposal, !proposal.changes.isEmpty else { return false }
        if proposal.createdMaskID != nil { return true }
        guard let expected, let preview = previewWorkspace?.aiCorrectionPreview else { return false }
        return preview.snapshot == expected && preview.settings == proposal.settings
    }
    private let propose: Propose
    private let proposeMask: ProposeMask
    private let validateSource: ValidateSource
    private let renderCorrection: RenderCorrection
    private weak var previewWorkspace: DevelopWorkspace?
    private var task: Task<Void, Never>?
    private var expected: AIEditingSnapshot?
    private var sourceStamp: ImageAnalysisSourceStamp?
    private var subscriptions: Set<AnyCancellable> = []
    private var isCurrentContext: (@MainActor () -> Bool)?

    init(propose: @escaping Propose = { snapshot, _, intent in
        try await AIDevelopmentService().propose(snapshot: snapshot, intent: intent)
    }, proposeMask: @escaping ProposeMask = { snapshot, instruction in
        try await AIObjectMaskService().propose(snapshot: snapshot, instruction: instruction)
    }, validateSource: @escaping ValidateSource = { snapshot, stamp in
        let request = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID())
        guard try await ImageAnalysisPreparer().sourceStamp(for: request) == stamp else {
            throw AIDevelopmentError.staleContext
        }
    }, renderCorrection: @escaping RenderCorrection = { bitmap, snapshot, settings, sourceStamp in
        // Reuse the exact decoded canvas source. The shared render actor bounds
        // Core Image work and caches repeated proposals without another RAW decode.
        let request = PreviewRequest(source: snapshot.source,
            pixelSize: min(2_400, max(bitmap.image.width, bitmap.image.height)),
            allowsEmbeddedPreview: false, sourceRevision: sourceStamp?.cacheRevision,
            allowsHDR: snapshot.settings.developColor.hdrEnabled)
        return try await AdjustedPreviewPipeline.shared.image(bitmap, request: request,
            settings: settings, priority: .selected, maximumOutputPixelSize: request.pixelSize)
    }) {
        self.propose = propose; self.proposeMask = proposeMask
        self.validateSource = validateSource; self.renderCorrection = renderCorrection
    }

    deinit { task?.cancel() }

    @discardableResult
    func start(library: LibraryModel, editor: EditingModel, workspace: DevelopWorkspace) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        discard()
        guard library.isDeveloping, !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings,
              workspace.tool == .basic, let assetID = library.selectedID else { return nil }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        editor.selectEditingFunction(.adjustments, assetID: assetID)
        editor.endEditing(assetID: assetID)
        guard let snapshot = editor.aiSnapshot(in: library), let bitmap = workspace.originalBitmap,
              workspace.isFinalPreviewReady,
              workspace.sourceIdentity == snapshot.source else {
            status = AIDevelopmentError.missingPreview.localizedDescription; return nil
        }
        do {
            try intent.validate()
            if createsMask {
                guard !intent.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      snapshot.settings.localAdjustments.count < LocalAdjustment.maximumCount else {
                    status = "Beschreibe das Objekt. Pro Foto sind höchstens 16 Masken möglich."; return nil
                }
            } else { _ = try intent.targetMask(in: snapshot.settings) }
        } catch { status = error.localizedDescription; return nil }
        let requestedIntent = intent
        let createsMask = self.createsMask
        let bitmapID = ObjectIdentifier(bitmap.image)
        let bitmapStamp = workspace.originalSourceStamp
        expected = snapshot
        previewWorkspace = workspace
        let previewRequest = workspace.beginCorrectionPreview()
        isCurrentContext = { [weak library, weak editor, weak workspace] in
            guard let library, let editor, let workspace else { return false }
            return Self.matchesEditingContext(snapshot, editor.localEditingAnchorSnapshot(in: library))
                && library.isDeveloping
                && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings
                && workspace.tool == .basic && workspace.sourceIdentity == snapshot.source
                && workspace.originalBitmap.map { ObjectIdentifier($0.image) } == bitmapID
                && workspace.originalSourceStamp == bitmapStamp
        }
        subscriptions.removeAll()
        // Published values invalidate synchronously at navigation boundaries.
        // A rapid leave/return must not evade the deferred snapshot check below.
        library.$workspaceMode.dropFirst().sink { [weak self] mode in
            if mode == .library { self?.invalidateEditingContext() }
        }.store(in: &subscriptions)
        workspace.$tool.dropFirst().sink { [weak self] tool in
            if tool != .basic { self?.invalidateEditingContext() }
        }.store(in: &subscriptions)
        library.$comparesOriginal.dropFirst().sink { [weak self] comparing in
            if comparing { self?.invalidateEditingContext() }
        }.store(in: &subscriptions)
        library.$comparesCurrentSourceWithoutSettings.dropFirst().sink { [weak self] comparing in
            if comparing { self?.invalidateEditingContext() }
        }.store(in: &subscriptions)
        editor.objectWillChange.merge(with: library.objectWillChange, workspace.objectWillChange)
            .sink { [weak self] in
                Task { @MainActor [weak self] in self?.invalidateContextIfNeeded() }
            }.store(in: &subscriptions)
        isRunning = true; status = "Qwen3.5‑4B erstellt einen lokalen Vorschlag …"
        // The worker captures immutable values only. No file IO, source stamps,
        // prompt validation or native inference blocks the main actor.
        let worker = Task.detached(priority: .userInitiated) { [propose, proposeMask, renderCorrection] in
            if createsMask {
                let response = try await proposeMask(snapshot, requestedIntent.instruction)
                if let bitmapStamp, response.sourceStamp != bitmapStamp { throw AIDevelopmentError.staleContext }
                let review = try AIDevelopmentReview(mask: response, baseline: snapshot.settings)
                return (review, response.sourceStamp, response.preview, Optional<PreviewBitmap>.none)
            }
            let response = try await propose(snapshot, bitmap, requestedIntent)
            // A native replacement can preserve the catalog size and mtime.
            // Never preview a proposal from that new file on an older decoded
            // canvas, even when its public source identity still compares equal.
            if let bitmapStamp, response.sourceStamp != bitmapStamp { throw AIDevelopmentError.staleContext }
            let review = try AIDevelopmentReview(proposal: response.proposal, baseline: snapshot.settings,
                strength: requestedIntent.strength, targetMaskID: requestedIntent.targetMaskID)
            try Task.checkCancellation()
            let preview: PreviewBitmap?
            if review.changes.isEmpty { preview = nil }
            else {
                do { preview = try await renderCorrection(bitmap, snapshot, review.settings, bitmapStamp) }
                catch is CancellationError { throw CancellationError() }
                catch { throw AICorrectionRenderingError() }
            }
            return (review, response.sourceStamp, Optional<PreviewBitmap>.none, preview)
        }
        let operation = Task { [weak self] in
            defer {
                self?.isRunning = false; self?.task = nil
                if self?.status == "Abbruch wird abgeschlossen …" { self?.status = "Abgebrochen." }
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.expected == snapshot, self.isCurrentContext?() == true else { return }
                self.proposal = result.0
                self.sourceStamp = result.1
                self.maskPreview = result.2
                if let preview = result.3 {
                    guard workspace.correctionPreviewRequestID == previewRequest else {
                        self.discard(); self.status = "Eine neuere Vorschau ist aktiv."; return
                    }
                    workspace.aiCorrectionPreview = AICorrectionPreview(snapshot: snapshot,
                        settings: result.0.settings, bitmap: preview)
                    workspace.showsAICorrectionProposal = true
                }
                self.status = self.proposal?.changes.isEmpty == true
                    ? "Keine Änderung vorgeschlagen." : "Vorschlag bereit."
            } catch {
                guard let self else { return }
                if error is CancellationError || Task.isCancelled {
                    if self.expected != nil { self.status = "Abgebrochen." }
                } else if self.expected == snapshot, self.isCurrentContext?() == true {
                    self.status = (error as? LocalizedError)?.errorDescription ?? AIDevelopmentError.inferenceFailed.localizedDescription
                }
            }
        }
        task = operation
        return operation
    }

    @discardableResult
    func apply(library: LibraryModel, editor: EditingModel) -> Task<Void, Never>? {
        guard !isRunning, let expected, let proposal, let sourceStamp,
              Self.matchesEditingContext(expected, editor.localEditingAnchorSnapshot(in: library)), isCurrentContext?() == true,
              !editor.hasActiveEditing(assetID: expected.assetID) else {
            discard(); status = AIDevelopmentError.staleContext.localizedDescription; return nil
        }
        // A valid model response can preserve every value (also at strength 0).
        // It must never report a successful edit when setSettings would be a no-op.
        guard canApplyProposal, editor.canEdit else { return nil }
        isRunning = true; status = "Bildquelle wird vor der Übernahme geprüft …"
        let worker = Task.detached(priority: .userInitiated) { [validateSource] in
            try await validateSource(expected, sourceStamp)
        }
        let operation = Task { [weak self] in
            defer {
                self?.isRunning = false; self?.task = nil
                if self?.status == "Abbruch wird abgeschlossen …" { self?.status = "Abgebrochen." }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.expected == expected,
                      Self.matchesEditingContext(expected, editor.localEditingAnchorSnapshot(in: library)), self.isCurrentContext?() == true,
                      !editor.hasActiveEditing(assetID: expected.assetID) else { return }
                guard self.canApplyProposal else {
                    self.status = "Erstelle die Vorschau erneut, bevor du sie übernimmst."; return
                }
                guard editor.canEdit else {
                    self.status = "Automatische Sicherung läuft. Übernimm den Vorschlag anschließend erneut."
                    return
                }
                // Source IO precedes this synchronous main-actor transaction.
                // The final snapshot check and ordinary undo/write stay atomic.
                if proposal.targetName == nil, proposal.createdMaskID == nil {
                    guard editor.developCommands.applyNumericSettings(proposal.settings,
                        assetID: expected.assetID, in: library) else { return }
                } else {
                    // Mask actions keep their existing typed adapter and local
                    // semantics; the numeric command catalog does not claim them.
                    editor.setSettings(proposal.settings, for: expected.assetID)
                }
                let applied = editor.settings(for: expected.assetID) == proposal.settings
                self.clearCorrectionPreview()
                self.expected = nil; self.proposal = nil; self.sourceStamp = nil; self.maskPreview = nil
                self.subscriptions.removeAll(); self.isCurrentContext = nil
                if !applied { self.status = "Der Vorschlag konnte nicht gespeichert werden." }
                else if proposal.createdMaskID != nil {
                    self.status = "Maske hinzugefügt."
                } else if let name = proposal.targetName {
                    self.status = "Vorschlag auf „\(name)“ übernommen."
                } else { self.status = "Vorschlag übernommen." }
            } catch {
                guard let self, self.expected == expected, !Task.isCancelled else { return }
                self.clearCorrectionPreview()
                self.expected = nil; self.proposal = nil; self.sourceStamp = nil; self.maskPreview = nil
                self.status = AIDevelopmentError.staleContext.localizedDescription
            }
        }
        task = operation
        return operation
    }

    func invalidateIfNeeded(library: LibraryModel, editor: EditingModel) {
        guard let expected else { return }
        if !Self.matchesEditingContext(expected, editor.localEditingAnchorSnapshot(in: library)) { discard(); status = AIDevelopmentError.staleContext.localizedDescription }
        else { invalidateContextIfNeeded() }
    }

    private static func matchesEditingContext(_ expected: AIEditingSnapshot, _ current: AIEditingSnapshot?) -> Bool {
        guard let current else { return false }
        // Saving already accepted edits only advances the durable revision.
        // The source, visible settings, edit/selection generations and store
        // epoch still protect against edits, undo, navigation and restoration.
        // This proposal uses the ordinary editor write, not a captured SQL CAS.
        return current.assetID == expected.assetID && current.source == expected.source
            && current.settings == expected.settings && current.token == expected.token
            && current.persistedVersion?.storeEpoch == expected.persistedVersion?.storeEpoch
    }

    private func invalidateContextIfNeeded() {
        if expected != nil, isCurrentContext?() != true {
            invalidateEditingContext()
        }
    }

    private func invalidateEditingContext() {
        guard expected != nil else { return }
        discard(); status = AIDevelopmentError.staleContext.localizedDescription
    }

    func cancel() {
        clearCorrectionPreview()
        task?.cancel(); expected = nil; proposal = nil; sourceStamp = nil; maskPreview = nil
        status = isRunning ? "Abbruch wird abgeschlossen …" : nil
    }

    func discard() {
        cancel(); subscriptions.removeAll(); isCurrentContext = nil
        if !isRunning { status = nil }
    }

    private func clearCorrectionPreview() {
        previewWorkspace?.aiCorrectionPreview = nil
        previewWorkspace = nil
    }
}

private struct AICorrectionRenderingError: LocalizedError {
    var errorDescription: String? { "Die Vorschau des Vorschlags konnte nicht erstellt werden. Erstelle den Vorschlag erneut." }
}
