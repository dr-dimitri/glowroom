import Foundation
import GlowroomCore

struct SemanticImageInput: Sendable {
    let values: [Float]
    let rasterSHA256: String
    let sourceRevision: String
}

enum SemanticSourceStampBatch {
    static let maximumCount = 64
}

protocol SemanticImagePreprocessing: Sendable {
    func sourceStamp(source: AIOriginalSourceFingerprint) async throws -> String
    /// Ordered one-for-one results; nil means only a missing or stale source.
    /// Batches never exceed maximumCount and never decode image pixels.
    func sourceStamps(sources: [AIOriginalSourceFingerprint]) async throws -> [String?]
    func prepare(source: AIOriginalSourceFingerprint, priority: PreviewPriority) async throws -> SemanticImageInput
}

extension SemanticImagePreprocessing {
    /// Compatibility for fakes/other preparers. Production overrides this
    /// requirement so an existential call performs one synchronous stat batch.
    func sourceStamps(sources: [AIOriginalSourceFingerprint]) async throws -> [String?] {
        guard sources.count <= SemanticSourceStampBatch.maximumCount else { throw SemanticEmbeddingError.invalidInput }
        try Task.checkCancellation()
        var result: [String?] = []; result.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            do { result.append(try await sourceStamp(source: source)) }
            catch {
                try Task.checkCancellation()
                guard error as? SemanticEmbeddingError == .staleSource else { throw error }
                result.append(nil)
            }
        }
        try Task.checkCancellation()
        return result
    }
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
