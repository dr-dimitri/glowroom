import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Glowroom
import GlowroomCore

/// Explicit, serial native measurement. The corpus contains only 10,000 copies
/// of the 30 frozen synthetic PNGs, paired with their frozen Torch vectors.
/// Installation/import, model conversion and downloads never happen here.
@Suite("Opt-in integrated semantic 10,000-candidate benchmark", .serialized)
struct SemanticIntegrationBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_RUN_SEMANTIC_INTEGRATION_BENCHMARK"] == "1"))
    func productionEncoderSQLiteAndSourceStamps() async throws {
        let output = URL(fileURLWithPath: "/private/tmp/glowroom-semantic-integration-benchmark", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report = IntegrationReport()
        do {
            try await Self.run(output: output, report: &report)
        } catch {
            // Preserve partial measurements and a typed error even if a gate,
            // unavailable installation or runtime failure prevents completion.
            report.failure = (error as? SemanticEmbeddingError).map { String(describing: $0) }
                ?? String(describing: type(of: error))
            report.processHighWaterRSSBytes = Self.highWaterRSS()
            try Self.write(report, to: output)
            print("Semantic integrated benchmark failure report: \(output.appendingPathComponent("results.json").path)")
            throw error
        }
        try Self.write(report, to: output)
        print("Semantic integrated benchmark: \(output.appendingPathComponent("results.json").path)")
        // Write JSON before recording a failing performance expectation.
        #expect(report.warmP95Milliseconds.map { $0 <= 500 } == true)
        #expect(report.additionalPeakRSSBytes.map { $0 <= 1_610_612_736 } == true)
    }

    private static func run(output: URL, report: inout IntegrationReport) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["GLOWROOM_SEMANTIC_INSTALL_DIR"], let real = realpath(path, nil) else {
            throw SemanticEmbeddingError.invalidInstallation
        }
        let installationDirectory = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        guard installationDirectory.path.hasPrefix("/private/tmp/") else { throw SemanticEmbeddingError.invalidInput }
        let installer = SemanticModelInstaller(directory: installationDirectory)
        guard let installation = try await installer.installedModel(),
              installation.descriptor == SemanticLocalProviderFactory.descriptor,
              installation.descriptor.dimension == 768 else { throw SemanticEmbeddingError.invalidInstallation }
        report.descriptor = installation.descriptor
        report.installationFingerprint = installation.installationFingerprint
        report.installedBytes = installation.installedBytes
        guard installation.installedBytes <= 1_073_741_824 else { throw SemanticEmbeddingError.invalidInstallation }

        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Semantic", isDirectory: true)
        let truthData = try Data(contentsOf: fixtures.appendingPathComponent("ground-truth.json"))
        guard digest(truthData) == "c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025" else {
            throw SemanticEmbeddingError.invalidInput
        }
        let truth = try JSONDecoder().decode(IntegrationTruth.self, from: truthData)
        guard truth.assets.count == 30 else { throw SemanticEmbeddingError.invalidInput }
        let queryData = try Data(contentsOf: fixtures.appendingPathComponent("query-token-golden.json"))
        let queries = try JSONDecoder().decode([IntegrationQuery].self, from: queryData)
        let german = Array(queries.filter { $0.language == "de" }.prefix(10))
        let english = Array(queries.filter { $0.language == "en" }.prefix(10))
        guard german.count == 10, english.count == 10 else { throw SemanticEmbeddingError.invalidInput }
        let measuredQueries = zip(german, english).flatMap { pair in [pair.0, pair.1] }
        guard Set(measuredQueries.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == 20 else {
            throw SemanticEmbeddingError.invalidInput
        }
        report.groundTruthSHA256 = digest(truthData); report.queryFixtureSHA256 = digest(queryData)
        let referenceData = try Data(contentsOf: fixtures.appendingPathComponent("reference-images.f32"))
        guard digest(referenceData) == "09d50c18b84838ce411b41dfd2117f867f5e1a764a1f4c575b163a9b3446f2cf",
              referenceData.count == 30 * 768 * 4 else { throw SemanticEmbeddingError.invalidVector }
        report.referenceVectorsSHA256 = digest(referenceData)
        let vectors: [[Float]] = try (0..<30).map { index in
            let vector = referenceData.withUnsafeBytes { raw in
                (0..<768).map { component in
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (index * 768 + component) * 4, as: UInt32.self)))
                }
            }
            try SemanticVectorSearch.validateVector(vector, dimension: 768)
            return vector
        }

        let setupStart = uptime()
        // Isolated instances use the production decoders and resampler, with no
        // personal/default disk cache. Only 30 fixture tensors are prepared.
        let preparer = SemanticImagePreprocessor(imagePipeline: ImagePreviewPipeline(diskCache: nil),
            renderPipeline: AdjustedPreviewPipeline())
        var pngs: [Data] = [], rasterDigests: [String] = []
        let rasterStart = uptime()
        for asset in truth.assets {
            let url = fixtures.appendingPathComponent(asset.path)
            let png = try Data(contentsOf: url)
            guard digest(png) == asset.png_sha256 else { throw SemanticEmbeddingError.invalidInput }
            pngs.append(png)
            let photo = try makePhoto(at: url, ordinal: pngs.count - 1, folderID: UUID())
            let input = try await preparer.prepare(source: source(photo))
            rasterDigests.append(input.rasterSHA256)
        }
        report.fixtureRasterPreparationMilliseconds = milliseconds(since: rasterStart)
        let corpus = output.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let frozenPNGs = pngs, folderID = UUID()
        // Two bounded file workers; SQLite mutations below remain serial.
        let generated = try await withThrowingTaskGroup(of: [(Int, PhotoAsset)].self) { group in
            for worker in 0..<2 {
                group.addTask {
                    var values: [(Int, PhotoAsset)] = []
                    for ordinal in stride(from: worker, to: 10_000, by: 2) {
                        try Task.checkCancellation()
                        let url = corpus.appendingPathComponent(String(format: "image-%05d.png", ordinal))
                        try frozenPNGs[ordinal % 30].write(to: url)
                        values.append((ordinal, try makePhoto(at: url, ordinal: ordinal, folderID: folderID)))
                    }
                    return values
                }
            }
            var values: [(Int, PhotoAsset)] = []
            for try await value in group { values.append(contentsOf: value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let store = try SemanticIndexStore(directory: output.appendingPathComponent("index", isDirectory: true))
        let generation = try await store.prepareGeneration(for: installation.descriptor,
            installationFingerprint: installation.installationFingerprint)
        let seedStart = uptime()
        for (ordinal, photo) in generated.enumerated() {
            let fingerprint = source(photo)
            let revision = try await preparer.sourceStamp(source: fingerprint)
            try await store.upsert(SemanticIndexRecord(assetID: photo.id, source: fingerprint,
                sourceRevision: revision, inputRasterSHA256: rasterDigests[ordinal % 30], vector: vectors[ordinal % 30]), in: generation)
        }
        try await store.activate(generation)
        report.seedStoreAndStampsMilliseconds = milliseconds(since: seedStart)
        report.setupMilliseconds = milliseconds(since: setupStart)
        report.candidateCount = generated.count
        let native = SemanticLocalProviderFactory.makeProvider(installation: installation)
        let provider = IntegrationTimedProvider(base: native)
        guard await provider.availability() == .available else { throw SemanticEmbeddingError.invalidInstallation }
        let service = SemanticSearchService(store: store, installer: installer,
            providerFactory: { _ in provider }, preparer: preparer, budget: .shared)
        await service.updateCatalog(snapshotSessionID: UUID(), generation: 1, assets: generated)
        let indexed = try await service.status(scope: generated)
        report.verifiedIndexedCandidateCount = indexed.indexedCount
        guard indexed.indexedCount == generated.count, indexed.missingCount == 0,
              indexed.staleCount == 0 else { throw SemanticEmbeddingError.staleSource }
        report.baseRSSBeforeProviderLoadBytes = residentRSS()
        report.processHighWaterBeforeProviderLoadBytes = highWaterRSS()
        let loadStart = uptime()
        let lease = try await AIResourceBudget.shared.acquireLocalInference()
        do {
            let vector = try await provider.encodeText("benchmark initial integrity verification and model load")
            try SemanticVectorSearch.validateVector(vector, dimension: 768)
            await AIResourceBudget.shared.release(lease)
        } catch {
            await AIResourceBudget.shared.release(lease)
            await provider.unload()
            await service.shutdown()
            throw error
        }
        report.firstIntegrityLoadAndEncodeMilliseconds = milliseconds(since: loadStart)
        report.residentRSSAfterProviderLoadBytes = residentRSS()
        do {
            // First complete service request is separate from the 20 warm,
            // distinct cache-miss queries, then the exact same 20 cache hits.
            report.firstServiceQuery = try await sample(query: .init(id: "first-service", language: "en", text: "first complete integrated semantic query"),
                phase: "first-service", service: service, provider: provider, photos: generated)
            for query in measuredQueries {
                report.samples.append(try await sample(query: query, phase: "warm-distinct", service: service, provider: provider, photos: generated))
            }
            for query in measuredQueries {
                report.samples.append(try await sample(query: query, phase: "warm-query-cache", service: service, provider: provider, photos: generated))
            }
            let distinct = report.samples.filter { $0.phase == "warm-distinct" }
            let repeats = report.samples.filter { $0.phase == "warm-query-cache" }
            guard zip(distinct, repeats).allSatisfy({ pair in
                pair.0.queryID == pair.1.queryID && pair.0.hitIDs == pair.1.hitIDs && pair.0.hitScores == pair.1.hitScores
            }) else { throw SemanticEmbeddingError.providerFailure }
            let warm = report.samples.filter { $0.phase == "warm-distinct" }.map(\.totalMilliseconds)
            let cached = report.samples.filter { $0.phase == "warm-query-cache" }.map(\.totalMilliseconds)
            report.warmP50Milliseconds = percentile(warm, fraction: 0.5)
            report.warmP95Milliseconds = percentile(warm, fraction: 0.95)
            report.cachedP50Milliseconds = percentile(cached, fraction: 0.5)
            report.cachedP95Milliseconds = percentile(cached, fraction: 0.95)
            guard report.samples.filter({ $0.phase == "warm-distinct" }).allSatisfy({ $0.nativeEncodeCalls == 1 }),
                  report.samples.filter({ $0.phase == "warm-query-cache" }).allSatisfy({ $0.nativeEncodeCalls == 0 }) else {
                throw SemanticEmbeddingError.providerFailure
            }
            report.processHighWaterRSSBytes = highWaterRSS()
            if let peak = report.processHighWaterRSSBytes, let baseline = report.baseRSSBeforeProviderLoadBytes {
                report.additionalPeakRSSBytes = peak > baseline ? peak - baseline : 0
            }
            report.latencyGatePassed = report.warmP95Milliseconds.map { $0 <= 500 }
            report.memoryGatePassed = report.additionalPeakRSSBytes.map { $0 <= 1_610_612_736 }
        } catch {
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }

    private static func sample(query: IntegrationQuery, phase: String, service: SemanticSearchService,
                               provider: IntegrationTimedProvider, photos: [PhotoAsset]) async throws -> IntegrationSample {
        let before = await provider.snapshot(), start = uptime()
        let result = try await service.search(query: query.text, candidates: photos, topK: 100)
        let elapsed = milliseconds(since: start), after = await provider.snapshot()
        guard result.candidateAssetIDs == photos.map(\.id), result.hits.count == 100,
              Set(result.hits.map(\.assetID)).count == 100,
              result.hits.allSatisfy({ $0.score.isFinite }) else { throw SemanticEmbeddingError.providerFailure }
        let admitted = Set(photos.map(\.id))
        guard result.hits.allSatisfy({ admitted.contains($0.assetID) }) else { throw SemanticEmbeddingError.providerFailure }
        let encodeTime = after.milliseconds - before.milliseconds
        return IntegrationSample(queryID: query.id, language: query.language, text: query.text, phase: phase,
            totalMilliseconds: elapsed, nativeEncodeMilliseconds: encodeTime,
            sourceStampSQLiteRankingAndCoordinationMilliseconds: max(0, elapsed - encodeTime),
            nativeEncodeCalls: after.calls - before.calls, hitIDs: result.hits.map(\.assetID), hitScores: result.hits.map(\.score))
    }

    private static func makePhoto(at url: URL, ordinal: Int, folderID: UUID) throws -> PhotoAsset {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber else {
            throw SemanticEmbeddingError.staleSource
        }
        return PhotoAsset(id: String(format: "synthetic-%05d", ordinal), folderID: folderID, fileURL: url,
            fileSize: size.int64Value, modifiedAt: modified)
    }
    private static func source(_ photo: PhotoAsset) -> AIOriginalSourceFingerprint {
        AIOriginalSourceFingerprint(fileURL: photo.fileURL, modifiedAt: photo.modifiedAt, fileSize: photo.fileSize)
    }
    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    private static func milliseconds(since start: Double) -> Double { (uptime() - start) * 1_000 }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[max(0, min(values.count - 1, Int(ceil(Double(values.count) * fraction)) - 1))]
    }
    private static func residentRSS() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
    private static func highWaterRSS() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss >= 0 else { return nil }
        return UInt64(usage.ru_maxrss) // Darwin reports bytes, not KiB.
    }
    private static func write(_ report: IntegrationReport, to output: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("results.json"), options: .atomic)
    }
}

private struct IntegrationTruth: Decodable {
    struct Asset: Decodable { let id: String; let path: String; let png_sha256: String }
    let assets: [Asset]
}
private struct IntegrationQuery: Codable, Sendable { let id: String; let language: String; let text: String }
private struct IntegrationSample: Codable {
    let queryID: String; let language: String; let text: String; let phase: String
    let totalMilliseconds: Double; let nativeEncodeMilliseconds: Double
    let sourceStampSQLiteRankingAndCoordinationMilliseconds: Double
    let nativeEncodeCalls: Int; let hitIDs: [String]; let hitScores: [Float]
}
private struct IntegrationReport: Encodable {
    let schemaVersion = 1
    let recordedAt = ISO8601DateFormatter().string(from: Date())
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let deviceModel: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }()
    let processorCount = ProcessInfo.processInfo.activeProcessorCount
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    #if DEBUG
    let configuration = "debug"
    #else
    let configuration = "release"
    #endif
    let modelComputeUnits = "cpuOnly"
    let limitations = [
        "Synthetic 256px PNGs only; 10,000 distinct files repeat 30 frozen contents/vectors. No camera-RAW or private-photo quality claim.",
        "Fixture preprocessing and serial SQLite seeding are setup, not 10,000 measured image-encoder calls or indexing throughput.",
        "OS file caches are already warm after setup and explicit full index-coverage verification; no cold filesystem or full graphical app measurement.",
        "First integrity/load measurement includes one encode; the provider API does not expose a pure load call.",
        "Non-encoding remainder includes two-worker source stamps, SQLite pages, ranking, validation and actor coordination; it is not isolated dot-product time.",
        "Darwin process high-water includes setup and the test harness; peak minus pre-load resident RSS is a conservative process delta, not isolated model allocation.",
        "Twenty warm distinct queries and twenty cache repeats are serial; p95 uses nearest rank. Run alone in release without competing models or builds."
    ]
    var descriptor: SemanticModelDescriptor?
    var installationFingerprint: String?
    var installedBytes: Int64?
    var groundTruthSHA256: String?
    var queryFixtureSHA256: String?
    var referenceVectorsSHA256: String?
    var candidateCount = 0
    var verifiedIndexedCandidateCount: Int?
    var setupMilliseconds: Double?
    var fixtureRasterPreparationMilliseconds: Double?
    var seedStoreAndStampsMilliseconds: Double?
    var firstIntegrityLoadAndEncodeMilliseconds: Double?
    var baseRSSBeforeProviderLoadBytes: UInt64?
    var processHighWaterBeforeProviderLoadBytes: UInt64?
    var residentRSSAfterProviderLoadBytes: UInt64?
    var processHighWaterRSSBytes: UInt64?
    var additionalPeakRSSBytes: UInt64?
    var firstServiceQuery: IntegrationSample?
    var samples: [IntegrationSample] = []
    var warmP50Milliseconds: Double?
    var warmP95Milliseconds: Double?
    var cachedP50Milliseconds: Double?
    var cachedP95Milliseconds: Double?
    var latencyGatePassed: Bool?
    var memoryGatePassed: Bool?
    var failure: String?
}

/// Only timing/count instrumentation wraps the real production CPU provider;
/// availability, native execution, errors and unloading are forwarded unchanged.
private actor IntegrationTimedProvider: SemanticEmbeddingProviding {
    nonisolated let descriptor: SemanticModelDescriptor
    private let base: any SemanticEmbeddingProviding
    private var calls = 0
    private var milliseconds = 0.0
    init(base: any SemanticEmbeddingProviding) { self.base = base; descriptor = base.descriptor }
    func availability() async -> SemanticAvailability { await base.availability() }
    func encodeText(_ text: String) async throws -> [Float] {
        let start = ProcessInfo.processInfo.systemUptime
        defer { calls += 1; milliseconds += (ProcessInfo.processInfo.systemUptime - start) * 1_000 }
        return try await base.encodeText(text)
    }
    func encodeImage(_ input: SemanticImageInput) async throws -> [Float] { try await base.encodeImage(input) }
    func unload() async { await base.unload() }
    func snapshot() -> (calls: Int, milliseconds: Double) { (calls, milliseconds) }
}
