import CoreGraphics
import CoreImage
import Foundation
import Metal
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Local, offline vision-language inference. The caller owns the shared
/// AIResourceBudget and the model-store lease until this method actually returns.
/// Nothing here writes to the catalogue, edits, originals, or a network service.
struct QwenDevelopmentBackend: Sendable {
    enum Failure: LocalizedError {
        case unsupportedHardware, missingRuntime, invalidInput, invalidResponse, busy

        var errorDescription: String? {
            switch self {
            case .unsupportedHardware: return "Qwen3.5 benötigt einen Mac mit Apple Silicon und verfügbarem Metal."
            case .missingRuntime: return "Die lokale Qwen-Laufzeit fehlt oder ist beschädigt. Bitte Glowroom neu installieren."
            case .invalidInput: return "Die Bildvorschau oder der Entwicklungsauftrag ist ungültig."
            case .invalidResponse: return "Das Modell hat keinen vollständigen Entwicklungsvorschlag geliefert."
            case .busy: return "Eine lokale Modellausführung läuft bereits."
            }
        }
    }

    func propose(modelDirectory: URL, image: CGImage, prompt: String, schema: String,
                 suppressesWhitespaceRuns: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= 2_048, image.height <= 2_048,
              !prompt.isEmpty, prompt.utf8.count <= 24_000, schema.utf8.count <= 24_000 else {
            throw Failure.invalidInput
        }
        // This actor does not cache weights. A completed/cancelled operation
        // releases all model references before the model directory can be deleted.
        return try await QwenNativeRuntime.shared.propose(
            modelDirectory: modelDirectory, image: image, prompt: prompt, schema: schema, suppressesWhitespaceRuns: suppressesWhitespaceRuns)
    }
}

private actor QwenNativeRuntime {
    static let shared = QwenNativeRuntime()
    private var initialized = false
    private var busy = false

    private func prepareRuntime() throws {
        guard !initialized else { return }
        #if arch(arm64)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw QwenDevelopmentBackend.Failure.unsupportedHardware
        }
        // A packaged app uses its own resource. Tests and command-line harnesses
        // receive a generated, checksum-verified path from the build scripts.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("mlx.metallib")
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        let development = ProcessInfo.processInfo.environment["GLOWROOM_MLX_METALLIB"].map(URL.init(fileURLWithPath:))
        guard let library = [bundled, adjacent, development].compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { throw QwenDevelopmentBackend.Failure.missingRuntime }
        do { _ = try device.makeLibrary(URL: library) }
        catch { throw QwenDevelopmentBackend.Failure.missingRuntime }
        GPU.metallib = library
        Memory.cacheLimit = 64 * 1_024 * 1_024
        initialized = true
        #else
        throw QwenDevelopmentBackend.Failure.unsupportedHardware
        #endif
    }

    func propose(modelDirectory: URL, image: CGImage, prompt: String, schema: String, suppressesWhitespaceRuns: Bool) async throws -> Data {
        guard !busy else { throw QwenDevelopmentBackend.Failure.busy }
        try prepareRuntime()
        try Task.checkCancellation()
        busy = true
        // All native calls and grammar compilation execute on this background
        // actor. Shared admission intentionally serializes model work to bound
        // Unified Memory; XGrammar CPU work overlaps the model's GPU passes.
        defer {
            Stream.gpu.synchronize()
            Memory.clearCache()
            busy = false
        }
        return try await infer(modelDirectory: modelDirectory, image: image, prompt: prompt, schema: schema, suppressesWhitespaceRuns: suppressesWhitespaceRuns)
    }

    private func infer(modelDirectory: URL, image: CGImage, prompt: String, schema: String, suppressesWhitespaceRuns: Bool) async throws -> Data {
        let container = try await VLMModelFactory.shared.loadContainer(from: modelDirectory, using: QwenTokenizerLoader())
        try Task.checkCancellation()
        return try await container.perform { context in
            let tokenizer = context.tokenizer
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            guard let eos = tokenizer.eosTokenId else { throw QwenDevelopmentBackend.Failure.invalidResponse }
            let grammarTokenizer = try GrammarTokenizer(vocab: vocabulary.vocab,
                vocabType: vocabulary.vocabType, eosTokenId: Int32(eos))
            let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema,
                fastForward: true, hostTokenizer: tokenizer)
            var input = UserInput(prompt: prompt, images: [.ciImage(CIImage(cgImage: image))],
                                  additionalContext: ["enable_thinking": false])
            input.processing.resize = CGSize(width: 1_024, height: 1_024)
            let prepared = try await context.processor.prepare(input: input)
            try Task.checkCancellation()
            var output = ""
            // Greedy sampling is intrinsic to GuidedGenerationLoop. It throws
            // on token exhaustion or premature EOS; no partial JSON is repaired.
            // Structured localization responses can otherwise emit long tab runs.
            // Suppress pathological whitespace runs without closing or repairing
            // incomplete JSON. The decoder still validates every returned value.
            let whitespace = suppressesWhitespaceRuns ? WhitespaceTokenBias.compute(tokenizer: tokenizer) : nil
            try GuidedGenerationLoop.run(input: prepared, context: context, constraint: constraint,
                maxTokens: 768, vocabSize: grammarTokenizer.vocabSize,
                whitespaceBias: whitespace?.bias, whitespaceTokenIDs: whitespace?.tokenIDs ?? [],
                prefill: PrefillParameters(stepSize: 512)) { text in
                    output += text
                    return !Task.isCancelled && output.utf8.count <= 16_384
                }
            try Task.checkCancellation()
            guard !output.isEmpty, output.utf8.count <= 16_384 else {
                throw QwenDevelopmentBackend.Failure.invalidResponse
            }
            return Data(output.utf8)
        }
    }
}

/// Reuses Glowroom's pinned tokenizer implementation, with local loading only.
private struct QwenTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        QwenTokenizer(base: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct QwenTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
