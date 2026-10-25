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
    let includesMaskCorrection: Bool

    init(external settings: EditSettings, baseline: EditSettings) {
        summary = "Korrekturvorschlag eines verbundenen MCP-Clients"
        targetName = nil; createdMaskID = nil; includesMaskCorrection = false; self.settings = settings
        changes = EditParameter.allCases.compactMap { parameter in
            let before = parameter.value(in: baseline), after = parameter.value(in: settings)
            return before == after ? nil : "\(parameter.rawValue): \(before.formatted()) → \(after.formatted())"
        }
    }

    init(proposal: AIDevelopmentProposal, baseline: EditSettings, strength: Double, targetMaskID: UUID? = nil) throws {
        var intent = AIDevelopmentIntent(); intent.strength = strength; intent.targetMaskID = targetMaskID
        let target = try intent.targetMask(in: baseline)
        summary = proposal.summary
        targetName = target?.name; createdMaskID = nil; includesMaskCorrection = false
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
        settings = result; targetName = response.layer.name; createdMaskID = response.layer.id; includesMaskCorrection = false
    }

    init(plan: AIEditPlan, baseline: AIEditingSnapshot) throws {
        settings = try plan.applying(to: baseline)
        summary = plan.explanation; targetName = plan.layer.name
        createdMaskID = plan.layer.id; includesMaskCorrection = true
        let values = plan.layer.settings
        let proposal = AIDevelopmentProposal(summary: plan.explanation, adjustments: .init(
            exposure: values.exposure, contrast: values.contrast, highlights: values.highlights,
            shadows: values.shadows, whites: values.whites, blacks: values.blacks,
            vibrance: values.vibrance, saturation: values.saturation,
            temperature: values.temperature, tint: values.tint))
        var draft = baseline.settings
        var neutral = plan.layer; neutral.settings = .neutral; draft.localAdjustments.append(neutral)
        let localReview = try Self(proposal: proposal, baseline: draft, strength: 1, targetMaskID: neutral.id)
        changes = ["Neue Maske: \(plan.layer.name)"] + localReview.changes
    }

}

@MainActor
final class AIDevelopmentModel: ObservableObject {
    typealias Propose = @Sendable (AIEditingSnapshot, PreviewBitmap, AIDevelopmentIntent) async throws -> AIDevelopmentResponse
    enum RequestMode: String, CaseIterable, Identifiable {
        case correction, maskOnly, maskCorrection
        var id: Self { self }
    }
    enum ReviewDisplay { case current, proposal, selection }
    typealias ProposePlan = @Sendable (AIEditingSnapshot, String) async throws -> AIEditPlanResponse
    typealias ProposeMask = @Sendable (AIEditingSnapshot, String) async throws -> AIObjectMaskResponse
    typealias ValidateSource = @Sendable (AIEditingSnapshot, ImageAnalysisSourceStamp) async throws -> Void
    typealias RenderCorrection = @Sendable (PreviewBitmap, AIEditingSnapshot, EditSettings, ImageAnalysisSourceStamp?) async throws -> PreviewBitmap
    @Published var intent = AIDevelopmentIntent() {
        didSet { if intent != oldValue { discard() } }
    }
    @Published var requestMode = RequestMode.correction {
        didSet { if requestMode != oldValue { discard() } }
    }
    // Compatibility for the existing direct-object-mask adapter and its tests.
    var createsMask: Bool {
        get { requestMode == .maskOnly }
        set { requestMode = newValue ? .maskOnly : .correction }
    }
    let permitsEditPlans: Bool
    @Published private(set) var reviewDisplay = ReviewDisplay.current
    @Published private(set) var maskPreview: PreviewBitmap?
    @Published private(set) var proposal: AIDevelopmentReview?
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false
    private(set) var externalRequestID: String?
    private(set) var externalOutcome: String? {
        didSet {
            if let id = externalRequestID, let state = externalOutcome { lastExternalResult = (id, state) }
        }
    }
    private(set) var lastExternalResult: (id: String, state: String)?
    var canApplyProposal: Bool {
        guard let proposal, !proposal.changes.isEmpty else { return false }
        if proposal.createdMaskID != nil && !proposal.includesMaskCorrection { return true }
        guard let expected, let preview = previewWorkspace?.aiCorrectionPreview else { return false }
        return preview.snapshot == expected && preview.settings == proposal.settings
    }
    private let propose: Propose
    private let proposeMask: ProposeMask
    private let proposePlan: ProposePlan
    private var correctionBitmap: PreviewBitmap?
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
    }, proposePlan: ProposePlan? = nil, validateSource: @escaping ValidateSource = { snapshot, stamp in
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
        self.permitsEditPlans = AIEditPlanQualification.productEnabled || proposePlan != nil
        self.proposePlan = proposePlan ?? { snapshot, instruction in
            try await AIEditPlanService().propose(snapshot: snapshot, instruction: instruction)
        }
        self.validateSource = validateSource; self.renderCorrection = renderCorrection
    }

    deinit { task?.cancel() }

    /// An external client receives no commit capability. Its absolute numeric
    /// patch enters the same visible review, source check and one-step undo path.
    func prepareExternal(snapshot: AIEditingSnapshot, patch: DevelopNumericPatch, requestID: String = UUID().uuidString,
                         library: LibraryModel, editor: EditingModel, workspace: DevelopWorkspace) async throws {
        guard !isRunning, proposal == nil, library.isDeveloping, workspace.tool == .basic,
              editor.developCommands.availability(in: library).isAvailable,
              Self.matchesEditingContext(snapshot, editor.localEditingAnchorSnapshot(in: library)),
              let bitmap = workspace.originalBitmap, let stamp = workspace.originalSourceStamp,
              workspace.isFinalPreviewReady, workspace.sourceIdentity == snapshot.source else {
            throw MCPFailure("inactive_target", "Open the target photo in Develop and finish active tools first.")
        }
        let settings = try patch.applying(to: snapshot.settings)
        guard settings != snapshot.settings else { throw MCPFailure("no_change", "The proposal does not change a control.") }
        let review = AIDevelopmentReview(external: settings, baseline: snapshot.settings)
        discard()
        // The external numeric contract is global. Keep its visible scope in
        // agreement even after a previous local-mask or combined-plan request.
        requestMode = .correction
        var globalIntent = intent; globalIntent.targetMaskID = nil; intent = globalIntent
        expected = snapshot; sourceStamp = stamp; previewWorkspace = workspace
        externalRequestID = requestID; externalOutcome = "preparing"
        let request = workspace.beginCorrectionPreview()
        isCurrentContext = { [weak library, weak editor, weak workspace] in
            guard let library, let editor, let workspace else { return false }
            return library.isDeveloping && workspace.tool == .basic
                && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings
                && workspace.sourceIdentity == snapshot.source && workspace.originalSourceStamp == stamp
                && Self.matchesEditingContext(snapshot, editor.localEditingAnchorSnapshot(in: library))
        }
        // A synchronous departure invalidates even A→B→A before a deferred
        // objectWillChange check can observe the intervening workspace/tool.
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
            .sink { [weak self] in Task { @MainActor [weak self] in self?.invalidateContextIfNeeded() } }
            .store(in: &subscriptions)
        isRunning = true; status = "MCP-Vorschlag wird vorbereitet …"
        defer { isRunning = false }
        do {
            let worker = Task.detached(priority: .userInitiated) { [validateSource, renderCorrection] in
                try await validateSource(snapshot, stamp)
                try Task.checkCancellation()
                let result = try await renderCorrection(bitmap, snapshot, settings, stamp)
                try await validateSource(snapshot, stamp)
                return result
            }
            let rendered = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard expected == snapshot, isCurrentContext?() == true, request == workspace.correctionPreviewRequestID else {
                throw MCPFailure("conflict", "The photo or editing context changed.")
            }
            proposal = review
            correctionBitmap = rendered; reviewDisplay = .proposal
            externalOutcome = "ready"
            workspace.aiCorrectionPreview = .init(snapshot: snapshot, settings: settings, bitmap: rendered)
            workspace.showsAICorrectionProposal = true
            status = "MCP-Vorschlag bereit. Prüfe die Bildwirkung und übernimm ausdrücklich."
        } catch { discard(); externalOutcome = "failed"; throw error }
    }

    @discardableResult
    func start(library: LibraryModel, editor: EditingModel, workspace: DevelopWorkspace) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        discard()
        externalRequestID = nil; externalOutcome = nil
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
            if requestMode == .maskCorrection, !permitsEditPlans {
                status = "Der gemeinsame Maskenauftrag ist noch nicht freigegeben."; return nil
            }
            if requestMode != .correction {
                guard !intent.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      snapshot.settings.localAdjustments.count < LocalAdjustment.maximumCount else {
                    status = "Beschreibe das Objekt. Pro Foto sind höchstens 16 Masken möglich."; return nil
                }
            } else { _ = try intent.targetMask(in: snapshot.settings) }
        } catch { status = error.localizedDescription; return nil }
        let requestedIntent = intent
        let requestMode = self.requestMode
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
        let worker = Task.detached(priority: .userInitiated) { [propose, proposeMask, proposePlan, renderCorrection, validateSource] in
            if requestMode == .maskCorrection {
                let response = try await proposePlan(snapshot, requestedIntent.instruction)
                if let bitmapStamp, response.sourceStamp != bitmapStamp { throw AIDevelopmentError.staleContext }
                let review = try AIDevelopmentReview(plan: response.plan, baseline: snapshot)
                try Task.checkCancellation()
                async let correction = renderCorrection(bitmap, snapshot, review.settings, response.sourceStamp)
                async let overlay = AIEditPlanSelectionPreview.render(bitmap, snapshot: snapshot,
                    mask: response.plan.layer.mask, stamp: response.sourceStamp)
                let rendered = try await (correction, overlay)
                try await validateSource(snapshot, response.sourceStamp)
                try Task.checkCancellation()
                return (review, response.sourceStamp, Optional(rendered.1), Optional(rendered.0))
            }
            if requestMode == .maskOnly {
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
                self.correctionBitmap = result.3
                self.reviewDisplay = result.3 == nil ? .current : .proposal
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
                if self.externalRequestID != nil { self.externalOutcome = applied ? "accepted" : "failed" }
                self.clearCorrectionPreview()
                self.expected = nil; self.proposal = nil; self.sourceStamp = nil; self.maskPreview = nil
                self.subscriptions.removeAll(); self.isCurrentContext = nil
                if !applied { self.status = "Der Vorschlag konnte nicht gespeichert werden." }
                else if proposal.includesMaskCorrection {
                    self.status = "Maske und Korrektur übernommen."
                } else if proposal.createdMaskID != nil {
                    self.status = "Maske hinzugefügt."
                } else if let name = proposal.targetName {
                    self.status = "Vorschlag auf „\(name)“ übernommen."
                } else { self.status = "Vorschlag übernommen." }
            } catch {
                guard let self, self.expected == expected, !Task.isCancelled else { return }
                if self.externalRequestID != nil { self.externalOutcome = "failed" }
                self.clearCorrectionPreview()
                self.expected = nil; self.proposal = nil; self.sourceStamp = nil; self.maskPreview = nil
                self.status = AIDevelopmentError.staleContext.localizedDescription
            }
        }
        task = operation
        return operation
    }

    func showReview(_ display: ReviewDisplay, workspace: DevelopWorkspace) {
        guard let proposal, let expected else { return }
        if display == .selection {
            guard proposal.includesMaskCorrection, let maskPreview else { return }
            workspace.aiCorrectionPreview = AICorrectionPreview(snapshot: expected, settings: proposal.settings, bitmap: maskPreview)
        } else if let correctionBitmap {
            workspace.aiCorrectionPreview = AICorrectionPreview(snapshot: expected, settings: proposal.settings, bitmap: correctionBitmap)
        }
        reviewDisplay = display
        workspace.showsAICorrectionProposal = display != .current
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
        if externalRequestID != nil, externalOutcome == "ready" || externalOutcome == "preparing" { externalOutcome = "discarded" }
        clearCorrectionPreview()
        task?.cancel(); expected = nil; proposal = nil; sourceStamp = nil; maskPreview = nil
        status = isRunning ? "Abbruch wird abgeschlossen …" : nil
    }

    func discard() {
        cancel(); subscriptions.removeAll(); isCurrentContext = nil
        if !isRunning { status = nil }
    }

    private func clearCorrectionPreview() {
        correctionBitmap = nil; reviewDisplay = .current
        previewWorkspace?.aiCorrectionPreview = nil
        previewWorkspace = nil
    }
}

private struct AICorrectionRenderingError: LocalizedError {
    var errorDescription: String? { "Die Vorschau des Vorschlags konnte nicht erstellt werden. Erstelle den Vorschlag erneut." }
}

/// The selected area is composited on the same accepted full source, then sent
/// through the saved display geometry. Both render passes use existing bounded
/// workers and reuse the canvas bitmap; they never reopen a RAW original.
private enum AIEditPlanSelectionPreview {
    static func render(_ bitmap: PreviewBitmap, snapshot: AIEditingSnapshot,
                       mask: LocalAdjustmentMask, stamp: ImageAnalysisSourceStamp) async throws -> PreviewBitmap {
        let request = PreviewRequest(source: snapshot.source,
            pixelSize: min(2400, max(bitmap.image.width, bitmap.image.height)), allowsEmbeddedPreview: false,
            sourceRevision: stamp.cacheRevision, allowsHDR: snapshot.settings.developColor.hdrEnabled)
        let full = AIDevelopmentMaskInput.fullCanvasSnapshot(snapshot)
        let basis = try await AdjustedPreviewPipeline.shared.image(bitmap, request: request,
            settings: full.settings, priority: .selected, maximumOutputPixelSize: request.pixelSize)
        let overlay = try await LocalMaskOverlayWorker.shared.image(mask,
            size: ArtifactPixelSize(width: basis.image.width, height: basis.image.height))
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: basis.image.width, height: basis.image.height,
            bitsPerComponent: 8, bytesPerRow: basis.image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AIDevelopmentError.missingPreview
        }
        let rect = CGRect(x: 0, y: 0, width: basis.image.width, height: basis.image.height)
        context.draw(basis.image, in: rect); context.setAlpha(0.5); context.draw(overlay, in: rect)
        guard let image = context.makeImage() else { throw AIDevelopmentError.missingPreview }
        var settings = EditSettings.neutral
        settings.developGeometry = snapshot.settings.developGeometry
        settings.developGeometry.retouchStrokes = []; settings.developGeometry.redEyeCorrections = []
        return try await AdjustedPreviewPipeline.shared.image(PreviewBitmap(image: image), request: request,
            settings: settings, priority: .selected, maximumOutputPixelSize: request.pixelSize)
    }
}
