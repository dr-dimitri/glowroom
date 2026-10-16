import Foundation
import PicEditCore

/// SDK-independent adapter boundary supports deterministic tests without Apple Intelligence.
/// Implementations must create a fresh session per generation and retain no history.
protocol LocalAIModelRuntime: Sendable {
    func availability() async -> AIAvailability
    func generate(_ prompt: LocalAIEditingPrompt) async throws -> LocalAIModelOutput
}

struct LocalAIModelOutput: Sendable {
    enum Status: Sendable {
        case proposal, imageAnalysis, whiteBalance, unsupported, unsupportedLanguage, refused
    }

    struct Change: Sendable {
        let parameter: String
        let value: Double
    }

    struct Look: Sendable {
        let id: String
        let name: String
        let changes: [Change]
        let explanation: String
    }

    let status: Status
    let changes: [Change]
    let explanation: String
    let variants: [Look]

    init(status: Status, changes: [Change], explanation: String, variants: [Look] = []) {
        self.status = status
        self.changes = changes
        self.explanation = explanation
        self.variants = variants
    }
}

/// A local text provider, admitted by AIRequestCoordinator/AIResourceBudget. It owns no
/// model cache or nested worker pool. The coordinator keeps the slot through SDK return.
struct LocalAIEditingProvider: AIEditingProvider {
    let id = "apple.system-language-model.local.v2"
    let capabilities: AIProviderCapabilities = [.textEditing, .lookSuggestions]
    let runtime: any LocalAIModelRuntime

    func availability() async -> AIAvailability { await runtime.availability() }

    func proposal(for request: AIEditingRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            let capability: AIProviderCapabilities = request.mode == .single ? .textEditing : .lookSuggestions
            guard capabilities.contains(capability) else { throw AIEditingError.unsupportedCapability }
            let prompt = try LocalAIEditingPrompt(request: request)
            // Check immediately before each call, including queued calls after availability changed.
            if case .unavailable(let reason) = await runtime.availability() {
                throw AIEditingError.unavailable(reason)
            }
            try Task.checkCancellation()
            let output = try await runtime.generate(prompt)
            try Task.checkCancellation()
            switch output.status {
            case .imageAnalysis: throw AIEditingError.unsupportedTask(.imageAnalysis)
            case .whiteBalance: throw AIEditingError.unsupportedTask(.whiteBalance)
            case .unsupported: throw AIEditingError.unsupportedTask(.other)
            case .unsupportedLanguage: throw AIEditingError.unsupportedTask(.unsupportedLanguage)
            case .refused: throw AIEditingError.safetyRefusal
            case .proposal: break
            }
            func changes(_ raw: [LocalAIModelOutput.Change]) throws -> [EditParameterChange] {
                try raw.map { change -> EditParameterChange in
                    guard let parameter = EditParameter(rawValue: change.parameter) else {
                        throw AIEditingError.invalidResponse(.unknownParameter)
                    }
                    return EditParameterChange(parameter: parameter, value: change.value)
                }
            }
            // Guided generation constrains shape, not correctness or semantic safety.
            let validator = EditProposalValidator()
            switch request.mode {
            case .single:
                guard output.variants.isEmpty else { throw AIEditingError.invalidResponse(.invalidType) }
                let proposal = EditProposal(changes: try changes(output.changes), explanation: output.explanation)
                _ = try validator.validate(proposal, against: request.snapshot.settings)
                let data = try JSONEncoder().encode(proposal)
                _ = try validator.validate(data, against: request.snapshot.settings)
                return data
            case .lookGroup:
                guard output.changes.isEmpty else { throw AIEditingError.invalidResponse(.invalidType) }
                let variants = try output.variants.map { variant -> AILookProposal in
                    guard let id = AILookID(rawValue: variant.id) else { throw AIEditingError.invalidResponse(.invalidLookID) }
                    return AILookProposal(id: id, name: variant.name,
                                          proposal: EditProposal(changes: try changes(variant.changes), explanation: variant.explanation))
                }
                let group = AILookProposalGroup(variants: variants)
                _ = try validator.validateLookGroup(group, against: request.snapshot.settings)
                let data = try JSONEncoder().encode(group)
                _ = try validator.validateLookGroup(data, against: request.snapshot.settings)
                return data
            }
        } catch is CancellationError {
            throw AIEditingError.cancelled
        } catch let error as AIEditingError {
            if Task.isCancelled { throw AIEditingError.cancelled }
            throw error
        } catch {
            if Task.isCancelled { throw AIEditingError.cancelled }
            // Never expose SDK debug contexts (which may include prompt/output) to UI or logs.
            throw AIEditingError.providerFailure
        }
    }
}

struct UnavailableLocalAIModelRuntime: LocalAIModelRuntime {
    let reason: AIUnavailableReason
    func availability() async -> AIAvailability { .unavailable(reason) }
    func generate(_ prompt: LocalAIEditingPrompt) async throws -> LocalAIModelOutput {
        throw AIEditingError.unavailable(reason)
    }
}

enum LocalAIEditingProviderFactory {
    static func makeProvider() -> any AIEditingProvider {
        if #available(macOS 26.0, *) {
            // Optional Apple SDK support must not raise the package's Swift 5.9 minimum.
            #if compiler(>=6.2) && canImport(FoundationModels) && !PICEDIT_DISABLE_FOUNDATION_MODELS
            return LocalAIEditingProvider(runtime: AppleSystemModelRuntime())
            #else
            return LocalAIEditingProvider(runtime: UnavailableLocalAIModelRuntime(reason: .sdkUnavailable))
            #endif
        }
        return LocalAIEditingProvider(runtime: UnavailableLocalAIModelRuntime(reason: .unsupportedSystem))
    }
}
