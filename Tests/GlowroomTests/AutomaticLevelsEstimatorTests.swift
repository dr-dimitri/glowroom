import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Native conservative automatic Levels")
struct AutomaticLevelsEstimatorTests {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    @Test(arguments: ToneProcessingVersion.allCases)
    func aPartialGrayRampIsSpreadMonotonicallyWithoutUpgradingItsToneVersion(version: ToneProcessingVersion) throws {
        let bitmap = try ramp()
        let session = EditRenderer.Session(lowPriority: true)
        var cache = AutomaticLevelsEstimator.Cache()
        let settings = EditSettings(toneProcessingVersion: version)
        let analysis = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        guard case .value(let levels) = analysis.estimate else {
            Issue.record("A broad, centered partial gray ramp needs a safe proposal: \(analysis.estimate)"); return
        }
        try levels.validate()
        #expect(levels.master.inputBlack > 0 && levels.master.inputWhite < 1)
        #expect(levels.master.gamma == 1 && levels.master.outputBlack == 0 && levels.master.outputWhite == 1)
        #expect(!levels.master.clampInput && !levels.master.clampOutput)
        #expect(levels.red == .neutral && levels.green == .neutral && levels.blue == .neutral)
        #expect(levels.transferFunction == settings.levels.transferFunction && levels.version == settings.levels.version)
        #expect(analysis.diagnostics.domain?.toneProcessingVersion == version)
        #expect(analysis.diagnostics.inputWidth == bitmap.image.width && analysis.diagnostics.inputHeight == bitmap.image.height)
        #expect(analysis.diagnostics.acceptedStrength != nil)
        let accepted = try #require(analysis.diagnostics.attempts.last)
        #expect(accepted.candidate.levels == levels && accepted.gateFailures.isEmpty)
        #expect(try #require(accepted.clipping).isWithinBudget)
        var proposed = settings; proposed.levels = levels
        let graph = try EditRenderer.globalGraph(bitmap, settings: proposed, session: session)
        let pixels = try FloatAnalysis.raster(graph, context: session.context(for: .consistentV2), colorSpace: Self.linear)
        for column in 1..<pixels.width {
            #expect(pixels.pixels[column * 4] >= pixels.pixels[(column - 1) * 4] - 0.000_001)
        }
        #expect(settings.toneProcessingVersion == version)
    }

    @Test(arguments: ToneProcessingVersion.allCases)
    func oldLevelsLocalMasksAndGeometryCannotBiasTheEstimateOrItsWarmCache(version: ToneProcessingVersion) throws {
        let bitmap = try ramp()
        let session = EditRenderer.Session(lowPriority: true)
        var cache = AutomaticLevelsEstimator.Cache()
        var settings = EditSettings(exposure: 0.1, contrast: 5, toneProcessingVersion: version)
        let first = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        guard case .value(let expected) = first.estimate else { Issue.record("Centered ramp must have a proposal"); return }
        settings.levels = .init(master: .init(inputBlack: 0.1, inputWhite: 0.9, gamma: 2, clampOutput: true),
            red: .init(gamma: 0.7), green: .init(outputBlack: 0.2, outputWhite: 0.8), blue: .init(gamma: 1.7))
        settings.developGeometry = .init(quarterTurns: 1, straightenAngle: 20, flipHorizontal: true)
        settings.localAdjustments = [try .init(name: "Excluded local exposure", mask: .init(shape: .radial(
            center: .init(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.4, rotation: 0)), settings: .init(exposure: 2))]
        let changed = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        #expect(changed.estimate == .value(expected))
        settings.levels = expected
        let repeated = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        #expect(repeated.estimate == .value(expected))
        #expect(cache.state().sourceMeasurements == 1 && cache.state().histogramMeasurements == 1)
        #expect(cache.state().baselineMeasurements == 1)
        #expect(cache.state().histogramHits == 2 && cache.state().baselineHits == 2)
    }

    @Test(arguments: [AutomaticLevelsFixtureKind.flat, .nearlyFlatNoise, .transparent, .lowKey, .highKey])
    func unsuitableAndDeliberatelyKeyedImagesKeepTheirExistingLevels(kind: AutomaticLevelsFixtureKind) throws {
        let bitmap = try fixture { x, y in
            let encoded: Double = switch kind {
            case .flat, .transparent: 0.5
            case .nearlyFlatNoise: 0.5 + Double((x * 17 + y * 7) % 11 - 5) * 0.001
            case .lowKey: 0.04 + 0.24 * Double(x) / 255
            case .highKey: 0.72 + 0.24 * Double(x) / 255
            }
            let value = SignedSRGB.decode(encoded)
            return (value, value, value, kind == .transparent ? 0 : 1)
        }
        var cache = AutomaticLevelsEstimator.Cache()
        let initial = EditSettings(levels: .init(master: .init(gamma: 2)), toneProcessingVersion: .consistentV2)
        let frozen = initial
        let result = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: initial,
            session: .init(lowPriority: true), cache: &cache)
        let expected: AutomaticLevelsNoProposalReason = switch kind {
        case .flat, .nearlyFlatNoise: .insufficientRange
        case .transparent: .insufficientSamples
        case .lowKey: .lowKey
        case .highKey: .highKey
        }
        #expect(result.estimate == .noProposal(expected))
        #expect(initial == frozen && result.diagnostics.attempts.isEmpty)
    }

    @Test func sourceProofUsesTheLargerDecodedBasisAndCannotMissAnIsolatedHDRHighlight() throws {
        let source = try fixture(width: 512, height: 512) { x, y in
            if x == 1 && y == 1 { return (4, 4, 4, 1) }
            let value = SignedSRGB.decode(0.2 + 0.6 * Double(x) / 511)
            return (value, value, value, 1)
        }
        let input = try EditRenderer.resized(source, width: 128, height: 128, priority: .selected,
                                             toneProcessingVersion: .consistentV2)
        let session = EditRenderer.Session(lowPriority: true)
        #expect(try FloatAnalysis.maximumSourceLuminance(input, context: session.context(for: .consistentV2)) < 1)
        var cache = AutomaticLevelsEstimator.Cache()
        let result = try AutomaticLevelsEstimator.analyze(bitmap: input, sourceBitmap: source,
            settings: .newEditingSettings, session: session, cache: &cache)
        #expect(result.estimate == .noProposal(.hdrSource))
        #expect(result.diagnostics.sourceProof.sourceIdentity == source.rangeSourceIdentity)
        #expect(result.diagnostics.sourceProof.width == 512 && result.diagnostics.sourceProof.height == 512)
        #expect(result.diagnostics.sourceProof.maximumLuminance == 4)
        #expect(result.diagnostics.inputWidth == 128 && result.diagnostics.inputHeight == 128)
        #expect(result.diagnostics.attempts.isEmpty)
    }

    @Test func missingRangeAndHDRModeReturnExplicitNoProposalWithoutEstimatingEndpoints() throws {
        let bitmap = try ramp()
        var cache = AutomaticLevelsEstimator.Cache()
        let session = EditRenderer.Session(lowPriority: true)
        let unknown = PreviewBitmap(image: bitmap.image, rangeProvenance: .unknown)
        #expect(try AutomaticLevelsEstimator.analyze(bitmap: unknown, settings: .newEditingSettings,
            session: session, cache: &cache).estimate == .noProposal(.unknownSourceRange))
        let hdr = EditSettings(developColor: .init(hdrEnabled: true), toneProcessingVersion: .consistentV2)
        #expect(try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: hdr,
            session: session, cache: &cache).estimate == .noProposal(.hdrOutput))
        #expect(cache.state().sourceMeasurements == 0)
    }

    @Test(arguments: ["texture", "clarity", "sharpening"])
    func frozenLegacyOutputLimitsAreDeclinedWithoutUpgradingOrBlamingTheP3Profile(control: String) throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let bitmap = try fixture(space: p3) { x, _ in
            let value = 0.2 + 0.6 * Double(x) / 255
            return (value, value, value, 1)
        }
        var settings = EditSettings(toneProcessingVersion: .legacyV1)
        switch control {
        case "texture": settings.texture = 20
        case "clarity": settings.clarity = 20
        default: settings.sharpeningAmount = 80
        }
        var cache = AutomaticLevelsEstimator.Cache()
        let result = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings,
            session: .init(lowPriority: true), cache: &cache)
        #expect(result.estimate == .noProposal(.legacyOutputLimits))
        #expect(result.diagnostics.attempts.isEmpty && cache.state().sourceMeasurements == 0)
        #expect(settings.toneProcessingVersion == .legacyV1)
    }

    @Test func v2PresenceAndSharpeningRemainActiveWhileEveryAttemptUsesThePairedOutputBudget() throws {
        let bitmap = try ramp()
        let settings = EditSettings(texture: 20, clarity: 15, sharpeningAmount: 50,
            sharpeningRadius: 1, sharpeningMasking: 30, toneProcessingVersion: .consistentV2)
        var cache = AutomaticLevelsEstimator.Cache()
        let result = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings,
            session: .init(lowPriority: true), cache: &cache)
        guard case .value = result.estimate else { Issue.record("A smooth centered V2 ramp with a mild suffix must remain eligible"); return }
        let attempts = result.diagnostics.attempts
        #expect(!attempts.isEmpty)
        #expect(attempts.map { $0.candidate.strength } == Array(AutomaticLevelsPolicy.strengths.prefix(attempts.count)))
        #expect(try #require(attempts.last?.clipping).isWithinBudget)
        #expect(result.diagnostics.domain?.toneProcessingVersion == .consistentV2)
    }

    @Test(arguments: ["sRGB", "displayP3"])
    func clippingIsMeasuredInTheActualDestinationProfileWithAlpha(profile: String) throws {
        let space = try #require(CGColorSpace(name: profile == "sRGB" ? CGColorSpace.sRGB : CGColorSpace.displayP3))
        let bitmap = try fixture(space: space) { x, _ in
            let value = 0.2 + 0.6 * Double(x) / 255
            return (value, value, value, 0.5)
        }
        let session = EditRenderer.Session(lowPriority: true)
        var cache = AutomaticLevelsEstimator.Cache()
        let result = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: .newEditingSettings,
            session: session, cache: &cache)
        #expect(result.diagnostics.domain?.targetProfile == space.name as String?)
        #expect(result.diagnostics.sourceProof.maximumLuminance.map { $0 < 1 } == true)
        #expect(result.diagnostics.visibleEquivalent == 256 * 16 * 0.5)
        guard case .value = result.estimate else { Issue.record("SDR \(profile) gray ramp must be eligible"); return }
        #expect(try #require(result.diagnostics.attempts.last?.clipping).isWithinBudget)
    }

    @Test func negativeExtendedSRGBP3CoordinatesAreNotAnHDRClassification() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let bitmap = try fixture(space: p3) { x, _ in
            if x == 255 { return (0, 1, 0, 1) }
            let value = 0.2 + 0.6 * Double(x) / 254
            return (value, value, value, 1)
        }
        let session = EditRenderer.Session(lowPriority: true)
        let pixels = try FloatAnalysis.raster(CIImage(cgImage: bitmap.image),
            context: session.context(for: .consistentV2), colorSpace: Self.linear)
        #expect(pixels.pixels[255 * 4] < 0 && pixels.pixels[255 * 4 + 1] > 1)
        var cache = AutomaticLevelsEstimator.Cache()
        let result = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: .newEditingSettings,
            session: session, cache: &cache)
        #expect(result.estimate != .noProposal(.hdrSource))
        #expect(result.estimate != .noProposal(.unsupportedDomain))
        #expect(result.diagnostics.domain?.targetProfile == CGColorSpace.displayP3 as String)
        #expect(result.diagnostics.sourceProof.maximumLuminance.map { $0 <= 1.000_01 } == true)
    }

    @Test(arguments: [8, 16])
    func trueGraySourcesUseTheDevelopedSRGBDestination(bits: Int) throws {
        let source = try gray(bits: bits)
        let target = try EditRenderer.developedOutputColorSpace(for: source.image)
        #expect(target.name == CGColorSpace.sRGB)
        var cache = AutomaticLevelsEstimator.Cache()
        let result = try AutomaticLevelsEstimator.analyze(bitmap: source, settings: .newEditingSettings,
            session: .init(lowPriority: true), cache: &cache)
        #expect(result.diagnostics.domain?.targetProfile == CGColorSpace.sRGB as String)
        guard case .value = result.estimate else { Issue.record("Known-range gray \(bits)-bit ramp must be supported"); return }
        #expect(try #require(result.diagnostics.attempts.last?.clipping).isWithinBudget)
    }

    @Test func cancellationStopsBeforeAnyNativeSourceProofOrCachePublication() async throws {
        let bitmap = try ramp()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            var cache = AutomaticLevelsEstimator.Cache()
            return try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: .newEditingSettings,
                session: .init(lowPriority: true), cache: &cache)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cacheSeparatesUpstreamSuffixSourceScaleAndFreshSourceIdentity() throws {
        let bitmap = try ramp()
        let session = EditRenderer.Session(lowPriority: true)
        var cache = AutomaticLevelsEstimator.Cache()
        var settings = EditSettings.newEditingSettings
        _ = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        settings.texture = 20
        _ = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        #expect(cache.state().histogramMeasurements == 1 && cache.state().baselineMeasurements == 2)
        settings.exposure = 0.1
        _ = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: settings, session: session, cache: &cache)
        #expect(cache.state().histogramMeasurements == 2 && cache.state().baselineMeasurements == 3)
        let scaled = PreviewBitmap(image: bitmap.image, sourceLongEdge: 2_560,
            rangeProvenance: bitmap.rangeProvenance, rangeSourceIdentity: bitmap.rangeSourceIdentity)
        _ = try AutomaticLevelsEstimator.analyze(bitmap: scaled, sourceBitmap: bitmap, settings: settings, session: session, cache: &cache)
        #expect(cache.state().sourceMeasurements == 1 && cache.state().histogramMeasurements == 3)
        let fresh = PreviewBitmap(image: bitmap.image, rangeProvenance: bitmap.rangeProvenance)
        _ = try AutomaticLevelsEstimator.analyze(bitmap: fresh, settings: settings, session: session, cache: &cache)
        #expect(cache.state().sourceMeasurements == 2 && cache.state().histogramMeasurements == 4)
        #expect(cache.state().entries == 1)
        #expect(cache.state().rasterBytes <= AutomaticLevelsEstimator.maximumCachedRasterBytes)
        #expect(cache.state().histogramBytes == AutomaticLevelsPolicy.maximumHistogramBytes)
    }

    @Test func normalCacheRetainsNeitherDecodedPixelsNorTheirProvider() throws {
        var cache = AutomaticLevelsEstimator.Cache()
        weak var image: CGImage?
        try autoreleasepool {
            let bitmap = try ramp(); image = bitmap.image
            _ = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: .newEditingSettings,
                session: .init(lowPriority: true), cache: &cache)
        }
        #expect(image == nil)
        #expect(cache.state().entries == 1 && cache.state().rasterBytes > 0)
    }

    @Test func artifactInputsClearAndDisableEveryPersistentHistogramAndRaster() async throws {
        let bitmap = try ramp()
        var cache = AutomaticLevelsEstimator.Cache()
        let session = EditRenderer.Session(lowPriority: true)
        _ = try AutomaticLevelsEstimator.analyze(bitmap: bitmap, settings: .newEditingSettings, session: session, cache: &cache)
        #expect(cache.state().entries == 1)
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 8 * 1_024 * 1_024))
        let phase = try await resources.acquire(kind: .codec, bytes: 4 * 1_024 * 1_024, priority: .interactive, retaining: [])
        let artifact = PreviewBitmap(image: bitmap.image, resourceOwner: resources,
            rangeProvenance: bitmap.rangeProvenance, rangeSourceIdentity: bitmap.rangeSourceIdentity)
        _ = try AutomaticLevelsEstimator.analyze(bitmap: artifact, settings: .newEditingSettings, session: session, cache: &cache)
        #expect(cache.state().entries == 0 && cache.state().histogramBytes == 0 && cache.state().rasterBytes == 0)
        let before = cache.state().sourceMeasurements
        _ = try AutomaticLevelsEstimator.analyze(bitmap: artifact, settings: .newEditingSettings, session: session, cache: &cache)
        #expect(cache.state().sourceMeasurements == before + 1)
        withExtendedLifetime(phase) {}
    }

    private func ramp() throws -> PreviewBitmap {
        try fixture { x, _ in
            let value = SignedSRGB.decode(0.2 + 0.6 * Double(x) / 255)
            return (value, value, value, 1)
        }
    }

    private func fixture(width: Int = 256, height: Int = 16, space: CGColorSpace = AutomaticLevelsEstimatorTests.linear,
                         pixel: (Int, Int) -> (Double, Double, Double, Double)) throws -> PreviewBitmap {
        var pixels: [Float] = []
        for row in 0..<height { for column in 0..<width {
            let (r, g, b, a) = pixel(column, row)
            pixels += [Float(r * a), Float(g * a), Float(b * a), Float(a)]
        } }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: true, intent: .relativeColorimetric))
        return PreviewBitmap(image: image)
    }

    private func gray(bits: Int) throws -> PreviewBitmap {
        var bytes = Data()
        if bits == 8 {
            for _ in 0..<16 { for x in 0..<256 { bytes.append(UInt8((0.2 + 0.6 * Double(x) / 255) * 255)) } }
        } else {
            var pixels: [UInt16] = []
            for _ in 0..<16 { for x in 0..<256 { pixels.append(UInt16((0.2 + 0.6 * Double(x) / 255) * 65_535)) } }
            bytes = pixels.withUnsafeBytes { Data($0) }
        }
        let image = try #require(CGImage(width: 256, height: 16, bitsPerComponent: bits, bitsPerPixel: bits,
            bytesPerRow: 256 * bits / 8, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: bits == 16 ? [.byteOrder16Little] : [], provider: CGDataProvider(data: bytes as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image, rangeProvenance: .sdrDecoded)
    }
}

enum AutomaticLevelsFixtureKind: Sendable { case flat, nearlyFlatNoise, transparent, lowKey, highKey }
