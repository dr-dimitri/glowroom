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

@available(macOS 26.0, *)
private struct SystemLookResponse: Decodable {
    struct Look: Decodable {
        let id: String
        let name: String
        let changes: [SystemEditResponse.Change]
        let explanation: String
    }
    let requestsWhiteBalance: Bool
    let requestsImageAnalysis: Bool
    let status: SystemEditResponse.Status
    let variants: [Look]
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
        let session = LanguageModelSession(model: model, tools: [], instructions: prompt.systemInstructions)
        do {
            let schema = try prompt.mode == .single ? Self.generationSchema() : Self.lookGenerationSchema()
            let response = try await session.respond(to: prompt.data, schema: schema,
                                                     options: GenerationOptions(sampling: .greedy,
                                                                                maximumResponseTokens: prompt.mode == .single ? 800 : 2_400))
            try Task.checkCancellation()
            return try Self.output(from: Data(response.content.jsonString.utf8), mode: prompt.mode)
        } catch is CancellationError {
            throw AIEditingError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.editingError(error)
        }
    }

    static func output(from data: Data, mode: AIEditingMode = .single) throws -> LocalAIModelOutput {
        guard data.count <= 65_536 else { throw AIEditingError.invalidResponse(.responseTooLarge) }
        if mode == .lookGroup {
            let content: SystemLookResponse
            do { content = try JSONDecoder().decode(SystemLookResponse.self, from: data) }
            catch { throw AIEditingError.invalidResponse(.malformedJSON) }
            // Explicit guided capability questions are more reliable than asking the
            // small model to encode every unsupported task in a single six-way enum.
            let category: LocalAIModelOutput.Status = content.requestsImageAnalysis ? .imageAnalysis
                : content.requestsWhiteBalance ? .whiteBalance : status(content.status)
            return LocalAIModelOutput(status: category, changes: [], explanation: "", variants: content.variants.map {
                LocalAIModelOutput.Look(id: $0.id, name: $0.name, changes: $0.changes.map {
                    LocalAIModelOutput.Change(parameter: $0.parameter, value: $0.value)
                }, explanation: $0.explanation)
            })
        }
        let content: SystemEditResponse
        do { content = try JSONDecoder().decode(SystemEditResponse.self, from: data) }
        catch { throw AIEditingError.invalidResponse(.malformedJSON) }
        return LocalAIModelOutput(status: status(content.status), changes: content.changes.map {
            LocalAIModelOutput.Change(parameter: $0.parameter, value: $0.value)
        }, explanation: content.explanation)
    }

    private static func status(_ value: SystemEditResponse.Status) -> LocalAIModelOutput.Status {
        switch value {
        case .proposal: return .proposal
        case .imageAnalysis: return .imageAnalysis
        case .whiteBalance: return .whiteBalance
        case .unsupported: return .unsupported
        case .unsupportedLanguage: return .unsupportedLanguage
        case .refused: return .refused
        }
    }

    /// Stable macOS 26 guided schema API, equivalent to @Generable. This also builds
    /// with Command Line Tools that ship FoundationModels but omit its macro plugin.
    static func generationSchema() throws -> GenerationSchema {
        let change = changeSchema()
        let root = DynamicGenerationSchema(name: "Bearbeitungsergebnis", properties: [
            statusSchema(),
            .init(name: "changes", description: "Nur gewünschte geänderte Regler; bei Ablehnung leer",
                  schema: DynamicGenerationSchema(arrayOf: change, maximumElements: EditParameter.allCases.count)),
            .init(name: "explanation", description: "Kurze deutsche Erklärung ohne Beobachtungen zum Bild",
                  schema: DynamicGenerationSchema(type: String.self))
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func lookGenerationSchema() throws -> GenerationSchema {
        let look = DynamicGenerationSchema(name: "StilistischesTextrezept", properties: [
            .init(name: "id", description: "natural zurückhaltend; contrasty mehr Kontrast; desaturated weniger Farbsättigung; jede ID genau einmal",
                  schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(AILookID.allCases.map(\.rawValue))])),
            .init(name: "name", description: "Kurzer deutscher Lookname: Natürlich, Kontrastreich oder Entsättigt",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "changes", description: "Wirksame absolute Reglerziele für diesen Stil, unabhängig vom gemeinsamen Ausgang",
                  schema: DynamicGenerationSchema(arrayOf: changeSchema(), maximumElements: EditParameter.allCases.count)),
            .init(name: "explanation", description: "Kurze stilistische Erklärung ohne Bildbeobachtungen, höchstens zwei Sätze",
                  schema: DynamicGenerationSchema(type: String.self))
        ])
        let root = DynamicGenerationSchema(name: "DreiTextrezepte", properties: [
            .init(name: "requestsWhiteBalance", description: "Fordert der tatsächliche userText wärmere oder kühlere Farben, Weißabgleich oder Farbtemperatur? Dann true, sonst false. Die drei Defaultstile allein verlangen dies NICHT.",
                  schema: DynamicGenerationSchema(type: Bool.self)),
            .init(name: "requestsImageAnalysis", description: "Fragt der tatsächliche userText nach Fotoinhalt oder einer bildbasierten Bewertung? Dann true, sonst false. Reine Reglerwünsche und die Defaultstile sind false.",
                  schema: DynamicGenerationSchema(type: Bool.self)),
            statusSchema(),
            .init(name: "variants", description: "Bei status proposal exakt drei wirksame unterschiedliche Varianten; bei Ablehnung leer",
                  schema: DynamicGenerationSchema(arrayOf: look, maximumElements: 3))
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func changeSchema() -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: "Reglerziel", properties: [
            .init(name: "parameter", description: "Exakter erlaubter Reglername",
                  schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(EditParameter.allCases.map(\.rawValue))])),
            .init(name: "value", description: "Absoluter Zielwert in den jeweiligen Reglergrenzen",
                  schema: DynamicGenerationSchema(type: Double.self, guides: [.range(-100...100)]))
        ])
    }

    private static func statusSchema() -> DynamicGenerationSchema.Property {
        .init(name: "status", description: "Bei Frage zum Fotoinhalt: imageAnalysis. Bei wärmer/kühler/Weißabgleich: whiteBalance. Nur bei unterstützten Regleränderungen: proposal. Sonst unsupported/unsupportedLanguage/refused.",
              schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf([
                "proposal", "imageAnalysis", "whiteBalance", "unsupported", "unsupportedLanguage", "refused"
              ])]))
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
