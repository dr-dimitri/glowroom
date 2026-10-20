import AppKit
import Combine
import Foundation
import GlowroomCore

/// Ephemeral, explicit analysis only. Neither the service nor this model has a
/// route to edit settings, undo history or confirmed catalog metadata.
@MainActor
final class ImageAnalysisModel: ObservableObject {
    enum State: Equatable {
        case idle
        case unavailable(ImageAnalysisUnavailableReason)
        case analyzing
        case ready
        case failed(String)
    }

    @Published var inputKind: ImageAnalysisInputKind = .originalPreview {
        didSet { if oldValue != inputKind { discard() } }
    }
    @Published private(set) var availability: ImageAnalysisAvailability?
    @Published private(set) var state: State = .idle
    @Published private(set) var result: ImageAnalysisResult?

    private let service: any ImageAnalysisServing
    private let snapshot: @MainActor (ImageAnalysisInputKind) -> AIEditingSnapshot?
    private var snapshotByKind: (@MainActor (ImageAnalysisInputKind) -> AIEditingSnapshot?)?
    private let commitInput: @MainActor () -> Void
    private var lifecycleID = UUID()
    private var request: ImageAnalysisRequest?
    private var task: Task<Void, Never>?
    private var availabilityCheckID = UUID()
    private var subscriptions: Set<AnyCancellable> = []

    init(service: any ImageAnalysisServing,
         snapshot: @escaping @MainActor () -> AIEditingSnapshot?,
         commitInput: @escaping @MainActor () -> Void = {}) {
        self.service = service
        self.snapshot = { _ in snapshot() }
        self.commitInput = commitInput
    }

    convenience init(service: any ImageAnalysisServing, editor: EditingModel, library: LibraryModel) {
        self.init(service: service, snapshot: { [weak editor, weak library] in
            guard let editor, let library else { return nil }
            return editor.aiSnapshot(in: library, intent: .importedOriginal)
        }, commitInput: { [weak editor, weak library] in
            NSApp?.keyWindow?.makeFirstResponder(nil)
            if let assetID = library?.selectedID { editor?.endEditing(assetID: assetID) }
        })
        self.snapshotByKind = { [weak editor, weak library] kind in
            guard let editor, let library else { return nil }
            return editor.aiSnapshot(in: library, intent: kind == .originalPreview ? .importedOriginal : .currentEditing)
        }
        // Epoch checks are deferred until @Published's complete mutation has
        // finished. Manual settings changes leave original analysis current.
        editor.objectWillChange.merge(with: library.objectWillChange).sink { [weak self] in
            Task { @MainActor [weak self] in self?.contextDidChange() }
        }.store(in: &subscriptions)
        // Maintenance can begin and finish before a deferred observer runs.
        // Its start must synchronously rotate this observer's lifecycle epoch.
        editor.$isRestoring.merge(with: editor.$isBackingUp, editor.$isClosing, library.$isClosing)
            .sink { [weak self] blocked in
                if blocked { self?.invalidateLifecycle() }
            }.store(in: &subscriptions)
    }

    deinit { task?.cancel() }

    var canAnalyze: Bool { state != .analyzing && availability == .available && currentSnapshot() != nil }
    var executionLocation: String { service.descriptor.executionLocation }
    var contextAvailable: Bool { currentSnapshot() != nil }

    func refreshAvailability() async {
        let checkID = UUID()
        availabilityCheckID = checkID
        let value = await service.availability()
        guard !Task.isCancelled, availabilityCheckID == checkID else { return }
        availability = value
        if request == nil, result == nil { state = restingState }
    }

    func analyze() {
        guard state != .analyzing else { return }
        if inputKind == .editedPreview { commitInput() }
        discard()
        guard availability == .available else { return }
        guard let current = currentSnapshot() else {
            state = .failed("Die Bildanalyse ist während Laden, Sicherung, Wiederherstellung oder Schließen nicht verfügbar.")
            return
        }
        let request = ImageAnalysisRequest(snapshot: current, inputKind: inputKind, language: "de_DE", lifecycleID: lifecycleID)
        self.request = request
        state = .analyzing
        let service = self.service
        task = Task { [weak self] in
            do {
                let response = try await service.analyze(request)
                try Task.checkCancellation()
                guard let self, self.request?.id == request.id else { return }
                guard self.isCurrent(request), response.request.id == request.id,
                      response.request.inputKind == request.inputKind,
                      self.isCurrent(response.request) else { self.discard(); return }
                self.request = nil
                self.task = nil
                self.result = response
                self.state = .ready
            } catch {
                guard let self, self.request?.id == request.id else { return }
                guard self.isCurrent(request) else { self.discard(); return }
                self.request = nil
                self.task = nil
                if error is CancellationError || (error as? ImageAnalysisError) == .cancelled || (error as? ImageAnalysisError) == .superseded {
                    self.state = self.restingState
                } else if case .unavailable(let reason) = error as? ImageAnalysisError {
                    self.availability = .unavailable(reason)
                    self.state = .unavailable(reason)
                } else {
                    self.state = .failed((error as? ImageAnalysisError)?.localizedDescription ?? ImageAnalysisError.providerFailure.localizedDescription)
                }
            }
        }
    }

    func discard() {
        request = nil
        task?.cancel()
        task = nil
        result = nil
        state = restingState
        // Cancel this observer only. Another user of the shared analysis service
        // may still need the same inference and its existing resource lease.
    }

    func contextDidChange() {
        if let expected = request ?? result?.request, !isCurrent(expected) { discard() }
        else { objectWillChange.send() }
    }

    func invalidateLifecycle() {
        lifecycleID = UUID()
        discard()
    }

    private func isCurrent(_ request: ImageAnalysisRequest) -> Bool {
        guard let current = currentSnapshot() else { return false }
        return request.matches(current: current, lifecycleID: lifecycleID)
    }

    private func currentSnapshot() -> AIEditingSnapshot? {
        if let snapshotByKind { return snapshotByKind(inputKind) }
        return snapshot(inputKind)
    }

    private var restingState: State {
        if case .unavailable(let reason) = availability { return .unavailable(reason) }
        return .idle
    }
}
