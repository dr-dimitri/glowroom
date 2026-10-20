import AppKit
import Combine
import Foundation
import PicEditCore

/// Owns generated recipes and immediately activates selected changes. The editor
/// remains the sole owner of history and saving; inference and source checks
/// run outside MainActor.
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
        case current = "Ausgangsstand"
        case proposal = "Aktive Bearbeitung"
        var id: Self { self }
    }

    struct Change: Identifiable, Equatable {
        let parameter: EditParameter
        let baseline: Double
        let target: Double
        var id: EditParameter { parameter }
        var delta: Double { target - baseline }
    }

    struct RegionalChange: Identifiable, Equatable {
        let id: UUID
        let name: String
        let changes: [Change]
    }

    @Published var prompt = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var availability: AIAvailability?
    @Published private(set) var result: AIProposalResult?
    @Published private(set) var lookGroup: AILookGroupResult?
    @Published private(set) var selectedLookID: AILookID?
    @Published private(set) var mode: AIEditingMode = .single
    @Published var comparison: Comparison = .proposal

    let maximumPromptBytes: Int
    let cards: AILookCardStore
    private var provider: any AIEditingProvider
    private var coordinator: AIRequestCoordinator
    private var providerSuspended = false
    private var authorization: (@MainActor (AIEditingRequest) async throws -> Bool)?
    @Published private(set) var providerLabel = "Lokal · Apple"
    @Published private(set) var supportsLooks = true
    @Published private(set) var usesImageContext = false
    private let snapshot: @MainActor () -> AIEditingSnapshot?
    private let accept: @MainActor (AIProposalResult) -> Bool
    private let commitInput: @MainActor () -> Void
    private let sourceReadable: @Sendable (AIEditingSnapshot) async -> Bool
    private var subscriptions: Set<AnyCancellable> = []
    private var requestTask: Task<Void, Never>?
    private(set) var requestID: UUID?
    private var requestSnapshot: AIEditingSnapshot?
    private var appliedSnapshot: AIEditingSnapshot?
    private var isApplying = false
    private var availabilityCheckID = UUID()

    init(provider: any AIEditingProvider, coordinator: AIRequestCoordinator,
         maximumPromptBytes: Int = 16_384,
         snapshot: @escaping @MainActor () -> AIEditingSnapshot?,
         accept: @escaping @MainActor (AIProposalResult) -> Bool,
         commitInput: @escaping @MainActor () -> Void = {},
         cards: AILookCardStore? = nil,
         sourceReadable: @escaping @Sendable (AIEditingSnapshot) async -> Bool = { await AIAssistantModel.checkSource($0) }) {
        self.provider = provider
        self.providerLabel = provider is any AIRemoteEditingProvider ? "Cloud · Anthropic (nur Text)" : "Lokal · Apple"
        self.supportsLooks = provider.capabilities.contains(.lookSuggestions)
        self.usesImageContext = provider.capabilities.contains(.imageUnderstanding)
        self.coordinator = coordinator
        self.maximumPromptBytes = max(1, maximumPromptBytes)
        self.snapshot = snapshot
        self.accept = accept
        self.commitInput = commitInput
        self.cards = cards ?? AILookCardStore()
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
                      // Applied recipes immediately become the visible editor state.
                      library.comparesOriginal = false
                      library.comparesCurrentSourceWithoutSettings = false
                      return editor.acceptAIProposal(result, in: library)
                  }, commitInput: { [weak editor, weak library] in
                      NSApp?.keyWindow?.makeFirstResponder(nil)
                      if let assetID = library?.selectedID {
                          editor?.endEditing(assetID: assetID)
                          editor?.selectEditingFunction(.assistant, assetID: assetID)
                      }
                  })
        // @Published emits before mutation. Defer the check one MainActor turn
        // so epochs and their complete catalog/settings snapshot are consistent.
        // Develop/library mode and dock visibility are presentation state.
        // The snapshot still rejects real selection/source/edit changes while
        // an untouched proposal survives navigation back to the same photo.
        editor.objectWillChange.merge(with: library.objectWillChange).sink { [weak self] in
            Task { @MainActor [weak self] in self?.contextDidChange() }
        }.store(in: &subscriptions)
    }

    deinit { requestTask?.cancel() }

    var promptProblem: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Beschreibe die gewünschte Bildkorrektur." }
        if prompt.utf8.count > maximumPromptBytes { return "Die Eingabe ist zu lang (höchstens \(maximumPromptBytes) UTF-8-Bytes)." }
        return nil
    }

    var canGenerate: Bool {
        canStart && provider.capabilities.contains(.textEditing) && promptProblem == nil
    }

    var lookPromptProblem: String? {
        prompt.utf8.count > maximumLookPromptBytes ? "Der optionale Zusatztext ist zu lang (höchstens \(maximumLookPromptBytes) UTF-8-Bytes)." : nil
    }

    private var maximumLookPromptBytes: Int { min(maximumPromptBytes, 2_048) }

    var canGenerateLooks: Bool {
        canStart && provider.capabilities.contains(.lookSuggestions) && lookPromptProblem == nil
    }

    private var canStart: Bool {
        !providerSuspended && state != .generating && availability == .available && snapshot() != nil
    }

    var activeProposalResult: AIProposalResult? {
        if let lookGroup, let selectedLookID,
           let selected = lookGroup.validation.variants.first(where: { $0.proposal.id == selectedLookID }) {
            return AIProposalResult(request: lookGroup.request,
                                    validation: .changes(proposal: selected.proposal.proposal, settings: selected.target))
        }
        return result
    }

    var canAccept: Bool {
        guard !isApplying, appliedSnapshot == nil, state == .previewing, let result = activeProposalResult,
              case .changes = result.validation else { return false }
        return snapshot() == result.request.snapshot
    }

    var hasAppliedChanges: Bool { appliedSnapshot != nil && currentContextIsValid }

    var changes: [Change] {
        guard let result = activeProposalResult, case .changes(_, let target) = result.validation else { return [] }
        return changes(from: result.request.snapshot.settings, to: target)
    }

    var regionalChanges: [RegionalChange] {
        guard let result = activeProposalResult else { return [] }
        return result.localAdjustments.map { layer in
            RegionalChange(id: layer.id, name: layer.name,
                changes: changes(from: .neutral, to: layer.settings.editSettings))
        }
    }

    func changes(for lookID: AILookID) -> [Change] {
        guard let lookGroup,
              let look = lookGroup.validation.variants.first(where: { $0.proposal.id == lookID }) else { return [] }
        return changes(from: lookGroup.request.snapshot.settings, to: look.target)
    }

    private func changes(from baseline: EditSettings, to target: EditSettings) -> [Change] {
        return EditParameter.allCases.compactMap { parameter in
            let before = parameter.value(in: baseline)
            let after = parameter.value(in: target)
            return before == after ? nil : Change(parameter: parameter, baseline: before, target: after)
        }
    }

    var explanation: String? {
        guard let result = activeProposalResult else { return nil }
        switch result.validation {
        case .changes(let proposal, _): return proposal.explanation
        case .noChange(let explanation): return explanation
        }
    }

    /// Explicit before/after comparison only; normal previews and exports read
    /// the immediately activated EditingModel settings.
    func displaySettings(assetID: String, committed: EditSettings, developing: Bool,
                         comparesOriginal: Bool) -> EditSettings {
        if comparesOriginal { return .neutral }
        guard developing, comparison == .current, hasAppliedChanges,
              let baseline = activeProposalResult?.request.snapshot,
              baseline.assetID == assetID else { return committed }
        return baseline.settings
    }

    func suspendProvider() {
        providerSuspended = true
        discard()
        availabilityCheckID = UUID()
        availability = nil
        let previous = coordinator
        Task { await previous.cancelAll() }
    }

    func replaceProvider(_ provider: any AIEditingProvider,
                         authorization: (@MainActor (AIEditingRequest) async throws -> Bool)? = nil) {
        suspendProvider()
        self.provider = provider
        self.coordinator = AIRequestCoordinator(provider: provider)
        self.authorization = authorization
        providerSuspended = false
        providerLabel = provider is any AIRemoteEditingProvider ? "Cloud · Anthropic (nur Text)" : "Lokal · Apple"
        supportsLooks = provider.capabilities.contains(.lookSuggestions)
        usesImageContext = provider.capabilities.contains(.imageUnderstanding)
        Task { [weak self] in await self?.refreshAvailability() }
    }

    func refreshAvailability() async {
        guard !providerSuspended else { return }
        let checkID = UUID()
        availabilityCheckID = checkID
        let value = await provider.availability()
        guard !Task.isCancelled, availabilityCheckID == checkID else { return }
        availability = value
        guard requestID == nil, result == nil, lookGroup == nil else { return }
        state = restingState
    }

    func generate() {
        generate(mode: .single)
    }

    func generateLooks() {
        generate(mode: .lookGroup)
    }

    private enum Response {
        case single(AIProposalResult)
        case looks(AILookGroupResult)
    }

    private func generate(mode: AIEditingMode) {
        guard state != .generating else { return }
        discard()
        self.mode = mode
        guard availability == .available else { return }
        let capability: AIProviderCapabilities = mode == .single ? .textEditing : .lookSuggestions
        guard provider.capabilities.contains(capability) else {
            state = .failed(AIEditingError.unsupportedCapability.localizedDescription)
            return
        }
        if let problem = mode == .single ? promptProblem : lookPromptProblem {
            state = .failed(problem)
            return
        }
        let contextUnavailable = "Die Bearbeitung ist zurzeit gesperrt. Warte, bis Laden, Sicherung oder Wiederherstellung abgeschlossen sind."
        // Reject unavailable contexts before commitInput can select another
        // function and clear its history. Recheck after finishing native input.
        guard snapshot() != nil else {
            state = .failed(contextUnavailable)
            return
        }
        commitInput()
        guard let baseline = snapshot() else {
            state = .failed(contextUnavailable)
            return
        }
        let request = AIEditingRequest(prompt: prompt, snapshot: baseline, mode: mode)
        do { try request.validate(maximumPromptBytes: mode == .lookGroup ? maximumLookPromptBytes : maximumPromptBytes) }
        catch { state = .failed((mode == .single ? promptProblem : lookPromptProblem) ?? error.localizedDescription); return }
        let id = request.id
        requestID = id
        requestSnapshot = baseline
        state = .generating
        let sourceReadable = self.sourceReadable
        let preparesImageInput = provider is any AIResolvedEditingProvider
        let coordinator = self.coordinator
        let authorization = self.authorization
        requestTask = Task { [weak self] in
            do {
                if let authorization {
                    guard try await authorization(request) else { throw CancellationError() }
                    try Task.checkCancellation()
                }
                // The image provider verifies and decodes its stamped input.
                // A separate 2400px preflight here would decode the same RAW
                // again under a different cache revision before its 1024px input.
                if !preparesImageInput {
                    guard await sourceReadable(baseline) else {
                        throw AssistantError.unreadableSource
                    }
                }
                try Task.checkCancellation()
                guard let owner = self, owner.requestID == id, owner.snapshot() == baseline else { throw CancellationError() }
                let response: Response
                switch mode {
                case .single: response = .single(try await coordinator.proposal(for: request))
                case .lookGroup: response = .looks(try await coordinator.lookGroup(for: request))
                }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                guard self.snapshot() == baseline else { self.discard(); return }
                self.requestTask = nil
                self.requestID = nil
                self.requestSnapshot = nil
                switch response {
                case .single(let result): self.result = result
                case .looks(let group):
                    self.lookGroup = group
                    // Creating alternatives does not choose one for the user.
                    // A card click activates its full target immediately.
                    self.cards.begin(group: group, selectedID: nil)
                }
                self.comparison = .proposal
                self.state = .previewing
                if case .single(let result) = response, case .changes = result.validation {
                    if !self.acceptProposal() {
                        self.discard()
                        self.state = .failed(AIEditingError.staleSnapshot.localizedDescription)
                    }
                }
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
                    self.state = .failed((error as? AICloudError)?.localizedDescription ?? (error as? AIEditingError)?.localizedDescription ?? AssistantError.unreadableSource.localizedDescription)
                }
            }
        }
    }

    @discardableResult
    func acceptProposal() -> Bool {
        guard canAccept, let candidate = activeProposalResult else { contextDidChange(); return false }
        // Admission is synchronous and rechecks the complete source/edit token.
        // Keep recipe details after activation, but reject a second activation.
        isApplying = true
        defer { isApplying = false }
        guard accept(candidate) else { return false }
        appliedSnapshot = snapshot()
        return true
    }

    func selectLook(_ id: AILookID) {
        guard !isApplying, state == .previewing, let group = lookGroup,
              currentContextIsValid, let current = snapshot(),
              let look = group.validation.variants.first(where: { $0.proposal.id == id })
        else { contextDidChange(); return }
        guard selectedLookID != id else {
            comparison = .proposal
            cards.select(id: id)
            return
        }
        // Targets share the original group baseline. Include every changed
        // numeric control so switching back also removes the previous recipe's
        // changes, while non-AI settings remain untouched.
        let patch = EditProposal(changes: EditParameter.allCases.compactMap { parameter in
            let target = parameter.value(in: look.target)
            return target == parameter.value(in: current.settings) ? nil : EditParameterChange(parameter: parameter, value: target)
        }, explanation: look.proposal.proposal.explanation)
        let candidate = AIProposalResult(request: AIEditingRequest(id: group.request.id, prompt: group.request.prompt,
            snapshot: current, mode: .lookGroup), validation: .changes(proposal: patch, settings: look.target))
        isApplying = true
        defer { isApplying = false }
        guard accept(candidate) else {
            discard()
            state = .failed(AIEditingError.staleSnapshot.localizedDescription)
            return
        }
        appliedSnapshot = snapshot()
        selectedLookID = id
        comparison = .proposal
        cards.select(id: id)
    }

    private var currentContextIsValid: Bool {
        guard let current = snapshot() else { return false }
        guard let applied = appliedSnapshot else {
            return current == (requestSnapshot ?? lookGroup?.request.snapshot ?? result?.request.snapshot)
        }
        // Accepted saves can advance persistedVersion without a new user edit.
        // All edit/selection tokens, source identity, settings and store epoch
        // must remain identical. Every subsequent card click still passes its
        // fresh complete snapshot through the editor's authoritative gate.
        return current.assetID == applied.assetID && current.source == applied.source
            && current.settings == applied.settings && current.token == applied.token
            && current.persistedVersion?.storeEpoch == applied.persistedVersion?.storeEpoch
    }

    func discard() {
        requestID = nil
        requestSnapshot = nil
        appliedSnapshot = nil
        requestTask?.cancel()
        requestTask = nil
        result = nil
        lookGroup = nil
        selectedLookID = nil
        cards.clear()
        comparison = .proposal
        state = restingState
    }

    func contextDidChange() {
        guard !isApplying else { return }
        if requestSnapshot != nil || result != nil || lookGroup != nil {
            if !currentContextIsValid { discard(); return }
        }
        objectWillChange.send()
    }

    private var restingState: State {
        if case .unavailable(let reason) = availability {
            return provider is any AIRemoteEditingProvider ? .failed(AICloudError.disabled.localizedDescription) : .unavailable(reason)
        }
        return .idle
    }

    private nonisolated static func checkSource(_ snapshot: AIEditingSnapshot) async -> Bool {
        guard !Task.isCancelled else { return false }
        if case .original = snapshot.source {
            guard await AIAssistantSourceReader.shared.isReadable(snapshot) else { return false }
        }
        let request = PreviewRequest(source: snapshot.source, pixelSize: 2_400, allowsEmbeddedPreview: false)
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
