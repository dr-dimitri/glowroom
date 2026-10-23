import Foundation

/// Immutable model data approved by the app. The runtime never downloads code
/// or follows a mutable repository branch while opening an installation.
struct LLMModelDescriptor: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let repository: String
    let revision: String
    let files: [SemanticManifestFile]
    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var requiredDownloadFreeBytes: Int64 { downloadBytes * 2 + 64 * 1_024 * 1_024 }
    var modelCard: URL { URL(string: "https://huggingface.co/\(repository)")! }
    func downloadURL(for file: SemanticManifestFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")!
    }

    // Identity copied from the complete, hashed local evaluation provenance.
    // This includes tokenizer, image processor and chat template, not weights alone.
    static let qwen35 = LLMModelDescriptor(id: "qwen35-4b-4bit", name: "Qwen3.5-4B", repository: "mlx-community/Qwen3.5-4B-4bit",
        revision: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c", files: [
            .init(path: "chat_template.jinja", bytes: 7_756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
            .init(path: "config.json", bytes: 3_366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
            .init(path: "model.safetensors", bytes: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
            .init(path: "model.safetensors.index.json", bytes: 101_944, sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
            .init(path: "preprocessor_config.json", bytes: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
            .init(path: "processor_config.json", bytes: 1_300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
            .init(path: "tokenizer.json", bytes: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            .init(path: "tokenizer_config.json", bytes: 1_139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
            .init(path: "video_preprocessor_config.json", bytes: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
            .init(path: "vocab.json", bytes: 6_722_759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003")
        ])
}

struct LLMInstalledModel: Sendable, Equatable {
    let directory: URL
    let descriptor: LLMModelDescriptor
    var installedBytes: Int64 { descriptor.downloadBytes }
}

struct LLMModelDownloadProgress: Sendable {
    let text: String
    let fraction: Double?
    let downloadedBytes: Int64
    let totalBytes: Int64
}

enum LLMModelError: Error, LocalizedError, Equatable {
    case invalidInstallation, operationInProgress, modelInUse, insufficientDiskSpace, modelNotInstalled, invalidDownload
    var errorDescription: String? {
        switch self {
        case .invalidInstallation: "Das LLM ist unvollständig oder verändert. Lösche es und lade es erneut herunter."
        case .operationInProgress: "Die Modellverwaltung arbeitet bereits. Warte auf den Abschluss oder brich den Download ab."
        case .modelInUse: "Das LLM wird gerade verwendet. Beende die AI-Entwicklung, bevor du es löschst."
        case .insufficientDiskSpace: "Es ist nicht genügend freier Speicher für das Modell und den Download vorhanden."
        case .modelNotInstalled: "Lade zuerst das LLM über „Modelle verwalten“ herunter."
        case .invalidDownload: "Der Modelldownload ist unvollständig oder stimmt nicht mit der geprüften Version überein."
        }
    }
}
