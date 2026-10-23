import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Version two Float analysis")
struct FloatAnalysisTests {
    @Test func readbackPreservesDifferencesBelowOneEightBitStep() throws {
        let bitmap = try fixture(width: 2) { x in
            let value = SignedSRGB.decode(x == 0 ? 0.5 : 0.500_8)
            return (value, value, value, 1)
        }
        let context = EditRenderer.Session(lowPriority: true).context(for: .consistentV2)
        let raster = try FloatAnalysis.raster(CIImage(cgImage: bitmap.image), context: context,
                                              colorSpace: FloatAnalysis.workingSpace)
        let first = SignedSRGB.encode(Double(raster.pixels[0]))
        let second = SignedSRGB.encode(Double(raster.pixels[4]))
        #expect(abs(first - 0.5) < 0.000_01)
        #expect(abs(second - 0.500_8) < 0.000_01)
        #expect(second - first > 0.000_7)
        #expect(second - first < 1.0 / 255)
    }

    @Test func alphaWeightingAndTransparentPixelsDoNotAlterPercentiles() throws {
        let bitmap = try fixture(width: 3) { x in
            switch x {
            case 0: (0.18, 0.18, 0.18, 1)
            case 1: (0.18, 0.18, 0.18, 0.25)
            default: (100, 100, 100, 0)
            }
        }
        let domain = try #require(FloatAnalysisDomain(bitmap: bitmap, version: .consistentV2))
        let session = EditRenderer.Session(lowPriority: true)
        let histogram = try FloatAnalysis.histogram(CIImage(cgImage: bitmap.image), context: session.context(for: .consistentV2),
            targetSpace: try #require(FloatAnalysis.extendedTargetSpace(bitmap.image.colorSpace!)), domain: domain)
        #expect(abs(histogram.total - 1.25) < 0.000_01)
        #expect(abs(histogram.percentile(0.5) - SignedSRGB.encode(0.18)) < 1.0 / 4_095)
        #expect(histogram.aboveSDRWhite == 0 && histogram.belowSDRBlack == 0)
    }

    @Test func sourceMaximumDoesNotLoseASmallHDRHighlightDuringDownsampling() throws {
        let bitmap = try fixture(width: 1_024) { x in
            let value = x == 1 ? 2.0 : 0.18
            return (value, value, value, 1)
        }
        let session = EditRenderer.Session(lowPriority: true)
        let maximum = try FloatAnalysis.maximumSourceLuminance(bitmap, context: session.context(for: .consistentV2))
        #expect(abs(maximum - 2) < 0.000_1)
    }

    @Test func anSDRP3ColorOutsideTheSRGBCubeIsMeasuredInItsOwnGamut() async throws {
        let bitmap = try fixture(width: 16, space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                 range: .sdrDecoded) { _ in (1, 0, 0, 1) }
        let session = EditRenderer.Session(lowPriority: true)
        let context = session.context(for: .consistentV2)
        let domain = try #require(FloatAnalysisDomain(bitmap: bitmap, version: .consistentV2))
        let linear = try FloatAnalysis.raster(CIImage(cgImage: bitmap.image), context: context,
                                             colorSpace: FloatAnalysis.workingSpace)
        #expect(linear.pixels[0] > 1)
        #expect(linear.pixels[1] < 0)
        let maximum = try FloatAnalysis.maximumSourceLuminance(bitmap, context: context)
        #expect(maximum < 1)
        let histogram = try FloatAnalysis.histogram(CIImage(cgImage: bitmap.image), context: context,
            targetSpace: try #require(FloatAnalysis.extendedTargetSpace(bitmap.image.colorSpace!)), domain: domain)
        #expect(histogram.lowerGamutExcursion == 0 && histogram.upperGamutExcursion == 0)
        #expect(histogram.aboveSDRWhite == 0)
        let result = try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: bitmap,
            settings: .init(toneProcessingVersion: .consistentV2))
        #expect(result == .noProposal(.insufficientRange))
    }

    @Test func trueHDRAndUnprovenRangeProduceExplicitlyDifferentNoProposalResults() async throws {
        let hdr = try fixture(width: 16) { _ in (2, 2, 2, 1) }
        let unknown = PreviewBitmap(image: hdr.image, rangeProvenance: .unknown)
        let estimator = AutomaticToneEstimator()
        let settings = EditSettings(exposure: -2, toneProcessingVersion: .consistentV2)
        #expect(try await estimator.estimate(for: .exposure, bitmap: hdr, settings: settings) == .noProposal(.hdrSource))
        #expect(try await estimator.estimate(for: .exposure, bitmap: unknown, settings: settings) == .noProposal(.unknownSourceRange))
        let sdr = try fixture(width: 16, range: .sdrDecoded) { _ in (0.18, 0.18, 0.18, 1) }
        var activeHDR = settings; activeHDR.developColor.hdrEnabled = true
        #expect(try await estimator.estimate(for: .exposure, bitmap: sdr, settings: activeHDR) == .noProposal(.hdrOutput))
    }

    @Test func nominalWhiteProvenanceIsPartOfTheHDRDecision() async throws {
        let normalized = try fixture(width: 64, range: .extended(nominalSDRWhite: 2)) { x in
            let value = Double(x) / 63 * 1.8
            return (value, value, value, 1)
        }
        let session = EditRenderer.Session(lowPriority: true)
        let maximum = try FloatAnalysis.maximumSourceLuminance(normalized, context: session.context(for: .consistentV2))
        let domain = try #require(FloatAnalysisDomain(bitmap: normalized, version: .consistentV2))
        #expect(maximum / domain.nominalSDRWhite < 1)
        let result = try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: normalized,
            settings: .init(toneProcessingVersion: .consistentV2))
        #expect(result != .noProposal(.hdrSource))
    }

    @Test func v2UsesAbsoluteCandidatesAndRetainsOtherGlobalExposure() async throws {
        let bitmap = try fixture(width: 256, range: .sdrDecoded) { x in
            let value = SignedSRGB.decode(0.05 + 0.45 * Double(x) / 255)
            return (value, value, value, 1)
        }
        let estimator = AutomaticToneEstimator()
        let dark = EditSettings(exposure: -5, toneProcessingVersion: .consistentV2)
        let bright = EditSettings(exposure: 5, toneProcessingVersion: .consistentV2)
        let first = try await estimator.estimate(for: .exposure, bitmap: bitmap, settings: dark)
        let second = try await estimator.estimate(for: .exposure, bitmap: bitmap, settings: bright)
        #expect(first == second)
        guard case .value(let value) = first else { Issue.record("A dark Float ramp must admit an exposure proposal"); return }
        #expect(value > 0 && value <= 5)
        #expect(abs(value / AutomaticToneControl.exposure.step - (value / AutomaticToneControl.exposure.step).rounded()) < 0.000_001)
        var accepted = dark; accepted.exposure = value
        #expect(try await estimator.estimate(for: .exposure, bitmap: bitmap, settings: accepted) == first)
        let shadows = try await estimator.estimate(for: .shadows, bitmap: bitmap,
            settings: .init(toneProcessingVersion: .consistentV2))
        let exposedShadows = try await estimator.estimate(for: .shadows, bitmap: bitmap,
            settings: .init(exposure: 2, toneProcessingVersion: .consistentV2))
        #expect(shadows != exposedShadows)
        #expect(exposedShadows == .value(0))
    }

    @Test func canceledV2AnalysisStopsBeforeReadback() async throws {
        let bitmap = try fixture(width: 16) { _ in (0.18, 0.18, 0.18, 1) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: bitmap,
                settings: .init(toneProcessingVersion: .consistentV2))
        }
        do { _ = try await task.value; Issue.record("Canceled Float analysis unexpectedly succeeded") }
        catch is CancellationError { }
    }

    @Test func artifactAnalysisIsAdmittedBeforeItAllocatesFloatBuffers() async throws {
        let bitmap = try fixture(width: 16) { _ in (0.18, 0.18, 0.18, 1) }
        let owner = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_024))
        let owned = PreviewBitmap(image: bitmap.image, resourceOwner: owner,
                                  rangeProvenance: bitmap.rangeProvenance)
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: owned,
                settings: .init(toneProcessingVersion: .consistentV2))
        }
        let state = await owner.state()
        #expect(state.chargedBytes == 0 && state.runningCodecs == 0 && state.pendingCodecs == 0)
    }

    @Test func aLargeLegacyArtifactPlansOnlyItsSmallCandidateGraph() throws {
        let width = 4_096, height = 2_731
        let sourceBytes = Int64(width * height * 4)
        let legacy = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: sourceBytes,
            width: width, height: height, version: .legacyV1, ownsSource: true)
        let precise = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: sourceBytes,
            width: width, height: height, version: .consistentV2, ownsSource: true)
        let budget: Int64 = 512 * 1_024 * 1_024
        // Real artifact decoding can retain two native source allocations. Both
        // stay charged while V1 imports/resizes and searches its small proxy.
        #expect(legacy + 2 * sourceBytes < budget)
        #expect(precise + 2 * sourceBytes > budget)
        let unowned = try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: sourceBytes,
            width: width, height: height, version: .legacyV1, ownsSource: false)
        #expect(unowned == legacy + sourceBytes)
        #expect(throws: ArtifactResourceError.capacityExceeded) {
            try AutomaticToneEstimator.estimatedAdditionalBytes(sourceBytes: .max,
                width: width, height: height, version: .legacyV1, ownsSource: true)
        }
    }

    @Test func aSmallLegacyArtifactDoesNotReserveTheV2FloatAnalysisBudget() async throws {
        let bitmap = try fixture(width: 16, range: .sdrDecoded) { _ in (0.18, 0.18, 0.18, 1) }
        let owner = ArtifactResourceOwner(limits: try .init(maximumBytes: 64 * 1_024))
        let owned = PreviewBitmap(image: bitmap.image, resourceOwner: owner,
                                  rangeProvenance: bitmap.rangeProvenance)
        let legacy = try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: owned, settings: .neutral)
        #expect(legacy == .value(0))
        try await waitForTestState("legacy analysis admission released", state: { await owner.state() }) {
            $0.chargedBytes == 0 && $0.runningCodecs == 0
        }
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: owned,
                settings: .init(toneProcessingVersion: .consistentV2))
        }
    }

    @Test func cancelingQueuedArtifactAnalysisDoesNotReleaseAnotherNativeLease() async throws {
        let bitmap = try fixture(width: 16) { _ in (0.18, 0.18, 0.18, 1) }
        let owner = ArtifactResourceOwner(limits: try .init(maximumBytes: 8 * 1_024 * 1_024))
        let blocker = try await owner.acquire(kind: .codec, bytes: 0)
        let owned = PreviewBitmap(image: bitmap.image, resourceOwner: owner,
                                  rangeProvenance: bitmap.rangeProvenance)
        let task = Task {
            try await AutomaticToneEstimator().estimate(for: .exposure, bitmap: owned,
                settings: .init(toneProcessingVersion: .consistentV2))
        }
        defer { task.cancel(); withExtendedLifetime(blocker) {} }
        try await waitForTestState("queued Float analysis", state: { await owner.state() }, until: { $0.pendingCodecs == 1 })
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled queued analysis unexpectedly succeeded") }
        catch is CancellationError { }
        let state = await owner.state()
        #expect(state.pendingCodecs == 0 && state.runningCodecs == 1 && state.chargedBytes == 0)
    }

    private func fixture(width: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                         range: PreviewRangeProvenance = .extended(nominalSDRWhite: 1),
                         pixel: (Int) -> (Double, Double, Double, Double)) throws -> PreviewBitmap {
        var pixels = [Float]()
        for x in 0..<width {
            let (red, green, blue, alpha) = pixel(x)
            pixels += [Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha)]
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: width, height: 1, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 4 * MemoryLayout<Float>.stride, space: space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image, rangeProvenance: range)
    }
}
