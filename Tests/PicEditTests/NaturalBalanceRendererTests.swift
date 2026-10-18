import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Natural image balance", .serialized)
struct NaturalBalanceRendererTests {
    @Test func disabledBalancePreservesPixelsAndExistingEdits() throws {
        let source = try fixture { x, _ in (UInt8(x), UInt8(x / 2), UInt8(255 - x), 255) }
        var off = EditSettings.neutral
        off.naturalBalanceColorAmount = 100
        #expect(try EditRenderer.render(source, settings: off).image === source.image)
        var legacy = EditSettings.neutral
        legacy.autoToneAmount = 65
        legacy.exposure = 0.3
        legacy.vibrance = 12
        off = legacy
        off.naturalBalanceColorAmount = 0
        #expect(try pixels(EditRenderer.render(source, settings: legacy).image) == pixels(EditRenderer.render(source, settings: off).image))
    }

    @Test func blackWhiteAndFlatGrayDoNotAcquireInventedDetail() throws {
        for value: UInt8 in [0, 2, 64, 128, 250, 255] {
            let source = try fixture(width: 32) { _, _ in (value, value, value, 255) }
            let result = try pixels(render(source).image)
            for index in stride(from: 0, to: result.count, by: 4) {
                #expect((0..<3).allSatisfy { abs(Int(result[index + $0]) - Int(value)) <= 1 })
            }
        }
    }

    @Test func dynamicRangeOpensShadowsAndRestrainsHighlights() throws {
        let levels: [UInt8] = [0, 8, 24, 45, 75, 110, 145, 185, 218, 240, 250, 255]
        let source = try fixture(width: levels.count) { x, _ in (levels[x], levels[x], levels[x], 255) }
        let output = try pixels(render(source, color: 0).image)
        #expect(output[2 * 4] > levels[2])
        #expect(output[9 * 4] < levels[9])
        #expect(output[0] == 0 && output[(levels.count - 1) * 4] == 255)
        #expect(Int(output[9 * 4]) - Int(output[2 * 4]) > 140, "Balancing must retain useful scene contrast")
        for index in 1..<levels.count {
            #expect(output[index * 4] >= output[(index - 1) * 4])
        }
    }

    @Test func monotoneRampsRemainNeutralWithoutNewClipping() throws {
        for bias in [1.0, 2.0, 0.5] {
            let source = try fixture { x, _ in
                let value = UInt8((255 * pow(Double(x) / 255, bias)).rounded())
                return (value, value, value, 255)
            }
            let before = try pixels(source.image), after = try pixels(render(source).image)
            for x in 0..<source.image.width {
                let index = x * 4
                #expect(abs(Int(after[index]) - Int(after[index + 1])) <= 1)
                #expect(abs(Int(after[index]) - Int(after[index + 2])) <= 1)
                if x > 0 { #expect(after[index] >= after[index - 4]) }
                if before[index] > 0 && before[index] < 255 { #expect(after[index] > 0 && after[index] < 255) }
            }
        }
    }

    @Test func dominantBrightAndDarkScenesKeepOppositeTailsSafe() throws {
        for values: (UInt8, UInt8, Int) in [(66, 230, 51), (25, 189, 205)] {
            let source = try fixture { x, _ in
                let gray = x < values.2 ? values.0 : values.1
                return (gray, gray, gray, 255)
            }
            let output = try pixels(render(source, color: 0).image)
            #expect(output[0] >= values.0, "A small shadow subject against a bright scene must not become darker")
            #expect(output[255 * 4] <= values.1, "A small highlight in a dark scene must not become brighter")
            #expect(Int(output[255 * 4]) - Int(output[0]) > 100)
        }
    }

    @Test func progressivePreviewAnalysisKeepsEquivalentSceneDecisions() throws {
        func gray(_ x: Int) -> UInt8 {
            x < 80 ? UInt8(12 + x / 2) : x < 170 ? UInt8(100 + x - 80) : UInt8(220 + (x - 170) / 3)
        }
        let small = try fixture(width: 256, height: 128) { x, _ in
            let value = gray(x)
            return (value, value, value, 255)
        }
        let large = try fixture(width: 1024, height: 512) { x, _ in
            let value = gray(x / 4)
            return (value, value, value, 255)
        }
        let first = try NaturalBalanceAnalysis.analyze(small.image)
        let second = try NaturalBalanceAnalysis.analyze(large.image)
        #expect(zip(first.offsets, second.offsets).allSatisfy { abs($0 - $1) < 0.005 })
        #expect(abs(first.colorBoost - second.colorBoost) < 0.005)
        #expect(first.faceCount == second.faceCount)
    }

    @Test func backlitFaceFillUsesUpperImageCoordinatesAndRequiresBrightBackground() throws {
        // The subject occupies less than 20% of the image, above its midpoint.
        // Vision's lower-left rectangle must map to top-down rows 12..<52;
        // using its y coordinate directly would instead sample bright rows below.
        let upperFace = CGRect(x: 48.0 / 256, y: 76.0 / 128, width: 64.0 / 256, height: 40.0 / 128)
        let lowerRegion = CGRect(x: 48.0 / 256, y: 12.0 / 128, width: 64.0 / 256, height: 40.0 / 128)
        func curve(_ analysis: NaturalBalanceAnalysis) -> AutoToneCurve {
            AutoToneCurve(ordinates: zip(AutoToneCurve.abscissae, analysis.offsets).map { $0 + $1 })
        }
        for face: UInt8 in [80, 110, 120] {
            let backlit = try fixture(width: 256, height: 128) { x, y in
                let gray: UInt8 = (48..<112).contains(x) && (12..<52).contains(y) ? face : 230
                return (gray, gray, gray, 255)
            }
            let histogramOnly = try NaturalBalanceAnalysis.analyze(backlit.image, faceRegions: [])
            let darkFace = try NaturalBalanceAnalysis.analyze(backlit.image, faceRegions: [upperFace])
            let brightRegion = try NaturalBalanceAnalysis.analyze(backlit.image, faceRegions: [lowerRegion])
            #expect(histogramOnly.faceCount == 0 && darkFace.faceCount == 1 && brightRegion.faceCount == 1)
            #expect(darkFace.offsets[1] > histogramOnly.offsets[1])
            #expect(darkFace.offsets[2] > histogramOnly.offsets[2],
                    "A small dark face needs more fill than the global histogram detects")
            #expect(brightRegion.offsets == histogramOnly.offsets,
                    "A detected region that is already bright must not request face fill")
            let input = Double(face) / 255
            let adjusted = curve(darkFace).value(at: input)
            #expect(adjusted >= input,
                    "The interpolated correction must not darken a face between shadow and middle-tone knots")
            if face == 80 {
                #expect(darkFace.offsets[2] > histogramOnly.offsets[2] + 0.02)
                #expect(adjusted > input + 2.0 / 255, "Backlight fill should visibly open a dark face")
            }
        }

        // 32x32 pixels occupy 3.125%: both the 5th and 95th percentiles see only
        // the constant bright background. Variance must still admit recognition.
        let tinyFace = CGRect(x: 64.0 / 256, y: 80.0 / 128, width: 32.0 / 256, height: 32.0 / 128)
        for face: UInt8 in [80, 110, 120] {
            let tinyPortrait = try fixture(width: 256, height: 128) { x, y in
                let gray: UInt8 = (64..<96).contains(x) && (16..<48).contains(y) ? face : 230
                return (gray, gray, gray, 255)
            }
            let analysis = try NaturalBalanceAnalysis.analyze(tinyPortrait.image, faceRegions: [tinyFace])
            let correction = curve(analysis)
            #expect(analysis.faceCount == 1)
            #expect(!correction.isIdentity, "A small subject must not be mistaken for a flat image")
            #expect(correction.value(at: Double(face) / 255) > Double(face) / 255)
        }

        let dimScene = try fixture(width: 256, height: 128) { x, y in
            let gray: UInt8 = (48..<112).contains(x) && (12..<52).contains(y) ? 30 : 90
            return (gray, gray, gray, 255)
        }
        let dimFace = try NaturalBalanceAnalysis.analyze(dimScene.image, faceRegions: [upperFace])
        let dimBackground = try NaturalBalanceAnalysis.analyze(dimScene.image, faceRegions: [lowerRegion])
        // Keep face count equal to isolate the new bright-background gate from
        // the existing general low-key portrait restraint.
        #expect(dimFace.offsets == dimBackground.offsets,
                "Face luminance must not trigger backlight fill when the whole scene is dark")
    }

    @Test func requestedSoftwareRenderingMatchesAutomaticRendering() throws {
        let source = try fixture { x, y in
            (UInt8(12 + x * 230 / 255), UInt8(8 + x * 220 / 255), UInt8(10 + (x + y) * 210 / 286), 255)
        }
        var settings = EditSettings.neutral
        settings.naturalBalanceAmount = 70
        settings.naturalBalanceColorAmount = 50
        let automatic = try pixels(EditRenderer.render(source, settings: settings,
            session: EditRenderer.Session(lowPriority: false)).image)
        let softwareRequested = try pixels(EditRenderer.render(source, settings: settings,
            session: EditRenderer.Session(lowPriority: false, softwareRenderer: true)).image)
        let differences = zip(automatic, softwareRequested).map { abs(Int($0) - Int($1)) }
        #expect(differences.max() ?? 0 <= 3)
        #expect(Double(differences.reduce(0, +)) / Double(differences.count) < 0.3)
        // Core Image may ignore the software preference. This checks a requested
        // configuration, not proof of an independently executed CPU backend.
    }

    @Test func colorControlAddsModerateChromaAndProtectsWarmSkinColors() throws {
        let colors: [(UInt8, UInt8, UInt8)] = [(24, 24, 24), (158, 110, 79), (79, 110, 158), (235, 235, 235)]
        let source = try fixture { x, _ in
            let value = colors[x / 64]
            return (value.0, value.1, value.2, 255)
        }
        let withoutColor = try pixels(render(source, color: 0).image)
        let moderate = try pixels(render(source, color: 50).image)
        let full = try pixels(render(source, color: 100).image)
        func chroma(_ values: [UInt8], at x: Int) -> Double {
            let channels = (0..<3).map { Double(values[x * 4 + $0]) }
            return channels.max()! - channels.min()!
        }
        let blue0 = chroma(withoutColor, at: 160)
        let blue50 = chroma(moderate, at: 160)
        let blue100 = chroma(full, at: 160)
        #expect(blue50 >= blue0 && blue100 >= blue50)
        #expect(blue100 > blue0, "Color control must change restrained colors")
        #expect(blue100 <= blue0 * 1.4 + 2, "Natural color must avoid exaggerated saturation")
        let skinGain = chroma(full, at: 96) / max(1, chroma(withoutColor, at: 96))
        let blueGain = blue100 / max(1, blue0)
        #expect(skinGain <= blueGain + 0.03, "Warm skin-like hues must not receive stronger saturation than cool colors")
        for x in [16, 240] {
            #expect(abs(Int(full[x * 4]) - Int(full[x * 4 + 1])) <= 1)
            #expect(abs(Int(full[x * 4]) - Int(full[x * 4 + 2])) <= 1)
        }
    }

    @Test func alphaWideGamutAndUnclippedSaturatedSubjectsSurvive() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let colors: [(UInt8, UInt8, UInt8)] = [(30, 30, 30), (248, 12, 24), (24, 245, 32), (24, 32, 248), (230, 230, 230)]
        let source = try fixture(width: 200, height: 48, space: p3) { x, y in
            let value = colors[x / 40]
            return (value.0, value.1, value.2, y < 4 ? 0 : y < 16 ? 128 : 255)
        }
        let result = try render(source)
        #expect(result.image.width == source.image.width && result.image.height == source.image.height)
        #expect(result.image.colorSpace?.name == source.image.colorSpace?.name)
        let before = try pixels(source.image, space: p3), after = try pixels(result.image, space: p3)
        for index in stride(from: 0, to: before.count, by: 4) {
            #expect(abs(Int(before[index + 3]) - Int(after[index + 3])) <= 1)
            if before[index + 3] == 0 { #expect((0..<3).allSatisfy { after[index + $0] == 0 }) }
            if before[index + 3] == 255 {
                #expect((0..<3).allSatisfy { after[index + $0] > 0 && after[index + $0] < 255 })
            }
        }
    }

    @Test func newBalanceTakesPrecedenceAndManualExposureFollowsIt() throws {
        let source = try fixture { x, _ in
            let value: UInt8 = x < 128 ? 30 : 230
            return (value, value, value, 255)
        }
        var settings = EditSettings.neutral
        settings.naturalBalanceAmount = 70
        let expected = try pixels(EditRenderer.render(source, settings: settings).image)
        settings.autoToneAmount = 100
        #expect(try pixels(EditRenderer.render(source, settings: settings).image) == expected,
                "Legacy automatic tone must not be stacked on top of natural balance")
        settings.exposure = 0.5
        let manual = try pixels(EditRenderer.render(source, settings: settings).image)
        #expect(manual[0] > expected[0])
        #expect(manual[200 * 4] > expected[200 * 4])
    }

    @Test func strengthIsAdjustableAndRepeatedRendersAreReproducible() throws {
        let source = try fixture { x, _ in
            let value: UInt8 = x < 128 ? 30 : 230
            return (value, value, value, 255)
        }
        let gentle = try pixels(render(source, amount: 25).image)
        let full = try pixels(render(source).image)
        #expect(gentle[0] >= 30 && gentle[0] < full[0])
        #expect(gentle[200 * 4] <= 230 && gentle[200 * 4] > full[200 * 4])
        #expect(try pixels(render(source).image) == full)
    }

    @Test func cancelledAnalysisDoesNotPoisonFollowingRequest() async throws {
        let source = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NaturalBalanceAnalysisCache.shared.analysis(for: source.image)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled analysis unexpectedly succeeded") }
        catch is CancellationError { }
        _ = try NaturalBalanceAnalysisCache.shared.analysis(for: source.image)
        _ = try render(source)
    }

    @Test func analysisCacheUsesBoundedWeakSourceIdentity() throws {
        let probe = NaturalBalanceAnalysisProbe()
        let cache = NaturalBalanceAnalysisCache(maximumEntries: 2, analyze: { try probe.analyze($0) })
        let first = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        let second = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        _ = try cache.analysis(for: first.image)
        _ = try cache.analysis(for: second.image)
        _ = try cache.analysis(for: first.image)
        #expect(probe.count == 2, "Equal pixels with different image identities must remain independent")
        weak var released: CGImage?
        try autoreleasepool {
            let third = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
            released = third.image
            _ = try cache.analysis(for: third.image)
            _ = try cache.analysis(for: first.image)
            #expect(probe.count == 3)
            _ = try cache.analysis(for: second.image)
            #expect(probe.count == 4, "The least recently used live source must be evicted")
            _ = try cache.analysis(for: third.image)
            #expect(probe.count == 5, "Leave the third image cached before releasing its last external reference")
        }
        #expect(released == nil, "Analysis must not extend the decoded source lifetime")
    }

    @Test func concurrentAnalysisSharesRecognitionWhileAnotherSourceProceeds() async throws {
        let probe = NaturalBalanceAnalysisProbe(blockFirst: true)
        let cache = NaturalBalanceAnalysisCache(maximumEntries: 1, analyze: { try probe.analyze($0) })
        let first = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        let second = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
        let producer = Task.detached { try cache.analysis(for: first.image) }
        defer { probe.release() }
        try await waitUntil { probe.count == 1 }
        let shared = Task.detached { try cache.analysis(for: first.image) }
        let independent = Task.detached { try cache.analysis(for: second.image) }
        _ = try await independent.value
        #expect(probe.count == 2, "A full cache must not serialize independent source analysis")
        probe.release()
        let original = try await producer.value
        let reused = try await shared.value
        #expect(original.offsets == reused.offsets && original.faceCount == reused.faceCount)
        #expect(probe.count == 2)
    }

    @Test func cancelledWaiterKeepsSharedAnalysisAndCancelledProducerCanBeRetried() async throws {
        for cancelProducer in [false, true] {
            let probe = NaturalBalanceAnalysisProbe(blockFirst: true)
            let cache = NaturalBalanceAnalysisCache(analyze: { try probe.analyze($0) })
            let source = try fixture { x, _ in (UInt8(x), UInt8(x), UInt8(x), 255) }
            let producer = Task.detached { try cache.analysis(for: source.image) }
            defer { probe.release() }
            try await waitUntil { probe.count == 1 }
            let waiter = Task.detached { try cache.analysis(for: source.image) }
            if cancelProducer {
                producer.cancel()
                probe.release()
                do { _ = try await producer.value; Issue.record("Cancelled producer unexpectedly succeeded") }
                catch is CancellationError { }
                _ = try await waiter.value
                #expect(probe.count == 2)
            } else {
                try await Task.sleep(for: .milliseconds(25))
                waiter.cancel()
                do { _ = try await waiter.value; Issue.record("Cancelled waiter unexpectedly succeeded") }
                catch is CancellationError { }
                #expect(probe.count == 1)
                probe.release()
                _ = try await producer.value
            }
            _ = try cache.analysis(for: source.image)
            #expect(probe.count == (cancelProducer ? 2 : 1))
        }
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw NaturalBalanceAnalysisProbeError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func render(_ source: PreviewBitmap, amount: Double = 100, color: Double = 100) throws -> PreviewBitmap {
        var settings = EditSettings.neutral
        settings.naturalBalanceAmount = amount
        settings.naturalBalanceColorAmount = color
        return try EditRenderer.render(source, settings: settings)
    }

    private func fixture(width: Int = 256, height: Int = 32,
                         space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                         pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> PreviewBitmap {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                bytes += [UInt8(Int(r) * Int(a) / 255), UInt8(Int(g) * Int(a) / 255), UInt8(Int(b) * Int(a) / 255), a]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return PreviewBitmap(image: try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }

    private func pixels(_ image: CGImage, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try values.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return values
    }
}

private enum NaturalBalanceAnalysisProbeError: Error { case timeout }

private final class NaturalBalanceAnalysisProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockFirst: Bool
    private var calls = 0

    init(blockFirst: Bool = false) { self.blockFirst = blockFirst }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func release() { gate.signal() }
    func analyze(_ image: CGImage) throws -> NaturalBalanceAnalysis {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        if first && blockFirst && gate.wait(timeout: .now() + 5) == .timedOut { throw NaturalBalanceAnalysisProbeError.timeout }
        return NaturalBalanceAnalysis(offsets: Array(repeating: 0, count: 7), colorBoost: 0.1, faceCount: 1)
    }
}
