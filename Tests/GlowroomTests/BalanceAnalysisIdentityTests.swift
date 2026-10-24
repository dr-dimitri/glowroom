import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Stable raster identity for balance analysis", .timeLimit(.minutes(1)))
struct BalanceAnalysisIdentityTests {
    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func equivalentFloatResizesReuseAnalysisAcrossNewImageInstances(kind: BalanceAnalysisCacheKind) throws {
        let source = try fixture()
        let first = try resize(source, width: 32, height: 8)
        let second = try resize(source, width: 32, height: 8)
        #expect(first.image !== second.image)
        #expect(SourceAnalysisIdentity(bitmap: first) == SourceAnalysisIdentity(bitmap: second))

        let cache = BalanceIdentityCacheProbe(kind: kind)
        #expect(try cache.analysis(first) == 1)
        #expect(try cache.analysis(second) == 1)
        for _ in 0..<4 {
            let recreated = try resize(source, width: 32, height: 8)
            #expect(recreated.image !== first.image)
            #expect(try cache.analysis(recreated) == 1)
        }
        #expect(cache.count == 1, "Deterministic resizes must not repeat scene analysis during slider changes")
    }

    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func stableEntriesRetainNeitherRasterNorTheIdentitySource(kind: BalanceAnalysisCacheKind) throws {
        let cache = BalanceIdentityCacheProbe(kind: kind)
        let token = UUID()
        var identity: SourceAnalysisIdentity?
        weak var released: CGImage?
        try autoreleasepool {
            let bitmap = try fixture(token: token)
            released = bitmap.image
            identity = SourceAnalysisIdentity(bitmap: bitmap)
            #expect(try cache.analysis(bitmap) == 1)
            #expect(released != nil)
        }
        #expect(released == nil, "Both the cached result and the value identity must release decoded pixels")

        let recreated = try fixture(token: token)
        #expect(SourceAnalysisIdentity(bitmap: recreated) == identity)
        #expect(try cache.analysis(recreated) == 1)
        #expect(cache.count == 1, "A completed stable entry remains reusable after its first image is released")
    }

    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func halfAndFloatResizesHaveIndependentAnalysis(kind: BalanceAnalysisCacheKind) throws {
        let source = try fixture()
        let half = try resize(source, width: 32, height: 8, version: .legacyV1)
        let sameHalf = try resize(source, width: 32, height: 8, version: .legacyV1)
        let precise = try resize(source, width: 32, height: 8)
        #expect(half.image.bitsPerComponent == 16)
        #expect(precise.image.bitsPerComponent == 32)
        #expect(SourceAnalysisIdentity(bitmap: half) == SourceAnalysisIdentity(bitmap: sameHalf))
        #expect(SourceAnalysisIdentity(bitmap: half) != SourceAnalysisIdentity(bitmap: precise))

        let cache = BalanceIdentityCacheProbe(kind: kind)
        #expect(try cache.analysis(half) == 1)
        #expect(try cache.analysis(sameHalf) == 1)
        #expect(try cache.analysis(precise) == 2)
        #expect(cache.count == 2)
    }

    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func dimensionsResizeChainAndFreshDecodeTokensInvalidateAnalysis(kind: BalanceAnalysisCacheKind) throws {
        let source = try fixture()
        let first = try resize(source, width: 37, height: 9)
        let direct = try resize(source, width: 19, height: 5)
        let twoStep = try resize(first, width: 19, height: 5)
        let newDecode = try fixture()
        let newProxy = try resize(newDecode, width: 37, height: 9)
        #expect(SourceAnalysisIdentity(bitmap: first) != SourceAnalysisIdentity(bitmap: direct))
        #expect(SourceAnalysisIdentity(bitmap: direct) != SourceAnalysisIdentity(bitmap: twoStep),
            "Different resampling graphs cannot assume equal pixels from equal output dimensions")
        #expect(SourceAnalysisIdentity(bitmap: first) != SourceAnalysisIdentity(bitmap: newProxy))

        let cache = BalanceIdentityCacheProbe(kind: kind)
        #expect(try cache.analysis(first) == 1)
        #expect(try cache.analysis(direct) == 2)
        #expect(try cache.analysis(twoStep) == 3)
        #expect(try cache.analysis(newProxy) == 4)
        #expect(try cache.analysis(first) == 1)
        #expect(cache.count == 4)
    }

    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func rasterMetadataIsPartOfTheIdentityEvenWhenTheTokenIsPreserved(kind: BalanceAnalysisCacheKind) throws {
        let source = try fixture()
        let precise = try resize(source, width: 32, height: 8)
        let half = try resize(source, width: 32, height: 8, version: .legacyV1)
        let smaller = try resize(source, width: 16, height: 4)
        let token = UUID()
        let rasters = [precise, half, smaller].map {
            PreviewBitmap(image: $0.image, sourceLongEdge: $0.sourceLongEdge,
                rangeProvenance: $0.rangeProvenance, rangeSourceIdentity: token)
        }
        #expect(Set(rasters.map { SourceAnalysisIdentity(bitmap: $0) }).count == 3)

        let cache = BalanceIdentityCacheProbe(kind: kind)
        for (index, raster) in rasters.enumerated() {
            #expect(try cache.analysis(raster) == Double(index + 1))
        }
        #expect(cache.count == 3)
    }

    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func mismatchedIdentityFallsBackWithoutPoisoningTheStableEntry(kind: BalanceAnalysisCacheKind) throws {
        let original = try fixture()
        let otherRaster = try fixture(width: 32, height: 8)
        let identity = SourceAnalysisIdentity(bitmap: original)
        let cache = BalanceIdentityCacheProbe(kind: kind)
        #expect(try cache.analysis(original) == 1)
        #expect(try cache.analysis(image: otherRaster.image, identity: identity) == 2)
        #expect(try cache.analysis(image: otherRaster.image, identity: identity) == 2,
            "An incompatible descriptor must use the existing verified object-identity fallback")
        #expect(try cache.analysis(original) == 1)
        #expect(cache.count == 2)
    }

    @Test(arguments: BalanceAnalysisCacheKind.allCases)
    func completedStableEntriesObeyTheLeastRecentlyUsedLimitAfterRasterRelease(kind: BalanceAnalysisCacheKind) throws {
        let cache = BalanceIdentityCacheProbe(kind: kind, maximumEntries: 2)
        let first = UUID(), second = UUID(), third = UUID()
        func request(_ token: UUID) throws -> Double {
            try autoreleasepool { try cache.analysis(fixture(token: token)) }
        }

        #expect(try request(first) == 1)
        #expect(try request(second) == 2)
        #expect(try request(first) == 1)
        #expect(cache.count == 2)
        #expect(try request(third) == 3)
        #expect(try request(first) == 1)
        #expect(cache.count == 3)
        #expect(try request(second) == 4, "The older stable result must be evicted even though its image is already gone")
        #expect(cache.count == 4)
    }

    private func resize(_ bitmap: PreviewBitmap, width: Int, height: Int,
                        version: ToneProcessingVersion = .consistentV2) throws -> PreviewBitmap {
        try EditRenderer.resized(bitmap, width: width, height: height, priority: .selected,
                                 toneProcessingVersion: version)
    }

    private func fixture(width: Int = 64, height: Int = 16, token: UUID = UUID()) throws -> PreviewBitmap {
        var pixels = [Float]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fineValue = Float(0.180_001 + Double(x + y) * 0.000_001)
                let edge: Float = (x * 13 + y * 7) % 11 < 5 ? 0.05 : 0.8
                pixels += [fineValue, edge, fineValue + 0.000_003, 1]
            }
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: space,
            bitmapInfo: [.floatComponents, .byteOrder32Little,
                         CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image, rangeProvenance: .extended(nominalSDRWhite: 1), rangeSourceIdentity: token)
    }
}

enum BalanceAnalysisCacheKind: String, CaseIterable, Sendable {
    case autoTone, naturalBalance
}

/// Deterministic injected results expose cache hits without running histogram
/// analysis or Vision; actual resizing still follows the production Float path.
private final class BalanceIdentityCacheProbe {
    private let counter = BalanceIdentityCounter()
    private let request: (CGImage, SourceAnalysisIdentity?) throws -> Double

    init(kind: BalanceAnalysisCacheKind, maximumEntries: Int = 8) {
        let counter = counter
        switch kind {
        case .autoTone:
            let cache = AutoToneAnalysisCache(maximumEntries: maximumEntries, analyze: { _ in
                AutoToneAnalysis(offsets: Array(repeating: Double(counter.next()), count: 7))
            })
            request = { try cache.analysis(for: $0, identity: $1).offsets[0] }
        case .naturalBalance:
            let cache = NaturalBalanceAnalysisCache(maximumEntries: maximumEntries, analyze: { _ in
                NaturalBalanceAnalysis(offsets: Array(repeating: Double(counter.next()), count: 7),
                    colorBoost: 0, faceCount: 0)
            })
            request = { try cache.analysis(for: $0, identity: $1).offsets[0] }
        }
    }

    var count: Int { counter.count }

    func analysis(_ bitmap: PreviewBitmap) throws -> Double {
        try request(bitmap.image, SourceAnalysisIdentity(bitmap: bitmap))
    }

    func analysis(image: CGImage, identity: SourceAnalysisIdentity?) throws -> Double {
        try request(image, identity)
    }
}

private final class BalanceIdentityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func next() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}
