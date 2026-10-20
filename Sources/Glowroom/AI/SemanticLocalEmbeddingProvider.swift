import Foundation
import CoreML
import GlowroomCore

/// The paired towers and token/preprocessing versions form one index space.
/// CPU-only is intentional: the measured all-device first-load RSS had too
/// little reserve to enable it in an application with its own image caches.
enum SemanticLocalProviderFactory {
    static let descriptor = SemanticModelDescriptor(
        modelID: "google/siglip2-base-patch32-256",
        sourceRevision: "94dffa8cb1179de3e03f091dbc3917e5d5a9ae84",
        releaseID: "siglip2-base-p32-256-fp32-image-fp16-text-v1",
        dimension: 768, maximumTextTokens: 64,
        tokenizerVersion: "gemma-json-swift-transformers-e37cacea-v1",
        preprocessingVersion: 1, normalizationVersion: 1)

    static func makeProvider(installation: SemanticInstalledModel?) -> any SemanticEmbeddingProviding {
        SemanticLocalEmbeddingProvider(installation: installation)
    }
}

/// One service owns one provider and holds the shared AI lease across loading
/// and prediction. SDK operations are synchronous on this actor: cancellation
/// cannot release the service's slot while Core ML is still using the models.
actor SemanticLocalEmbeddingProvider: SemanticEmbeddingProviding {
    nonisolated let descriptor = SemanticLocalProviderFactory.descriptor
    private let installation: SemanticInstalledModel?
    private var loaded: Loaded?

    private struct Loaded {
        let text: MLModel
        let image: MLModel
        let tokenizer: SemanticTokenizer
        let fileStamps: [(URL, String)]
    }

    init(installation: SemanticInstalledModel?) { self.installation = installation }

    func availability() async -> SemanticAvailability {
        guard let installation else { return .unavailable(.modelNotInstalled) }
        guard installation.descriptor == descriptor,
              SemanticInstallationIO.validHash(installation.installationFingerprint),
              installation.installedBytes > 0,
              installation.installedBytes <= SemanticModelInstaller.maximumInstalledBytes else {
            return .unavailable(.invalidInstallation)
        }
        // Eight GiB is an admission floor, not an integrated memory claim.
        // The real full-app RSS gate remains separate from model-only results.
        guard ProcessInfo.processInfo.physicalMemory >= 8 * 1_024 * 1_024 * 1_024 else {
            return .unavailable(.insufficientMemory)
        }
        do {
            try SemanticInstallationIO.requireDirectory(installation.directory)
            try SemanticInstallationIO.requireDirectory(installation.directory.appendingPathComponent("text.mlmodelc"))
            try SemanticInstallationIO.requireDirectory(installation.directory.appendingPathComponent("image.mlmodelc"))
            return .available
        } catch { return .unavailable(.invalidInstallation) }
    }

    func encodeText(_ text: String) async throws -> [Float] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 4_096 else { throw SemanticEmbeddingError.invalidInput }
        do {
            let models = try ensureLoaded()
            let tokens = try models.tokenizer.tokens(for: text)
            try verifyStamps(models)
            let vector = try autoreleasepool { () throws -> [Float] in
                let array = try MLMultiArray(shape: [1, 64], dataType: .int32)
                tokens.withUnsafeBytes { source in
                    array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
                let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": array])
                let output = try models.text.prediction(from: input)
                return try Self.vector(output)
            }
            try Task.checkCancellation()
            try verifyStamps(models)
            return vector
        } catch { throw Self.sanitized(error) }
    }

    func encodeImage(_ input: SemanticImageInput) async throws -> [Float] {
        guard input.values.count == 3 * 256 * 256,
              input.values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
              SemanticInstallationIO.validHash(input.rasterSHA256), !input.sourceRevision.isEmpty else {
            throw SemanticEmbeddingError.invalidInput
        }
        do {
            let models = try ensureLoaded()
            try verifyStamps(models)
            let vector = try autoreleasepool { () throws -> [Float] in
                let array = try MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32)
                input.values.withUnsafeBytes { source in
                    array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
                let features = try MLDictionaryFeatureProvider(dictionary: ["pixels": array])
                let output = try models.image.prediction(from: features)
                return try Self.vector(output)
            }
            try Task.checkCancellation()
            try verifyStamps(models)
            return vector
        } catch { throw Self.sanitized(error) }
    }

    func unload() async { loaded = nil }

    private func ensureLoaded() throws -> Loaded {
        try Task.checkCancellation()
        if let loaded { return loaded }
        guard let installation else { throw SemanticEmbeddingError.unavailable(.modelNotInstalled) }
        guard installation.descriptor == descriptor else { throw SemanticEmbeddingError.unsupportedVersion }
        guard ProcessInfo.processInfo.physicalMemory >= 8 * 1_024 * 1_024 * 1_024 else {
            throw SemanticEmbeddingError.unavailable(.insufficientMemory)
        }
        let stamps = try SemanticModelInstaller.verifyInstallation(installation)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        // Preserve the measured text-first lifetime. Draining each model's
        // temporary specialization objects avoids overlapping them with the
        // other tower and the large tokenizer vocabulary.
        let text = try autoreleasepool {
            try MLModel(contentsOf: installation.directory.appendingPathComponent("text.mlmodelc"), configuration: configuration)
        }
        try Task.checkCancellation()
        let image = try autoreleasepool {
            try MLModel(contentsOf: installation.directory.appendingPathComponent("image.mlmodelc"), configuration: configuration)
        }
        try Task.checkCancellation()
        let tokenizer = try autoreleasepool {
            try SemanticTokenizer(directory: installation.directory.appendingPathComponent("tokenizer"))
        }
        try Task.checkCancellation()
        let result = Loaded(text: text, image: image, tokenizer: tokenizer, fileStamps: stamps)
        try verifyStamps(result)
        loaded = result
        return result
    }

    private func verifyStamps(_ models: Loaded) throws {
        do {
            for (url, expected) in models.fileStamps {
                guard try SemanticInstallationIO.stamp(url) == expected else { throw SemanticEmbeddingError.installationChanged }
            }
        } catch {
            loaded = nil
            throw SemanticEmbeddingError.installationChanged
        }
    }

    private static func vector(_ output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.count == 768, array.dataType == .float32 else { throw SemanticEmbeddingError.invalidVector }
        return try normalized((0..<768).map { array[$0].floatValue })
    }

    static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == 768, values.allSatisfy(\.isFinite) else { throw SemanticEmbeddingError.invalidVector }
        let squared = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squared.isFinite, squared > 1e-24 else { throw SemanticEmbeddingError.invalidVector }
        let norm = sqrt(squared)
        let result = values.map { Float(Double($0) / norm) }
        guard result.allSatisfy(\.isFinite) else { throw SemanticEmbeddingError.invalidVector }
        return result
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError { return SemanticEmbeddingError.cancelled }
        return (error as? SemanticEmbeddingError) ?? SemanticEmbeddingError.providerFailure
    }
}
