// Keep imports and availability-only types out of older SDK/compiler builds.
#if compiler(>=6.2) && canImport(FoundationModels) && !PICEDIT_DISABLE_FOUNDATION_MODELS
import Foundation
import FoundationModels
import PicEditCore

@available(macOS 26.0, *)
private struct SystemEditResponse: Decodable {
    enum Status: String, Decodable {
        case proposal, imageAnalysis, whiteBalance, unsupported, unsupportedLanguage, refused
    }

    struct Change: Decodable {
        var parameter: String

        var value: Double
    }

    var status: Status

    var changes: [Change]

    var explanation: String
}

/// SystemLanguageModel is explicitly selected: FoundationModels also has other backends.
/// No tools, adapters, prewarming/download API, persistence or network client are installed.
@available(macOS 26.0, *)
struct AppleSystemModelRuntime: LocalAIModelRuntime {
    private let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    func availability() async -> AIAvailability {
        Self.availability(model.availability, supportsGerman: model.supportsLocale(Locale(identifier: "de_DE")))
    }

    static func availability(_ availability: SystemLanguageModel.Availability,
                             supportsGerman: Bool) -> AIAvailability {
        switch availability {
        case .available:
            return supportsGerman ? .available : .unavailable(.unsupportedLanguage)
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.unsupportedHardware)
            case .appleIntelligenceNotEnabled: return .unavailable(.disabled)
            case .modelNotReady: return .unavailable(.modelUnavailable)
            @unknown default: return .unavailable(.unknown)
            }
        }
    }

    func generate(_ prompt: LocalAIEditingPrompt) async throws -> LocalAIModelOutput {
        try Task.checkCancellation()
        if case .unavailable(let reason) = await availability() { throw AIEditingError.unavailable(reason) }
        // A fresh session gives bounded, isolated context. Calls are serial through the
        // shared coordinator budget; no session is ever shared across calls or photos.
        let session = LanguageModelSession(model: model, tools: [], instructions: LocalAIEditingPrompt.instructions)
        do {
            let response = try await session.respond(to: prompt.data, schema: Self.generationSchema(),
                                                     options: GenerationOptions(sampling: .greedy,
                                                                                maximumResponseTokens: 800))
            try Task.checkCancellation()
            return try Self.output(from: Data(response.content.jsonString.utf8))
        } catch is CancellationError {
            throw AIEditingError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.editingError(error)
        }
    }

    static func output(from data: Data) throws -> LocalAIModelOutput {
        guard data.count <= 65_536 else { throw AIEditingError.invalidResponse(.responseTooLarge) }
        let content: SystemEditResponse
        do { content = try JSONDecoder().decode(SystemEditResponse.self, from: data) }
        catch { throw AIEditingError.invalidResponse(.malformedJSON) }
        let status: LocalAIModelOutput.Status
        switch content.status {
        case .proposal: status = .proposal
        case .imageAnalysis: status = .imageAnalysis
        case .whiteBalance: status = .whiteBalance
        case .unsupported: status = .unsupported
        case .unsupportedLanguage: status = .unsupportedLanguage
        case .refused: status = .refused
        }
        return LocalAIModelOutput(status: status, changes: content.changes.map {
            LocalAIModelOutput.Change(parameter: $0.parameter, value: $0.value)
        }, explanation: content.explanation)
    }

    /// Stable macOS 26 guided schema API, equivalent to @Generable. This also builds
    /// with Command Line Tools that ship FoundationModels but omit its macro plugin.
    static func generationSchema() throws -> GenerationSchema {
        let change = DynamicGenerationSchema(name: "Reglerziel", properties: [
            .init(name: "parameter", description: "Exakter erlaubter Reglername",
                  schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(EditParameter.allCases.map(\.rawValue))])),
            .init(name: "value", description: "Absoluter Zielwert in den jeweiligen Reglergrenzen",
                  schema: DynamicGenerationSchema(type: Double.self, guides: [.range(-100...100)]))
        ])
        let root = DynamicGenerationSchema(name: "Bearbeitungsergebnis", properties: [
            .init(name: "status", description: "Bei Frage zum Fotoinhalt: imageAnalysis. Bei wärmer/kühler/Weißabgleich: whiteBalance. Nur bei unterstützten Regleränderungen: proposal. Sonst unsupported/unsupportedLanguage/refused.",
                  schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf([
                    "proposal", "imageAnalysis", "whiteBalance", "unsupported", "unsupportedLanguage", "refused"
                  ])])),
            .init(name: "changes", description: "Nur gewünschte geänderte Regler; bei Ablehnung leer",
                  schema: DynamicGenerationSchema(arrayOf: change, maximumElements: EditParameter.allCases.count)),
            .init(name: "explanation", description: "Kurze deutsche Erklärung ohne Beobachtungen zum Bild",
                  schema: DynamicGenerationSchema(type: String.self))
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// No automatic retries: even transient failures require an explicit new user request.
    static func editingError(_ error: LanguageModelSession.GenerationError) -> AIEditingError {
        switch error {
        case .exceededContextWindowSize: return .inputLimitExceeded
        case .assetsUnavailable: return .unavailable(.modelUnavailable)
        case .guardrailViolation, .refusal: return .safetyRefusal
        case .unsupportedLanguageOrLocale: return .unsupportedTask(.unsupportedLanguage)
        case .decodingFailure: return .invalidResponse(.invalidType)
        case .rateLimited, .concurrentRequests: return .temporaryModelFailure
        case .unsupportedGuide: return .providerFailure
        @unknown default: return .providerFailure
        }
    }
}
#endif
