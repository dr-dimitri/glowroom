import AppKit
import Combine
import Foundation
import PicEditCore

/// Only owns an ephemeral proposal. The editor remains the sole owner of edits,
/// history and saving; inference and source checks run outside MainActor.
@MainActor
final class AIAssistantModel: ObservableObject {
    enum State: Equatable {
        case idle
        case unavailable(AIUnavailableReason)
        case generating
        case previewing
        case failed(String)
    }

    enum Comparison: String, CaseIterable, Identifiable {
        case current = "Aktuelle Bearbeitung"
        case proposal = "Vorschlag"
        var id: Self { self }
    }

    struct Change: Identifiable, Equatable {
        let parameter: EditParameter
        let baseline: Double
        let target: Double
        var id: EditParameter { parameter }
        var delta: Double { target - baseline }
    }

    @Published var prompt = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var availability: AIAvailability?
    @Published private(set) var result: AIProposalResult?
    @Published var comparison: Comparison = .proposal

    let maximumPromptBytes: Int
    private let provider: any AIEditingProvider
    private let coordinator: AIRequestCoordinator
    private let snapshot: @MainActor () -> AIEditingSnapshot?
    private let accept: @MainActor (AIProposalResult) -> Bool
    private let commitInput: @MainActor () -> Void
    private let sourceReadable: @Sendable (AIEditingSnapshot) async -> Bool
    private var subscriptions: Set<AnyCancellable> = []
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var requestSnapshot: AIEditingSnapshot?
    private var availabilityCheckID = UUID()

    init(provider: any AIEditingProvider, coordinator: AIRequestCoordinator,
         maximumPromptBytes: Int = 16_384,
         snapshot: @escaping @MainActor () -> AIEditingSnapshot?,
         accept: @escaping @MainActor (AIProposalResult) -> Bool,
         commitInput: @escaping @MainActor () -> Void = {},
         sourceReadable: @escaping @Sendable (AIEditingSnapshot) async -> Bool = { await AIAssistantModel.checkSource($0) }) {
        self.provider = provider
        self.coordinator = coordinator
        self.maximumPromptBytes = max(1, maximumPromptBytes)
        self.snapshot = snapshot
        self.accept = accept
        self.commitInput = commitInput
        self.sourceReadable = sourceReadable
    }

    convenience init(provider: any AIEditingProvider, coordinator: AIRequestCoordinator,
                     editor: EditingModel, library: LibraryModel, maximumPromptBytes: Int = 16_384) {
        self.init(provider: provider, coordinator: coordinator,
                  maximumPromptBytes: maximumPromptBytes,
                  snapshot: { [weak editor, weak library] in
                      guard let editor, let library else { return nil }
                      return editor.aiSnapshot(in: library)
                  }, accept: { [weak editor, weak library] result in
                      guard let editor, let library else { return false }
                      // Close the original comparison before applying a clearly
                      // labelled proposal; the proposal never changes this flag.
                      library.comparesOriginal = false
                      return editor.acceptAIProposal(result, in: library)
                  }, commitInput: { [weak editor, weak library] in
                      NSApp?.keyWindow?.makeFirstResponder(nil)
                      if let assetID = library?.selectedID { editor?.endEditing(assetID: assetID) }
                  })
        // @Published emits before mutation. Defer the check one MainActor turn
        // so epochs and their complete catalog/settings snapshot are consistent.
        editor.objectWillChange.merge(with: library.objectWillChange).sink { [weak self, weak library] in
            Task { @MainActor [weak self, weak library] in
                guard let self else { return }
                if library?.isDeveloping != true { self.discard() }
                else { self.contextDidChange() }
            }
        }.store(in: &subscriptions)
    }

    deinit { requestTask?.cancel() }

    var promptProblem: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Beschreibe die gewünschte Regleränderung." }
        if prompt.utf8.count > maximumPromptBytes { return "Die Eingabe ist zu lang (höchstens \(maximumPromptBytes) UTF-8-Bytes)." }
        return nil
    }

    var canGenerate: Bool {
        state != .generating && availability == .available && promptProblem == nil && snapshot() != nil
    }

    var canAccept: Bool {
        guard state == .previewing, let result,
              case .changes = result.validation else { return false }
        return snapshot() == result.request.snapshot
    }

    var changes: [Change] {
        guard let result, case .changes(_, let target) = result.validation else { return [] }
        let baseline = result.request.snapshot.settings
        return EditParameter.allCases.compactMap { parameter in
            let before = parameter.value(in: baseline)
            let after = parameter.value(in: target)
            return before == after ? nil : Change(parameter: parameter, baseline: before, target: after)
        }
    }

    var explanation: String? {
        guard let result, case .changes(let proposal, _) = result.validation else { return nil }
        return proposal.explanation
    }

    /// Used exclusively by the selected Develop preview. Export, thumbnails and
    /// the ordinary inspector always read EditingModel.settings(for:) directly.
    func displaySettings(assetID: String, committed: EditSettings, developing: Bool,
                         comparesOriginal: Bool) -> EditSettings {
        if comparesOriginal { return .neutral }
        guard developing, comparison == .proposal, canAccept, let result,
              result.request.snapshot.assetID == assetID,
              case .changes(_, let target) = result.validation else { return committed }
        return target
    }

    func refreshAvailability() async {
        let checkID = UUID()
        availabilityCheckID = checkID
        let value = await provider.availability()
        guard !Task.isCancelled, availabilityCheckID == checkID else { return }
        availability = value
        guard requestID == nil, result == nil else { return }
        state = restingState
    }

    func generate() {
        guard state != .generating else { return }
        commitInput()
        discard()
        guard availability == .available else { return }
        guard let baseline = snapshot() else {
            state = .failed("Die Bearbeitung ist zurzeit gesperrt. Warte, bis Laden, Sicherung oder Wiederherstellung abgeschlossen sind.")
            return
        }
        let request = AIEditingRequest(prompt: prompt, snapshot: baseline)
        do { try request.validate(maximumPromptBytes: maximumPromptBytes) }
        catch { state = .failed(promptProblem ?? error.localizedDescription); return }
        let id = request.id
        requestID = id
        requestSnapshot = baseline
        state = .generating
        let sourceReadable = self.sourceReadable
        let coordinator = self.coordinator
        requestTask = Task { [weak self] in
            do {
                guard await sourceReadable(baseline) else {
                    throw AssistantError.unreadableSource
                }
                try Task.checkCancellation()
                let result = try await coordinator.proposal(for: request)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                guard self.snapshot() == baseline else { self.discard(); return }
                self.requestTask = nil
                self.requestID = nil
                self.requestSnapshot = nil
                self.result = result
                self.comparison = .proposal
                self.state = .previewing
            } catch {
                guard let self, self.requestID == id else { return }
                guard self.snapshot() == baseline else { self.discard(); return }
                self.requestTask = nil
                self.requestID = nil
                self.requestSnapshot = nil
                if error is CancellationError || (error as? AIEditingError) == .cancelled || (error as? AIEditingError) == .superseded {
                    self.state = self.restingState
                } else if case .unavailable(let reason) = error as? AIEditingError {
                    self.availability = .unavailable(reason)
                    self.state = .unavailable(reason)
                } else {
                    // Stable local categories only: no provider payload, prompt
                    // or path is exposed through arbitrary error descriptions.
                    self.state = .failed((error as? AIEditingError)?.localizedDescription ?? AssistantError.unreadableSource.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    func acceptProposal() -> Bool {
        guard canAccept, let candidate = result else { contextDidChange(); return false }
        // Consume first, so reentrancy or a second button action cannot apply it
        // twice. The synchronous editor gate rechecks locks and the full token.
        result = nil
        state = restingState
        return accept(candidate)
    }

    func discard() {
        requestID = nil
        requestSnapshot = nil
        requestTask?.cancel()
        requestTask = nil
        result = nil
        comparison = .proposal
        state = restingState
    }

    func contextDidChange() {
        if let expected = requestSnapshot ?? result?.request.snapshot, snapshot() != expected { discard() }
        else { objectWillChange.send() }
    }

    private var restingState: State {
        if case .unavailable(let reason) = availability { return .unavailable(reason) }
        return .idle
    }

    private nonisolated static func checkSource(_ snapshot: AIEditingSnapshot) async -> Bool {
        guard await AIAssistantSourceReader.shared.isReadable(snapshot), !Task.isCancelled,
              case .original(let source) = snapshot.source else { return false }
        let request = PreviewRequest(url: URL(fileURLWithPath: source.standardizedPath), modifiedAt: source.modifiedAt,
                                     pixelSize: 2_400, fileSize: source.fileSize, allowsEmbeddedPreview: false)
        do {
            // Exactly the Develop preview's request: share its decoded or
            // in-flight basis and reject damaged formats before model work.
            _ = try await ImagePreviewPipeline.shared.image(for: request, priority: .selected)
            return !Task.isCancelled
        } catch { return false }
    }
}

/// A single actual open/read may block on removable or network storage. Keep
/// this serial slot occupied until it returns, including after UI cancellation;
/// queued cancelled requests skip their I/O rather than creating more workers.
private actor AIAssistantSourceReader {
    static let shared = AIAssistantSourceReader()
    func isReadable(_ snapshot: AIEditingSnapshot) -> Bool {
        guard !Task.isCancelled, case .original(let source) = snapshot.source else { return false }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: source.standardizedPath)) else { return false }
        defer { try? handle.close() }
        // Read a bounded byte to reject directories and unreadable sources;
        // image decoding remains with the existing shared preview pipeline.
        return (try? handle.read(upToCount: 1))?.isEmpty == false
    }
}

private enum AssistantError: Error, LocalizedError {
    case unreadableSource
    var errorDescription: String? { "Das ausgewählte Original ist nicht lesbar. Prüfe, ob die Datei und ihr Laufwerk verfügbar sind." }
}
