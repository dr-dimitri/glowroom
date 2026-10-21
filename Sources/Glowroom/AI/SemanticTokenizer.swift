import Foundation
import Tokenizers
import struct Hub.Config
import GlowroomCore

/// Only local typed JSON configuration enters the upstream tokenizer. No HubApi,
/// model-folder loader, remote resolver or chat-template execution is used.
struct SemanticTokenizer: Sendable {
    private let tokenizer: any Tokenizer

    init(directory: URL) throws {
        let config = try Self.read(directory.appendingPathComponent("tokenizer_config.json"), maximumBytes: 128 * 1_024)
        let data = try Self.read(directory.appendingPathComponent("tokenizer.json"), maximumBytes: 40 * 1_024 * 1_024)
        tokenizer = try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: data, strict: true)
    }

    func tokens(for text: String) throws -> [Int32] {
        try Task.checkCancellation()
        guard text.utf8.count <= 4_096 else {
            throw SemanticEmbeddingError.invalidInput
        }
        let values = tokenizer.encode(text: text.lowercased(), addSpecialTokens: false)
        guard values.allSatisfy({ $0 >= 0 && $0 < 256_000 }) else { throw SemanticEmbeddingError.invalidInput }
        let tokens = Array(values.prefix(63)) + [1]
        return (tokens + Array(repeating: 0, count: 64 - tokens.count)).map(Int32.init)
    }

    private static func read(_ url: URL, maximumBytes: Int) throws -> Config {
        try autoreleasepool {
            let data = try SemanticInstallationIO.read(url, limit: maximumBytes)
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [NSString: Any] else {
                throw SemanticEmbeddingError.invalidInstallation
            }
            try Task.checkCancellation()
            // The pinned Gemma vocabulary is an array of token/score pairs;
            // object keys are configuration names and decimal added-token IDs.
            // Use the public upstream Config initializer, without a Hub loader.
            let config = Config(dictionary)
            try Task.checkCancellation()
            return config
        }
    }
}
