import Darwin
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

/// Separate, explicit image-to-image evaluation. Uses only the frozen synthetic
/// motif/color counterexamples, production SQLite, native stamps and ranker.
/// No private originals, model installation, decoding or inference are needed.
@Suite("Opt-in local image similarity evaluation", .serialized)
struct SemanticImageSimilarityEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_RUN_IMAGE_SIMILARITY_EVALUATION"] == "1"))
    func frozenMotifGroupsAndColorCounterexamples() async throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Semantic", isDirectory: true)
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("ground-truth.json")))
        let bytes = try Data(contentsOf: fixtureDirectory.appendingPathComponent("reference-images.f32"))
        try #require(truth.assets.count == 30 && bytes.count == 30 * 768 * 4)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-image-similarity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let descriptor = SemanticLocalProviderFactory.descriptor
        let installation = SemanticInstalledModel(directory: output.appendingPathComponent("unused-model"), descriptor: descriptor,
            installationFingerprint: String(repeating: "e", count: 64), installedBytes: 0)
        let preparer = SemanticImagePreprocessor()
        let store = try SemanticIndexStore(directory: output.appendingPathComponent("Catalog"))
        let generation = try await store.prepareGeneration(for: descriptor, installationFingerprint: installation.installationFingerprint)
        let folderID = UUID()
        var photos: [PhotoAsset] = []
        for (ordinal, asset) in truth.assets.enumerated() {
            let file = output.appendingPathComponent(asset.id + ".png")
            try FileManager.default.copyItem(at: fixtureDirectory.appendingPathComponent(asset.path), to: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let photo = PhotoAsset(id: asset.id, folderID: folderID, fileURL: file,
                fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: try #require(attributes[.modificationDate] as? Date))
            let source = AIOriginalSourceFingerprint(fileURL: file, modifiedAt: photo.modifiedAt, fileSize: photo.fileSize)
            let vector = bytes.withUnsafeBytes { raw in
                (0..<768).map { component in
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (ordinal * 768 + component) * 4, as: UInt32.self)))
                }
            }
            try SemanticVectorSearch.validateVector(vector, dimension: 768)
            let revision = try await preparer.sourceStamp(source: source)
            try await store.upsert(SemanticIndexRecord(assetID: photo.id, source: source,
                sourceRevision: revision, inputRasterSHA256: String(repeating: "c", count: 64), vector: vector), in: generation)
            photos.append(photo)
        }
        try await store.activate(generation)
        let provider = NoInferenceProvider(descriptor: descriptor)
        let service = SemanticSearchService(store: try SemanticIndexStore(directory: output.appendingPathComponent("Catalog")),
            installer: MetadataOnlyInstaller(model: installation), providerFactory: { _ in provider }, preparer: preparer, budget: AIResourceBudget())
        await service.updateCatalog(snapshotSessionID: UUID(), generation: 1, assets: photos)
        let baselineRSS = Self.peakRSS()
        let start = ProcessInfo.processInfo.systemUptime
        let first = try await service.search(similarTo: photos[0], candidates: photos, topK: 4)
        let firstMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        #expect(first.hits.count == 4 && !first.hits.contains { $0.assetID == photos[0].id })
        let byID = Dictionary(uniqueKeysWithValues: truth.assets.map { ($0.id, $0) })
        var samples: [Sample] = []
        for photo in photos {
            let begin = ProcessInfo.processInfo.systemUptime
            let result = try await service.search(similarTo: photo, candidates: photos, topK: 4)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1_000
            let reference = byID[photo.id]!
            let neighbors = result.hits.map { byID[$0.assetID]! }
            #expect(result.hits.count == 4 && !result.hits.contains { $0.assetID == photo.id })
            samples.append(Sample(referenceID: photo.id, motif: reference.kind, color: reference.color,
                milliseconds: milliseconds, neighborIDs: neighbors.map(\.id),
                sameMotifCount: neighbors.filter { $0.kind == reference.kind }.count,
                sameColorDifferentMotifCount: neighbors.filter { $0.kind != reference.kind && $0.color == reference.color }.count))
        }
        let report = Report(indexedCount: photos.count, dimension: descriptor.dimension, topK: 4,
            conditions: "Fresh service/SQLite handle after seeded setup; OS/filesystem caches warm from setup. First access is not a cold disk or cold OS measurement. No native model loaded. Warm samples reuse the same service. RSS is the process-lifetime high-water increment and can hide allocations below an earlier peak. Synthetic motifs and same-color different-motif counterexamples only; no RAW, GUI or general photo quality claim.",
            firstAccessMilliseconds: firstMilliseconds, warmSamples: samples,
            additionalPeakRSSBytes: max(0, Self.peakRSS() - baselineRSS))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let resultFile = output.appendingPathComponent("results.json")
        try encoder.encode(report).write(to: resultFile, options: .atomic)
        print("Image similarity evaluation: \(resultFile.path)")
        await service.shutdown()
    }

    private static func peakRSS() -> Int64 {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
    private struct Truth: Decodable { let assets: [Asset] }
    private struct Asset: Decodable { let id: String; let kind: String; let color: String; let path: String }
    private struct Sample: Encodable {
        let referenceID: String; let motif: String; let color: String; let milliseconds: Double
        let neighborIDs: [String]; let sameMotifCount: Int; let sameColorDifferentMotifCount: Int
    }
    private struct Report: Encodable {
        let indexedCount: Int; let dimension: Int; let topK: Int; let conditions: String
        let firstAccessMilliseconds: Double; let warmSamples: [Sample]; let additionalPeakRSSBytes: Int64
    }
    private actor NoInferenceProvider: SemanticEmbeddingProviding {
        nonisolated let descriptor: SemanticModelDescriptor
        init(descriptor: SemanticModelDescriptor) { self.descriptor = descriptor }
        func availability() -> SemanticAvailability { .available }
        func encodeText(_ text: String) throws -> [Float] { throw SemanticEmbeddingError.providerFailure }
        func encodeImage(_ input: SemanticImageInput) throws -> [Float] { throw SemanticEmbeddingError.providerFailure }
        func unload() {}
    }
    private actor MetadataOnlyInstaller: SemanticModelInstalling {
        let model: SemanticInstalledModel
        init(model: SemanticInstalledModel) { self.model = model }
        func installedModel() -> SemanticInstalledModel? { model }
        func inspect(source: URL) throws -> SemanticModelImportReview { throw SemanticEmbeddingError.invalidInput }
        func install(_ review: SemanticModelImportReview, progress: @escaping @Sendable (SemanticInstallProgress) -> Void) throws -> SemanticInstalledModel { throw SemanticEmbeddingError.invalidInput }
        func remove() throws { throw SemanticEmbeddingError.invalidInput }
    }
}
