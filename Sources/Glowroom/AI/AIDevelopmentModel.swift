import AppKit
import Combine
import Foundation
import GlowroomCore

struct AIDevelopmentReview: Equatable {
    let summary: String
    let changes: [String]
    let settings: EditSettings

    init(proposal: AIDevelopmentProposal, baseline: EditSettings, strength: Double) throws {
        summary = proposal.summary
        settings = try proposal.adjustments.applying(to: baseline, strength: strength)
        let controls: [(String, Double, Double)] = [
            ("Belichtung", baseline.exposure, settings.exposure), ("Kontrast", baseline.contrast, settings.contrast),
            ("Lichter", baseline.highlights, settings.highlights), ("Tiefen", baseline.shadows, settings.shadows),
            ("Weiß", baseline.whites, settings.whites), ("Schwarz", baseline.blacks, settings.blacks),
            ("Dynamik", baseline.vibrance, settings.vibrance), ("Sättigung", baseline.saturation, settings.saturation),
            ("Temperatur", baseline.developColor.temperature, settings.developColor.temperature),
            ("Tönung", baseline.developColor.tint, settings.developColor.tint)]
        changes = controls.compactMap { label, before, after in
            guard before != after else { return nil }
            return "\(label): \(before.formatted(.number.precision(.fractionLength(0...2)))) → \(after.formatted(.number.precision(.fractionLength(0...2))))"
        }
    }
}

@MainActor
final class AIDevelopmentModel: ObservableObject {
    typealias Propose = @Sendable (AIEditingSnapshot, PreviewBitmap, AIDevelopmentIntent) async throws -> AIDevelopmentResponse
    typealias ValidateSource = @Sendable (AIEditingSnapshot, ImageAnalysisSourceStamp) async throws -> Void
    @Published var intent = AIDevelopmentIntent() {
        didSet { if intent != oldValue { discard() } }
    }
    @Published private(set) var proposal: AIDevelopmentReview?
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false
    private let propose: Propose
    private let validateSource: ValidateSource
    private var task: Task<Void, Never>?
    private var expected: AIEditingSnapshot?
    private var sourceStamp: ImageAnalysisSourceStamp?
    private var subscriptions: Set<AnyCancellable> = []
    private var isCurrentContext: (@MainActor () -> Bool)?

    init(propose: @escaping Propose = { snapshot, _, intent in
        try await AIDevelopmentService().propose(snapshot: snapshot, intent: intent)
    }, validateSource: @escaping ValidateSource = { snapshot, stamp in
        let request = ImageAnalysisRequest(snapshot: snapshot, inputKind: .editedPreview, lifecycleID: UUID())
        guard try await ImageAnalysisPreparer().sourceStamp(for: request) == stamp else {
            throw AIDevelopmentError.staleContext
        }
    }) { self.propose = propose; self.validateSource = validateSource }

    deinit { task?.cancel() }

    @discardableResult
    func start(library: LibraryModel, editor: EditingModel, workspace: DevelopWorkspace) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        discard()
        guard library.isAIDeveloping, !library.comparesOriginal, !library.comparesCurrentSourceWithoutSettings,
              workspace.tool == .basic, let assetID = library.selectedID else { return nil }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        editor.selectEditingFunction(.adjustments, assetID: assetID)
        editor.endEditing(assetID: assetID)
        guard let snapshot = editor.aiSnapshot(in: library), let bitmap = workspace.originalBitmap,
              workspace.sourceIdentity == snapshot.source else {
            status = AIDevelopmentError.missingPreview.localizedDescription; return nil
        }
        do { try intent.validate() } catch { status = error.localizedDescription; return nil }
        let requestedIntent = intent
        let bitmapID = ObjectIdentifier(bitmap.image)
        expected = snapshot
        isCurrentContext = { [weak library, weak editor, weak workspace] in
            guard let library, let editor, let workspace else { return false }
            return editor.isCurrentAISnapshot(snapshot, in: library)
                && library.isAIDeveloping
                && !library.comparesOriginal && !library.comparesCurrentSourceWithoutSettings
                && workspace.tool == .basic && workspace.sourceIdentity == snapshot.source
                && workspace.originalBitmap.map { ObjectIdentifier($0.image) } == bitmapID
        }
        subscriptions.removeAll()
        editor.objectWillChange.merge(with: library.objectWillChange, workspace.objectWillChange)
            .sink { [weak self] in
                Task { @MainActor [weak self] in self?.invalidateContextIfNeeded() }
            }.store(in: &subscriptions)
        isRunning = true; status = "Qwen3.5‑4B erstellt einen lokalen Vorschlag …"
        // The worker captures immutable values only. No file IO, source stamps,
        // prompt validation or native inference blocks the main actor.
        let worker = Task.detached(priority: .userInitiated) { [propose] in
            try await propose(snapshot, bitmap, requestedIntent)
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
                self.proposal = try AIDevelopmentReview(proposal: result.proposal, baseline: snapshot.settings, strength: requestedIntent.strength)
                self.sourceStamp = result.sourceStamp
                self.status = self.proposal?.changes.isEmpty == true
                    ? "Das Modell schlägt bei dieser Stärke keine Änderung vor." : "Prüfe den Vorschlag vor dem Übernehmen."
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
              editor.isCurrentAISnapshot(expected, in: library), isCurrentContext?() == true,
              !editor.hasActiveEditing(assetID: expected.assetID) else {
            discard(); status = AIDevelopmentError.staleContext.localizedDescription; return nil
        }
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
                      editor.isCurrentAISnapshot(expected, in: library), self.isCurrentContext?() == true,
                      !editor.hasActiveEditing(assetID: expected.assetID) else { return }
                // Source IO precedes this synchronous main-actor transaction.
                // The final snapshot check and ordinary undo/write stay atomic.
                editor.setSettings(proposal.settings, for: expected.assetID)
                let applied = editor.settings(for: expected.assetID) == proposal.settings
                self.expected = nil; self.proposal = nil; self.sourceStamp = nil
                self.subscriptions.removeAll(); self.isCurrentContext = nil
                self.status = applied ? "Vorschlag übernommen. Mit ⌘Z rückgängig machen." : "Der Vorschlag konnte nicht gespeichert werden."
            } catch {
                guard let self, self.expected == expected, !Task.isCancelled else { return }
                self.expected = nil; self.proposal = nil; self.sourceStamp = nil
                self.status = AIDevelopmentError.staleContext.localizedDescription
            }
        }
        task = operation
        return operation
    }

    func invalidateIfNeeded(library: LibraryModel, editor: EditingModel) {
        guard let expected else { return }
        if !editor.isCurrentAISnapshot(expected, in: library) { discard(); status = AIDevelopmentError.staleContext.localizedDescription }
        else { invalidateContextIfNeeded() }
    }

    private func invalidateContextIfNeeded() {
        if expected != nil, isCurrentContext?() != true {
            discard(); status = AIDevelopmentError.staleContext.localizedDescription
        }
    }

    func cancel() {
        task?.cancel(); expected = nil; proposal = nil; sourceStamp = nil
        status = isRunning ? "Abbruch wird abgeschlossen …" : nil
    }

    func discard() {
        cancel(); subscriptions.removeAll(); isCurrentContext = nil
        if !isRunning { status = nil }
    }
}
