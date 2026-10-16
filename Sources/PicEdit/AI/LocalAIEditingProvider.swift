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

    let status: Status
    let changes: [Change]
    let explanation: String
}

/// A local text provider, admitted by AIRequestCoordinator/AIResourceBudget. It owns no
/// model cache or nested worker pool. The coordinator keeps the slot through SDK return.
struct LocalAIEditingProvider: AIEditingProvider {
    let id = "apple.system-language-model.local.v1"
    let capabilities: AIProviderCapabilities = [.textEditing]
    let runtime: any LocalAIModelRuntime

    func availability() async -> AIAvailability { await runtime.availability() }

    func proposal(for request: AIEditingRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
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
            let changes = try output.changes.map { change -> EditParameterChange in
                guard let parameter = EditParameter(rawValue: change.parameter) else {
                    throw AIEditingError.invalidResponse(.unknownParameter)
                }
                return EditParameterChange(parameter: parameter, value: change.value)
            }
            let proposal = EditProposal(changes: changes, explanation: output.explanation)
            // Guided generation constrains shape, not correctness or semantic safety.
            let validator = EditProposalValidator()
            _ = try validator.validate(proposal, against: request.snapshot.settings)
            let data = try JSONEncoder().encode(proposal)
            _ = try validator.validate(data, against: request.snapshot.settings)
            return data
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
