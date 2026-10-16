import Foundation
import Tokenizers
import struct Hub.Config
import PicEditCore

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
        let data = try SemanticInstallationIO.read(url, limit: maximumBytes)
        return try JSONDecoder().decode(Config.self, from: data)
    }
}
