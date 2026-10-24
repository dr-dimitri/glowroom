import Combine
import Foundation
import GlowroomCore

/// A proposed object selection is never an accepted edit. The inline workspace
/// owns the source/revision guard and installs the exact layer only on approval.
@MainActor
final class InlineObjectMaskModel: ObservableObject {
    enum SetupRequirement: Equatable, Sendable { case languageModel, subjectModel }
    typealias Propose = @Sendable (AIEditingSnapshot, String) async throws -> AIObjectMaskResponse
    typealias ValidateSource = @Sendable (AIEditingSnapshot, ImageAnalysisSourceStamp) async throws -> Void
    typealias CheckModels = @Sendable () async throws -> SetupRequirement?

    @Published var instruction = "" {
        didSet { if instruction != oldValue { discard() } }
    }
    @Published private(set) var proposal: AIObjectMaskResponse?
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false
    @Published private(set) var setupRequirement: SetupRequirement?
    @Published private(set) var modelsReady = false
    @Published private(set) var isCheckingModels = false

    private let propose: Propose
    private let validateSource: ValidateSource
    private let checkModels: CheckModels
    private var task: Task<Void, Never>?
    private var operation = UUID()
    private var readinessOperation = UUID()
    private var snapshot: AIEditingSnapshot?
    private var currentContext: (@MainActor () -> Bool)?
    var hasContext: Bool { snapshot != nil }
    var blocksMaskInput: Bool { isRunning || proposal != nil }

    init(propose: @escaping Propose = { snapshot, instruction in
        try await AIObjectMaskService().propose(snapshot: snapshot, instruction: instruction)
    }, validateSource: @escaping ValidateSource = { snapshot, stamp in
        guard try await ImageAnalysisPreparer().sourceStamp(for: AIObjectMaskService.preparationRequest(snapshot: snapshot)) == stamp else {
            throw AIDevelopmentError.staleContext
        }
    }, checkModels: @escaping CheckModels = {
        do {
            guard try await AICorrectionReadiness.installedModel() else { return .languageModel }
        } catch {
            if InlineObjectMaskModel.setupRequirement(for: error) == .languageModel { return .languageModel }
            throw error
        }
        do {
            guard try await SubjectMattingModelStore.shared.installedModel() != nil else { return .subjectModel }
        } catch {
            if InlineObjectMaskModel.setupRequirement(for: error) == .subjectModel { return .subjectModel }
            throw error
        }
        return nil
    }) {
        self.propose = propose; self.validateSource = validateSource; self.checkModels = checkModels
    }

    deinit { task?.cancel() }

    func refreshModels() async {
        let token = UUID(); readinessOperation = token; isCheckingModels = true
        do {
            let requirement = try await checkModels()
            try Task.checkCancellation()
            guard readinessOperation == token else { return }
            setupRequirement = requirement; modelsReady = requirement == nil
        } catch is CancellationError { }
        catch {
            guard readinessOperation == token else { return }
            modelsReady = false; status = error.localizedDescription
        }
        if readinessOperation == token { isCheckingModels = false }
    }

    @discardableResult
    func start(snapshot: AIEditingSnapshot, expectedSourceStamp: ImageAnalysisSourceStamp? = nil,
               isCurrent: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        guard !isRunning, isCurrent() else { return nil }
        discard()
        do {
            try AIObjectMaskProposal.validateInstruction(instruction)
            guard snapshot.settings.localAdjustments.count < LocalAdjustment.maximumCount else { throw AIObjectMaskError.maskLimit }
        } catch { status = error.localizedDescription; return nil }
        let token = UUID(); operation = token
        self.snapshot = snapshot; currentContext = isCurrent
        let instruction = instruction
        isRunning = true; status = "Objektauswahl wird erstellt …"
        // The existing resource budget serializes native model work. A canceled
        // request stops being visible immediately, while its native worker keeps
        // admission until it has actually returned.
        let worker = Task.detached(priority: .userInitiated) { [checkModels, propose] in
            let requirement = try await checkModels()
            try Task.checkCancellation()
            if let requirement { return (Optional(requirement), Optional<AIObjectMaskResponse>.none) }
            let response = try await propose(snapshot, instruction)
            try Task.checkCancellation()
            if let expectedSourceStamp, response.sourceStamp != expectedSourceStamp { throw AIDevelopmentError.staleContext }
            var candidate = snapshot.settings
            candidate.localAdjustments.append(response.layer)
            _ = try EditingSnapshot(settings: candidate)
            return (Optional<SetupRequirement>.none, Optional(response))
        }
        let operationTask = Task { [weak self] in
            defer {
                if let self, self.operation == token { self.isRunning = false; self.task = nil }
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.operation == token else { return }
                guard self.currentContext?() == true else { self.invalidate(); return }
                self.setupRequirement = result.0; self.modelsReady = result.0 == nil
                if result.0 != nil {
                    self.snapshot = nil; self.currentContext = nil
                    self.status = "Modell für die Objektauswahl einrichten."
                } else {
                    self.proposal = result.1
                    self.status = "Maskenvorschlag bereit."
                }
            } catch {
                guard let self, self.operation == token else { return }
                self.snapshot = nil; self.currentContext = nil
                if error is CancellationError || Task.isCancelled { self.status = "Abgebrochen." }
                else if let requirement = Self.setupRequirement(for: error) {
                    self.setupRequirement = requirement; self.modelsReady = false
                    self.status = "Modell für die Objektauswahl einrichten."
                } else { self.status = error.localizedDescription }
            }
        }
        task = operationTask
        return operationTask
    }

    @discardableResult
    func apply(accept: @escaping @MainActor (LocalAdjustment) -> Bool) -> Task<Void, Never>? {
        guard !isRunning, let snapshot, let proposal else { return nil }
        guard currentContext?() == true else { invalidate(); return nil }
        let token = operation
        isRunning = true; status = "Foto wird vor der Übernahme geprüft …"
        let worker = Task.detached(priority: .userInitiated) { [validateSource] in
            try await validateSource(snapshot, proposal.sourceStamp)
        }
        let operationTask = Task { [weak self] in
            defer {
                if let self, self.operation == token { self.isRunning = false; self.task = nil }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.operation == token else { return }
                guard self.currentContext?() == true else { self.invalidate(); return }
                // Clear the proposal before the synchronous accepted edit emits
                // settings changes. This also makes duplicate approval a no-op.
                self.snapshot = nil; self.currentContext = nil; self.proposal = nil
                self.status = accept(proposal.layer) ? "Maske hinzugefügt." : "Die Maske konnte nicht übernommen werden."
            } catch {
                guard let self, self.operation == token else { return }
                self.proposal = nil; self.snapshot = nil; self.currentContext = nil
                self.status = error is CancellationError ? "Abgebrochen." : AIDevelopmentError.staleContext.localizedDescription
            }
        }
        task = operationTask
        return operationTask
    }

    func invalidateIfNeeded() {
        if hasContext, currentContext?() != true { invalidate() }
    }

    func invalidate() {
        guard hasContext else { return }
        discard(); status = AIDevelopmentError.staleContext.localizedDescription
    }

    func discard() {
        operation = UUID(); task?.cancel(); task = nil
        snapshot = nil; currentContext = nil; proposal = nil; isRunning = false; status = nil
    }

    nonisolated private static func setupRequirement(for error: Error) -> SetupRequirement? {
        if let error = error as? LLMModelError {
            switch error {
            case .modelNotInstalled, .invalidInstallation, .invalidDownload: return .languageModel
            default: return nil
            }
        }
        if let error = error as? SubjectMattingError {
            switch error {
            case .modelNotInstalled, .invalidModel, .updateRequired: return .subjectModel
            default: return nil
            }
        }
        return nil
    }
}
