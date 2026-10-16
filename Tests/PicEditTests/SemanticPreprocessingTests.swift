import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import PicEdit
import PicEditCore

private let semanticFixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Semantic")

private struct SemanticPreprocessingGolden: Decodable {
    struct Case: Decodable { let width: Int; let height: Int; let resized_rgb_sha256: String }
    let cases: [Case]
}

@Suite("Semantic original raster preparation")
struct SemanticPreprocessingTests {
    @Test func bilinearAndQuantizationMatchPinnedPillowFixtures() throws {
        let golden = try JSONDecoder().decode(SemanticPreprocessingGolden.self,
            from: Data(contentsOf: semanticFixtureDirectory.appendingPathComponent("preprocessing-golden.json")))
        for item in golden.cases {
            var rgb = [UInt8](); rgb.reserveCapacity(item.width * item.height * 3)
            for y in 0..<item.height { for x in 0..<item.width { for c in 0..<3 { rgb.append(UInt8((x * 17 + y * 29 + c * 61) % 256)) } } }
            let image = try #require(CGImage(width: item.width, height: item.height, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: item.width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: CGDataProvider(data: Data(rgb) as CFData)!, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
            let input = try SemanticImagePreprocessor.tensor(from: PreviewBitmap(image: image), sourceRevision: "test")
            #expect(input.values.count == 196_608)
            #expect(input.sourceRevision == "test")
            var actual = [UInt8](repeating: 0, count: 256 * 256 * 3)
            for pixel in 0..<(256 * 256) { for channel in 0..<3 {
                actual[pixel * 3 + channel] = UInt8(clamping: Int(((input.values[channel * 256 * 256 + pixel] + 1) * 127.5).rounded()))
            } }
            #expect(SemanticInstallationIO.digest(Data(actual)) == item.resized_rgb_sha256,
                    "Pillow bilinear mismatch at \(item.width)x\(item.height)")
            #expect(SemanticInstallationIO.validHash(input.rasterSHA256))
        }
    }

    @Test func transparencyUsesWhiteAndRasterIdentityIgnoresFileIdentity() throws {
        let data = Data([255, 0, 0, 0])
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bitmap = PreviewBitmap(image: image)
        let a = try SemanticImagePreprocessor.tensor(from: bitmap, sourceRevision: "source-a")
        let b = try SemanticImagePreprocessor.tensor(from: bitmap, sourceRevision: "source-b")
        #expect(a.values.allSatisfy { $0 == 1 })
        #expect(a.rasterSHA256 == b.rasterSHA256)
        #expect(a.sourceRevision != b.sourceRevision)
    }

    @Test func nativeSourceStampDetectsReplacementEvenWhenSizeAndMtimeStayEqual() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.bin")
        try Data([1, 2, 3, 4]).write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = try #require(attributes[.modificationDate] as? Date)
        let source = AIOriginalSourceFingerprint(fileURL: url, modifiedAt: date, fileSize: 4)
        let preparer = SemanticImagePreprocessor()
        let first = try await preparer.sourceStamp(source: source)
        try Data([4, 3, 2, 1]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let second = try await preparer.sourceStamp(source: source)
        #expect(first != second)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: url.path)
        await #expect(throws: SemanticEmbeddingError.staleSource) { try await preparer.sourceStamp(source: source) }
    }
}

private struct SemanticTokenGolden: Decodable { let text: String; let input_ids: [Int32] }

@Suite("Semantic offline tokenizer parity")
struct SemanticTokenizerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_RUN_SEMANTIC_TOKENIZER_TESTS"] == "1"))
    func officialConfigAPIHasAll58ExactFrozenTokens() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PICEDIT_SEMANTIC_TOKENIZER_DIR"])
        let tokenizer = try SemanticTokenizer(directory: URL(fileURLWithPath: path))
        var count = 0
        for name in ["token-golden.json", "query-token-golden.json"] {
            let rows = try JSONDecoder().decode([SemanticTokenGolden].self,
                from: Data(contentsOf: semanticFixtureDirectory.appendingPathComponent(name)))
            for row in rows { #expect(try tokenizer.tokens(for: row.text) == row.input_ids); count += 1 }
        }
        #expect(count == 58)
    }
}
