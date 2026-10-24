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

    // Generated from the versioned model card; installation validation is unchanged.
    static let qwen35 = LocalModelRegistry.qwen35
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
