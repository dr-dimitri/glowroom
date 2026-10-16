import CryptoKit
import Darwin
import Foundation
import Testing
@testable import PicEdit
import PicEditCore

private struct SemanticNativeTruth: Decodable {
    struct Asset: Decodable { let id: String; let path: String; let png_sha256: String }
    struct Query: Decodable { let id: String; let relevant_asset_ids: [String] }
    let assets: [Asset]
    let queries: [Query]
}
private struct SemanticNativeQuery: Decodable { let id: String; let language: String; let text: String }

/// Never downloads a model or reads personal photographs. Every input is one
/// of the frozen programmatically drawn fixtures. Native work remains serial.
@Suite("Opt-in native semantic pair", .serialized)
struct SemanticNativeModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_RUN_SEMANTIC_MODEL_TESTS"] == "1"))
    func approvedImportAndProductionProviderMatchFrozenTorchPair() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["PICEDIT_SEMANTIC_PACKAGE_DIR"]))
        let directory = URL(fileURLWithPath: try #require(environment["PICEDIT_SEMANTIC_INSTALL_DIR"])).standardizedFileURL
        #expect(directory.path.hasPrefix("/private/tmp/") || directory.path.hasPrefix("/tmp/"))
        guard directory.path.hasPrefix("/private/tmp/") || directory.path.hasPrefix("/tmp/") else {
            throw SemanticEmbeddingError.invalidInput
        }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Semantic")
        let truthData = try Data(contentsOf: fixtures.appendingPathComponent("ground-truth.json"))
        #expect(SemanticInstallationIO.digest(truthData) == "c262bc1ecbd589f6c8a22e616e54d90bca13593bd1e1469b8f31266a08945025")
        let truth = try JSONDecoder().decode(SemanticNativeTruth.self, from: truthData)
        let queries = try JSONDecoder().decode([SemanticNativeQuery].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("query-token-golden.json")))
        #expect(truth.assets.count == 30 && queries.count == 50)
        let imageReferences = try Self.vectors(fixtures.appendingPathComponent("reference-images.f32"), count: 30)
        let queryReferences = try Self.vectors(fixtures.appendingPathComponent("reference-queries.f32"), count: 50)
        let installer = SemanticModelInstaller(directory: directory)
        let review = try await installer.inspect(source: package)
        let installed = try await installer.install(review)
        #expect(installed.installedBytes <= 1_073_741_824)
        let provider = SemanticLocalProviderFactory.makeProvider(installation: installed)
        #expect(await provider.availability() == .available)
        let lease = try await AIResourceBudget.shared.acquireLocalInference()
        let preparer = SemanticImagePreprocessor()
        var imageVectors: [[Float]] = []; var maximumImageDistance = 0.0; var maximumTextDistance = 0.0
        var hits = ["de": 0, "en": 0]
        do {
            for (index, asset) in truth.assets.enumerated() {
                let url = fixtures.appendingPathComponent(asset.path)
                #expect(SemanticInstallationIO.digest(try Data(contentsOf: url)) == asset.png_sha256)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let source = AIOriginalSourceFingerprint(fileURL: url,
                    modifiedAt: try #require(attributes[.modificationDate] as? Date),
                    fileSize: try #require(attributes[.size] as? NSNumber).int64Value)
                let input = try await preparer.prepare(source: source)
                let vector = try await provider.encodeImage(input)
                let distance = abs(1 - Self.dot(vector, imageReferences[index]))
                maximumImageDistance = max(maximumImageDistance, distance)
                #expect(distance <= 0.001, "Image \(index) differs from the frozen reference")
                imageVectors.append(vector)
            }
            for (index, query) in queries.enumerated() {
                let vector = try await provider.encodeText(query.text)
                let distance = abs(1 - Self.dot(vector, queryReferences[index]))
                maximumTextDistance = max(maximumTextDistance, distance)
                #expect(distance <= 0.001, "Text \(index) differs from the frozen reference")
                let ranked = imageVectors.enumerated().map { ($0.offset, Self.dot($0.element, vector)) }.sorted {
                    $0.1 == $1.1 ? truth.assets[$0.0].id < truth.assets[$1.0].id : $0.1 > $1.1
                }
                if let positive = truth.queries.first(where: { $0.id == query.id }) {
                    let top = Set(ranked.prefix(5).map { truth.assets[$0.0].id })
                    if !top.isDisjoint(with: positive.relevant_asset_ids) { hits[query.language, default: 0] += 1 }
                }
            }
            #expect(hits["de", default: 0] >= 16 && hits["en", default: 0] >= 16)
            #expect(abs(hits["de", default: 0] - hits["en", default: 0]) <= 2)
            print("Semantic production pair: 30 images/50 queries; maximum cosine distances \(maximumImageDistance)/\(maximumTextDistance); DE/EN hits \(hits["de", default: 0])/\(hits["en", default: 0]); installed \(installed.installedBytes) bytes")
        } catch {
            await provider.unload(); await AIResourceBudget.shared.release(lease)
            throw error
        }
        await provider.unload(); await AIResourceBudget.shared.release(lease)
    }

    private static func vectors(_ url: URL, count: Int) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        guard data.count == count * 768 * 4 else { throw SemanticEmbeddingError.invalidVector }
        let values = data.withUnsafeBytes { raw in
            (0..<(count * 768)).map { index in Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))) }
        }
        return (0..<count).map { Array(values[($0 * 768)..<(($0 + 1) * 768)]) }
    }
    private static func dot(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }
}
