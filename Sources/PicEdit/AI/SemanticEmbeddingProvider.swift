import Foundation
import PicEditCore

struct SemanticImageInput: Sendable {
    let values: [Float]
    let rasterSHA256: String
    let sourceRevision: String
}

protocol SemanticImagePreprocessing: Sendable {
    func sourceStamp(source: AIOriginalSourceFingerprint) async throws -> String
    func prepare(source: AIOriginalSourceFingerprint, priority: PreviewPriority) async throws -> SemanticImageInput
}

extension SemanticImagePreprocessing {
    func prepare(source: AIOriginalSourceFingerprint) async throws -> SemanticImageInput {
        try await prepare(source: source, priority: .thumbnail)
    }
}

protocol SemanticEmbeddingProviding: Sendable {
    var descriptor: SemanticModelDescriptor { get }
    func availability() async -> SemanticAvailability
    func encodeText(_ text: String) async throws -> [Float]
    func encodeImage(_ input: SemanticImageInput) async throws -> [Float]
    func unload() async
}

struct SemanticModelLicense: Hashable, Sendable {
    let title: String
    let text: String
}

struct SemanticModelImportReview: Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let descriptor: SemanticModelDescriptor
    let sourceBytes: Int64
    let maximumInstalledBytes: Int64
    let stagingBytesRequired: Int64
    let licenses: [SemanticModelLicense]
    var licenseTexts: [String] { licenses.map { $0.title + "\n\n" + $0.text } }
}

struct SemanticInstalledModel: Hashable, Sendable {
    let directory: URL
    let descriptor: SemanticModelDescriptor
    let installationFingerprint: String
    let installedBytes: Int64
}

struct SemanticInstallProgress: Sendable {
    enum Phase: Sendable { case verifying, copying, compiling, publishing }
    let phase: Phase
    let completedBytes: Int64
    let totalBytes: Int64
}
