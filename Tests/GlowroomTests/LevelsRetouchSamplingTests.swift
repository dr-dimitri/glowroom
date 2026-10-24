import CoreGraphics
import CoreImage
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Retouch-aware bounded Levels sampling")
struct LevelsRetouchSamplingTests {
    @Test func untouchedWindowsAndDisabledRepairsKeepTheOriginalProbe() throws {
        let bitmap = try fixture()
        let session = EditRenderer.Session(lowPriority: true)
        let point = CGPoint(x: 0.2, y: 0.2)
        let original = try sample(bitmap, settings: .newEditingSettings, point: point, session: session)
        let farDab = try DevelopRetouchStroke(mode: .clone, source: .init(x: 0.2, y: 0.2),
            target: .init(x: 0.8, y: 0.8), radius: 0.1)
        let disabled = try patch(mask: mask { _, _ in 255 }, opacity: 0, replacement: replacement())
        let farMask = try patch(mask: mask { x, y in x > 40 && y > 40 ? 255 : 0 })
        var settings = EditSettings.newEditingSettings
        settings.developGeometry.retouchStrokes = [farDab, disabled, farMask]
        let actual = try sample(bitmap, settings: settings, point: point, session: session)
        #expect(actual == original)
    }

    @Test func replacementBoundsRestrictAnOtherwiseFullCanvasMask() throws {
        let bitmap = try fixture()
        let session = EditRenderer.Session(lowPriority: true)
        let point = CGPoint(x: 0.8, y: 0.5)
        var settings = EditSettings.newEditingSettings
        let frozen = try replacement(bounds: DevelopCropRect(x: 0, y: 0, width: 0.25, height: 1))
        settings.developGeometry.retouchStrokes = [try patch(mask: mask { _, _ in 255 }, replacement: frozen)]
        let actual = try sample(bitmap, settings: settings, point: point, session: session)
        let original = try sample(bitmap, settings: .newEditingSettings, point: point, session: session)
        #expect(actual == original)
    }

    @Test(arguments: [DevelopRetouchMode.clone, .heal])
    func cloneAndHealingCoverageAreRejectedWithoutInventingAnInverse(mode: DevelopRetouchMode) throws {
        let bitmap = try fixture()
        var settings = EditSettings.newEditingSettings
        settings.developGeometry.retouchStrokes = [try patch(mode: mode, mask: mask { _, _ in 255 })]
        #expect(throws: LevelsRetouchSamplingError.ambiguousRetouch) { try sample(bitmap, settings: settings) }
    }

    @Test func historicalDabsUseConservativeRadiusBounds() throws {
        let bitmap = try fixture()
        var settings = EditSettings.newEditingSettings
        settings.developGeometry.retouchStrokes = [try DevelopRetouchStroke(mode: .clone,
            source: .init(x: 0.1, y: 0.1), target: .init(x: 0.5, y: 0.5), radius: 0.2, feather: 0)]
        // The corner of the radius rectangle is deliberately conservative:
        // the old radial coverage formula is private to the renderer.
        #expect(throws: LevelsRetouchSamplingError.ambiguousRetouch) {
            try sample(bitmap, settings: settings, point: .init(x: 0.32, y: 0.32))
        }
    }

    @Test func fractionalCoveragePartialWindowsAndFractionalOpacityAreRejected() throws {
        let bitmap = try fixture()
        let frozen = try replacement()
        let cases = [
            try patch(mask: mask { _, _ in 128 }, replacement: frozen),
            try patch(mask: mask { x, _ in x < 32 ? 255 : 0 }, replacement: frozen),
            try patch(mask: mask { _, _ in 255 }, opacity: 0.5, replacement: frozen),
            try patch(mask: mask { _, _ in 255 }, replacement: replacement(
                bounds: DevelopCropRect(x: 0, y: 0, width: 0.5, height: 1)))
        ]
        for stroke in cases {
            var settings = EditSettings.newEditingSettings
            settings.developGeometry.retouchStrokes = [stroke]
            #expect(throws: LevelsRetouchSamplingError.ambiguousRetouch) { try sample(bitmap, settings: settings) }
        }
    }

    @Test func overlappingFrozenReplacementsAreAmbiguousEvenWhenBothAreOpaque() throws {
        let bitmap = try fixture()
        var settings = EditSettings.newEditingSettings
        settings.developGeometry.retouchStrokes = [
            try patch(mask: mask { _, _ in 255 }, replacement: replacement()),
            try patch(mask: mask { _, _ in 255 }, replacement: replacement())
        ]
        #expect(throws: LevelsRetouchSamplingError.ambiguousRetouch) { try sample(bitmap, settings: settings) }
    }

    @Test(arguments: [ToneProcessingVersion.legacyV1, .consistentV2], [0.25, 1.0])
    func oneOpaqueFrozenReplacementUsesTheRenderersOriginalAnalysisAndPreLevelsPipeline(version: ToneProcessingVersion, alpha: Double) throws {
        let bitmap = try fixture(alpha: alpha)
        let session = EditRenderer.Session(lowPriority: true)
        var settings = EditSettings.newEditingSettings
        settings.toneProcessingVersion = version
        settings.exposure = 0.4; settings.contrast = 12; settings.shadows = 8
        settings.naturalBalanceAmount = 65
        settings.developColor.temperature = 7_100
        settings.developColor.tint = -5
        settings.developGeometry.retouchStrokes = [try patch(mask: mask { _, _ in 255 }, replacement: replacement())]
        let actual = try sample(bitmap, settings: settings, session: session)
        // Full ordinary rendering independently prepares the replacement using
        // the original canvas's histogram. With the suffix neutral and complete
        // coverage, its output is exactly the replacement's pre-Levels input.
        let context = session.context(for: .consistentV2)
        let rendered = try EditRenderer.filterGraph(bitmap.image, settings: settings, context: context,
                                                   sourcePixelScale: bitmap.sourcePixelScale)
        let expected = try LevelsSampler.sample(graph: rendered, normalizedTopLeft: .init(x: 0.5, y: 0.5), context: context)
        expectClose(actual.sample, expected.sample)
        #expect(actual.proxyWidth == 64 && actual.proxyHeight == 64)
        #expect(actual.windowPixelCount == 25 && actual.visibleEquivalent == 25 * alpha)
        let untouched = try sample(bitmap, settings: .newEditingSettings)
        #expect(abs(actual.sample.red - untouched.sample.red) > 0.01)
    }

    private func sample(_ bitmap: PreviewBitmap, settings: EditSettings,
                        point: CGPoint = .init(x: 0.5, y: 0.5),
                        session: EditRenderer.Session = EditRenderer.Session(lowPriority: true)) throws -> LevelsSampleReport {
        try LevelsRetouchSampling.sample(bitmap: bitmap, settings: settings, normalizedTopLeft: point,
            session: session, context: session.context(for: .consistentV2))
    }

    private func mask(_ pixel: (Int, Int) -> UInt8) throws -> LocalMaskRaster {
        var bytes = Data()
        for y in 0..<64 { for x in 0..<64 { bytes.append(pixel(x, y)) } }
        return try LocalMaskRaster(width: 64, height: 64, bytes: bytes)
    }

    private func replacement(bounds: DevelopCropRect? = nil) throws -> DevelopRetouchReplacement {
        try DevelopRetouchReplacement(bounds: bounds ?? DevelopCropRect(x: 0, y: 0, width: 1, height: 1),
            width: 4, height: 4, rgba: Data(Array(repeating: [UInt8(210), 100, 45, 255], count: 16).flatMap { $0 }))
    }

    private func patch(mode: DevelopRetouchMode = .heal, mask: LocalMaskRaster,
                       opacity: Double = 1, replacement: DevelopRetouchReplacement? = nil) throws -> DevelopRetouchStroke {
        try DevelopRetouchStroke(mode: mode, source: .init(x: 0.2, y: 0.2), target: .init(x: 0.5, y: 0.5),
            radius: 0.2, feather: 0.5, opacity: opacity, mask: mask, replacement: replacement)
    }

    private func fixture(alpha: Double = 1) throws -> PreviewBitmap {
        var pixels = [Float]()
        for y in 0..<64 { for x in 0..<64 {
            pixels += [Float((0.04 + Double(x) * 0.002) * alpha),
                       Float((0.05 + Double(y) * 0.003) * alpha), Float(0.1 * alpha), Float(alpha)]
        } }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = try #require(CGImage(width: 64, height: 64, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: 64 * 16, space: space,
            bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        return PreviewBitmap(image: image)
    }

    private func expectClose(_ actual: LevelsPickerSample, _ expected: LevelsPickerSample,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.red - expected.red) < 0.000_02 && abs(actual.green - expected.green) < 0.000_02 &&
            abs(actual.blue - expected.blue) < 0.000_02, sourceLocation: sourceLocation)
    }
}
